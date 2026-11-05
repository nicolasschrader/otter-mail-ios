import Foundation
import Testing
@testable import Otter_Mail

/**
 * The tasks' pure parts: how the list groups and sorts them (in the calendar's
 * days, `CalendarDates`), the JSON on disk, which reminders are scheduled and
 * what their requests are called, and which notifications route to a task
 * rather than to mail.
 */
struct TaskTests {
    private func zone(_ identifier: String = "Europe/Berlin") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func task(_ content: String, due: Date? = nil, hasTime: Bool = false, reminder: Bool = false,
                      done: Bool = false, created: Date = Date(timeIntervalSince1970: 0)) -> MailTask {
        MailTask(content: content, due: due, hasTime: hasTime, reminder: reminder, done: done, created: created)
    }

    // MARK: Sorting and grouping

    @Test func groupsByWhenATaskIsDue() {
        let calendar = zone()
        let dates = CalendarDates(calendar: calendar)
        let now = at(2026, 3, 10, 14, 0, in: calendar)
        let group = { (task: MailTask) in TaskList.group(of: task, now: now, dates: dates) }

        #expect(group(task("no date")) == .noDate)
        #expect(group(task("yesterday", due: at(2026, 3, 9, 23, 0, in: calendar))) == .overdue)
        #expect(group(task("today, no time", due: at(2026, 3, 10, 9, 0, in: calendar))) == .today)
        // A time that has passed is overdue; later today is still today.
        #expect(group(task("this morning", due: at(2026, 3, 10, 9, 0, in: calendar), hasTime: true)) == .overdue)
        #expect(group(task("tonight", due: at(2026, 3, 10, 20, 0, in: calendar), hasTime: true)) == .today)
        #expect(group(task("tomorrow", due: at(2026, 3, 11, 8, 0, in: calendar), hasTime: true)) == .upcoming)
        #expect(group(task("finished", due: at(2026, 3, 9, 8, 0, in: calendar), done: true)) == .done)
    }

    @Test func sortsSoonestFirstAndTheUndatedLast() {
        let calendar = zone()
        let dates = CalendarDates(calendar: calendar)
        let now = at(2026, 3, 10, 14, 0, in: calendar)
        let later = task("later", due: at(2026, 3, 12, 9, 0, in: calendar))
        let soon = task("soon", due: at(2026, 3, 11, 9, 0, in: calendar))
        let none = task("none")
        let first = task("written first", created: Date(timeIntervalSince1970: 10))
        let second = task("written second", created: Date(timeIntervalSince1970: 20))

        #expect(TaskList.sorted([none, later, soon]).map(\.content) == ["soon", "later", "none"])
        #expect(TaskList.sorted([second, first]).map(\.content) == ["written first", "written second"])

        let sections = TaskList.sections([none, later, soon], now: now, dates: dates)
        #expect(sections.map(\.id) == [.upcoming, .noDate])
        #expect(sections[0].tasks.map(\.content) == ["soon", "later"])
    }

    @Test func sectionsAreInOrderAndFinishedTasksReadNewestFirst() {
        let calendar = zone()
        let dates = CalendarDates(calendar: calendar)
        let now = at(2026, 3, 10, 14, 0, in: calendar)
        var earlier = task("done earlier", done: true)
        earlier.completed = at(2026, 3, 10, 9, 0, in: calendar)
        var later = task("done later", done: true)
        later.completed = at(2026, 3, 10, 13, 0, in: calendar)
        let sections = TaskList.sections([
            earlier,
            later,
            task("no date"),
            task("overdue", due: at(2026, 3, 1, 9, 0, in: calendar)),
            task("today", due: now),
            task("upcoming", due: at(2026, 3, 20, 9, 0, in: calendar)),
        ], now: now, dates: dates)

        #expect(sections.map(\.id) == [.overdue, .today, .upcoming, .noDate, .done])
        #expect(sections.last?.tasks.map(\.content) == ["done later", "done earlier"])
    }

