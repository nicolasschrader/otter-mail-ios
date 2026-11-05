import Foundation

/**
 * The calendar the screens show, as core maps it (contracts' CalendarEvent and
 * packages/core/src/providers/gmail/calendar.ts) in the phone's types: times as
 * Dates, and an all-day event from local midnight to the midnight after its
 * last day, which is how Google writes it.
 */
nonisolated struct CalendarEvent: Identifiable, Hashable {
    enum Status: String {
        case confirmed, tentative, cancelled
    }

    enum Response: String {
        case needsAction, accepted, declined, tentative

        var title: String {
            switch self {
            case .needsAction: "No answer"
            case .accepted: "Going"
            case .declined: "Not going"
            case .tentative: "Maybe"
            }
        }

        var symbol: String {
            switch self {
            case .needsAction: "circle.dotted"
            case .accepted: "checkmark.circle.fill"
            case .declined: "xmark.circle.fill"
            case .tentative: "questionmark.circle.fill"
            }
        }
    }

    struct Attendee: Identifiable, Hashable {
        var person: Person
        var response: Response = .needsAction

        var id: String { person.email.lowercased() }
    }

    var eventId: String
    var calendar: EventCalendar
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var location: String? = nil
    /** Google's description, often HTML. */
    var details: String? = nil
    var status: Status = .confirmed
    var organizer: Person? = nil
    var attendees: [Attendee] = []
    /** The mailbox's own answer, or nil when it isn't among the attendees. */
    var response: Response? = nil
    var meetingLink: String? = nil
    var htmlLink: String? = nil
    var recurring = false

    var id: String { "\(calendar.id)/\(eventId)" }
}

/** One of the account's calendars (core's CalendarInfo). */
nonisolated struct EventCalendar: Identifiable, Hashable {
    var id: String
    var name: String
    var color: String? = nil
    var primary = false
    /** Turned on in Google Calendar (core's `hiddenByDefault`, the other way round). */
    var shown = true
}

nonisolated struct EventDay: Identifiable, Hashable {
    let id: Date
    let events: [CalendarEvent]

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(id) { return "Today" }
        if calendar.isDateInTomorrow(id) { return "Tomorrow" }
        if calendar.isDateInYesterday(id) { return "Yesterday" }
        if calendar.isDate(id, equalTo: .now, toGranularity: .year) {
            return id.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return id.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}

/** What the calendar screen is looking at, and so what it asks Google for. */
nonisolated enum CalendarMode: String, CaseIterable, Identifiable {
    case agenda, week, month

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

nonisolated struct EventWindow: Hashable {
    var from: Date
    var to: Date
}

/**
 * Days, weeks and months of events. The week starts where the phone's region
 * starts it (`Calendar.firstWeekday`), and every bucket is a local day, so an
 * event is on the days it covers where the user is.
 */
nonisolated enum EventDays {
    static func startOfWeek(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func window(_ mode: CalendarMode, anchor: Date, calendar: Calendar = .current) -> EventWindow {
        let from: Date
        let days: Int
        switch mode {
        case .agenda:
            from = calendar.startOfDay(for: anchor)
            days = 120
        case .week:
            from = startOfWeek(anchor, calendar: calendar)
            days = 7
        case .month:
            // Six weeks from the week the month starts in: the grid, whatever the month.
            from = startOfWeek(startOfMonth(anchor, calendar: calendar), calendar: calendar)
            days = 42
        }
        return EventWindow(from: from, to: calendar.date(byAdding: .day, value: days, to: from) ?? from)
    }

    static func days(in window: EventWindow, calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: window.from)
        while day < window.to, days.count < 400 {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /**
     * The last day an event covers. An event ending at midnight (an all-day
     * event's end is the midnight after it) stops the day before.
     */
    static func lastDay(of event: CalendarEvent, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: event.start)
        let end = calendar.startOfDay(for: event.end)
        guard end > start else { return start }
        guard event.end == end, let before = calendar.date(byAdding: .day, value: -1, to: end) else { return end }
        return max(start, before)
    }

    /** Every day in the window that has events, each event on each day it covers. */
    static func byDay(_ events: [CalendarEvent], in window: EventWindow, calendar: Calendar = .current) -> [Date: [CalendarEvent]] {
        let first = calendar.startOfDay(for: window.from)
        var byDay: [Date: [CalendarEvent]] = [:]
        for event in events {
            let last = lastDay(of: event, calendar: calendar)
            var day = max(calendar.startOfDay(for: event.start), first)
            while day <= last, day < window.to {
                byDay[day, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return byDay.mapValues(Self.sorted)
    }

    static func group(_ events: [CalendarEvent], in window: EventWindow, calendar: Calendar = .current) -> [EventDay] {
        byDay(events, in: window, calendar: calendar)
            .map { EventDay(id: $0.key, events: $0.value) }
            .sorted { $0.id < $1.id }
    }

    static func events(_ events: [CalendarEvent], on day: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        let window = EventWindow(from: start, to: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        return byDay(events, in: window, calendar: calendar)[start] ?? []
    }

    /** All day first, then by time, as every calendar lists a day. */
    static func sorted(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            if a.start != b.start { return a.start < b.start }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

/**
 * Meeting links, as contracts' meetings.ts finds them: the conference link a
 * provider we know hands out, picked out of the location or the description.
 */
nonisolated enum Meetings {
    enum Provider: String {
        case googleMeet, teams, zoom, webex, other

        var title: String {
            switch self {
            case .googleMeet: "Google Meet"
            case .teams: "Microsoft Teams"
            case .zoom: "Zoom"
            case .webex: "Webex"
            case .other: "Meeting"
            }
        }
    }

    static func provider(_ link: String) -> Provider {
        guard let url = URL(string: link), url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else { return .other }
        let path = url.path()
        let on = { (domain: String) in host == domain || host.hasSuffix("." + domain) }
        if host == "meet.google.com" {
            return path.dropFirst().first?.isLetter == true ? .googleMeet : .other
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") ? .teams : .other
        }
        if on("zoom.us") || on("zoom.com") {
            return ["/j/", "/my/", "/w/"].contains(where: path.hasPrefix) ? .zoom : .other
        }
        if on("webex.com") {
            return path.hasPrefix("/meet") || path.hasPrefix("/join") || path.contains("/j.php") ? .webex : .other
        }
        return .other
    }

    /** The first link to a meeting in any of these; descriptions may be HTML. */
    static func findLink(in texts: [String?]) -> String? {
        for text in texts.compactMap({ $0 }) {
            for token in text.split(whereSeparator: { $0.isWhitespace || "\"'<>()".contains($0) }) {
                guard let https = token.range(of: "https://") else { continue }
                var link = String(token[https.lowerBound...]).replacingOccurrences(of: "&amp;", with: "&")
                while let last = link.last, ".,;:!?".contains(last) { link.removeLast() }
                if provider(link) != .other { return link }
            }
        }
        return nil
    }
}
