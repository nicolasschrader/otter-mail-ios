import Foundation
import Testing
@testable import Otter_Mail

/**
 * Making, changing and deleting events, as ported from the web app's
 * event-panel.tsx (NewEvent, EventDetails, TimeRows), api.ts (eventTimes,
 * hasGuests, useCalendarActions) and core's gmail/calendar.ts (apiBody). The
 * store's writes go to a stand-in for Google that records what it was asked;
 * nothing here reaches a calendar.
 */
struct EventEditingTests {
    private let robin = "robin@otter.example"
    private var mine: EventCalendar {
        EventCalendar(id: "robin@otter.example", name: "Robin", primary: true, account: robin, writable: true)
    }
    private var shared: EventCalendar {
        EventCalendar(id: "holidays", name: "Holidays", account: robin)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private var dates: CalendarDates { CalendarDates(calendar: calendar) }

    /** The store keeps the links it knows are gone; each test keeps its own, not the app's. */
    private func isolated() -> UserDefaults {
        let suite = "EventEditingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    // MARK: Drafts

    @Test func aNewEventTodayStartsAtTheNextHourForAnHour() {
        let draft = EventDraft.new(on: mine, day: at(7, 0), now: at(7, 14, 20), dates: dates)
        #expect(draft.start == at(7, 15))
        #expect(draft.end == at(7, 16))
        #expect(!draft.allDay)
        #expect(draft.calendar == mine)
    }

    @Test func aNewEventOnAnotherDayStartsAtNine() {
        let draft = EventDraft.new(on: mine, day: at(12, 0), now: at(7, 14), dates: dates)
        #expect(draft.start == at(12, 9))
        #expect(draft.end == at(12, 10))
    }

    @Test func allDayCoversTheDaysAndBackIsNineToTen() {
        var draft = EventDraft(calendar: mine, start: at(9, 14), end: at(10, 11))
        draft.setAllDay(true, dates: dates)
        #expect(draft.start == at(9, 0))
        #expect(draft.end == at(11, 0), "an all-day event ends the midnight after its last day")
        #expect(dates.sameDay(draft.lastDay(dates: dates), at(10, 0)))
        draft.setAllDay(false, dates: dates)
        #expect(draft.start == at(9, 9))
        #expect(draft.end == at(9, 10))
    }

    @Test func movingTheStartKeepsTheLength() {
        var draft = EventDraft(calendar: mine, start: at(9, 14), end: at(9, 15, 30))
        draft.move(to: at(10, 8))
        #expect(draft.end == at(10, 9, 30))
    }

    @Test func editingReadsTheDescriptionAsText() {
        let event = CalendarEvent(eventId: "e", calendar: mine, title: "(no title)", start: at(9, 9), end: at(9, 10),
                                  location: "Studio", details: "Bring <b>seeds</b><br>and gloves")
        let draft = EventDraft(editing: event)
        #expect(draft.title == "")
        #expect(draft.location == "Studio")
        #expect(draft.notes == "Bring seeds\nand gloves")
    }

    // MARK: Validation

    @Test func anEndBeforeTheStartIsRefused() {
        var draft = EventDraft(calendar: mine, start: at(9, 10), end: at(9, 10))
        #expect(draft.problem == "The end has to be after the start.")
        draft.end = at(9, 11)
        #expect(draft.problem == nil)
    }

    @Test func aReadOnlyCalendarIsRefused() {
        let draft = EventDraft(calendar: shared, start: at(9, 10), end: at(9, 11))
        #expect(draft.problem == "This calendar can't be changed from Otter Mail.")
    }

    @Test func theDefaultCalendarIsThePickThenThePrimaryThenAnyThatTakesEvents() {
        let work = EventCalendar(id: "work", name: "Work", account: robin, writable: true)
        let all = [shared, work, mine]
        #expect(defaultCalendar(of: all, chosen: "") == mine)
        #expect(defaultCalendar(of: all, chosen: work.key) == work)
        #expect(defaultCalendar(of: all, chosen: "\(robin)|primary") == mine, "core names the primary calendar `primary`")
        #expect(defaultCalendar(of: all, chosen: shared.key) == mine, "a read-only pick doesn't take events")
        #expect(defaultCalendar(of: [shared], chosen: "") == nil)
    }

    @Test func onlyYourOwnEventsOnWritableCalendarsOpenToBeChanged() {
        let organizer = Person(name: "Jonas", email: "jonas@example.de")
        let yours = CalendarEvent(eventId: "a", calendar: mine, title: "Mine", start: at(9, 9), end: at(9, 10))
        let invite = CalendarEvent(eventId: "b", calendar: mine, title: "Theirs", start: at(9, 9), end: at(9, 10), organizer: organizer)
        let readOnly = CalendarEvent(eventId: "c", calendar: shared, title: "Holiday", start: at(9, 0), end: at(10, 0), allDay: true)
        #expect(yours.isEditable)
        #expect(!invite.isEditable)
        #expect(!readOnly.isEditable)
    }

    // MARK: Payloads

    @Test func createSendsTitleTimesAndPlace() {
        var draft = EventDraft(calendar: mine, title: "  Lunch  ", start: at(9, 12), end: at(9, 13))
        draft.location = " Café Linden "
        let input = draft.input(dates: dates)
        #expect(input == EventInput(title: "Lunch", start: .instant(at(9, 12)), end: .instant(at(9, 13)), location: "Café Linden"))
        let body = EventBody.json(input, timeZone: "Europe/Berlin")
        #expect(body["summary"] as? String == "Lunch")
        #expect(body["location"] as? String == "Café Linden")
        #expect(body["description"] == nil)
        #expect((body["start"] as? [String: Any])?["dateTime"] as? String == "2026-11-09T11:00:00Z")
        #expect((body["start"] as? [String: Any])?["timeZone"] as? String == "Europe/Berlin")
        #expect((body["end"] as? [String: Any])?["dateTime"] as? String == "2026-11-09T12:00:00Z")
    }

    @Test func anUntitledEventIsNoTitle() {
        let draft = EventDraft(calendar: mine, title: "   ", start: at(9, 12), end: at(9, 13))
        #expect(draft.input(dates: dates).title == "(no title)")
    }

    @Test func allDaySendsLocalDaysWithTheEndTheDayAfter() {
        var draft = EventDraft(calendar: mine, title: "Offsite", start: at(9, 0), end: at(9, 0))
        draft.allDay = true
        let input = draft.input(dates: dates)
        #expect(input.start == .day("2026-11-09"))
        #expect(input.end == .day("2026-11-10"), "an end at the start is moved to the day after, as eventTimes does")
        #expect(input.allDay == true)
        let body = EventBody.json(input)
        #expect((body["start"] as? [String: Any])?["date"] as? String == "2026-11-09")
        #expect((body["start"] as? [String: Any])?["dateTime"] == nil)
    }

    @Test func aPatchHasOnlyWhatChanged() {
        let original = EventDraft(calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13), location: "Café", notes: "Bring cake")
        var draft = original
        #expect(draft.patch(from: original, dates: dates).isEmpty)
        draft.location = "Park"
        #expect(draft.patch(from: original, dates: dates) == EventInput(location: "Park"))
        draft.move(to: at(9, 14))
        let moved = draft.patch(from: original, dates: dates)
        #expect(moved.start == .instant(at(9, 14)))
        #expect(moved.end == .instant(at(9, 15)))
        #expect(moved.allDay == false)
        #expect(moved.title == nil)
        #expect(moved.description == nil)
    }

    @Test func turningAnEventAllDayClearsItsTimes() throws {
        let original = EventDraft(calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13))
        var draft = original
        draft.setAllDay(true, dates: dates)
        let body = EventBody.json(draft.patch(from: original, dates: dates), wasAllDay: false)
        let start = try #require(body["start"] as? [String: Any])
        #expect(start["date"] as? String == "2026-11-09")
        #expect(start["dateTime"] is NSNull)
        #expect(start["timeZone"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func googleSaysWhichCalendarsTakeEvents() throws {
        let json = """
        {"items":[
          {"id":"robin@otter.example","summary":"Robin","primary":true,"accessRole":"owner"},
          {"id":"team","summary":"Team","accessRole":"writer"},
          {"id":"holidays","summary":"Holidays","accessRole":"reader"}
        ]}
        """
        let listed = try GoogleEvents.calendars(Data(json.utf8), account: robin).calendars
        #expect(listed.map(\.writable) == [true, true, false])
    }