    @Test func labelsTheDueDateInTheCalendarsWords() {
        let calendar = zone()
        var preferences = CalendarPreferences()
        preferences.timeFormat = .twentyFour
        let dates = CalendarDates(calendar: calendar, preferences: preferences)
        let now = at(2026, 3, 10, 14, 0, in: calendar)

        #expect(TaskList.dueLabel(task("none"), now: now, dates: dates) == nil)
        #expect(TaskList.dueLabel(task("day", due: at(2026, 3, 11, 0, 0, in: calendar)), now: now, dates: dates) == "Tomorrow")
        #expect(TaskList.dueLabel(
            task("time", due: at(2026, 3, 10, 18, 30, in: calendar), hasTime: true), now: now, dates: dates
        ) == "Today · 18:30")
    }

    // MARK: Reminders

    @Test func remindsOnlyWhenThereIsATimeStillToCome() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ahead = now.addingTimeInterval(3600)
        #expect(task("day only", due: ahead, reminder: true).reminderAt == nil)
        #expect(task("no reminder", due: ahead, hasTime: true).reminderAt == nil)
        #expect(task("reminds", due: ahead, hasTime: true, reminder: true).reminderAt == ahead)
        #expect(task("finished", due: ahead, hasTime: true, reminder: true, done: true).reminderAt == nil)
    }

    @Test func schedulesTheNearestRemindersAndNothingInThePast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reminding = { (name: String, seconds: TimeInterval) in
            self.task(name, due: now.addingTimeInterval(seconds), hasTime: true, reminder: true)
        }
        let past = reminding("past", -60)
        let soon = reminding("soon", 60)
        let later = reminding("later", 600)
        let plain = task("no reminder", due: now.addingTimeInterval(60))

        let scheduled = TaskReminders.scheduled([later, past, plain, soon], now: now)
        #expect(scheduled.map(\.content) == ["soon", "later"])

        // iOS keeps 64 pending requests an app, so only the nearest are asked for.
        let many = (1...50).map { reminding("task \($0)", TimeInterval($0) * 60) }
        let limited = TaskReminders.scheduled(Array(many.reversed()), now: now, limit: 3)
        #expect(limited.map(\.content) == ["task 1", "task 2", "task 3"])
        #expect(TaskReminders.scheduled(many, now: now).count == TaskReminders.limit)
    }

    @Test func namesOneRequestPerTaskAndFindsItsScope() {
        let id = UUID()
        let identifier = TaskReminders.identifier(id, scope: "demo")
        #expect(identifier == TaskReminders.identifier(id, scope: "demo"))
        #expect(identifier != TaskReminders.identifier(UUID(), scope: "demo"))
        #expect(TaskReminders.scope(of: identifier) == "demo")
        #expect(TaskReminders.scope(of: TaskReminders.identifier(id, scope: "cm9iaW4=")) == "cm9iaW4=")
        #expect(TaskReminders.scope(of: "otter-mail:something") == nil)
        #expect(TaskReminders.scope(of: "mail:demo:\(id.uuidString)") == nil)
    }

    // MARK: Routing

    @Test func routesItsOwnRemindersAndLeavesMailAlone() {
        let id = UUID()
        let reminding = task("reminds")
        let payload = TaskReminders.payload(reminding, scope: "demo")
        #expect(TaskReminders.destination(payload) == TaskDestination(scope: "demo", id: reminding.id))
        #expect(TaskReminders.destination(["otterTask": ["id": id.uuidString, "scope": "demo"]] as [AnyHashable: Any])
            == TaskDestination(scope: "demo", id: id))
        // Mail's notifications (OtterMailApp's AppDelegate) must still reach their conversation.
        #expect(TaskReminders.destination([
            "otter": ["userId": "u1", "email": "robin@otter.example"], "thread": "t1", "message": "m1",
        ] as [AnyHashable: Any]) == nil)
        #expect(TaskReminders.destination(["otterTask": ["id": "not a uuid", "scope": "demo"]] as [AnyHashable: Any]) == nil)
        #expect(TaskReminders.destination(["otterTask": ["id": id.uuidString, "scope": ""]] as [AnyHashable: Any]) == nil)
        #expect(TaskReminders.destination([:] as [AnyHashable: Any]) == nil)
    }

    // MARK: On disk

    @Test func keepsTasksOnDiskPerScope() throws {
        let folder = URL.temporaryDirectory.appending(path: "tasks-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = TaskFiles(folder: folder)

        #expect(!files.exists("demo"))
        #expect(files.load("demo").isEmpty)

        let linked = MailTask(
            content: "Say yes to dinner",
            notes: "Bring the wine.",
            due: Date(timeIntervalSince1970: 1_700_000_000),
            hasTime: true,
            reminder: true,
            email: TaskEmail(mailbox: "robin@otter.example", thread: "t1", message: "m1", subject: "Dinner Saturday?")
        )
        files.save([linked, MailTask(content: "Water the plot")], scope: "demo")

        #expect(files.exists("demo"))
        let loaded = files.load("demo")
        #expect(loaded.count == 2)
        #expect(loaded.first == linked)
        #expect(loaded.first?.email?.thread == "t1")
        // One scope an account: the demo's tasks aren't another's.
        #expect(files.load("cm9iaW4=").isEmpty)
    }

    @Test func readsAFileMissingTheFieldsItDoesntHaveYet() throws {
        let id = UUID()
        let json = Data(#"[{"id":"\#(id.uuidString)","content":"Older build"}]"#.utf8)
        let tasks = try JSONDecoder().decode([MailTask].self, from: json)
        #expect(tasks.count == 1)
        #expect(tasks[0].id == id)
        #expect(tasks[0].content == "Older build")
        #expect(tasks[0].due == nil)
        #expect(!tasks[0].done)
    }

    @Test func takesItsContentAndLinkFromTheConversation() {
        let thread = MailThread(
            id: "t1",
            mailbox: "robin@otter.example",
            subject: "Dinner Saturday? 🍝",
            labels: ["INBOX"],
            messages: [Message(
                id: "m1",
                from: Person(name: "Maya Chen", email: "maya.chen@example.com"),
                to: [Person(name: "Robin", email: "robin@otter.example")],
                cc: [],
                date: Date(timeIntervalSince1970: 1_700_000_000),
                text: "Pasta?",
                html: nil,
                attachments: [],
                unread: true,
                starred: false,
                draft: false,
                headers: [:]
            )]
        )
        let task = MailTask(from: thread, mailbox: "robin@otter.example")
        #expect(task.content == "Dinner Saturday? 🍝")
        #expect(task.email?.mailbox == "robin@otter.example")
        #expect(task.email?.thread == "t1")
        #expect(task.email?.message == "m1")
        // Without notes, a reminder says which conversation it came from.
        #expect(task.reminderBody == "From: Dinner Saturday? 🍝")
    }
}
