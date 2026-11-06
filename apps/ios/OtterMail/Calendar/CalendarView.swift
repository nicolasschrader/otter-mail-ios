import SwiftUI

/**
 * The mailbox's calendar, opened full screen from the inbox's toolbar or the
 * places bar (⌃⌄ › Calendar), in the
 * Mac and web apps' modes (CALENDAR_MODES: Day, Week, Month) and the agenda of
 * the days ahead. It follows the account's Settings › Calendar
 * (`CalendarPreferences`). Read-only, as the sign-in asks only to read the
 * calendar; answering an invitation stays in the mail.
 */
struct CalendarView: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let scope: String

    @State private var events = CalendarStore()
    @State private var mode: CalendarMode = .agenda
    @State private var anchor = Date.now
    @State private var picked: Date?
    @State private var now = Date.now
    @State private var path: [CalendarEvent] = []

    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }
    private var mailbox: Mailbox? { store.mailbox(for: scope) }
    private var window: EventWindow { dates.window(mode, anchor: anchor) }
    private var weekends: Bool { dates.showsWeekends(mode) }
    private var days: [Date] { dates.visibleDays(mode, anchor, weekends: weekends) }
    private var columns: Int { weekends ? 7 : 5 }

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
                .navigationDestination(for: CalendarEvent.self) { event in
                    EventView(event: event, dates: dates, color: color(event.calendar))
                }
        }
    }

    @ViewBuilder private var content: some View {
        if let mailbox, mailbox.capabilities.calendar {
            list(mailbox)
                .task(id: window) { await load() }
                .refreshable { await load(force: true) }
                // A sign-in finishing (the button a mailbox without calendar access shows) is reason to look again.
                .onChange(of: session.busy) { before, current in
                    if before != nil, current == nil { Task { await load(force: true) } }
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
            if mode == .day { periodRow }
            if mode == .week { weekStrip }
            if mode == .month { monthGrid }
            switch events.state {
            case .noAccess: noAccess(mailbox)
            case .failed(let message): failed(message)
            default: listed
            }
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden, edges: .top)
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .contentMargins(.bottom, 24, for: .scrollContent)
    }

    @ViewBuilder private var listed: some View {
        let withEvents = shownDays.filter { !$0.events.isEmpty }
        ForEach(withEvents) { day in
            Section {
                ForEach(day.events) { event in row(event, on: day.id) }
            } header: {
                header(day)
            }
            .textCase(nil)
        }
        if withEvents.isEmpty {
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
            emptyTitle,
            systemImage: "calendar",
            description: Text(mode == .agenda ? "The months ahead are clear." : "")
        )
        .foregroundStyle(palette.muted)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.top, 40)
    }

    private var emptyTitle: String {
        switch mode {
        case .agenda: "Nothing coming up"
        case .week: "Nothing this week"
        case .day: "Nothing on \(dates.heading(days.first ?? anchor, now: now))"
        case .month: "Nothing on \(dates.heading(pickedDay, now: now))"
        }
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
                        .padding(.horizontal, 14)
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

    private var periodRow: some View {
        period(title)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(palette.canvas)
    }

    private var weekStrip: some View {
        let grouped = byDay
        return VStack(spacing: 8) {
            period(title)
            HStack(spacing: 2) {
                ForEach(days, id: \.self) { day in
                    let on = grouped[day] ?? []
                    DayCell(
                        day: day,
                        dots: dots(on),
                        count: on.count,
                        weekday: dates.weekdayShort(day),
                        today: dates.sameDay(day, now)
                    )
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
            period(title)
            HStack(spacing: 2) {
                ForEach(days.prefix(columns), id: \.self) { day in
                    Text(dates.weekdayShort(day))
                        .font(.inter(.caption2))
                        .foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                ForEach(days, id: \.self) { day in
                    let on = grouped[day] ?? []
                    DayCell(
                        day: day,
                        dots: dots(on),
                        count: on.count,
                        inMonth: dates.calendar.isDate(day, equalTo: anchor, toGranularity: .month),
                        selected: dates.sameDay(day, pickedDay),
                        today: dates.sameDay(day, now),
                        action: { picked = day }
                    )
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(palette.canvas)
    }

    private func period(_ title: String) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.inter(.headline))
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            stepper(-1, symbol: "chevron.left", title: "Previous")
            stepper(1, symbol: "chevron.right", title: "Next")
        }
        .padding(.horizontal, 8)
    }

    private func stepper(_ by: Int, symbol: String, title: String) -> some View {
        Button {
            anchor = dates.step(mode, anchor, by: by)
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
            Text(dates.heading(day.id, now: now)).fontWeight(.medium).foregroundStyle(palette.text)
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
            EventRow(event: event, day: day, dates: dates, color: color(event.calendar))
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .listRowBackground(palette.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    /** What the account's `calendar:show-declined` allows, as calendar-view.tsx filters it. */
    private var shown: [CalendarEvent] {
        preferences.calendar.showDeclined ? events.events : events.events.filter { $0.response != .declined }
    }

    private var byDay: [Date: [CalendarEvent]] {
        EventDays.byDay(shown, days: days, dates: dates)
    }

    private var shownDays: [EventDay] {
        switch mode {
        case .agenda:
            EventDays.agenda(shown, from: dates.startOfDay(now), now: now, dates: dates)
        case .day:
            [EventDay(id: days.first ?? anchor, events: EventDays.events(shown, on: days.first ?? anchor, dates: dates))]
        case .week:
            EventDays.grouped(shown, days: days, dates: dates)
        case .month:
            [EventDay(id: pickedDay, events: EventDays.events(shown, on: pickedDay, dates: dates))]
        }
    }

    /** The day the month's grid is listing: the one tapped, else today, else the month's first. */
    private var pickedDay: Date {
        if let picked, picked >= window.from, picked < window.to { return picked }
        let today = dates.startOfDay(now)
        let month = dates.startOfMonth(anchor)
        let chosen = dates.calendar.isDate(today, equalTo: month, toGranularity: .month) ? today : month
        // With weekends hidden the grid has no weekend cell to list, so the next weekday leads.
        return dates.stepDays(chosen, 0, weekends: weekends)
    }

    /** As CalendarTitle writes it: the day itself, else the month the week sits in. */
    private var title: String {
        let first = days.first ?? anchor
        switch mode {
        case .day: return "\(dates.dayTitle(first)) · \(dates.weekdayLong(first))"
        case .week: return dates.monthTitle(dates.addDays(first, 3))
        default: return dates.monthTitle(anchor)
        }
    }

    private func dots(_ onDay: [CalendarEvent]) -> [Color] {
        onDay.prefix(3).map { color($0.calendar) }
    }

    private func color(_ calendar: EventCalendar) -> Color {
        EventStyle.legible(
            EventStyle.hex(for: calendar, mailbox: mailbox, preferences: preferences.calendar),
            over: palette.textRGB
        )
    }

    private func load(force: Bool = false) async {
        guard let mailbox else { return }
        now = .now
        await events.load(
            window, mailbox: mailbox, demo: store.isDemo, google: session.google, dates: dates, force: force
        )
    }
}