    @Test func googlesAnswerToACreateIsTheEvent() throws {
        let json = """
        {"id":"abc","summary":"Lunch","location":"Café","start":{"dateTime":"2026-11-09T12:00:00+01:00"},
         "end":{"dateTime":"2026-11-09T13:00:00+01:00"},"htmlLink":"https://calendar.google.com/event?eid=abc"}
        """
        let event = try GoogleEvents.event(Data(json.utf8), on: mine, me: robin, times: EventTimes(calendar: calendar))
        #expect(event.eventId == "abc")
        #expect(event.title == "Lunch")
        #expect(event.start == at(9, 12))
        #expect(event.calendar == mine)
    }

    // MARK: The store, against a stand-in for Google

    @MainActor @Test func theStoreCreatesChangesAndDeletesThroughTheWriter() async throws {
        let store = CalendarStore(defaults: isolated())
        let mailbox = Mailbox(email: robin, name: "Robin", displayName: "Robin", color: "#336699", signature: "", labels: [])
        let window = dates.window(.day, anchor: at(9, 0))
        await store.load(window, sources: [mailbox], demo: true, google: GoogleAuth(), dates: dates)
        let listed = store.lists[robin] ?? []
        let firstWritable = listed.first { $0.writable }
        let calendar = try #require(firstWritable)
        let writer = RecordingWriter(dates: dates)

        let draft = EventDraft(calendar: calendar, title: "Dentist", start: at(9, 15), end: at(9, 16))
        let made = try await store.create(draft, with: writer, dates: dates)
        #expect(found(made, in: window, of: store) != nil)
        #expect(await writer.calls == ["create Dentist notify:false"])

        var changed = EventDraft(editing: made)
        changed.title = "Dentist (moved)"
        changed.move(to: at(9, 17))
        let saved = try await store.update(made, to: changed, with: writer, dates: dates)
        #expect(saved.title == "Dentist (moved)")
        #expect(found(made, in: window, of: store)?.start == at(9, 17))
        #expect(await writer.patches.last == EventInput(
            title: "Dentist (moved)", start: .instant(at(9, 17)), end: .instant(at(9, 18)), allDay: false
        ))

        try await store.delete(saved, with: writer)
        #expect(found(made, in: window, of: store) == nil)
        #expect(await writer.calls.last == "delete Dentist (moved) notify:false")
    }

    @MainActor @Test func anUnchangedEventIsntSentAndAnInvalidOneIsRefused() async throws {
        let store = CalendarStore(defaults: isolated())
        let writer = RecordingWriter(dates: dates)
        let event = CalendarEvent(eventId: "e", calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13))
        _ = try await store.update(event, to: EventDraft(editing: event), with: writer, dates: dates)
        var backwards = EventDraft(editing: event)
        backwards.end = at(9, 11)
        await #expect(throws: EventProblem.self) {
            try await store.update(event, to: backwards, with: writer, dates: dates)
        }
        await #expect(throws: EventProblem.self) {
            try await store.create(EventDraft(calendar: shared, start: at(9, 9), end: at(9, 10)), with: writer, dates: dates)
        }
        #expect(await writer.calls.isEmpty)
    }

    @MainActor @Test func guestsAreToldOfChangesToEventsWithThem() async throws {
        let store = CalendarStore(defaults: isolated())
        let writer = RecordingWriter(dates: dates)
        let guest = CalendarEvent.Attendee(person: Person(name: "Maya", email: "maya@example.com"))
        let event = CalendarEvent(eventId: "e", calendar: mine, title: "Review", start: at(9, 12), end: at(9, 13), attendees: [guest])
        var draft = EventDraft(editing: event)
        draft.location = "Studio"
        _ = try await store.update(event, to: draft, with: writer, dates: dates)
        try await store.delete(event, with: writer)
        #expect(await writer.calls == ["update Review notify:true", "delete Review notify:true"])
    }

    @MainActor @Test func theDemosChangesOutliveItsEventsBeingMadeAgain() async throws {
        let store = CalendarStore(defaults: isolated())
        let mailbox = Mailbox(email: robin, name: "Robin", displayName: "Robin", color: "#336699", signature: "", labels: [])
        let window = dates.window(.day, anchor: .now)
        await store.load(window, sources: [mailbox], demo: true, google: GoogleAuth(), dates: dates)
        let listed = store.lists[robin] ?? []
        let firstWritable = listed.first { $0.writable }
        let calendar = try #require(firstWritable)
        let writer = store.writer(for: robin, demo: true, google: GoogleAuth())
        let start = dates.calendar.date(bySettingHour: 18, minute: 0, second: 0, of: .now)!
        let made = try await store.create(
            EventDraft(calendar: calendar, title: "Demo dinner", start: start, end: start.addingTimeInterval(3600)),
            with: writer, demo: true, dates: dates
        )
        await store.load(window, sources: [mailbox], demo: true, google: GoogleAuth(), dates: dates, force: true)
        #expect(found(made, in: window, of: store) != nil)

        try await store.delete(made, with: writer, demo: true)
        await store.load(window, sources: [mailbox], demo: true, google: GoogleAuth(), dates: dates, force: true)
        #expect(found(made, in: window, of: store) == nil)
    }

    /** A task's event deleted is gone once its day is loaded without it, not merely out of reach. */
    @MainActor @Test func aTasksDeletedEventIsGone() async throws {
        let store = CalendarStore(defaults: isolated())
        let mailbox = Mailbox(email: robin, name: "Robin", displayName: "Robin", color: "#336699", signature: "", labels: [])
        let window = dates.window(.day, anchor: .now)
        await store.load(window, sources: [mailbox], demo: true, google: GoogleAuth(), dates: dates)
        let calendar = try #require((store.lists[robin] ?? []).first { $0.writable })
        let writer = store.writer(for: robin, demo: true, google: GoogleAuth())
        let start = dates.calendar.date(bySettingHour: 18, minute: 0, second: 0, of: .now)!
        let made = try await store.create(
            EventDraft(calendar: calendar, title: "Demo dinner", start: start, end: start.addingTimeInterval(3600)),
            with: writer, demo: true, dates: dates
        )
        let link = TaskEvent(made, scope: .occurrence)
        let elsewhere = TaskEvent(
            CalendarEvent(eventId: "later", calendar: calendar, title: "Later", start: dates.addDays(start, 30), end: dates.addDays(start, 30)),
            scope: .occurrence
        )
        #expect(!store.isGone(link))

        try await store.delete(made, with: writer, demo: true)
        #expect(store.isGone(link))
        #expect(!store.isGone(elsewhere))
    }

    /** A task's event deleted is still gone after a restart, its mailbox still there and nothing loaded. */
    @MainActor @Test func aTasksDeletedEventStaysGoneAfterARestart() async throws {
        let suite = "EventEditingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let event = CalendarEvent(eventId: "e", calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13))
        let link = TaskEvent(event, scope: .occurrence)
        try await CalendarStore(defaults: defaults).delete(event, with: RecordingWriter(dates: dates))

        #expect(CalendarStore(defaults: defaults).isGone(link))
    }

    // MARK: Kept on the device

    /** Each test's calendar on disk, not the app's. */
    private func onDisk() -> CalendarCache {
        CalendarCache(folder: URL.temporaryDirectory.appending(path: "calendar-\(UUID())", directoryHint: .isDirectory))
    }

    private var robinsMailbox: Mailbox {
        Mailbox(email: robin, name: "Robin", displayName: "Robin", color: "#336699", signature: "", labels: [])
    }

    /** After a restart, offline, the calendar shows the events it last had, and not one deleted since. */
    @MainActor @Test func savedEventsShowAfterARestartWithoutTheDeletedOne() async throws {
        let defaults = isolated()
        let disk = onDisk()
        let window = dates.window(.day, anchor: at(9, 0))
        let lunch = CalendarEvent(eventId: "lunch", calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13))
        let dentist = CalendarEvent(eventId: "dentist", calendar: mine, title: "Dentist", start: at(9, 15), end: at(9, 16))
        disk.save(CalendarCache.Saved(calendars: [mine], windows: [window: [lunch, dentist]]), account: robin)

        let before = CalendarStore(defaults: defaults, cache: disk)
        await before.load(window, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(before.state == .ready)
        #expect(before.events(in: window)?.map(\.eventId) == ["lunch", "dentist"])
        try await before.delete(dentist, with: RecordingWriter(dates: dates))

        let after = CalendarStore(defaults: defaults, cache: disk)
        await after.load(window, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(after.state == .ready)
        #expect(after.events(in: window)?.map(\.eventId) == ["lunch"])

        disk.save(CalendarCache.Saved(calendars: [mine], windows: [window: [lunch, dentist]]), account: robin)
        let stale = CalendarStore(defaults: defaults, cache: disk)
        await stale.load(window, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(stale.events(in: window)?.map(\.eventId) == ["lunch"])
    }

    /** Offline after a restart, each mailbox's calendars are there, so scoping to one hides the other's saved events. */
    @MainActor @Test func savedEventsKeepToTheMailboxScopedTo() async throws {
        let disk = onDisk()
        let acme = "robin@acme.example"
        let work = EventCalendar(id: acme, name: "Acme", primary: true, account: acme, writable: true)
        let mailboxes = [robin, acme].map {
            Mailbox(email: $0, name: "Robin", displayName: "Robin", color: "#336699", signature: "", labels: [])
        }
        let window = dates.window(.day, anchor: at(9, 0))
        let lunch = CalendarEvent(eventId: "lunch", calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13))
        let review = CalendarEvent(eventId: "review", calendar: work, title: "Review", start: at(9, 15), end: at(9, 16))
        disk.save(CalendarCache.Saved(calendars: [mine], windows: [window: [lunch]]), account: robin)
        disk.save(CalendarCache.Saved(calendars: [work], windows: [window: [review]]), account: acme)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(window, sources: mailboxes, demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.lists[robin] == [mine])
        #expect(store.lists[acme] == [work])
        let calendars = mailboxes.flatMap { store.lists[$0.email] ?? [] }
        let shown = CalendarShown.scoped([:], account: robin, calendars: calendars)
        #expect(CalendarShown.visible(store.events(in: window) ?? [], shown: shown).map(\.eventId) == ["lunch"])
    }

    /** The agenda saved yesterday shows today's part of it offline, less a series Google said is gone. */
    @MainActor @Test func aSavedAgendaShowsTheNextDayWithoutAGoneSeries() async throws {
        let defaults = isolated()
        let disk = onDisk()
        let yesterday = dates.window(.agenda, anchor: at(8, 9))
        let today = dates.window(.agenda, anchor: at(9, 9))
        let past = CalendarEvent(eventId: "past", calendar: mine, title: "Breakfast", start: at(8, 12), end: at(8, 13))
        let lunch = CalendarEvent(eventId: "lunch", calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13))
        var standup = CalendarEvent(eventId: "standup_1", calendar: mine, title: "Standup", start: at(10, 9), end: at(10, 10))
        standup.seriesId = "standup"
        disk.save(CalendarCache.Saved(calendars: [mine], windows: [yesterday: [past, lunch, standup]]), account: robin)
        defaults.set([TaskEvent(standup, scope: .series).key], forKey: "calendar.goneLinks")

        let store = CalendarStore(defaults: defaults, cache: disk)
        await store.load(today, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.state == .ready)
        #expect(store.events(in: today)?.map(\.eventId) == ["lunch"])
    }

    /** Saved windows that overlap show the newest copy of each event: an older month doesn't bring back one gone or changed since. */
    @MainActor @Test func anOlderSavedMonthDoesntBringBackWhatANewerAgendaDropped() async throws {
        let disk = onDisk()
        let month = dates.window(.month, anchor: at(9, 0))
        let yesterday = dates.window(.agenda, anchor: at(8, 9))
        let today = dates.window(.agenda, anchor: at(9, 9))
        let cancelled = CalendarEvent(eventId: "cancelled", calendar: mine, title: "Dentist", start: at(10, 15), end: at(10, 16))
        let lunch = CalendarEvent(eventId: "lunch", calendar: mine, title: "Lunch", start: at(10, 12), end: at(10, 13))
        var renamed = lunch
        renamed.title = "Team lunch"
        disk.save(CalendarCache.Saved(
            calendars: [mine],
            windows: [month: [lunch, cancelled], yesterday: [renamed]],
            fetched: [month: at(8, 8), yesterday: at(8, 9)]
        ), account: robin)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(today, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.events(in: today)?.map(\.title) == ["Team lunch"])
    }

    /** A month saved itself, but before a newer agenda, shows the agenda's copy offline after a restart. */
    @MainActor @Test func aSavedMonthShowsWhatANewerAgendaHasAfterARestart() async throws {
        let disk = onDisk()
        let month = dates.window(.month, anchor: at(9, 0))
        let agenda = dates.window(.agenda, anchor: at(8, 9))
        let cancelled = CalendarEvent(eventId: "cancelled", calendar: mine, title: "Dentist", start: at(10, 15), end: at(10, 16))
        let lunch = CalendarEvent(eventId: "lunch", calendar: mine, title: "Lunch", start: at(10, 12), end: at(10, 13))
        var renamed = lunch
        renamed.title = "Team lunch"
        disk.save(CalendarCache.Saved(
            calendars: [mine],
            windows: [month: [lunch, cancelled], agenda: [renamed]],
            fetched: [month: at(8, 8), agenda: at(8, 9)]
        ), account: robin)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.events(in: month)?.map(\.title) == ["Team lunch"])
    }

    /** An event a newer agenda moved out of the month leaves the month's older copy behind after a restart. */
    @MainActor @Test func anEventMovedOutOfASavedMonthLeavesItAfterARestart() async throws {
        let disk = onDisk()
        let month = dates.window(.month, anchor: at(9, 0))
        let agenda = dates.window(.agenda, anchor: at(9, 9))
        let dentist = CalendarEvent(eventId: "dentist", calendar: mine, title: "Dentist", start: at(5, 15), end: at(5, 16))
        var moved = dentist
        moved.start = at(45, 15)
        moved.end = at(45, 16)
        disk.save(CalendarCache.Saved(
            calendars: [mine],
            windows: [month: [dentist], agenda: [moved]],
            fetched: [month: at(8, 8), agenda: at(9, 9)]
        ), account: robin)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.events(in: month)?.map(\.eventId) == [])
    }

    /** An event a newer month moved to it leaves the older month it was in, though the two don't overlap. */
    @MainActor @Test func anEventMovedToAnotherSavedMonthLeavesTheOldOne() async throws {
        let disk = onDisk()
        let november = dates.window(.month, anchor: at(9, 0))
        let december = dates.window(.month, anchor: at(45, 0))
        let dentist = CalendarEvent(eventId: "dentist", calendar: mine, title: "Dentist", start: at(5, 15), end: at(5, 16))
        var moved = dentist
        moved.start = at(45, 15)
        moved.end = at(45, 16)
        disk.save(CalendarCache.Saved(
            calendars: [mine],
            windows: [november: [dentist], december: [moved]],
            fetched: [november: at(8, 8), december: at(9, 9)]
        ), account: robin)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(november, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.events(in: november)?.map(\.eventId) == [])
    }

    /** A month and an agenda restored: what the agenda then fetches, a rename or a deletion, shows in the month at once. */
    @MainActor @Test func aRestoredMonthTakesWhatTheAgendaFetches() async throws {
        let disk = onDisk()
        let month = dates.window(.month, anchor: at(9, 0))
        let agenda = dates.window(.agenda, anchor: at(9, 9))
        let lunch = CalendarEvent(eventId: "lunch", calendar: mine, title: "Lunch", start: at(10, 12), end: at(10, 13))
        let dentist = CalendarEvent(eventId: "dentist", calendar: mine, title: "Dentist", start: at(11, 15), end: at(11, 16))
        let past = CalendarEvent(eventId: "past", calendar: mine, title: "Breakfast", start: at(5, 8), end: at(5, 9))
        var renamed = lunch
        renamed.title = "Team lunch"
        disk.save(CalendarCache.Saved(
            calendars: [mine],
            windows: [month: [past, lunch, dentist], agenda: [lunch, dentist]],
            fetched: [month: at(8, 8), agenda: at(8, 9)]
        ), account: robin)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.events(in: month)?.map(\.title) == ["Breakfast", "Lunch", "Dentist"])
        store.absorb([(robin, .success([renamed]))], for: agenda)
        #expect(store.events(in: month)?.map(\.title) == ["Breakfast", "Team lunch"])

        let after = CalendarStore(defaults: isolated(), cache: disk)
        await after.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(after.events(in: month)?.map(\.title) == ["Breakfast", "Team lunch"])
    }

    /** A fetch that finds nothing new still saves when it was made, so an older window's deleted event stays gone after a restart. */
    @MainActor @Test func anUnchangedFetchKeepsItsTimeAfterARestart() async throws {
        let disk = onDisk()
        let month = dates.window(.month, anchor: at(9, 0))
        let agenda = dates.window(.agenda, anchor: at(9, 9))
        let dentist = CalendarEvent(eventId: "dentist", calendar: mine, title: "Dentist", start: at(10, 15), end: at(10, 16))

        let before = CalendarStore(defaults: isolated(), cache: disk)
        await before.load(agenda, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        before.absorb([(robin, .success([]))], for: agenda)
        before.absorb([(robin, .success([dentist]))], for: month)
        before.absorb([(robin, .success([]))], for: agenda)

        let after = CalendarStore(defaults: isolated(), cache: disk)
        await after.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(after.events(in: month)?.map(\.eventId) == [])
    }

    /** A mailbox removed, then the account signed out, takes its saved events with it at once, the ones a task's link opens included. */
    @MainActor @Test func aRemovedMailboxsEventsGoAtOnce() async throws {
        let defaults = isolated()
        let disk = onDisk()
        let acme = "robin@acme.example"
        let work = EventCalendar(id: acme, name: "Acme", primary: true, account: acme, writable: true)
        let mailboxes = [robinsMailbox, Mailbox(email: acme, name: "Robin", displayName: "Acme", color: "#993366", signature: "", labels: [])]
        let window = dates.window(.day, anchor: at(9, 0))
        let lunch = CalendarEvent(eventId: "lunch", calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13))
        let review = CalendarEvent(eventId: "review", calendar: work, title: "Review", start: at(9, 15), end: at(9, 16))
        disk.save(CalendarCache.Saved(calendars: [mine], windows: [window: [lunch]]), account: robin)
        disk.save(CalendarCache.Saved(calendars: [work], windows: [window: [review]]), account: acme)
        defaults.set(try JSONEncoder().encode(mailboxes), forKey: "otter:mailboxes")

        let store = CalendarStore(defaults: defaults, cache: disk)
        await store.load(window, sources: mailboxes, demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.find(TaskEvent(lunch, scope: .occurrence)) != nil)

        defaults.set(try JSONEncoder().encode([mailboxes[0]]), forKey: "otter:mailboxes")
        await settled { store.find(TaskEvent(review, scope: .occurrence)) == nil }
        #expect(store.find(TaskEvent(review, scope: .occurrence)) == nil)
        #expect(store.events(in: window)?.map(\.eventId) == ["lunch"])
        #expect(store.lists[acme] == nil)
        #expect(disk.load(acme) == CalendarCache.Saved())

        defaults.removeObject(forKey: "otter:mailboxes")
        await settled { store.find(TaskEvent(lunch, scope: .occurrence)) == nil }
        #expect(store.find(TaskEvent(lunch, scope: .occurrence)) == nil)
        #expect(store.lists.isEmpty)
        #expect(disk.load(robin) == CalendarCache.Saved())
    }

    /** Waits for what the main queue delivers, as the store hears of defaults changing there. */
    @MainActor private func settled(_ done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /**
     * An all-day event saved in Berlin is the same day in New York after a restart: Nov 12 from
     * midnight to midnight there, not Nov 11 at 6 PM to Nov 12 at 6 PM. An event at a time keeps its moment.
     */
    @MainActor @Test func aSavedAllDayEventKeepsItsDayInAnotherZone() async throws {
        let disk = onDisk()
        let berlin = calendar
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        newYork.locale = Locale(identifier: "en_US")
        let there = CalendarDates(calendar: newYork)
        let day = { (zone: Calendar, number: Int) in zone.date(from: DateComponents(year: 2026, month: 11, day: number))! }
        let holiday = CalendarEvent(eventId: "holiday", calendar: mine, title: "Holiday", start: day(berlin, 12), end: day(berlin, 13), allDay: true)
        let call = CalendarEvent(eventId: "call", calendar: mine, title: "Call", start: at(12, 15), end: at(12, 16))
        let month = dates.window(.month, anchor: at(9, 0))
        let thirteenth = dates.window(.day, anchor: day(berlin, 13))
        disk.save(CalendarCache.Saved(
            calendars: [mine],
            windows: [month: [holiday, call], thirteenth: []],
            fetched: [month: at(8, 8), thirteenth: at(8, 9)],
            timeZone: "Europe/Berlin"
        ), account: robin)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        let twelfth = there.window(.day, anchor: day(newYork, 12))
        await store.load(twelfth, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        let shown = try #require(store.events(in: twelfth)?.first { $0.eventId == "holiday" })
        #expect(shown.start == day(newYork, 12))
        #expect(shown.end == day(newYork, 13))
        #expect(store.events(in: twelfth)?.first { $0.eventId == "call" }?.start == at(12, 15))

        for other in [11, 13] {
            let window = there.window(.day, anchor: day(newYork, other))
            await store.load(window, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
            #expect(store.events(in: window)?.contains { $0.eventId == "holiday" } == false)
        }

        // Saved again by a fetch elsewhere, the Berlin windows keep their days: Nov 13's doesn't take the holiday from the month.
        store.absorb([(robin, .success([]))], for: there.window(.day, anchor: day(newYork, 20)))
        let again = CalendarStore(defaults: isolated(), cache: disk)
        let monthThere = there.window(.month, anchor: day(newYork, 9))
        await again.load(monthThere, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        await again.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        let kept = try #require(again.events(in: month)?.first { $0.eventId == "holiday" })
        #expect(kept.start == day(newYork, 12))
        #expect(kept.end == day(newYork, 13))
        let shownAgain = try #require(again.events(in: monthThere)?.first { $0.eventId == "holiday" })
        #expect(shownAgain.start == day(newYork, 12))
        for other in [11, 13] {
            let window = there.window(.day, anchor: day(newYork, other))
            await again.load(window, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
            #expect(again.events(in: window)?.contains { $0.eventId == "holiday" } == false)
        }
    }

    /** The phone moves from Berlin to New York with the store kept: a saved all-day event stays on its day, then and after a restart. */
    @MainActor @Test func anAllDayEventKeepsItsDayWhenThePhoneMovesWhileOpen() async throws {
        let disk = onDisk()
        let berlin = calendar
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        newYork.locale = Locale(identifier: "en_US")
        let there = CalendarDates(calendar: newYork)
        let day = { (zone: Calendar, number: Int) in zone.date(from: DateComponents(year: 2026, month: 11, day: number))! }
        let holiday = CalendarEvent(eventId: "holiday", calendar: mine, title: "Holiday", start: day(berlin, 12), end: day(berlin, 13), allDay: true)
        let month = dates.window(.month, anchor: at(9, 0))

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        store.absorb([(robin, .success([holiday]))], for: month)

        let twentieth = there.window(.day, anchor: day(newYork, 20))
        await store.load(twentieth, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        store.absorb([(robin, .success([]))], for: twentieth)
        let twelfth = there.window(.day, anchor: day(newYork, 12))
        await store.load(twelfth, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        #expect(store.events(in: twelfth)?.first { $0.eventId == "holiday" }?.start == day(newYork, 12))
        #expect(store.events(in: month)?.first { $0.eventId == "holiday" }?.start == day(newYork, 12))

        let after = CalendarStore(defaults: isolated(), cache: disk)
        await after.load(twelfth, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        let kept = try #require(after.events(in: twelfth)?.first { $0.eventId == "holiday" })
        #expect(kept.start == day(newYork, 12))
        #expect(kept.end == day(newYork, 13))
        for other in [11, 13] {
            let window = there.window(.day, anchor: day(newYork, other))
            await after.load(window, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
            #expect(after.events(in: window)?.contains { $0.eventId == "holiday" } == false)
        }
    }

    private func zoned(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /**
     * Only Nov 12 saved, in Kiritimati (+14), opened offline in Honolulu (-10): the two days only touch,
     * but the saved day is Nov 12 here too, so its all-day event is on Nov 12 and no other day.
     */
    @MainActor @Test func aSavedDayKeepsItsAllDayEventAcrossTheDateLine() async throws {
        let disk = onDisk()
        let kiritimati = zoned("Pacific/Kiritimati")
        let honolulu = zoned("Pacific/Honolulu")
        let there = CalendarDates(calendar: honolulu)
        let day = { (zone: Calendar, number: Int) in zone.date(from: DateComponents(year: 2026, month: 11, day: number))! }
        let holiday = CalendarEvent(
            eventId: "holiday", calendar: mine, title: "Holiday", start: day(kiritimati, 12), end: day(kiritimati, 13), allDay: true
        )
        let saved = CalendarDates(calendar: kiritimati).window(.day, anchor: day(kiritimati, 12))
        disk.save(CalendarCache.Saved(
            calendars: [mine], windows: [saved: [holiday]], fetched: [saved: day(kiritimati, 11)], timeZone: "Pacific/Kiritimati"
        ), account: robin)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        let twelfth = there.window(.day, anchor: day(honolulu, 12))
        await store.load(twelfth, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        let shown = try #require(store.events(in: twelfth)?.first { $0.eventId == "holiday" })
        #expect(shown.start == day(honolulu, 12))
        #expect(shown.end == day(honolulu, 13))
        for other in [11, 13] {
            let window = there.window(.day, anchor: day(honolulu, other))
            await store.load(window, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
            #expect((store.events(in: window) ?? []).contains { $0.eventId == "holiday" } == false)
        }
    }

    /**
     * A fetch started in Berlin lands after the phone moved to New York: its all-day event is Berlin's
     * day, so it's dropped rather than saved as New York's, and after a restart the event is still on Nov 12.
     */
    @MainActor @Test func aFetchFromBeforeTheZoneChangedIsDropped() async throws {
        let disk = onDisk()
        let berlin = calendar
        let newYork = zoned("America/New_York")
        let there = CalendarDates(calendar: newYork)
        let day = { (zone: Calendar, number: Int) in zone.date(from: DateComponents(year: 2026, month: 11, day: number))! }
        let holiday = CalendarEvent(eventId: "holiday", calendar: mine, title: "Holiday", start: day(berlin, 12), end: day(berlin, 13), allDay: true)
        var renamed = holiday
        renamed.title = "Late holiday"
        let month = dates.window(.month, anchor: at(9, 0))

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        store.absorb([(robin, .success([holiday]))], for: month, fetchedIn: berlin.timeZone)

        let twelfth = there.window(.day, anchor: day(newYork, 12))
        await store.load(twelfth, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        #expect(!store.absorb([(robin, .success([renamed]))], for: month, fetchedIn: berlin.timeZone))
        let moved = try #require(store.events(in: month)?.first { $0.eventId == "holiday" })
        #expect(moved.title == "Holiday")
        #expect(moved.start == day(newYork, 12))

        let after = CalendarStore(defaults: isolated(), cache: disk)
        await after.load(twelfth, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        let kept = try #require(after.events(in: twelfth)?.first { $0.eventId == "holiday" })
        #expect(kept.start == day(newYork, 12))
        #expect(kept.end == day(newYork, 13))
        let eleventh = there.window(.day, anchor: day(newYork, 11))
        await after.load(eleventh, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: there)
        #expect((after.events(in: eleventh) ?? []).contains { $0.eventId == "holiday" } == false)
    }

    /** An event moved here to a day loaded since its month is on that day after a restart, in the day and the month. */
    @MainActor @Test func anEventMovedToALoadedDayIsThereAfterARestart() async throws {
        let disk = onDisk()
        let month = dates.window(.month, anchor: at(9, 0))
        let twelfth = dates.window(.day, anchor: at(12, 0))
        let dentist = CalendarEvent(eventId: "dentist", calendar: mine, title: "Dentist", start: at(9, 15), end: at(9, 16))

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        store.absorb([(robin, .success([dentist]))], for: month)
        store.absorb([(robin, .success([]))], for: twelfth)
        var draft = EventDraft(editing: dentist)
        draft.move(to: at(12, 15))
        try await store.update(dentist, to: draft, with: RecordingWriter(dates: dates), dates: dates)
        #expect(store.events(in: twelfth)?.map(\.eventId) == ["dentist"])

        let after = CalendarStore(defaults: isolated(), cache: disk)
        await after.load(twelfth, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(after.events(in: twelfth)?.map(\.start) == [at(12, 15)])
        await after.load(month, sources: [robinsMailbox], demo: false, google: GoogleAuth(), dates: dates)
        #expect(after.events(in: month)?.map(\.start) == [at(12, 15)])
    }

    /** A mailbox saved only a month still shows its part of a day another mailbox saved itself. */
    @MainActor @Test func eachMailboxFillsItsOwnPartOfASavedWindow() async throws {
        let disk = onDisk()
        let acme = "robin@acme.example"
        let work = EventCalendar(id: acme, name: "Acme", primary: true, account: acme, writable: true)
        let mailboxes = [robin, acme].map {
            Mailbox(email: $0, name: "Robin", displayName: "Robin", color: "#336699", signature: "", labels: [])
        }
        let day = dates.window(.day, anchor: at(9, 0))
        let month = dates.window(.month, anchor: at(9, 0))
        let lunch = CalendarEvent(eventId: "lunch", calendar: mine, title: "Lunch", start: at(9, 12), end: at(9, 13))
        let review = CalendarEvent(eventId: "review", calendar: work, title: "Review", start: at(9, 15), end: at(9, 16))
        disk.save(CalendarCache.Saved(calendars: [mine], windows: [day: [lunch]]), account: robin)
        disk.save(CalendarCache.Saved(calendars: [work], windows: [month: [review]]), account: acme)

        let store = CalendarStore(defaults: isolated(), cache: disk)
        await store.load(day, sources: mailboxes, demo: false, google: GoogleAuth(), dates: dates)
        #expect(store.events(in: day)?.map(\.eventId) == ["lunch", "review"])
    }

    /** Google may answer for a deleted event with `cancelled` and no times: gone, not a failure. */
    @Test func aCancelledEventWithoutTimesIsGone() throws {
        let cancelled = #"{"id":"abc","status":"cancelled"}"#
        #expect(try GoogleEvents.unlessCancelled(Data(cancelled.utf8), on: mine, me: robin, times: EventTimes(calendar: calendar)) == nil)
        let live = #"{"id":"abc","start":{"dateTime":"2026-11-09T12:00:00+01:00"}}"#
        #expect(try GoogleEvents.unlessCancelled(Data(live.utf8), on: mine, me: robin, times: EventTimes(calendar: calendar))?.eventId == "abc")
    }

    /** A task's event moved to a day not loaded is missing from its old day, and still not gone: it keeps its id. */
    @MainActor @Test func aTasksMovedEventIsntGone() async throws {
        let store = CalendarStore(defaults: isolated())
        let mailbox = Mailbox(email: robin, name: "Robin", displayName: "Robin", color: "#336699", signature: "", labels: [])
        let window = dates.window(.day, anchor: .now)
        await store.load(window, sources: [mailbox], demo: true, google: GoogleAuth(), dates: dates)
        let calendar = try #require((store.lists[robin] ?? []).first { $0.writable })
        let writer = RecordingWriter(dates: dates)
        let start = dates.calendar.date(bySettingHour: 18, minute: 0, second: 0, of: .now)!
        let made = try await store.create(
            EventDraft(calendar: calendar, title: "Demo dinner", start: start, end: start.addingTimeInterval(3600)),
            with: writer, dates: dates
        )
        let link = TaskEvent(made, scope: .occurrence)

        var moved = EventDraft(editing: made)
        moved.move(to: dates.addDays(start, 30))
        try await store.update(made, to: moved, with: writer, dates: dates)

        #expect(store.find(link) == nil)
        #expect(!store.isGone(link))
    }

    /** The window's copy of an event, looked up outside the macros so they wrap no closure. */
    @MainActor private func found(_ event: CalendarEvent, in window: EventWindow, of store: CalendarStore) -> CalendarEvent? {
        let events = store.events(in: window) ?? []
        return events.first { $0.id == event.id }
    }
}

/** Google, as far as the store can tell: it answers as Google would and keeps what it was asked. */
private actor RecordingWriter: EventWriter {
    let dates: CalendarDates
    private(set) var calls: [String] = []
    private(set) var patches: [EventInput] = []

    init(dates: CalendarDates) { self.dates = dates }

    func create(_ input: EventInput, on calendar: EventCalendar, notify: Bool) async throws -> CalendarEvent {
        calls.append("create \(input.title ?? "") notify:\(notify)")
        let blank = CalendarEvent(eventId: "made-\(calls.count)", calendar: calendar, title: "", start: .now, end: .now)
        return input.applied(to: blank, dates: dates)
    }

    func update(_ event: CalendarEvent, with patch: EventInput, notify: Bool) async throws -> CalendarEvent {
        calls.append("update \(event.title) notify:\(notify)")
        patches.append(patch)
        return patch.applied(to: event, dates: dates)
    }

    func delete(_ event: CalendarEvent, notify: Bool) async throws {
        calls.append("delete \(event.title) notify:\(notify)")
    }
}
