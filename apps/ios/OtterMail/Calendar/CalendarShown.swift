import Foundation
import Observation

/**
 * Calendars shown or hidden by hand, by `calendarKey`, as
 * apps/web/src/main/calendar/calendar-store.ts keeps them: on this device only
 * (`calendar:shown`, its localStorage key), and the rest follow Google's own
 * choice (`hiddenByDefault`: a calendar not selected there).
 */
@Observable
final class CalendarShown {
    nonisolated static let key = "calendar:shown"

    private(set) var shown: [String: Bool]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shown = Self.read(defaults.string(forKey: Self.key))
    }

    nonisolated static func read(_ json: String?) -> [String: Bool] {
        guard let data = json?.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return record.compactMapValues { $0 as? Bool }
    }

    nonisolated static func isShown(_ shown: [String: Bool], key: String, hiddenByDefault: Bool) -> Bool {
        shown[key] ?? !hiddenByDefault
    }

    nonisolated static func isShown(_ shown: [String: Bool], _ calendar: EventCalendar, mailbox: String) -> Bool {
        isShown(shown, key: EventStyle.key(mailbox: mailbox, calendar: calendar.id), hiddenByDefault: !calendar.shown)
    }

    nonisolated static func visible(_ events: [CalendarEvent], shown: [String: Bool], mailbox: String) -> [CalendarEvent] {
        events.filter { isShown(shown, $0.calendar, mailbox: mailbox) }
    }

    func isShown(key: String, hiddenByDefault: Bool) -> Bool {
        Self.isShown(shown, key: key, hiddenByDefault: hiddenByDefault)
    }

    func isShown(_ calendar: EventCalendar, mailbox: String) -> Bool {
        Self.isShown(shown, calendar, mailbox: mailbox)
    }

    func setShown(key: String, show: Bool) {
        shown[key] = show
        guard let data = try? JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys]) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }

    func setShown(_ calendar: EventCalendar, mailbox: String, show: Bool) {
        setShown(key: EventStyle.key(mailbox: mailbox, calendar: calendar.id), show: show)
    }
}
