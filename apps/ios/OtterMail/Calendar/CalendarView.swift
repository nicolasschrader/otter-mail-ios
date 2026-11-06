import SwiftUI

/**
 * Every mailbox's calendar in one, as the Mac and web apps combine them, a
 * section of the home screen in the mail's place,
 * chosen from the bottom bar (whose ⌃⌄ scopes it, `CalendarScopePanel`), in the
 * phone's pages, Agenda, Day and Month (the Mac and web apps' CALENDAR_MODES
 * less Week, with the agenda of the days ahead), turned by the picker or a
 * sideways swipe that follows the finger, each page kept up between turns.
 * It follows the account's Settings › Calendar (`CalendarPreferences`).
 * Read-only here; invitations are answered in Catch up (`CatchUpView`).
 */
struct CalendarView: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /** Held by HomeView, so the events outlive switching sections. */
    let events: CalendarStore
    /** Held by HomeView too, as the bar's ⌃⌄ panel shows, hides and scopes the calendars. */
    let visibility: CalendarShown
    /** Listing the calendars to show or hide, in the events' place (the toolbar's Calendars). */
    @Binding var listing: Bool
    var onTitle: () -> Void = {}

    @State private var mode: CalendarMode = .agenda
    /** Where the pager is, under the finger; `mode` is the page it last came to rest on. */
    @State private var page: CalendarMode?
    @State private var anchor = Date.now
    @State private var picked: Date?
    @State private var now = Date.now
    @State private var path: [CalendarEvent] = []

    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }

    private var calendars: [EventCalendar] { sources.flatMap { events.lists[$0.email] ?? [] } }

    /** The mailbox scoped to, else every calendar unless some are turned off: then how many of them show. */
    private var shownTitle: String {
        if let account = visibility.account, let mailbox = sources.first(where: { $0.email == account }) {
            return mailbox.displayName
        }
        let all = calendars
        let shown = all.count(where: { visibility.isShown($0) })
        return shown == all.count ? "All calendars" : "\(shown) of \(all.count)"
    }
    private var sources: [Mailbox] { CalendarStore.sources(store.shownMailboxes) }
    private var denied: [Mailbox] { sources.filter { events.denied.contains($0.email) } }
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
                                    PlaceTitle(title: "Calendars")
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back to Calendar")
                        } else {
                            Button(action: onTitle) {
                                PlaceTitle(title: "Calendar", scope: shownTitle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Lists the calendars")
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    // One item alone, so a long title never folds it into a ⋯ menu; Today is in the pages' own header.
                    if !listing, !sources.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Calendars", systemImage: "calendar") { listing = true }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                .navigationDestination(for: CalendarEvent.self) { event in
                    EventView(event: event, dates: dates, color: color(event.calendar))
                }
        }
    }

    @ViewBuilder private var content: some View {
        if !sources.isEmpty {
            Group {
                if listing {
                    calendarList
                } else {
                    pages
                }
            }
            .task(id: windows) { await load() }
            .onChange(of: sources.map(\.email)) { _, shown in
                if let account = visibility.account, !shown.contains(account) { visibility.account = nil }
                Task { await load() }
            }
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
            // The places bar offers Calendar only where there is one; this is for the last such mailbox going away.
            ContentUnavailableView(
                "No calendar",
                systemImage: "calendar",
                description: Text("None of your mailboxes has one Otter Mail can read.")
            )
            .foregroundStyle(palette.muted)
        }
    }

    /** calendar-sidebar.tsx's list: a section per mailbox, each calendar's switch, or the mailbox's sign-in when it needs one. */
    private var calendarList: some View {
        List {
            ForEach(CalendarStore.grouped(sources, lists: events.lists), id: \.mailbox.email) { group in
                Section {
                    if events.denied.contains(group.mailbox.email) {
                        HStack(spacing: 12) {
                            Text("Sign in again to show this calendar")
                                .font(.inter(.subheadline))
                                .foregroundStyle(palette.muted)
                            Spacer(minLength: 8)
                            SignInAgainButton(mailbox: group.mailbox, title: "Sign in again")
                                .buttonStyle(.glass)
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                        .listRowBackground(palette.canvas)
                        .listRowSeparator(.hidden)
                    } else if group.calendars.isEmpty, events.state == .loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(group.calendars, id: \.key) { calendar in
                        Toggle(isOn: Binding(
                            get: { visibility.isShown(calendar) },
                            set: { visibility.setShown(calendar, show: $0) }
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
                    Text(group.mailbox.displayName)
                        .font(.inter(.footnote).weight(.medium))
                        .foregroundStyle(palette.muted)
                        .frame(minHeight: 36)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
                .textCase(nil)
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
     * sets off (the picked day, the agenda's anchor, a load)
     * runs under the finger.
     */
    private var pages: some View {
        VStack(spacing: 0) {
            ModePicker(page: $page, settled: mode, select: select)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(CalendarMode.phone) { option in
                        calendarPage(option)
                            .equatable()
                            // The pages beside the one in front stay mounted: out of VoiceOver's (and UI tests') reach.
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("calendar-page-\(option.rawValue)")
                            .accessibilityHidden(option != mode)
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

    private func calendarPage(_ mode: CalendarMode) -> CalendarPage {
        CalendarPage(
            mode: mode,
            mailboxes: sources,
            denied: denied,
            found: events.events(in: window(mode)),
            state: events.state,
            anchor: anchor,
            picked: picked,
            now: now,
            shown: visibility.scoped(calendars),
            onStep: { by in
                anchor = dates.step(mode, anchor, by: by)
                picked = nil
            },
            onToday: {
                anchor = .now
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
            EventStyle.hex(for: calendar, mailbox: store.mailbox(calendar.account), preferences: preferences.calendar),
            over: palette.textRGB
        )
    }

    /** The page in front first, then the others and Day's and Month's either side, ahead of a turn. */
    private func load(force: Bool = false) async {
        let sources = self.sources
        guard !sources.isEmpty else { return }
        // To the minute, so a load doesn't redraw every page for a clock that hasn't moved.
        if !dates.calendar.isDate(now, equalTo: .now, toGranularity: .minute) { now = .now }
        let front = CalendarMode.phone.contains(mode) ? mode : .agenda
        await events.load(
            window(front), sources: sources, demo: store.isDemo, google: session.google, dates: dates, force: force
        )
        guard !Task.isCancelled else { return }
        let others = CalendarMode.phone.filter { $0 != front }.map(window)
        let neighbours = [CalendarMode.day, .month].flatMap { mode -> [EventWindow] in
            [-1, 1].map { dates.window(mode, anchor: dates.step(mode, anchor, by: $0)) }
        }
        await events.prefetch(others + neighbours, sources: sources, demo: store.isDemo, google: session.google, dates: dates)
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
