import Foundation
import Observation
import UserNotifications

/**
 * The tasks the screens render from, and their local reminders. New logic, and
 * local: tasks belong to the signed-in Otter account (or to the demo), stay on
 * this iPhone and sync nowhere. Signing out leaves them on disk and takes their
 * reminders down; signing in again schedules them afresh.
 */
@Observable
final class TaskStore {
    private(set) var tasks: [MailTask] = []
    private(set) var scope: String?
    /** Notifications are off for Otter Mail, so a reminder can't arrive (the editor says so). */
    private(set) var remindersDenied = false

    @ObservationIgnored private let files: TaskFiles

    init(files: TaskFiles = .live) { self.files = files }

    /** One scope an account, the same slug the draft recovery uses, and `demo` for the demo. */
    static func scope(user: String?) -> String {
        guard let user else { return "demo" }
        return Data(user.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
    }

    func open(_ scope: String, seed: [MailTask] = []) {
        self.scope = scope
        let known = files.exists(scope)
        tasks = known ? files.load(scope) : seed
        if !known { files.save(tasks, scope: scope) }
        reschedule()
    }

    /** Signing out: this account's reminders go, its tasks wait on disk for the next sign-in. */
    func close() {
        let closing = scope
        tasks = []
        scope = nil
        guard let closing else { return }
        Task { await Self.forget(scope: closing) }
    }

    func task(_ id: UUID) -> MailTask? { tasks.first { $0.id == id } }

    func contains(_ id: UUID) -> Bool { task(id) != nil }

    func save(_ task: MailTask) {
        guard let scope else { return }
        var task = task
        task.content = task.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.content.isEmpty else { return }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        files.save(tasks, scope: scope)
        // Nothing is asked of the user for a reminder that has already passed.
        if let at = task.reminderAt, at > .now {
            Task { await askForReminders() }
        } else {
            reschedule()
        }
    }

    func delete(_ task: MailTask) {
        guard let scope else { return }
        tasks.removeAll { $0.id == task.id }
        files.save(tasks, scope: scope)
        let identifier = TaskReminders.identifier(task.id, scope: scope)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        reschedule()
    }

    func setDone(_ done: Bool, _ task: MailTask) {
        guard var found = self.task(task.id) else { return }
        found.done = done
        found.completed = done ? .now : nil
        save(found)
    }

    /** Asked only when the user sets a reminder, never before. */
    func askForReminders() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await checkReminders()
        reschedule()
    }

    func checkReminders() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        remindersDenied = status == .denied
    }

    /** The nearest reminders, as requests; the ones that no longer apply are taken down. */
    func reschedule() {
        guard let scope else { return }
        let requests = TaskReminders.scheduled(tasks).map { Self.request($0, scope: scope) }
        Task { await Self.apply(requests, scope: scope) }
    }

    private static func apply(_ requests: [UNNotificationRequest], scope: String) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let allowed = [.authorized, .provisional, .ephemeral].contains(status)
        let keep = allowed ? Set(requests.map(\.identifier)) : []
        let mine = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { TaskReminders.scope(of: $0) == scope && !keep.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: mine)
        guard allowed else { return }
        // The same identifier replaces its pending request, so an edited task keeps one.
        for request in requests { try? await center.add(request) }
    }

    private static func forget(scope: String) async {
        let center = UNUserNotificationCenter.current()
        let mine = await center.pendingNotificationRequests().map(\.identifier).filter { TaskReminders.scope(of: $0) == scope }
        center.removePendingNotificationRequests(withIdentifiers: mine)
        center.removeDeliveredNotifications(withIdentifiers: mine)
    }

    private static func request(_ task: MailTask, scope: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = task.content
        content.body = task.reminderBody
        content.sound = .default
        content.userInfo = TaskReminders.payload(task, scope: scope)
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: task.reminderAt ?? .now)
        return UNNotificationRequest(
            identifier: TaskReminders.identifier(task.id, scope: scope),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        )
    }
}
