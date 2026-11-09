import Foundation
import Observation

/**
 * What the calendar screen renders from: every calendar of every mailbox that
 * has one, merged as the Mac and web apps merge them (calendar-view.tsx's
 * calendarAccounts and useCalendarLists), and their events kept per window as
 * React Query keeps them (`useCalendarEvents`): a window shown before is shown
 * again at once, after a restart too (`CalendarCache`), and asked of Google
 * again in the background once it's older than `freshFor`. HomeView holds it,
 * so it outlives switching to Mail and back. Google Calendar for a Gmail mailbox, the pretend one in the demo. A
 * mailbox signed in from before the app asked for calendar access is `denied`,
 * and the others still load; only when every one is does the screen end in
 * `noAccess`, where it offers signing in again (core's NoCalendarAccess).
 */
@Observable
final class CalendarStore {
    enum State: Equatable {
        case loading, ready, noAccess
        case failed(String)
    }

    /** `staleTime` in apps/web/src/main/calendar/api.ts. */
    static let freshFor: TimeInterval = 30

    static func isFresh(_ loadedAt: Date?, now: Date = .now) -> Bool {
        guard let loadedAt else { return false }
        return now.timeIntervalSince(loadedAt) < freshFor
    }

    private(set) var state: State = .ready
    /** Each mailbox's calendars, by its address. */
    private(set) var lists: [String: [EventCalendar]] = [:]
    /** The mailboxes whose sign-in doesn't cover the calendar, by address. */
    private(set) var denied: Set<String> = []
    /** Observed, so every page the screen keeps up draws its own window as soon as it lands. */
    private var cache: [EventWindow: [CalendarEvent]] = [:]
    /** Each window's events by mailbox, so one mailbox failing a refresh keeps what it had. */
    @ObservationIgnored private var parts: [EventWindow: [String: [CalendarEvent]]] = [:]
    @ObservationIgnored private var loadedAt: [EventWindow: Date] = [:]
    /** When each mailbox's part of a window was last fetched, kept on disk, so the newest saved copy of an event wins. */
    @ObservationIgnored private var fetchedAt: [EventWindow: [String: Date]] = [:]
    @ObservationIgnored private var accounts: [String] = []
    /** Mailboxes whose calendar list is asked for again on their next fetch. */
    @ObservationIgnored private var stale: Set<String> = []
    @ObservationIgnored private var generation = 0
    /** The demo's events made, changed and deleted, as its pretend events are made again on every load. */
    @ObservationIgnored private var demoEdits = DemoEdits()
    /** The demo's answers, for the same reason. */
    @ObservationIgnored private var demoAnswers: [String: CalendarEvent.Response] = [:]
    /** Task links Google answered for with nothing, or whose event was deleted here, by `TaskEvent.key`; kept across restarts. */
    private var gone: Set<String> {
        didSet { if gone != oldValue { defaults.set(gone.sorted(), forKey: Self.goneKey) } }
    }
    @ObservationIgnored private let defaults: UserDefaults
    private static let goneKey = "calendar.goneLinks"
    @ObservationIgnored private let disk: CalendarCache
    /** The demo's pretend events are made again on every load, so they aren't kept on disk. */
    @ObservationIgnored private var demo = false
    /** The windows read back from disk, that a window not saved itself is shown from. */
    @ObservationIgnored private var restored: Set<EventWindow> = []
    /** Where the phone is, the zone the events in memory are drawn in. */
    @ObservationIgnored private var zone = TimeZone.current
    /** Restored windows drawn in another zone, by that zone, and as the same days here: what their all-day events are compared with. */
    @ObservationIgnored private var zones: [EventWindow: String] = [:]
    @ObservationIgnored private var days: [EventWindow: EventWindow] = [:]
    /** How many windows each mailbox keeps on disk, the nearest to now. */
    static let savedWindows = 12
    /** The mailboxes kept on this device, as last seen; one gone from them takes its events with it. */
    @ObservationIgnored private var onDevice: Set<String>
    @ObservationIgnored private nonisolated(unsafe) var watching: (any NSObjectProtocol)?

