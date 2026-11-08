import Foundation
import Testing
@testable import Otter_Mail

/**
 * A task's links to mail and events: files from before several links (one
 * `email`) read as one link and are written so those builds still read them,
 * a link a build can't read is left out rather than the task, and an event's
 * link reaches its occurrence or its whole series.
 */
struct TaskLinkTests {
    private let id = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func decode(_ json: String) throws -> MailTask {
        try JSONDecoder().decode(MailTask.self, from: Data(json.utf8))
    }

    private func email(_ thread: String, mailbox: String = "robin@otter.example") -> TaskEmail {
        TaskEmail(mailbox: mailbox, thread: thread, message: "m-\(thread)", subject: "Subject \(thread)")
    }

    private func event(
        _ eventId: String, series: String? = nil, originalStart: Date? = nil, calendar: String = "work",
        account: String = "robin@otter.example"
    ) -> CalendarEvent {
        CalendarEvent(
            eventId: eventId, calendar: EventCalendar(id: calendar, name: "Work", account: account), title: "Standup",
            start: originalStart ?? start, end: (originalStart ?? start).addingTimeInterval(900), recurring: series != nil,
            seriesId: series, originalStart: originalStart
        )
    }

    // MARK: Migration

    @Test func readsTheOneEmailOfAnOlderFileAsItsOnlyLink() throws {
        let task = try decode(#"""
        {"id":"\#(id.uuidString)","content":"Say yes","email":{"mailbox":"robin@otter.example","thread":"t1","message":"m1","subject":"Dinner?"}}
        """#)
        #expect(task.emails == [TaskEmail(mailbox: "robin@otter.example", thread: "t1", message: "m1", subject: "Dinner?")])
        #expect(task.email?.thread == "t1")
        #expect(task.events.isEmpty)
    }

    @Test func readsAnOlderFileWithoutLinks() throws {
        let task = try decode(#"{"id":"\#(id.uuidString)","content":"Water the plot"}"#)
        #expect(task.emails.isEmpty)
        #expect(task.events.isEmpty)
        #expect(task.email == nil)
    }

    @Test func prefersTheListOverTheOneEmailItRepeats() throws {
        let task = try decode(#"""
        {"id":"\#(id.uuidString)","content":"Both",
         "email":{"mailbox":"robin@otter.example","thread":"t1","subject":"One"},
         "emails":[{"mailbox":"robin@otter.example","thread":"t1","subject":"One"},{"mailbox":"robin@otter.example","thread":"t2","subject":"Two"}]}
        """#)
        #expect(task.emails.map(\.thread) == ["t1", "t2"])
    }

    @Test func writesTheFirstLinkAsTheOneEmailForOlderBuilds() throws {
        let task = MailTask(content: "Linked", emails: [email("t1"), email("t2")])
        let data = try JSONEncoder().encode(task)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["email"] as? [String: Any])?["thread"] as? String == "t1")
        #expect((object["emails"] as? [Any])?.count == 2)

        // What an older build reads is the first link; this build reads every one.
        #expect(try JSONDecoder().decode(OlderTask.self, from: data).email?.thread == "t1")
        #expect(try JSONDecoder().decode(MailTask.self, from: data) == task)
    }

    @Test func roundTripsEmailsAndEvents() throws {
        let series = TaskEvent(event("standup_1", series: "standup", originalStart: start), scope: .series)
        let one = TaskEvent(event("call"), scope: .occurrence)
        let task = MailTask(content: "Both", emails: [email("t1")], events: [series, one])
        let decoded = try JSONDecoder().decode(MailTask.self, from: JSONEncoder().encode(task))
        #expect(decoded == task)
        #expect(decoded.events.map(\.scope) == [.series, .occurrence])
    }

    @Test func leavesOutALinkItCantReadAndKeepsTheTask() throws {
        let task = try decode(#"""
        {"id":"\#(id.uuidString)","content":"Mixed",
         "emails":[{"mailbox":"robin@otter.example","thread":"t1","subject":"One"},{"thread":42}],
         "events":[{"account":"robin@otter.example","calendarId":"work","eventId":"e1","title":"Call","start":800000000},{"title":"no ids"}]}
        """#)
        #expect(task.content == "Mixed")
        #expect(task.emails.map(\.thread) == ["t1"])
        #expect(task.events.map(\.eventId) == ["e1"])
        #expect(task.events.first?.provider == "google")
    }

    @Test func readsAScopeItDoesntKnowAsTheOneOccurrence() throws {
        let task = try decode(#"""
        {"id":"\#(id.uuidString)","content":"Newer",
         "events":[{"account":"Robin@Otter.example","calendarId":"work","eventId":"e1","seriesId":"s","scope":"thisAndFollowing","title":"Call","start":800000000}]}
        """#)
        #expect(task.events.first?.scope == .occurrence)
        #expect(task.events.first?.account == "robin@otter.example")
    }

    @Test func linksOnlyAnEventOfASeriesAsTheSeries() {
        let single = TaskEvent(event("call"), scope: .series)
        #expect(single.scope == .occurrence)
        #expect(single.scoped(.series).scope == .occurrence)
    }

    // MARK: Links

    @Test func keepsOneLinkATarget() {
        var task = MailTask(content: "Dedup", email: email("t1"), emails: [email("t1", mailbox: "Robin@Otter.example"), email("t2")])
        #expect(task.emails.map(\.thread) == ["t1", "t2"])
        task = TaskLinks.linking(task, email: email("t2"))
        #expect(task.emails.count == 2)

        let occurrence = TaskEvent(event("standup_1", series: "standup", originalStart: start), scope: .occurrence)
        task = TaskLinks.linking(TaskLinks.linking(task, event: occurrence), event: occurrence)
        #expect(task.events.count == 1)
        // The series is another link than its occurrence.
        task = TaskLinks.linking(task, event: occurrence.scoped(.series))
        #expect(task.events.count == 2)
    }

    @Test func rescopesInPlaceWithoutMakingASecondLink() {
        let occurrence = TaskEvent(event("standup_1", series: "standup", originalStart: start), scope: .occurrence)
        var task = MailTask(content: "Rescope", events: [occurrence])
        task = TaskLinks.rescoping(task, event: occurrence.key, to: .series)
        #expect(task.events.map(\.scope) == [.series])
        // Widening an occurrence to a series already linked folds them into one.
        task = MailTask(content: "Fold", events: [occurrence, occurrence.scoped(.series)])
        task = TaskLinks.rescoping(task, event: occurrence.key, to: .series)
        #expect(task.events.count == 1)
    }

    @Test func unlinkingKeepsTheTaskAndItsOtherLinks() {
        let call = TaskEvent(event("call"), scope: .occurrence)
        var task = MailTask(content: "Keep", emails: [email("t1"), email("t2")], events: [call])
        task = TaskLinks.unlinking(task, email: email("t1").key)
        task = TaskLinks.unlinking(task, event: call.key)
        #expect(task.content == "Keep")
        #expect(task.emails.map(\.thread) == ["t2"])
        #expect(task.events.isEmpty)
    }

    @Test func findsTheTasksOfAConversationUnderAnyOfItsAddresses() {
        let linked = MailTask(content: "Alias", email: email("t1", mailbox: "Robin@Otter.example"))
        let other = MailTask(content: "Other", email: email("t2"))
        let found = TaskLinks.linked([linked, other], thread: "t1", mailboxes: ["alias@otter.example", "robin@otter.example"])
        #expect(found.map(\.content) == ["Alias"])
    }

    @Test func reachesAnOccurrenceOrTheWholeSeries() {
        let first = event("standup_1", series: "standup", originalStart: start)
        let next = event("standup_2", series: "standup", originalStart: start.addingTimeInterval(86400))
        let elsewhere = event("standup_2", series: "standup", originalStart: start, calendar: "home")

        let occurrence = TaskEvent(first, scope: .occurrence)
        #expect(occurrence.matches(first))
        #expect(!occurrence.matches(next))
        #expect(!occurrence.matches(elsewhere))

        let series = TaskEvent(first, scope: .series)
        #expect(series.matches(first))
        #expect(series.matches(next))
        #expect(!series.matches(elsewhere))

        let tasks = [MailTask(content: "One", events: [occurrence]), MailTask(content: "All", events: [series])]
        #expect(TaskLinks.linked(tasks, to: next).map(\.content) == ["All"])
        #expect(TaskLinks.linked(tasks, to: first).map(\.content) == ["One", "All"])
    }

    @Test func findsAMovedOccurrenceByWhereItWas() {
        let linked = TaskEvent(event("standup_1", series: "standup", originalStart: start), scope: .occurrence)
        var moved = event("standup_moved", series: "standup", originalStart: start)
        moved.start = start.addingTimeInterval(7200)
        #expect(linked.matches(moved))
    }

    @Test func keepsWhatTheEventSaidForWhenItsGone() {
        let link = TaskEvent(event("call"), scope: .occurrence)
        let kept = link.snapshot(calendar: nil)
        #expect(kept.title == "Standup")
        #expect(kept.start == start)
        #expect(kept.end == start.addingTimeInterval(900))
        #expect(kept.calendar.id == "work")
    }
}

/** A task as builds from before several links read it. */
private nonisolated struct OlderTask: Decodable {
    var email: TaskEmail?
}
