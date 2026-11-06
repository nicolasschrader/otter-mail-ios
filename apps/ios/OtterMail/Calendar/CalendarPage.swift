import SwiftUI

/**
 * One of the calendar's pages, Agenda, Day or Month, drawn from what it's
 * handed rather than from the screen around it. `==` holds only what its own
 * page shows, so a turn settling, the month's pick or another page's window
 * landing leaves the others undrawn (CalendarView applies `.equatable()`).
 */
struct CalendarPage: View, Equatable {
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette

    let mode: CalendarMode
    /** The mailboxes read from (`CalendarStore.sources`), for their colors and names. */
    let mailboxes: [Mailbox]
    /** Those whose sign-in doesn't cover the calendar, while others' events still show. */
    let denied: [Mailbox]
    /** The page's window's events, nil until fetched. */
    let found: [CalendarEvent]?
    let state: CalendarStore.State
    let anchor: Date
    let picked: Date?
    let now: Date
    let shown: [String: Bool]
    var onStep: (Int) -> Void = { _ in }
    var onToday: () -> Void = {}
    var onPick: (Date) -> Void = { _ in }
    var onRetry: () -> Void = {}
    var onRefresh: () async -> Void = {}

    static func == (a: Self, b: Self) -> Bool {
        a.mode == b.mode && looks(a.mailboxes) == looks(b.mailboxes) && looks(a.denied) == looks(b.denied)
            && a.found == b.found && a.state == b.state && a.now == b.now
            && a.shown == b.shown
            // The agenda runs from today whatever the chevrons did; only the month lists a picked day.
            && (a.mode == .agenda || a.anchor == b.anchor)
            && (a.mode != .month || a.picked == b.picked)
    }

    /** What a page draws of a mailbox: not its labels or counts, which change under it. */
    private static func looks(_ mailboxes: [Mailbox]) -> [[String]] {
        mailboxes.map { [$0.email, $0.displayName, $0.color] }
    }

    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }

    var body: some View {
        List {
            if mode == .day { periodRow }
            if mode == .week { weekStrip }
            if mode == .month { monthGrid }
            switch state {
            case .noAccess: noAccess
            case .failed(let message) where found == nil: failed(message)
            default:
                ForEach(denied) { signInRow($0) }
                listed
            }
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden, edges: .top)
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .refreshable { await onRefresh() }
    }

    private func days(_ mode: CalendarMode) -> [Date] {
        dates.visibleDays(mode, anchor, weekends: dates.showsWeekends(mode))
    }

    @ViewBuilder private var listed: some View {
        let withEvents = shownDays(shownEvents).filter { !$0.events.isEmpty }
        ForEach(withEvents) { day in
            Section {
                ForEach(day.events) { event in row(event, on: day.id) }
            } header: {
                header(day)
            }
            .textCase(nil)
        }
        if withEvents.isEmpty {
            if found == nil {
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
        case .day: "Nothing on \(dates.heading(days(.day).first ?? anchor, now: now))"
        case .month: "Nothing on \(dates.heading(pickedDay, now: now))"
        }
    }

    private var noAccess: some View {
        ContentUnavailableView {
            Label("Sign in again to show your calendar", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("\(denied.map(\.displayName).formatted(.list(type: .and))) signed in to Google before Otter Mail asked to read its calendar.")
        } actions: {
            ForEach(denied) { mailbox in
                SignInAgainButton(mailbox: mailbox, title: denied.count > 1 ? "Sign in \(mailbox.displayName) again" : "Sign in again")
                    .buttonStyle(.glass)
            }
        }
        .foregroundStyle(palette.text)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.top, 40)
    }

    /** web's AllowCalendarAccess: one mailbox's calendar missing, the rest shown. */
    private func signInRow(_ mailbox: Mailbox) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(palette.muted)
            Text("Sign in again to show \(mailbox.displayName)'s calendar")
                .font(.inter(.footnote))
                .foregroundStyle(palette.muted)
                .lineLimit(2)
            Spacer(minLength: 8)
            SignInAgainButton(mailbox: mailbox, title: "Sign in")
                .buttonStyle(.plain)
                .foregroundStyle(palette.text)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(palette.canvas)
    }

    private func failed(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load the calendar", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: onRetry)
                .buttonStyle(.glass)
        }
        .foregroundStyle(palette.text)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.top, 40)
    }

    private var periodRow: some View {
        period
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(palette.canvas)
    }

    private var weekStrip: some View {
        let days = self.days(.week)
        let grouped = byDay(days)
        return VStack(spacing: 8) {
            period
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
        let dates = self.dates
        let days = self.days(.month)
        let columns = dates.showsWeekends(.month) ? 7 : 5
        let grouped = byDay(days)
        let pickedDay = self.pickedDay
        return VStack(spacing: 8) {
            period
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
                        action: { onPick(day) }
                    )
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(palette.canvas)
    }

    private var period: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.inter(.headline))
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            Button("Today", action: onToday)
                .font(.inter(.subheadline).weight(.medium))
                .foregroundStyle(palette.text)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: 36)
                .contentShape(.rect)
            stepper(-1, symbol: "chevron.left", title: "Previous")
            stepper(1, symbol: "chevron.right", title: "Next")
        }
        .padding(.horizontal, 8)
    }

    private func stepper(_ by: Int, symbol: String, title: String) -> some View {
        Button {
            onStep(by)
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

    /** The events of the calendars shown (`CalendarShown`) that the account's `calendar:show-declined` allows, as calendar-view.tsx filters them. */
    private var shownEvents: [CalendarEvent] {
        let visible = CalendarShown.visible(found ?? [], shown: shown)
        return preferences.calendar.showDeclined ? visible : visible.filter { $0.response != .declined }
    }

    private func byDay(_ days: [Date]) -> [Date: [CalendarEvent]] {
        EventDays.byDay(shownEvents, days: days, dates: dates)
    }

    private func shownDays(_ shown: [CalendarEvent]) -> [EventDay] {
        switch mode {
        case .agenda:
            return EventDays.agenda(shown, from: dates.startOfDay(now), now: now, dates: dates)
        case .day:
            let day = days(.day).first ?? anchor
            return [EventDay(id: day, events: EventDays.events(shown, on: day, dates: dates))]
        case .week:
            return EventDays.grouped(shown, days: days(.week), dates: dates)
        case .month:
            return [EventDay(id: pickedDay, events: EventDays.events(shown, on: pickedDay, dates: dates))]
        }
    }

    /** The day the month's grid is listing: the one tapped, else today, else the month's first. */
    private var pickedDay: Date {
        let window = dates.window(.month, anchor: anchor)
        if let picked, picked >= window.from, picked < window.to { return picked }
        let today = dates.startOfDay(now)
        let month = dates.startOfMonth(anchor)
        let chosen = dates.calendar.isDate(today, equalTo: month, toGranularity: .month) ? today : month
        // With weekends hidden the grid has no weekend cell to list, so the next weekday leads.
        return dates.stepDays(chosen, 0, weekends: dates.showsWeekends(.month))
    }

    /** As CalendarTitle writes it: the day itself, else the month the week sits in. */
    private var title: String {
        let first = days(mode).first ?? anchor
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
            EventStyle.hex(for: calendar, mailbox: mailboxes.first { $0.email == calendar.account }, preferences: preferences.calendar),
            over: palette.textRGB
        )
    }
}
