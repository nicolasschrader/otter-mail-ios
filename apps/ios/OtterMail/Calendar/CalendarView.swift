import SwiftUI

/**
 * The mailbox's calendar, a section of the home screen in the mail's place,
 * chosen from the bottom bar or the places bar (⌃⌄ › Calendar), in the
 * phone's pages, Agenda, Day and Month (the Mac and web apps' CALENDAR_MODES
 * less Week, with the agenda of the days ahead), turned by the picker or a
 * sideways swipe that follows the finger, each page kept up between turns.
 * It follows the account's Settings › Calendar (`CalendarPreferences`).
 * Read-only, as the sign-in asks only to read the calendar; answering an
 * invitation stays in the mail.
 */
struct CalendarView: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let scope: String
    /** Held by HomeView, so the events outlive switching sections. */
    let events: CalendarStore
    var onTitle: () -> Void = {}

    @State private var mode: CalendarMode = .agenda
    /** Where the pager is, under the finger; `mode` is the page it last came to rest on. */
    @State private var page: CalendarMode?
    @State private var anchor = Date.now
    @State private var picked: Date?
    @State private var now = Date.now
    @State private var path: [CalendarEvent] = []
    @State private var visibility = CalendarShown()
    /** Listing the calendars to show or hide, in the events' place. */
    @State private var listing = false

    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }
    private var mailbox: Mailbox? { store.mailbox(for: scope) }
    /** Every page's window, so turning one doesn't wait on a fetch. */
    private var windows: [EventWindow] { CalendarMode.phone.map(window) }

    /** The agenda is the days ahead from today; Day and Month share the anchor their chevrons move. */
    private func window(_ mode: CalendarMode) -> EventWindow {
        dates.window(mode, anchor: mode == .agenda ? now : anchor)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(palette.canvas)
                .navigationTitle("Calendar")
                .toolbarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if listing {
                            Button { listing = false } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(palette.text)
                                    PlaceTitle(title: "Calendars", scope: mailbox?.displayName ?? "")
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back to Calendar")
                        } else {
                            Button(action: onTitle) {
                                PlaceTitle(title: "Calendar", scope: mailbox?.displayName ?? "")
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows every place")
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    if !listing, mailbox?.capabilities.calendar == true {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if mode != .agenda {
                                Button("Today") { anchor = .now; picked = nil }
                            }
                            Button("Calendars", systemImage: "calendar") { listing = true }
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
            Group {
                if listing {
                    calendarList(mailbox)
                } else {
                    pages(mailbox)
                }
            }
            .task(id: windows) { await load() }
            // Runs once a turn has come to rest (`settle`), never under the finger.
            .onChange(of: mode) {
                picked = nil
                // The agenda is the days ahead and has no way to move: it starts today.
                if mode == .agenda, !dates.sameDay(anchor, .now) { anchor = .now }
                // A page whose prefetch failed asks again once it's turned to.
                if events.events(in: window(mode)) == nil { Task { await load() } }
                #if DEBUG
                let started = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async {
                    print("calendar: \(mode.rawValue) drawn in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000))ms")
                }
                #endif
            }
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

    private func calendarList(_ mailbox: Mailbox) -> some View {
        List {
            Section {
                ForEach(events.calendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { visibility.isShown(calendar, mailbox: mailbox.email) },
                        set: { visibility.setShown(calendar, mailbox: mailbox.email, show: $0) }
                    )) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(color(calendar))
                                .frame(width: 10, height: 10)
                            Text(calendar.name)
                                .font(.inter(.body))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                    .listRowBackground(palette.canvas)
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(mailbox.displayName)
                    .font(.inter(.footnote).weight(.medium))
                    .foregroundStyle(palette.muted)
                    .frame(minHeight: 36)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            .textCase(nil)
            if events.calendars.isEmpty {
                if events.state == .loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView("No calendars", systemImage: "calendar")
                        .foregroundStyle(palette.muted)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .padding(.top, 40)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .contentMargins(.bottom, 24, for: .scrollContent)
    }

    /**
     * Agenda, Day and Month side by side in a paging ScrollView, the pager
     * owning sideways drags and each page's list its own scrolling. The pages
     * stay mounted, so turning one draws what is already there, and `mode`
     * follows `page` only once the scroll has come to rest: nothing the turn
     * sets off (the picked day, the agenda's anchor, a load, the Today button)
     * runs under the finger.
     */
    private func pages(_ mailbox: Mailbox) -> some View {
        VStack(spacing: 0) {
            ModePicker(page: $page, settled: mode, select: select)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(CalendarMode.phone) { option in
                        calendarPage(mailbox, option)
                            .equatable()
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(option)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            .onScrollPhaseChange { _, phase in
                if phase == .idle { settle() }
            }
            .onAppear { page = mode }
            .background(palette.canvas)
        }
    }

    private func calendarPage(_ mailbox: Mailbox, _ mode: CalendarMode) -> CalendarPage {
        CalendarPage(
            mode: mode,
            mailbox: mailbox,
            found: events.events(in: window(mode)),
            state: events.state,
            anchor: anchor,
            picked: picked,
            now: now,
            shown: visibility.shown,
            onStep: { by in
                anchor = dates.step(mode, anchor, by: by)
                picked = nil
            },
            onPick: { picked = $0 },
            onRetry: { Task { await load(force: true) } },
            onRefresh: { await load(force: true) }
        )
    }

    /** The picker scrolls the pager, animating only the scroll; `mode` follows once it lands. */
    private func select(_ option: CalendarMode) {
        guard option != page else { return }
        if reduceMotion {
            page = option
            settle()
        } else {
            withAnimation(.smooth(duration: 0.3)) { page = option } completion: { settle() }
        }
    }

    private func settle() {
        if let landed = mode.settling(on: page) { mode = landed }
    }

    private func color(_ calendar: EventCalendar) -> Color {
        EventStyle.legible(
            EventStyle.hex(for: calendar, mailbox: mailbox, preferences: preferences.calendar),
            over: palette.textRGB
        )
    }

    /** The page in front first, then the others and Day's and Month's either side, ahead of a turn. */
    private func load(force: Bool = false) async {
        guard let mailbox else { return }
        // To the minute, so a load doesn't redraw every page for a clock that hasn't moved.
        if !dates.calendar.isDate(now, equalTo: .now, toGranularity: .minute) { now = .now }
        let front = CalendarMode.phone.contains(mode) ? mode : .agenda
        await events.load(
            window(front), mailbox: mailbox, demo: store.isDemo, google: session.google, dates: dates, force: force
        )
        guard !Task.isCancelled else { return }
        let others = CalendarMode.phone.filter { $0 != front }.map(window)
        let neighbours = [CalendarMode.day, .month].flatMap { mode -> [EventWindow] in
            [-1, 1].map { dates.window(mode, anchor: dates.step(mode, anchor, by: $0)) }
        }
        await events.prefetch(others + neighbours, mailbox: mailbox, demo: store.isDemo, google: session.google, dates: dates)
    }
}

/** Agenda, Day, Month: the pager's own position lit, so it follows the finger without redrawing the screen. */
private struct ModePicker: View {
    @Environment(\.palette) private var palette
    @Binding var page: CalendarMode?
    let settled: CalendarMode
    let select: (CalendarMode) -> Void

    var body: some View {
        let current = page ?? settled
        HStack(spacing: 4) {
            ForEach(CalendarMode.phone) { option in
                Button {
                    select(option)
                } label: {
                    Text(option.title)
                        .font(.inter(.subheadline).weight(.medium))
                        .foregroundStyle(current == option ? palette.text : palette.muted)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(current == option ? palette.text.opacity(0.08) : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current == option ? .isSelected : [])
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
    }
}
