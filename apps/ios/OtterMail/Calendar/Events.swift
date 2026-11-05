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
}

/**
 * The events a day, a week, a month and the agenda list, as the Mac and web
 * apps list them (apps/web/src/main/calendar's month-grid.tsx, time-grid.tsx
 * and agenda.tsx). Every day is a local day, so an event is on the days it
 * covers where the user is.
 */
nonisolated enum EventDays {
    /** All day first, then by time, the longer first: month-grid.tsx's order. */
    static func sorted(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.id < b.id
        }
    }

    /** On a day when it overlaps it, as the grids test it: `endMs > start && startMs < end`. */
    static func spans(_ event: CalendarEvent, _ day: Date, dates: CalendarDates) -> Bool {
        let start = dates.startOfDay(day)
        return event.end > start && event.start < dates.addDays(start, 1)
    }

    static func events(_ events: [CalendarEvent], on day: Date, dates: CalendarDates) -> [CalendarEvent] {
        sorted(events.filter { spans($0, day, dates: dates) })
    }

    /** Each of those days that has events, with them. */
    static func byDay(_ events: [CalendarEvent], days: [Date], dates: CalendarDates) -> [Date: [CalendarEvent]] {
        let sorted = Self.sorted(events)
        var byDay: [Date: [CalendarEvent]] = [:]
        for day in days {
            let on = sorted.filter { spans($0, day, dates: dates) }
            if !on.isEmpty { byDay[dates.startOfDay(day)] = on }
        }
        return byDay
    }

    static func grouped(_ events: [CalendarEvent], days: [Date], dates: CalendarDates) -> [EventDay] {
        byDay(events, days: days, dates: dates)
            .map { EventDay(id: $0.key, events: $0.value) }
            .sorted { $0.id < $1.id }
    }

    /**
     * The agenda's rows, as agenda.tsx builds them: what hasn't ended yet,
     * earliest first, each event once under the day it starts — or under
     * `from` when it started before that.
     */
    static func agenda(_ events: [CalendarEvent], from: Date, now: Date, dates: CalendarDates) -> [EventDay] {
        let coming = events.filter { $0.end > now }.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.id < b.id
        }
        var days: [EventDay] = []
        for event in coming {
            let day = dates.startOfDay(max(event.start, from))
            if let last = days.last, dates.sameDay(last.id, day) {
                days[days.count - 1] = EventDay(id: last.id, events: last.events + [event])
            } else {
                days.append(EventDay(id: day, events: [event]))
            }
        }
        return days
    }

    /**
     * The last day an event covers. An event ending at midnight (an all-day
     * event's end is the midnight after it) stops the day before, which is
     * what `spans` says too.
     */
    static func lastDay(of event: CalendarEvent, dates: CalendarDates) -> Date {
        let start = dates.startOfDay(event.start)
        let end = dates.startOfDay(event.end)
        guard end > start else { return start }
        return event.end == end ? max(start, dates.addDays(end, -1)) : end
    }

    /**
     * The day an event's end is shown under: its last day when it's all day,
     * the end's own day when it's at a time, so a meeting ending at midnight
     * says the day it really ends.
     */
    static func endDay(of event: CalendarEvent, dates: CalendarDates) -> Date {
        event.allDay ? lastDay(of: event, dates: dates) : dates.startOfDay(event.end)
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
