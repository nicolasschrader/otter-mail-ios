import Foundation
import Observation

/**
 * What the calendar screen renders from: one window of events at a time, kept
 * per window so stepping back a month doesn't ask Google again. Google Calendar
 * for a Gmail mailbox, the pretend one in the demo. A sign-in from before the
 * app asked for calendar access ends in `noAccess`, where the screen offers
 * signing in again (as core's NoCalendarAccess does on the Mac).
 */
@Observable
final class CalendarStore {
    enum State: Equatable {
        case loading, ready, noAccess
        case failed(String)
    }

    private(set) var state: State = .ready
    private(set) var events: [CalendarEvent] = []
    private(set) var calendars: [EventCalendar] = []
    @ObservationIgnored private var cache: [EventWindow: [CalendarEvent]] = [:]
    @ObservationIgnored private var generation = 0

    func load(
        _ window: EventWindow,
        mailbox: Mailbox,
        demo: Bool,
        google: GoogleAuth,
        dates: CalendarDates = CalendarDates(),
        force: Bool = false
    ) async {
        if force {
            cache.removeAll()
            calendars = []
        }
        // Every load, a cached one included, leaves the one before it to be dropped when it lands.
        generation += 1
        let mine = generation
        if let kept = cache[window] {
            events = kept
            state = .ready
            return
        }
        state = .loading
        if demo {
            return keep(DemoCalendar.events(in: window, dates: dates), for: window)
        }
        let api = GoogleCalendarAPI(email: mailbox.email) { [google] refresh in
            try await google.accessToken(mailbox.email, force: refresh)
        }
        do {
            let known = calendars.isEmpty ? try await api.calendars() : calendars
            guard mine == generation else { return }
            calendars = known
            var found: [CalendarEvent] = []
            try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
                for calendar in known.filter(\.shown) {
                    group.addTask { try await api.events(on: calendar, in: window) }
                }
                for try await part in group { found += part }
            }
            guard mine == generation else { return }
            keep(found, for: window)
        } catch {
            guard mine == generation else { return }
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

    private func keep(_ found: [CalendarEvent], for window: EventWindow) {
        let sorted = EventDays.sorted(found)
        cache[window] = sorted
        events = sorted
        state = .ready
    }
}
