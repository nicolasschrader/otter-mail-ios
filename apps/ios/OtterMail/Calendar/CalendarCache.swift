import Foundation

/**
 * Each mailbox's calendars and events on disk, by window, so the calendar shows what it had
 * at once after a restart while Google is asked again. Written atomically as
 * `MailCache` and `TaskFiles` write theirs.
 */
nonisolated final class CalendarCache: Sendable {
    static let live = CalendarCache(folder: URL.cachesDirectory.appending(path: "calendar", directoryHint: .isDirectory))

    private let folder: URL
    private let queue = DispatchQueue(label: "app.otter.mail.calendar", qos: .utility)

    init(folder: URL) { self.folder = folder }

    struct Saved: Codable, Equatable {
        var calendars: [EventCalendar] = []
        var windows: [EventWindow: [CalendarEvent]] = [:]
        /** When each window was fetched, so the newest saved copy of an event wins. */
        var fetched: [EventWindow: Date] = [:]
        /** Where the phone was: an all-day event is its days there, read back as the same days where the phone is now. */
        var timeZone = TimeZone.current.identifier
        /** The windows whose days are another zone's, kept from before the phone moved: their bounds are midnights there. */
        var zones: [EventWindow: String] = [:]
    }

    private func file(_ account: String) -> URL { folder.appending(path: "\(account.lowercased()).json") }

    /** Read on the writing queue, so it sees the last save. */
    func load(_ account: String) -> Saved {
        queue.sync {
            guard let data = try? Data(contentsOf: file(account)) else { return Saved() }
            return (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
        }
    }

    func save(_ saved: Saved, account: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved)
                .write(to: self.file(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func remove(_ account: String) {
        queue.async { try? FileManager.default.removeItem(at: self.file(account)) }
    }

    /**
     * An all-day event saved in another zone, on the same days where the phone is now: Google gives
     * it as dates, so a day in Berlin stays that day in New York rather than the hours it was there.
     */
    static func moved(_ event: CalendarEvent, from zone: TimeZone, to calendar: Calendar) -> CalendarEvent {
        guard event.allDay, zone != calendar.timeZone else { return event }
        let day = sameDay(from: zone, to: calendar)
        var event = event
        event.start = day(event.start)
        event.end = day(event.end)
        event.originalStart = event.originalStart.map(day)
        return event
    }

    /** A window drawn in another zone as the same days where the phone is now, what its all-day events are compared with. */
    static func days(_ window: EventWindow, from zone: TimeZone, to calendar: Calendar) -> EventWindow {
        let day = sameDay(from: zone, to: calendar)
        return EventWindow(from: day(window.from), to: day(window.to))
    }

    private static func sameDay(from zone: TimeZone, to calendar: Calendar) -> (Date) -> Date {
        var then = calendar
        then.timeZone = zone
        let saved = CalendarDates(calendar: then)
        let times = EventTimes(calendar: calendar)
        return { times.day(saved.dayKey($0)) ?? $0 }
    }

    private struct Address: Decodable { var email: String }

    /** The mailboxes Session keeps on this device (its `otter:mailboxes`), by lowercased address. */
    static func mailboxes(in defaults: UserDefaults) -> Set<String> {
        let saved = defaults.data(forKey: "otter:mailboxes").flatMap { try? JSONDecoder().decode([Address].self, from: $0) } ?? []
        return Set(saved.map { $0.email.lowercased() })
    }
}
