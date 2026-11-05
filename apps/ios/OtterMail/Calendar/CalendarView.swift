import SwiftUI

/**
 * The mailbox's calendar, opened from the places bar (⌃⌄ › Calendar): the days
 * ahead, a week at a glance, or a month's grid where tapping a day lists it.
 * Read-only, as the sign-in asks only to read the calendar; answering an
 * invitation stays in the mail.
 */
struct CalendarView: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let scope: String

    @State private var events = CalendarStore()
    @State private var mode: CalendarMode = .agenda
    @State private var anchor = Date.now
    @State private var picked: Date?
    @State private var path: [CalendarEvent] = []

    private var calendar: Calendar { .current }
    private var mailbox: Mailbox? { store.mailbox(for: scope) }
    private var window: EventWindow { EventDays.window(mode, anchor: anchor, calendar: calendar) }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(palette.canvas)
                .navigationTitle("Calendar")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if mode != .agenda {
                            Button("Today") { anchor = .now; picked = nil }
                        }
                    }
                }
                .navigationDestination(for: CalendarEvent.self) { EventView(event: $0) }
        }
    }

    @ViewBuilder private var content: some View {
        if let mailbox, mailbox.capabilities.calendar {
            list(mailbox)
                .task(id: window) { await load() }
                .refreshable { await load(force: true) }
                // A sign-in finishing (the button a mailbox without calendar access shows) is reason to look again.
                .onChange(of: session.busy) { before, now in
                    if before != nil, now == nil { Task { await load(force: true) } }
                }
        } else {
            // The places bar offers Calendar only where there is one; this is for a mailbox that goes away.
            ContentUnavailableView(
                "No calendar",
                systemImage: "calendar",
                description: Text("\(mailbox?.displayName ?? "This mailbox") doesn't have one Otter Mail can read.")
            )
            .foregroundStyle(palette.muted)
        }
    }

    private func list(_ mailbox: Mailbox) -> some View {
        List {
            modes
            if mode == .week { weekStrip }
            if mode == .month { monthGrid }
            switch events.state {
            case .noAccess: noAccess(mailbox)
            case .failed(let message): failed(message)
            default: days
            }
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden, edges: .top)
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .contentMargins(.bottom, 24, for: .scrollContent)
    }

    @ViewBuilder private var days: some View {
        let shown = shownDays.filter { !$0.events.isEmpty }
        ForEach(shown) { day in
            Section {
                ForEach(day.events) { event in row(event, on: day.id) }
            } header: {
                header(day)
            }
            .textCase(nil)
        }
        if shown.isEmpty {
            if events.state == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                empty
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            mode == .agenda ? "Nothing coming up" : mode == .week ? "Nothing this week" : "Nothing on \(pickedTitle)",
            systemImage: "calendar",
            description: Text(mode == .agenda ? "The months ahead are clear." : "")
        )
        .foregroundStyle(palette.muted)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.top, 40)
    }

    private func noAccess(_ mailbox: Mailbox) -> some View {
        ContentUnavailableView {
            Label("Sign in again to show your calendar", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("\(mailbox.displayName) signed in to Google before Otter Mail asked to read its calendar.")
        } actions: {
            SignInAgainButton(mailbox: mailbox, title: "Sign in again")
                .buttonStyle(.glass)
        }
        .foregroundStyle(palette.text)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.top, 40)
    }

    private func failed(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load the calendar", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await load(force: true) } }
                .buttonStyle(.glass)
        }
        .foregroundStyle(palette.text)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.top, 40)
    }

    private var modes: some View {
        HStack(spacing: 4) {
            ForEach(CalendarMode.allCases) { option in
                Button {
                    mode = option
                    picked = nil
                    // The agenda is the days ahead and has no way to move: it starts today.
                    if option == .agenda { anchor = .now }
                } label: {
                    Text(option.title)
                        .font(.inter(.subheadline).weight(.medium))
                        .foregroundStyle(mode == option ? palette.text : palette.muted)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(mode == option ? palette.text.opacity(0.08) : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(palette.canvas)
    }

    private var weekStrip: some View {
        let grouped = byDay
        return VStack(spacing: 8) {
            period(weekTitle, by: .weekOfYear)
            HStack(spacing: 2) {
                ForEach(EventDays.days(in: window, calendar: calendar), id: \.self) { day in
                    DayCell(day: day, events: grouped[day] ?? [], weekday: true, today: calendar.isDateInToday(day))
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(palette.canvas)
    }

    private var monthGrid: some View {
        let grouped = byDay
        return VStack(spacing: 8) {
            period(monthTitle, by: .month)
            HStack(spacing: 2) {
                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.inter(.caption2))
                        .foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(EventDays.days(in: window, calendar: calendar), id: \.self) { day in
                    DayCell(
                        day: day,
                        events: grouped[day] ?? [],
                        inMonth: calendar.isDate(day, equalTo: anchor, toGranularity: .month),
                        selected: calendar.isDate(day, inSameDayAs: pickedDay),
                        today: calendar.isDateInToday(day),
                        action: { picked = day }
                    )
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(palette.canvas)
    }

    private func period(_ title: String, by component: Calendar.Component) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.inter(.headline))
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            stepper(-1, by: component, symbol: "chevron.left", title: "Previous")
            stepper(1, by: component, symbol: "chevron.right", title: "Next")
        }
        .padding(.horizontal, 8)
    }

    private func stepper(_ step: Int, by component: Calendar.Component, symbol: String, title: String) -> some View {
        Button {
            guard let moved = calendar.date(byAdding: component, value: step, to: anchor) else { return }
            anchor = moved
            picked = nil
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.muted)
                .frame(width: 40, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func header(_ day: EventDay) -> some View {
        HStack(spacing: 6) {
            Text(day.title).fontWeight(.medium).foregroundStyle(palette.text)
            Spacer()
            Text("\(day.events.count)").monospacedDigit()
        }
        .font(.inter(.footnote))
        .foregroundStyle(palette.muted)
        .frame(minHeight: 36)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }

    private func row(_ event: CalendarEvent, on day: Date) -> some View {
        NavigationLink(value: event) {
            EventRow(event: event, day: day, calendar: calendar)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .listRowBackground(palette.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    private var byDay: [Date: [CalendarEvent]] {
        EventDays.byDay(events.events, in: window, calendar: calendar)
    }

    private var shownDays: [EventDay] {
        switch mode {
        case .agenda, .week:
            EventDays.group(events.events, in: window, calendar: calendar)
        case .month:
            [EventDay(id: pickedDay, events: EventDays.events(events.events, on: pickedDay, calendar: calendar))]
        }
    }

    /** The day the month's grid is listing: the one tapped, else today, else the month's first. */
    private var pickedDay: Date {
        if let picked, picked >= window.from, picked < window.to { return picked }
        let today = calendar.startOfDay(for: .now)
        let month = EventDays.startOfMonth(anchor, calendar: calendar)
        return calendar.isDate(today, equalTo: month, toGranularity: .month) ? today : month
    }

    private var pickedTitle: String {
        EventDay(id: pickedDay, events: []).title
    }

    private var weekTitle: String {
        let last = calendar.date(byAdding: .day, value: 6, to: window.from) ?? window.from
        let first = calendar.isDate(window.from, equalTo: last, toGranularity: .month)
            ? window.from.formatted(.dateTime.day())
            : window.from.formatted(.dateTime.day().month(.abbreviated))
        return "\(first) – \(last.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private var monthTitle: String {
        let month = EventDays.startOfMonth(anchor, calendar: calendar)
        return calendar.isDate(month, equalTo: .now, toGranularity: .year)
            ? month.formatted(.dateTime.month(.wide))
            : month.formatted(.dateTime.month(.wide).year())
    }

    /** The region's week: Monday first here, Sunday first there. */
    private var weekdayNames: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % symbols.count] }
    }

    private func load(force: Bool = false) async {
        guard let mailbox else { return }
        await events.load(window, mailbox: mailbox, demo: store.isDemo, google: session.google, force: force)
    }
}
