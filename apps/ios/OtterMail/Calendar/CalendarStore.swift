import Foundation
import Observation

/**
 * What the calendar screen renders from: events kept per window as the Mac and web apps' React Query does (`useCalendarEvents`):
 * a window shown before is shown again at once, and asked of Google again in
 * the background once it's older than `freshFor`. HomeView holds it, so it
 * outlives switching to Mail and back. Google Calendar for a Gmail mailbox,
 * the pretend one in the demo. A sign-in from before the app asked for
 * calendar access ends in `noAccess`, where the screen offers signing in again
 * (as core's NoCalendarAccess does on the Mac).
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
    private(set) var calendars: [EventCalendar] = []
    /** Observed, so every page the screen keeps up draws its own window as soon as it lands. */
    private var cache: [EventWindow: [CalendarEvent]] = [:]
    @ObservationIgnored private var loadedAt: [EventWindow: Date] = [:]
    @ObservationIgnored private var email: String?
    @ObservationIgnored private var generation = 0

    func load(
        _ window: EventWindow,
        mailbox: Mailbox,
        demo: Bool,
        google: GoogleAuth,
        dates: CalendarDates = CalendarDates(),
        force: Bool = false
    ) async {
        if force || mailbox.email != email { forget(mailbox.email) }
        // Every load, a cached one included, leaves the one before it to be dropped when it lands.
        generation += 1
        let mine = generation
        let kept = cache[window]
        if kept != nil {
            if state != .ready { state = .ready }
            if Self.isFresh(loadedAt[window]) { return }
        } else {
            state = .loading
        }
        do {
            let found = try await fetch(window, mailbox: mailbox, demo: demo, google: google, dates: dates)
            guard email == mailbox.email else { return }
            keep(found, for: window, shown: mine == generation)
        } catch {
            guard mine == generation else { return }
            // A refresh that fails leaves the events already up, as React Query keeps its data.
            if kept != nil { return }
            switch error {
            case is GoogleCalendarAPI.NoAccess, GoogleAuth.Failure.signedOut:
                state = .noAccess
            case is CancellationError:
                state = .ready
            case let stopped as URLError where stopped.code == .cancelled:
                state = .ready
            default:
                ErrorReports.capture(error, scope: "calendar")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /** The windows either side, fetched ahead as `useCalendarEvents` prefetches them; failures wait for the real load. */
    func prefetch(_ windows: [EventWindow], mailbox: Mailbox, demo: Bool, google: GoogleAuth, dates: CalendarDates) async {
        guard mailbox.email == email, !calendars.isEmpty || demo else { return }
        for window in windows where !Self.isFresh(loadedAt[window]) {
            guard let found = try? await fetch(window, mailbox: mailbox, demo: demo, google: google, dates: dates),
                  email == mailbox.email
            else { continue }
            keep(found, for: window, shown: false)
        }
    }

    private func fetch(
        _ window: EventWindow, mailbox: Mailbox, demo: Bool, google: GoogleAuth, dates: CalendarDates
    ) async throws -> [CalendarEvent] {
        if demo {
            if calendars != DemoCalendar.calendars { calendars = DemoCalendar.calendars }
            return DemoCalendar.events(in: window, dates: dates)
        }
        let api = GoogleCalendarAPI(email: mailbox.email) { [google] refresh in
            try await google.accessToken(mailbox.email, force: refresh)
        }
        let known = calendars.isEmpty ? try await api.calendars() : calendars
        guard email == mailbox.email else { throw CancellationError() }
        if calendars != known { calendars = known }
        // Every calendar, the ones Google hides included: the screen filters by `CalendarShown`, so turning one on needs no fetch.
        var found: [CalendarEvent] = []
        try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for calendar in known {
                group.addTask { try await api.events(on: calendar, in: window) }
            }
            for try await part in group { found += part }
        }
        return found
    }

    private func forget(_ next: String) {
        cache.removeAll()
        loadedAt.removeAll()
        calendars = []
        email = next
    }

    /** A refresh that finds what's already there writes nothing, so the pages it would redraw (mid-swipe, perhaps) stay as they are. */
    private func keep(_ found: [CalendarEvent], for window: EventWindow, shown: Bool) {
        let sorted = EventDays.sorted(found)
        if cache[window] != sorted { cache[window] = sorted }
        loadedAt[window] = .now
        if shown, state != .ready { state = .ready }
    }

    /** A window's events, nil until they have been fetched. */
    func events(in window: EventWindow) -> [CalendarEvent]? { cache[window] }
}
