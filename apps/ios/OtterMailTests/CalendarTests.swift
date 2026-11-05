import Foundation
import Testing
@testable import Otter_Mail

/**
 * The calendar's pure parts: Google's JSON mapped as core maps it
 * (packages/core/src/providers/gmail/calendar.ts), meeting links as contracts
 * finds them, and the day, week and month buckets the screens list.
 */
struct CalendarTests {
    private let mine = EventCalendar(id: "primary", name: "Robin Otter", color: "#0ea5e9", primary: true)
    private let me = "robin@otter.example"

    private func zone(_ identifier: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func events(_ json: String, in calendar: Calendar) throws -> [CalendarEvent] {
        try GoogleEvents.events(Data(json.utf8), on: mine, me: me, times: EventTimes(calendar: calendar)).events
    }

    private let review = """
    {"items": [{
      "id": "evt-1",
      "status": "confirmed",
      "htmlLink": "https://www.google.com/calendar/event?eid=abc",
      "summary": "Design review",
      "description": "Agenda: <a href=\\"https://example.com/doc?a=1&amp;b=2\\">the doc</a>",
      "location": "Studio",
      "start": {"dateTime": "2026-05-04T09:00:00+02:00", "timeZone": "Europe/Berlin"},
      "end": {"dateTime": "2026-05-04T10:30:00+02:00", "timeZone": "Europe/Berlin"},
      "organizer": {"email": "maya@example.com", "displayName": "Maya Chen"},
      "attendees": [
        {"email": "maya@example.com", "displayName": "Maya Chen", "responseStatus": "accepted"},
        {"email": "ROBIN@otter.example", "self": true, "responseStatus": "tentative"},
        {"email": "sam@acme.example"}
      ],
      "hangoutLink": "https://meet.google.com/abc-defg-hij",
      "conferenceData": {"entryPoints": [
        {"entryPointType": "more", "uri": "https://tel.meet/x"},
        {"entryPointType": "video", "uri": "https://meet.google.com/xyz-video"}
      ]},
      "recurringEventId": "evt-series"
    }]}
    """

    @Test func mapsAnEventAtATime() throws {
        let calendar = zone("Europe/Berlin")
        let event = try #require(try events(review, in: calendar).first)
        #expect(event.eventId == "evt-1")
        #expect(event.id == "primary/evt-1")
        #expect(event.title == "Design review")
        #expect(event.start == day(2026, 5, 4, 9, 0, in: calendar))
        #expect(event.end == day(2026, 5, 4, 10, 30, in: calendar))
        #expect(!event.allDay)
        #expect(event.location == "Studio")
        #expect(event.status == .confirmed)
        #expect(event.organizer == Person(name: "Maya Chen", email: "maya@example.com"))
        #expect(event.attendees.map(\.person.email) == ["maya@example.com", "ROBIN@otter.example", "sam@acme.example"])
        #expect(event.attendees.map(\.response) == [.accepted, .tentative, .needsAction])
        #expect(event.response == .tentative)
        // The conference's video link comes before the Meet link and the text.
        #expect(event.meetingLink == "https://meet.google.com/xyz-video")
        #expect(event.htmlLink == "https://www.google.com/calendar/event?eid=abc")
        #expect(event.recurring)
        #expect(event.calendar == mine)
    }

    @Test func readsTheMailboxesOwnAnswer() throws {
        let calendar = zone("Europe/Berlin")
        // Google doesn't always mark the attendee: the address decides, as core's isSelf does.
        let unmarked = """
        {"items": [{"id": "a", "summary": "Lunch",
          "start": {"dateTime": "2026-05-04T12:00:00Z"}, "end": {"dateTime": "2026-05-04T13:00:00Z"},
          "attendees": [{"email": "Robin@Otter.Example", "responseStatus": "declined"}]}]}
        """
        #expect(try events(unmarked, in: calendar).first?.response == .declined)

        let theirs = """
        {"items": [{"id": "b", "summary": "Their meeting",
          "start": {"dateTime": "2026-05-04T12:00:00Z"}, "end": {"dateTime": "2026-05-04T13:00:00Z"},
          "attendees": [{"email": "maya@example.com", "responseStatus": "accepted"}]}]}
        """
        let event = try #require(try events(theirs, in: calendar).first)
        #expect(event.response == nil)
        #expect(event.attendees.count == 1)
    }

    @Test func mapsAnAllDayEventAtLocalMidnight() throws {
        let json = """
        {"items": [{"id": "c", "summary": "Mum's birthday",
          "start": {"date": "2026-05-04"}, "end": {"date": "2026-05-05"}}]}
        """
        let berlin = zone("Europe/Berlin")
        let event = try #require(try events(json, in: berlin).first)
        #expect(event.allDay)
        #expect(event.start == day(2026, 5, 4, in: berlin))
        #expect(event.end == day(2026, 5, 5, in: berlin))
        // Its end is the midnight after it, so it covers one day.
        #expect(EventDays.lastDay(of: event, calendar: berlin) == day(2026, 5, 4, in: berlin))

        let newYork = zone("America/New_York")
        let there = try #require(try events(json, in: newYork).first)
        #expect(there.start == day(2026, 5, 4, in: newYork))
        #expect(there.start != event.start)
    }

    @Test func spreadsALongerEventOverEveryDayItCovers() throws {
        let calendar = zone("Europe/Berlin")
        let json = """
        {"items": [
          {"id": "offsite", "summary": "Offsite", "start": {"date": "2026-05-04"}, "end": {"date": "2026-05-07"}},
          {"id": "train", "summary": "Night train",
           "start": {"dateTime": "2026-05-04T22:40:00+02:00"}, "end": {"dateTime": "2026-05-05T07:15:00+02:00"}},
          {"id": "late", "summary": "Last orders",
           "start": {"dateTime": "2026-05-04T23:00:00+02:00"}, "end": {"dateTime": "2026-05-05T00:00:00+02:00"}}
        ]}
        """
        let found = try events(json, in: calendar)
        let week = EventWindow(from: day(2026, 5, 4, in: calendar), to: day(2026, 5, 11, in: calendar))
        let byDay = EventDays.byDay(found, in: week, calendar: calendar)
        #expect(byDay[day(2026, 5, 4, in: calendar)]?.map(\.eventId) == ["offsite", "train", "late"])
        #expect(byDay[day(2026, 5, 5, in: calendar)]?.map(\.eventId) == ["offsite", "train"])
        #expect(byDay[day(2026, 5, 6, in: calendar)]?.map(\.eventId) == ["offsite"])
        #expect(byDay[day(2026, 5, 7, in: calendar)] == nil)
        // An event ending at midnight stops the day before.
        #expect(EventDays.lastDay(of: found[2], calendar: calendar) == day(2026, 5, 4, in: calendar))
    }

    @Test func keepsWhatGoogleLeavesOut() throws {
        let calendar = zone("Europe/Berlin")
        let json = """
        {"items": [
          {"id": "d", "status": "cancelled", "start": {"dateTime": "2026-05-04T09:00:00Z"}, "end": {"dateTime": "2026-05-04T10:00:00Z"}},
          {"id": "e", "status": "tentative", "summary": "Maybe", "start": {"dateTime": "2026-05-04T11:00:00Z"}, "end": {"dateTime": "2026-05-04T12:00:00Z"}},
          {"id": "f", "summary": "No end", "start": {"dateTime": "2026-05-04T14:00:00Z"}},
          {"id": "g", "summary": "No times at all"}
        ]}
        """
        let found = try events(json, in: calendar)
        #expect(found.map(\.eventId) == ["d", "e", "f"])
        #expect(found[0].title == "(no title)")
        #expect(found[0].status == .cancelled)
        #expect(found[0].response == nil)
        #expect(found[1].status == .tentative)
        // Without an end it lasts an hour, as a new event does on the Mac.
        #expect(found[2].end == found[2].start.addingTimeInterval(3600))
    }

    @Test func findsMeetingLinksLikeTheDesktop() throws {
        let calendar = zone("Europe/Berlin")
        let json = """
        {"items": [
          {"id": "zoom", "summary": "Book club", "location": "https://bokcirkel.zoom.us/j/8829104425.",
           "start": {"dateTime": "2026-05-04T19:00:00Z"}, "end": {"dateTime": "2026-05-04T20:00:00Z"}},
          {"id": "html", "summary": "Sync",
           "description": "Read <a href=\\"https://example.com/notes\\">this</a> then join https://teams.microsoft.com/l/meetup-join/19%3ameeting?a=1&amp;b=2",
           "start": {"dateTime": "2026-05-05T19:00:00Z"}, "end": {"dateTime": "2026-05-05T20:00:00Z"}},
          {"id": "none", "summary": "Coffee", "location": "Café Linden", "description": "See https://example.com/map",
           "start": {"dateTime": "2026-05-06T19:00:00Z"}, "end": {"dateTime": "2026-05-06T20:00:00Z"}},
          {"id": "hangout", "summary": "Standup", "hangoutLink": "https://meet.google.com/abc-defg-hij",
           "start": {"dateTime": "2026-05-07T19:00:00Z"}, "end": {"dateTime": "2026-05-07T20:00:00Z"}}
        ]}
        """
        let found = try events(json, in: calendar)
        #expect(found[0].meetingLink == "https://bokcirkel.zoom.us/j/8829104425")
        #expect(found[1].meetingLink == "https://teams.microsoft.com/l/meetup-join/19%3ameeting?a=1&b=2")
        #expect(found[2].meetingLink == nil)
        #expect(found[3].meetingLink == "https://meet.google.com/abc-defg-hij")
    }

    @Test func knowsWhichLinksAreMeetings() {
        #expect(Meetings.provider("https://meet.google.com/abc-defg-hij") == .googleMeet)
        #expect(Meetings.provider("https://meet.google.com/") == .other)
        #expect(Meetings.provider("https://teams.live.com/meet/9321") == .teams)
        #expect(Meetings.provider("https://teams.microsoft.com/l/channel/19") == .other)
        #expect(Meetings.provider("https://zoom.us/j/123") == .zoom)
        #expect(Meetings.provider("https://acme.zoom.us/my/robin") == .zoom)
        #expect(Meetings.provider("https://acme.zoom.us/account") == .other)
        #expect(Meetings.provider("https://acme.webex.com/acme/j.php?MTID=m1") == .webex)
        #expect(Meetings.provider("http://meet.google.com/abc-defg-hij") == .other)
        #expect(Meetings.provider("https://example.com/call") == .other)
        #expect(Meetings.findLink(in: [nil, "no link here"]) == nil)
    }

    @Test func bucketsEventsWhereThePhoneIs() throws {
        let json = """
        {"items": [{"id": "h", "summary": "Late call",
          "start": {"dateTime": "2026-11-04T23:30:00Z"}, "end": {"dateTime": "2026-11-05T00:15:00Z"}}]}
        """
        let berlin = zone("Europe/Berlin")
        let found = try events(json, in: berlin)
        // The same instant is the 5th in Berlin (+01:00) and still the 4th in New York.
        let newYork = zone("America/New_York")
        let week = { (calendar: Calendar) in
            EventWindow(from: self.day(2026, 11, 2, in: calendar), to: self.day(2026, 11, 9, in: calendar))
        }
        #expect(EventDays.byDay(found, in: week(berlin), calendar: berlin).keys.sorted() == [day(2026, 11, 5, in: berlin)])
        #expect(EventDays.byDay(found, in: week(newYork), calendar: newYork).keys.sorted() == [day(2026, 11, 4, in: newYork)])
    }

    @Test func startsTheWeekWhereTheRegionDoes() {
        // 1 November 2026 is a Sunday.
        let monday = zone("Europe/Berlin", firstWeekday: 2)
        let sunday = zone("Europe/Berlin", firstWeekday: 1)
        let wednesday = day(2026, 11, 4, 12, 0, in: monday)
        #expect(EventDays.startOfWeek(wednesday, calendar: monday) == day(2026, 11, 2, in: monday))
        #expect(EventDays.startOfWeek(wednesday, calendar: sunday) == day(2026, 11, 1, in: sunday))

        let week = EventDays.window(.week, anchor: wednesday, calendar: monday)
        #expect(week.from == day(2026, 11, 2, in: monday))
        #expect(EventDays.days(in: week, calendar: monday).count == 7)

        // The month's grid is six weeks from the week its first day falls in.
        let month = EventDays.window(.month, anchor: wednesday, calendar: monday)
        #expect(month.from == day(2026, 10, 26, in: monday))
        #expect(EventDays.days(in: month, calendar: monday).count == 42)
        #expect(EventDays.window(.month, anchor: wednesday, calendar: sunday).from == day(2026, 11, 1, in: sunday))

        let agenda = EventDays.window(.agenda, anchor: wednesday, calendar: monday)
        #expect(agenda.from == day(2026, 11, 4, in: monday))
        #expect(EventDays.days(in: agenda, calendar: monday).count == 120)
    }

    @Test func groupsADaysEventsAllDayFirst() throws {
        let calendar = zone("Europe/Berlin")
        let json = """
        {"items": [
          {"id": "later", "summary": "Later", "start": {"dateTime": "2026-05-04T16:00:00+02:00"}, "end": {"dateTime": "2026-05-04T17:00:00+02:00"}},
          {"id": "earlier", "summary": "Earlier", "start": {"dateTime": "2026-05-04T09:00:00+02:00"}, "end": {"dateTime": "2026-05-04T10:00:00+02:00"}},
          {"id": "whole", "summary": "Whole day", "start": {"date": "2026-05-04"}, "end": {"date": "2026-05-05"}}
        ]}
        """
        let found = try events(json, in: calendar)
        let window = EventWindow(from: day(2026, 5, 4, in: calendar), to: day(2026, 5, 5, in: calendar))
        let days = EventDays.group(found, in: window, calendar: calendar)
        #expect(days.count == 1)
        #expect(days[0].id == day(2026, 5, 4, in: calendar))
        #expect(days[0].events.map(\.eventId) == ["whole", "earlier", "later"])
        #expect(EventDays.events(found, on: day(2026, 5, 4, 15, 0, in: calendar), calendar: calendar).count == 3)
        #expect(EventDays.events(found, on: day(2026, 5, 5, in: calendar), calendar: calendar).isEmpty)
    }

    @Test func readsTheAccountsCalendars() throws {
        let json = """
        {"items": [
          {"id": "robin@otter.example", "summary": "robin@otter.example", "primary": true, "backgroundColor": "#9fe1e7"},
          {"id": "work@otter.example", "summary": "Work", "summaryOverride": "Otterware", "selected": false},
          {"id": "holidays", "summary": "Holidays", "hidden": true},
          {"id": "birthdays", "summary": "Birthdays"}
        ]}
        """
        let page = try GoogleEvents.calendars(Data(json.utf8))
        #expect(page.next == nil)
        #expect(page.calendars.map(\.id) == ["robin@otter.example", "birthdays", "work@otter.example"])
        #expect(page.calendars[0].primary)
        #expect(page.calendars[0].color == "#9fe1e7")
        // Its name in Google Calendar wins, and one turned off there isn't fetched.
        #expect(page.calendars[2].name == "Otterware")
        #expect(page.calendars.map(\.shown) == [true, true, false])
    }

    @Test func carriesGooglesNextPage() throws {
        let json = """
        {"nextPageToken": "page-2", "items": [{"id": "a", "summary": "One of many",
          "start": {"dateTime": "2026-05-04T09:00:00Z"}, "end": {"dateTime": "2026-05-04T10:00:00Z"}}]}
        """
        let page = try GoogleEvents.events(Data(json.utf8), on: mine, me: me, times: EventTimes(calendar: zone("Europe/Berlin")))
        #expect(page.next == "page-2")
        #expect(page.events.count == 1)
    }

    @Test func theDemoFillsEveryView() {
        let calendar = zone("Europe/Berlin")
        let now = day(2026, 11, 4, 10, 0, in: calendar)
        for mode in CalendarMode.allCases {
            let window = EventDays.window(mode, anchor: now, calendar: calendar)
            let events = DemoCalendar.events(in: window, now: now, calendar: calendar)
            #expect(!events.isEmpty, "\(mode.title) has nothing to show")
            #expect(events.allSatisfy { $0.end > window.from && $0.start < window.to })
        }
        let month = EventDays.window(.month, anchor: now, calendar: calendar)
        let offsite = DemoCalendar.events(in: month, now: now, calendar: calendar).filter { $0.eventId == "offsite" }
        #expect(offsite.count == 1)
        #expect(offsite.first?.allDay == true)
        #expect(EventDays.byDay(offsite, in: month, calendar: calendar).count == 3)
    }
}
