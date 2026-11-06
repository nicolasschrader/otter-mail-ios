import Foundation

/**
 * The demo's tasks, as `DemoCalendar` is its calendar: a few made-up ones
 * placed around today, two of them linked to the demo mailbox's own
 * conversations, so Tasks has something in it without an account. No reminders,
 * since the app asks for notifications only when the user sets one.
 */
nonisolated enum DemoTasks {
    private static let mailbox = "demo@otter.example"

    /** As the web demo's Todoist has an Inbox and Work (apps/web/src/web/demo/todoist.ts). */
    static let home = TaskProject(id: "demo-home", name: "Home")
    static let work = TaskProject(id: "demo-work", name: "Work")
    static let projects = [home, work]

    static func seed(now: Date = .now, calendar: Calendar = .current) -> [MailTask] {
        let day = { (ahead: Int) in calendar.date(byAdding: .day, value: ahead, to: calendar.startOfDay(for: now)) ?? now }
        let at = { (date: Date, hour: Int) in calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date }
        return [
            MailTask(
                content: "Say yes to dinner on Saturday",
                notes: "Offer to bring the wine.",
                due: at(day(0), 18),
                hasTime: true,
                created: now.addingTimeInterval(-3600),
                email: TaskEmail(mailbox: mailbox, thread: "\(mailbox)/2", subject: "Dinner Saturday? 🍝")
            ),
            MailTask(
                content: "Check in for the flight to Lisbon",
                due: day(2),
                created: now.addingTimeInterval(-7200),
                email: TaskEmail(
                    mailbox: mailbox,
                    thread: "\(mailbox)/3",
                    subject: "Your flight to Lisbon is confirmed — TP 1352, Fri 16 Oct"
                )
            ),
            MailTask(content: "Pick up the parcel", due: day(-1), created: now.addingTimeInterval(-86400 * 3), projectId: home.id),
            MailTask(
                content: "Water the garden plot", notes: "The raised beds first.", created: now.addingTimeInterval(-86400),
                projectId: home.id
            ),
            MailTask(content: "Draft the offsite agenda", due: day(5), created: now.addingTimeInterval(-5400), projectId: work.id),
            MailTask(
                content: "Read the welcome message",
                done: true,
                completed: now.addingTimeInterval(-1800),
                created: now.addingTimeInterval(-86400 * 2),
                email: TaskEmail(mailbox: mailbox, thread: "\(mailbox)/0", subject: "Welcome to the Otter Mail demo")
            ),
        ]
    }
}