    init(defaults: UserDefaults = .standard, cache: CalendarCache = .live) {
        self.defaults = defaults
        gone = Set(defaults.stringArray(forKey: Self.goneKey) ?? [])
        disk = cache
        onDevice = CalendarCache.mailboxes(in: defaults)
        // A mailbox removed, or the account signed out, is forgotten at once, the calendar's screens shown or not.
        // Heard as Session writes, not later on the main queue: signing out lets go of this store right after.
        watching = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self.forgetRemoved() }
            } else {
                Task { @MainActor in self.forgetRemoved() }
            }
        }
    }

    deinit {
        if let watching { NotificationCenter.default.removeObserver(watching) }
    }

    /** The mailboxes the calendar is read from: calendar-view.tsx's calendarAccounts. */
    nonisolated static func sources(_ mailboxes: [Mailbox]) -> [Mailbox] {
        mailboxes.filter { $0.capabilities.calendar && !$0.signedOut }
    }

    /** Every mailbox's part of a window as one list, the calendar's order. */
    nonisolated static func merged(_ parts: [String: [CalendarEvent]], accounts: [String]) -> [CalendarEvent] {
        EventDays.sorted(accounts.flatMap { parts[$0] ?? [] })
    }

    /** The calendar list's sections, a mailbox each, in the mailboxes' order: calendar-sidebar.tsx's groups. */
    nonisolated static func grouped(
        _ sources: [Mailbox], lists: [String: [EventCalendar]]
    ) -> [(mailbox: Mailbox, calendars: [EventCalendar])] {
        sources.map { ($0, lists[$0.email] ?? []) }
    }

    /**
     * The invitations waiting on an answer, soonest first: on a shown calendar,
     * not cancelled or over, one per series (its next occurrence), and an event
     * on two of a mailbox's calendars once, its primary one's.
     */
    nonisolated static func invites(_ events: [CalendarEvent], shown: [String: Bool], now: Date = .now) -> [CalendarEvent] {
        var seen: Set<String> = []
        return CalendarShown.visible(events, shown: shown)
            .filter { $0.response == .needsAction && $0.status != .cancelled && $0.end > now }
            .sorted { ($0.start, $0.calendar.primary ? 0 : 1) < ($1.start, $1.calendar.primary ? 0 : 1) }
            .filter { seen.insert(answerKey($0)).inserted }
    }

    /** What an answer is given to: the series for an occurrence of one (core's `allEvents`), else the event. */
    nonisolated static func answerKey(_ event: CalendarEvent) -> String {
        "\(event.calendar.account.lowercased())/\(event.seriesId ?? event.eventId)"
    }

    /** Answers an invitation, and every window's copy of it (each occurrence, for a series) says so at once. */
    func respond(_ response: CalendarEvent.Response, to event: CalendarEvent, demo: Bool, google: GoogleAuth) async throws {
        let account = event.calendar.account
        let key = Self.answerKey(event)
        if demo {
            demoAnswers[key] = response
        } else {
            let api = GoogleCalendarAPI(email: account) { [google] refresh in
                try await google.accessToken(account, force: refresh)
            }
            try await api.respond(response, to: event.seriesId ?? event.eventId, on: event.calendar.id)
        }
        for (window, byAccount) in parts {
            guard let mine = byAccount[account] else { continue }
            parts[window]?[account] = mine.map { Self.answerKey($0) == key ? Self.answered($0, response) : $0 }
            cache[window] = Self.merged(parts[window] ?? [:], accounts: accounts)
        }
        save()
    }

    /** Where an event's changes go: the demo's stand-in, or the mailbox's Google Calendar. */
    func writer(for account: String, demo: Bool, google: GoogleAuth) -> EventWriter {
        if demo { return DemoEventWriter() }
        return GoogleCalendarAPI(email: account) { [google] refresh in
            try await google.accessToken(account, force: refresh)
        }
    }

    /**
     * api.ts's create: made on the calendar picked, then in every window it falls
     * in at once; the windows are fetched again on their next load. Guests are
     * told only when there are some (none are added here).
     */
    @discardableResult
    func create(_ draft: EventDraft, with writer: EventWriter, demo: Bool = false, dates: CalendarDates = CalendarDates()) async throws -> CalendarEvent {
        if let problem = draft.problem { throw EventProblem(message: problem) }
        let made = try await writer.create(draft.input(dates: dates), on: draft.calendar, notify: false)
        if demo { demoEdits.made.append(made) }
        let account = made.calendar.account
        for (window, byAccount) in parts where Self.holds(window, made, days: days) {
            parts[window]?[account] = (byAccount[account] ?? []) + [made]
        }
        settle()
        return made
    }

    /** api.ts's update: only what changed, and the guests told when there are any. */
    @discardableResult
    func update(
        _ event: CalendarEvent, to draft: EventDraft, with writer: EventWriter, demo: Bool = false, dates: CalendarDates = CalendarDates()
    ) async throws -> CalendarEvent {
        if let problem = draft.problem { throw EventProblem(message: problem) }
        let patch = draft.patch(from: EventDraft(editing: event), dates: dates)
        guard !patch.isEmpty else { return event }
        let saved = try await writer.update(event, with: patch, notify: event.hasGuests)
        if demo { demoEdits.changed[event.id] = saved }
        replace(event, with: saved)
        return saved
    }

    /** api.ts's remove: guests told when it's yours and has some. */
    func delete(_ event: CalendarEvent, with writer: EventWriter, demo: Bool = false) async throws {
        try await writer.delete(event, notify: event.hasGuests && event.isMine)
        if demo { demoEdits.deleted.insert(event.id) }
        gone.insert(TaskEvent(event, scope: .occurrence).key)
        replace(event, with: nil)
    }

    /**
     * An event's copy in every window, changed or gone, as api.ts's replace patches the cache,
     * and in the windows it moved to, so none of them says it isn't there.
     */
    private func replace(_ event: CalendarEvent, with next: CalendarEvent?) {
        let account = event.calendar.account
        for (window, byAccount) in parts {
            guard let mine = byAccount[account] else { continue }
            var kept = mine.filter { $0.id != event.id }
            if let next, Self.holds(window, next, days: days) { kept.append(next) }
            if kept != mine { parts[window]?[account] = kept }
        }
        settle()
    }

    /** api.ts's settle: what the cache shows now, and every window asked again on its next load. */
    private func settle() {
        for (window, byAccount) in parts {
            let merged = Self.merged(byAccount, accounts: accounts)
            if cache[window] != merged { cache[window] = merged }
        }
        loadedAt.removeAll()
        save()
    }

    /** Every mailbox's calendars and its part of the windows nearest to now, written over what it had on disk. */
    private func save() {
        guard !demo else { return }
        let now = Date.now
        let nearest = parts.keys
            .sorted { abs($0.from.timeIntervalSince(now)) < abs($1.from.timeIntervalSince(now)) }
            .prefix(Self.savedWindows)
        for account in accounts {
            var windows: [EventWindow: [CalendarEvent]] = [:]
            var fetched: [EventWindow: Date] = [:]
            var drawn: [EventWindow: String] = [:]
            for window in nearest {
                windows[window] = parts[window]?[account]
                fetched[window] = fetchedAt[window]?[account]
                drawn[window] = zones[window]
            }
            disk.save(
                CalendarCache.Saved(
                    calendars: lists[account] ?? [], windows: windows, fetched: fetched, timeZone: zone.identifier, zones: drawn
                ),
                account: account
            )
        }
    }

    /**
     * A mailbox's calendars and events as they were last saved, less any deleted since, in the windows
     * not loaded yet, each up to date with the newer saved windows; its all-day events on their own
     * days where the phone is now. A window keeps the zone its days were drawn in, saved again or not,
     * so its all-day events are compared with those days. Its calendar list is asked of Google again on its next fetch.
     */
    private func restore(_ account: String, dates: CalendarDates) {
        let saved = disk.load(account)
        if lists[account] == nil, !saved.calendars.isEmpty {
            lists[account] = saved.calendars
            stale.insert(account)
        }
        let here = dates.calendar.timeZone
        let zone = TimeZone(identifier: saved.timeZone) ?? here
        var drawn: [EventWindow: (zone: String, days: EventWindow)] = [:]
        for window in saved.windows.keys {
            let there = saved.zones[window].flatMap(TimeZone.init(identifier:)) ?? zone
            if there != here { drawn[window] = (there.identifier, CalendarCache.days(window, from: there, to: dates.calendar)) }
        }
        let copies = saved.windows.map { window, events in
            (
                window: window,
                events: events.filter { !isGone($0) }.map { CalendarCache.moved($0, from: zone, to: dates.calendar) },
                fetched: saved.fetched[window] ?? .distantPast
            )
        }
        let restoredDays = drawn.mapValues { $0.days }
        for window in saved.windows.keys where parts[window]?[account] == nil {
            parts[window, default: [:]][account] = Self.newest(in: window, of: copies, days: restoredDays)
            fetchedAt[window, default: [:]][account] = saved.fetched[window]
            restored.insert(window)
            if let other = drawn[window] {
                zones[window] = other.zone
                days[window] = other.days
            }
        }
    }

    /** Whether an event falls in a window; an all-day one in a window drawn in another zone, by that window's days here. */
    nonisolated static func holds(_ window: EventWindow, _ event: CalendarEvent, days: [EventWindow: EventWindow] = [:]) -> Bool {
        let bounds = event.allDay ? days[window] ?? window : window
        return event.end > bounds.from && event.start < bounds.to
    }

    /** Deleted here, or Google said its series is gone. */
    private func isGone(_ event: CalendarEvent) -> Bool {
        gone.contains(TaskEvent(event, scope: .occurrence).key) || gone.contains(TaskEvent(event, scope: .series).key)
    }

    /**
     * A window's part for each mailbox without one, shown from that mailbox's saved windows it overlaps
     * (the agenda starts anew each day), or whose days here do, for one drawn in another zone. They
     * agree already (`restore`, `spread`), so each event is taken from the newest that has it.
     */
    private func fill(_ window: EventWindow) {
        let missing = accounts.filter { parts[window]?[$0] == nil }
        let overlapping = restored.filter { saved in
            [saved, days[saved] ?? saved].contains { $0.from < window.to && $0.to > window.from }
        }
        guard !missing.isEmpty, !overlapping.isEmpty else { return }
        var filled = false
        for account in missing {
            let copies = overlapping
                .compactMap { saved in parts[saved]?[account].map { (events: $0, fetched: fetchedAt[saved]?[account] ?? .distantPast) } }
                .sorted { $0.fetched > $1.fetched }
            guard !copies.isEmpty else { continue }
            var seen: Set<String> = []
            parts[window, default: [:]][account] = copies.flatMap { saved in
                saved.events.filter { Self.holds(window, $0, days: days) && seen.insert($0.id).inserted }
            }
            fetchedAt[window, default: [:]][account] = copies.map(\.fetched).min()
            filled = true
        }
        guard filled else { return }
        cache[window] = Self.merged(parts[window] ?? [:], accounts: accounts)
    }

    /**
     * A window shown here that a window drawn in another zone has the same bounds as (Kiritimati's
     * Nov 12 is Honolulu's Nov 11): its all-day events fill the days they're on here first, and it
     * keeps only what falls in it as this zone's window, with the all-day events of saved windows
     * whose days here it is. Either may have a part of its own already, saved as another zone's day.
     */
    private func claim(_ window: EventWindow) {
        guard let other = days[window], other != window else { return }
        fill(other)
        take(window, into: other)
        zones[window] = nil
        days[window] = nil
        for saved in restored where saved != window {
            if let here = days[saved], here.from < window.to, here.to > window.from { take(saved, into: window) }
        }
        parts[window] = parts[window]?.mapValues { $0.filter { Self.holds(window, $0) } }
        for shown in [window, other] where cache[shown] != nil {
            cache[shown] = Self.merged(parts[shown] ?? [:], accounts: accounts)
        }
    }

    /** A window's all-day events that are on the days of `target` here, added to each mailbox's part `target` has. */
    private func take(_ window: EventWindow, into target: EventWindow) {
        for (account, events) in parts[window] ?? [:] {
            guard let theirs = parts[target]?[account] else { continue }
            let ids = Set(theirs.map(\.id))
            let moving = events.filter { $0.allDay && Self.holds(target, $0) && !ids.contains($0.id) }
            if !moving.isEmpty { parts[target]?[account] = theirs + moving }
        }
    }

    /**
     * A window from the saved copies: each event's newest copy, and none from an older window where a
     * newer one had nothing or moved it elsewhere, any window. The window's own copy wins a tie.
     * `days` are the windows drawn in another zone, as `holds` takes them.
     */
    nonisolated static func newest(
        in window: EventWindow,
        of copies: [(window: EventWindow, events: [CalendarEvent], fetched: Date)],
        days: [EventWindow: EventWindow] = [:]
    ) -> [CalendarEvent] {
        let newest = copies
            .sorted { ($0.fetched, $0.window == window ? 1 : 0) > ($1.fetched, $1.window == window ? 1 : 0) }
        var seen: Set<String> = []
        var kept: [CalendarEvent] = []
        for (index, saved) in newest.enumerated() {
            let newer = newest[..<index]
            kept += saved.events.filter { event in
                holds(window, event, days: days)
                    && !newer.contains { holds($0.window, event, days: days) }
                    && !seen.contains(event.id)
            }
            seen.formUnion(saved.events.map(\.id))
        }
        return kept
    }

    nonisolated static func answered(_ event: CalendarEvent, _ response: CalendarEvent.Response) -> CalendarEvent {
        var event = event
        event.response = response
        let me = event.calendar.account.lowercased()
        event.attendees = event.attendees.map { who in
            var who = who
            if who.person.email.lowercased() == me { who.response = response }
            return who
        }
        return event
    }

    func load(
        _ window: EventWindow,
        sources: [Mailbox],
        demo: Bool,
        google: GoogleAuth,
        dates: CalendarDates = CalendarDates(),
        force: Bool = false
    ) async {
        self.demo = demo
        follow(dates)
        let here = zone
        adopt(sources.map(\.email), dates: dates)
        if force {
            loadedAt.removeAll()
            stale = Set(accounts)
            if !denied.isEmpty { denied.removeAll() }
        }
        // Every load, a cached one included, leaves the one before it to be dropped when it lands.
        generation += 1
        let mine = generation
        claim(window)
        fill(window)
        let kept = cache[window]
        if kept != nil {
            if state != .ready { state = .ready }
            if Self.isFresh(loadedAt[window]) { return }
        } else if !sources.isEmpty, denied.count < sources.count {
            state = .loading
        }
        let asked = sources.filter { !denied.contains($0.email) }
        let results = await fetch(window, from: asked, demo: demo, google: google, dates: dates)
        var failures: [Error] = []
        for (account, result) in results {
            guard case .failure(let error) = result else { continue }
            switch error {
            case is GoogleCalendarAPI.NoAccess, GoogleAuth.Failure.signedOut:
                denied.insert(account)
            case is CancellationError:
                break
            case let stopped as URLError where stopped.code == .cancelled:
                break
            default:
                failures.append(error)
            }
        }
        let reached = absorb(results, for: window, fetchedIn: here)
        guard mine == generation else { return }
        // A refresh that fails leaves the events already up, as React Query keeps its data.
        if kept == nil { for error in failures { ErrorReports.capture(error, scope: "calendar") } }
        if reached || kept != nil {
            if state != .ready { state = .ready }
        } else if !sources.isEmpty, denied.count == sources.count {
            state = .noAccess
        } else if let first = failures.first {
            state = .failed(first.localizedDescription)
        } else {
            state = .ready
        }
    }

    /**
     * The phone moved to another zone with the store kept: the events in memory are drawn there as
     * `restore` draws saved ones, each all-day event on its own days, every window keeping the zone
     * its days were drawn in, and shown in the new zone's windows until those are fetched.
     */
    private func follow(_ dates: CalendarDates) {
        let here = dates.calendar.timeZone
        guard here != zone else { return }
        let old = zone
        zone = here
        for (window, byAccount) in parts {
            parts[window] = byAccount.mapValues { $0.map { CalendarCache.moved($0, from: old, to: dates.calendar) } }
            let there = zones[window].flatMap(TimeZone.init(identifier:)) ?? old
            if there == here {
                zones[window] = nil
                days[window] = nil
            } else {
                zones[window] = there.identifier
                days[window] = CalendarCache.days(window, from: there, to: dates.calendar)
            }
            restored.insert(window)
            if cache[window] != nil { cache[window] = Self.merged(parts[window] ?? [:], accounts: accounts) }
        }
        loadedAt.removeAll()
    }

    /** The windows either side, fetched ahead as `useCalendarEvents` prefetches them; failures wait for the real load. */
    func prefetch(_ windows: [EventWindow], sources: [Mailbox], demo: Bool, google: GoogleAuth, dates: CalendarDates) async {
        guard sources.map(\.email) == accounts, !lists.isEmpty || demo else { return }
        follow(dates)
        let here = zone
        let asked = sources.filter { !denied.contains($0.email) && lists[$0.email] != nil }
        guard !asked.isEmpty else { return }
        for window in windows where !Self.isFresh(loadedAt[window]) {
            let results = await fetch(window, from: asked, demo: demo, google: google, dates: dates)
            guard sources.map(\.email) == accounts else { return }
            absorb(results, for: window, fetchedIn: here)
        }
    }

    /** Every mailbox at once; each answers for itself, so one refused leaves the others' events. */
    private func fetch(
        _ window: EventWindow, from sources: [Mailbox], demo: Bool, google: GoogleAuth, dates: CalendarDates
    ) async -> [(String, Result<[CalendarEvent], Error>)] {
        let demoAccount = demo ? sources.first?.email : nil
        return await withTaskGroup(of: (String, Result<[CalendarEvent], Error>).self) { group in
            for source in sources {
                group.addTask {
                    await self.result(window, from: source, demoAccount: demoAccount, demo: demo, google: google, dates: dates)
                }
            }
            var results: [(String, Result<[CalendarEvent], Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    private func result(
        _ window: EventWindow, from source: Mailbox, demoAccount: String?, demo: Bool, google: GoogleAuth, dates: CalendarDates
    ) async -> (String, Result<[CalendarEvent], Error>) {
        do {
            let found = demo
                ? demoEvents(window, account: source.email, first: source.email == demoAccount, dates: dates)
                : try await fetch(window, from: source, google: google, dates: dates)
            return (source.email, .success(found))
        } catch {
            return (source.email, .failure(error))
        }
    }

    /** The demo's pretend calendars: Robin's under its first mailbox, Acme's under the others. */
    private func demoEvents(_ window: EventWindow, account: String, first: Bool, dates: CalendarDates) -> [CalendarEvent] {
        let calendars = (first ? DemoCalendar.calendars : DemoCalendar.acmeCalendars).map { $0.of(account) }
        if lists[account] != calendars { lists[account] = calendars }
        let pretend = (first ? DemoCalendar.events(in: window, dates: dates) : DemoCalendar.acmeEvents(in: window, dates: dates))
            .map { event in
                var event = event
                event.calendar = event.calendar.of(account)
                return demoAnswers[Self.answerKey(event)].map { Self.answered(event, $0) } ?? event
            }
        return demoEdits.applied(to: pretend, in: window, account: account)
    }

    /** All-day events read as days in the zone the load began in, which `absorb` compares with where the phone is when they land. */
    private func fetch(_ window: EventWindow, from mailbox: Mailbox, google: GoogleAuth, dates: CalendarDates) async throws -> [CalendarEvent] {
        let account = mailbox.email
        let api = GoogleCalendarAPI(email: account) { [google] refresh in
            try await google.accessToken(account, force: refresh)
        }
        let known: [EventCalendar]
        if !stale.contains(account), let listed = lists[account] {
            known = listed
        } else {
            known = try await api.calendars()
        }
        guard accounts.contains(account) else { throw CancellationError() }
        stale.remove(account)
        if lists[account] != known { lists[account] = known }
        // Every calendar, the ones Google hides included: the screen filters by `CalendarShown`, so turning one on needs no fetch.
        var found: [CalendarEvent] = []
        try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for calendar in known {
                group.addTask { [zone = dates.calendar] in try await api.events(on: calendar, in: window, zone: zone) }
            }
            for try await part in group { found += part }
        }
        return found
    }

    /**
     * A different set of mailboxes keeps what the ones still there had, shows what a new one
     * had on disk, and asks again for all of them.
     */
    private func adopt(_ next: [String], dates: CalendarDates = CalendarDates()) {
        guard next != accounts else { return }
        let gone = Set(accounts).subtracting(next)
        let added = demo ? [] : next.filter { !accounts.contains($0) }
        accounts = next
        loadedAt.removeAll()
        guard !gone.isEmpty || !added.isEmpty else { return }
        lists = lists.filter { !gone.contains($0.key) }
        denied.subtract(gone)
        for account in added { restore(account, dates: dates) }
        for (window, byAccount) in parts {
            let left = byAccount.filter { !gone.contains($0.key) }
            parts[window] = left
            fetchedAt[window] = fetchedAt[window]?.filter { !gone.contains($0.key) }
            let merged = Self.merged(left, accounts: next)
            if cache[window] != merged { cache[window] = merged }
        }
    }

    /** A mailbox gone from the device (removed, or the account signed out) takes its saved events with it at once. */
    func forgetRemoved() {
        let now = CalendarCache.mailboxes(in: defaults)
        let removed = onDevice.subtracting(now)
        onDevice = now
        guard !removed.isEmpty else { return }
        for account in removed { disk.remove(account) }
        adopt(accounts.filter { !removed.contains($0.lowercased()) })
    }

    /**
     * What each mailbox found, in its place in the window; a mailbox that failed keeps its part.
     * A refresh that finds what's already there redraws nothing, so the pages it would redraw
     * (mid-swipe, perhaps) stay as they are; it's saved still, so the disk knows how fresh it is.
     * The other windows take what it found. True when any mailbox answered. A fetch made before the
     * phone moved to another zone is dropped: its all-day events are that zone's days, not these.
     */
    @discardableResult
    func absorb(
        _ results: [(String, Result<[CalendarEvent], Error>)], for window: EventWindow, fetchedIn: TimeZone? = nil
    ) -> Bool {
        if let fetchedIn, fetchedIn != zone { return false }
        var reached = false
        var complete = true
        for (account, result) in results where accounts.contains(account) {
            switch result {
            case .success(let found):
                parts[window, default: [:]][account] = found
                fetchedAt[window, default: [:]][account] = .now
                // Fetched where the phone is now: Google gives every all-day event in it by this zone's days.
                zones[window] = nil
                days[window] = nil
                spread(found, of: account, from: window)
                reached = true
            case .failure:
                complete = false
            }
        }
        guard reached else { return false }
        for (shown, byAccount) in parts where shown == window || cache[shown] != nil {
            let merged = Self.merged(byAccount, accounts: accounts)
            if cache[shown] != merged { cache[shown] = merged }
        }
        if complete { loadedAt[window] = .now }
        save()
        return true
    }

    /**
     * A mailbox's newer events in its other windows: an event changed, moved or gone in the
     * window fetched is so in every window, as Google has it now.
     */
    private func spread(_ found: [CalendarEvent], of account: String, from window: EventWindow) {
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let within = { (event: CalendarEvent, window: EventWindow) in Self.holds(window, event, days: self.days) }
        for (other, byAccount) in parts where other != window {
            guard let mine = byAccount[account] else { continue }
            var kept = mine.compactMap { event -> CalendarEvent? in
                if let newer = byId[event.id] { return within(newer, other) ? newer : nil }
                return within(event, window) ? nil : event
            }
            let had = Set(mine.map(\.id))
            kept += found.filter { !had.contains($0.id) && within($0, other) }
            if kept != mine { parts[other]?[account] = kept }
        }
    }

    /** A window's events, nil until they have been fetched. */
    func events(in window: EventWindow) -> [CalendarEvent]? { cache[window] }

    /** An event as the cache has it now, after a change saved since it was opened. */
    func current(_ event: CalendarEvent) -> CalendarEvent? {
        for events in cache.values {
            if let found = events.first(where: { $0.id == event.id }) { return found }
        }
        return nil
    }

    /** What a task's link reaches: the event, gone from the calendar, or out of reach (signed out, offline). */
    enum Reach: Equatable {
        case found(CalendarEvent)
        case gone
        case unavailable
    }

    /** The event a task's link reaches among those loaded: the occurrence, or the series' next one. */
    func find(_ link: TaskEvent, now: Date = .now) -> CalendarEvent? {
        Self.nearest(cache.values.flatMap { $0.filter(link.matches) }, now: now)
    }

    /**
     * Whether a task's link is known to be gone, by its event's id: deleted here, or Google said so
     * when it was opened. Missing from the day it was on proves nothing: it may have moved.
     */
    func isGone(_ link: TaskEvent, now: Date = .now) -> Bool {
        find(link, now: now) == nil && gone.contains(link.key)
    }

    /** The first not over yet, else the last there was. */
    nonisolated static func nearest(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events.filter { $0.end > now }.min { $0.start < $1.start } ?? events.max { $0.start < $1.start }
    }

    /**
     * A task's link outside the windows loaded, asked of Google by the
     * occurrence's id (the demo makes its events again around the link's day).
     * A series whose linked occurrence is gone is found by the series' own id,
     * and shown read-only: changing it there would change every occurrence.
     * Nothing is written, and the task keeps its link whatever the answer.
     */
    func resolve(_ link: TaskEvent, sources: [Mailbox], demo: Bool, google: GoogleAuth, dates: CalendarDates) async -> Reach {
        let reach = await reach(link, sources: sources, demo: demo, google: google, dates: dates)
        switch reach {
        case .found: gone.remove(link.key)
        case .gone: gone.insert(link.key)
        case .unavailable: break
        }
        return reach
    }

    private func reach(_ link: TaskEvent, sources: [Mailbox], demo: Bool, google: GoogleAuth, dates: CalendarDates) async -> Reach {
        if let found = find(link) { return .found(found) }
        guard link.provider == "google", let mailbox = sources.first(where: { $0.email.lowercased() == link.account }) else {
            return .unavailable
        }
        let calendar = lists[mailbox.email]?.first { $0.id == link.calendarId }
            ?? EventCalendar(id: link.calendarId, name: link.calendarId, account: mailbox.email)
        if demo {
            let day = dates.startOfDay(link.originalStart ?? link.start)
            let around = EventWindow(from: dates.addDays(day, -1), to: dates.addDays(day, 2))
            let found = demoEvents(around, account: mailbox.email, first: sources.first?.email == mailbox.email, dates: dates)
            return Self.nearest(found.filter(link.matches), now: .now).map(Reach.found) ?? .gone
        }
        let api = GoogleCalendarAPI(email: mailbox.email) { [google] refresh in
            try await google.accessToken(mailbox.email, force: refresh)
        }
        do {
            if let occurrence = try await api.event(link.eventId, on: calendar) { return .found(occurrence) }
            guard link.scope == .series, let seriesId = link.seriesId, var series = try await api.event(seriesId, on: calendar) else {
                return .gone
            }
            series.calendar.writable = false
            return .found(series)
        } catch {
            return .unavailable
        }
    }
}

/** Why an event can't be saved, said before asking Google. */
nonisolated struct EventProblem: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/** The demo's changes, laid over its pretend events each time they're made again. */
nonisolated struct DemoEdits {
    var made: [CalendarEvent] = []
    var changed: [String: CalendarEvent] = [:]
    var deleted: Set<String> = []

    func applied(to events: [CalendarEvent], in window: EventWindow, account: String) -> [CalendarEvent] {
        let mine = made.filter { $0.calendar.account == account }
        let all = (events + mine)
            .filter { !deleted.contains($0.id) }
            .map { changed[$0.id] ?? $0 }
            .filter { $0.end > window.from && $0.start < window.to }
        return EventDays.sorted(all)
    }
}

/** The demo's stand-in for Google: the event as Google would hand it back, nothing sent anywhere. */
nonisolated struct DemoEventWriter: EventWriter {
    var dates = CalendarDates()

    func create(_ input: EventInput, on calendar: EventCalendar, notify: Bool) async throws -> CalendarEvent {
        let blank = CalendarEvent(eventId: "demo-\(UUID().uuidString.lowercased())", calendar: calendar, title: "", start: .now, end: .now)
        return input.applied(to: blank, dates: dates)
    }

    func update(_ event: CalendarEvent, with patch: EventInput, notify: Bool) async throws -> CalendarEvent {
        patch.applied(to: event, dates: dates)
    }

    func delete(_ event: CalendarEvent, notify: Bool) async throws {}
}
