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
    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "This iPhone's task file couldn't be read, so nothing was written over it. Reopen Otter Mail to try again."
            }
        }
    }

    private(set) var tasks: [MailTask] = []
    /** The lists made here, after the Inbox (`TaskProject.inbox`), which is always there. */
    private(set) var projects: [TaskProject] = []
    /** The list shown, nil for All; kept on this iPhone for the scope. */
    private(set) var selected: String?
    private(set) var scope: String?
    /** Notifications are off for Otter Mail, so a reminder can't arrive (the editor says so). */
    private(set) var remindersDenied = false
    /** Reminders iOS has no room for yet: they're asked for as the nearer ones arrive. */
    private(set) var waiting: Set<UUID> = []
    /** A save that didn't land, for the screen to show. */
    var failure: String?

    @ObservationIgnored private let files: TaskFiles
    @ObservationIgnored private let reminders: any TaskReminding
    /** The reminder work in flight, so a newer job queues behind it rather than racing it. */
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /** The file couldn't be read: it keeps whatever it holds until the next sign-in. */
    @ObservationIgnored private var unreadable = false

    @ObservationIgnored private let defaults: UserDefaults

    init(files: TaskFiles = .live, reminders: any TaskReminding = LiveReminders(), defaults: UserDefaults = .standard) {
        self.files = files
        self.reminders = reminders
        self.defaults = defaults
    }

    /** The Inbox, then the lists made here. */
    var lists: [TaskProject] { [.inbox] + projects }

    /** The tasks on the list shown. */
    var visible: [MailTask] { TaskProject.filter(tasks, project: selected) }

    func project(_ id: String?) -> TaskProject? { lists.first { $0.id == id } }

    /** One scope an account, the same slug the draft recovery uses, and `demo` for the demo. */
    static func scope(user: String?) -> String {
        guard let user else { return "demo" }
        return Data(user.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
    }

    func open(_ scope: String, seed: [MailTask] = [], seedProjects: [TaskProject] = []) {
        self.scope = scope
        unreadable = false
        failure = nil
        do {
            if let known = try files.load(scope) {
                tasks = known
            } else {
                tasks = seed
                persist()
            }
            if let known = try files.loadProjects(scope) {
                projects = known
            } else {
                projects = seedProjects
                if !seedProjects.isEmpty { persistProjects() }
            }
        } catch {
            tasks = []
            projects = []
            unreadable = true
            failure = Failure.unreadable.localizedDescription
            ErrorReports.capture(error, scope: "tasks")
        }
        let chosen = defaults.string(forKey: Self.selectedKey(scope))
        selected = lists.contains { $0.id == chosen } ? chosen : nil
        reschedule()
    }

    nonisolated static func selectedKey(_ scope: String) -> String { "tasks:project:\(scope)" }

    /** Shows one list, or every task for nil. */
    func select(_ project: String?) {
        guard let scope, project == nil || self.project(project) != nil else { return }
        selected = project
        defaults.set(project, forKey: Self.selectedKey(scope))
    }

    /** A new list, kept on disk before it's shown, and then the one shown. */
    @discardableResult
    func createProject(_ name: String) async throws -> TaskProject? {
        guard let scope, let name = TaskProject.named(name) else { return nil }
        let made = TaskProject(id: UUID().uuidString, name: name)
        let keeping = projects + [made]
        try await writeProjects(keeping, scope: scope)
        projects = keeping
        select(made.id)
        return made
    }

    /** A list made here takes a new name; the Inbox keeps its own. */
    func renameProject(_ id: String, to name: String) async throws {
        guard let scope, let name = TaskProject.named(name),
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var keeping = projects
        keeping[index].name = name
        try await writeProjects(keeping, scope: scope)
        projects = keeping
    }

    /** Signing out: this account's reminders go, its tasks wait on disk for the next sign-in. */
    func close() {
        let closing = scope
        tasks = []
        projects = []
        selected = nil
        scope = nil
        waiting = []
        failure = nil
        unreadable = false
        guard let closing else { return }
        // Delivered reminders are their own list, and leaving the demo doesn't clear it otherwise.
        notify { [reminders] _ in
            let mine = await reminders.pending() + reminders.delivered()
            let ours = mine.filter { TaskReminders.scope(of: $0) == closing }
            await reminders.remove(pending: ours, delivered: ours)
        }
    }

    func task(_ id: UUID) -> MailTask? { tasks.first { $0.id == id } }

    func contains(_ id: UUID) -> Bool { task(id) != nil }

    func linked(to event: CalendarEvent) -> [MailTask] { TaskLinks.linked(tasks, to: event) }

    func linked(thread: String, mailboxes: [String]) -> [MailTask] { TaskLinks.linked(tasks, thread: thread, mailboxes: mailboxes) }

    /** A task's links changed from the event or conversation they point at, kept as Save keeps it: on disk first. */
    func update(_ id: UUID, _ change: (MailTask) -> MailTask) async throws {
        guard let task = task(id) else { return }
        try await save(change(task))
    }

    /** Keeps a task, and only confirms it once the file is written (the editor waits on this). */
    func save(_ task: MailTask) async throws {
        guard let scope else { return }
        var task = task
        task.content = task.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.content.isEmpty else { return }
        var keeping = tasks
        if let index = keeping.firstIndex(where: { $0.id == task.id }) {
            keeping[index] = task
        } else {
            keeping.append(task)
        }
        // On disk first: a write that throws leaves the list as it was, and the editor says why.
        try await write(keeping, scope: scope)
        tasks = keeping
        // Nothing is asked of the user for a reminder that has already passed.
        if let at = task.reminderAt, at > .now {
            await askForReminders()
        } else {
            reschedule()
        }
    }

    func delete(_ task: MailTask) {
        guard let scope else { return }
        tasks.removeAll { $0.id == task.id }
        persist()
        let gone = TaskReminders.identifier(task.id, scope: scope)
        notify { [reminders] _ in await reminders.remove(pending: [gone], delivered: [gone]) }
        reschedule()
    }

    func setDone(_ done: Bool, _ task: MailTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].done = done
        tasks[index].completed = done ? .now : nil
        persist()
        reschedule()
    }

    /** Asked only when the user sets a reminder, never before. */
    func askForReminders() async {
        if await reminders.status() == .notDetermined { await reminders.ask() }
        await checkReminders()
        reschedule()
    }

    func checkReminders() async {
        remindersDenied = await reminders.status() == .denied
    }

    /** The nearest reminders, as requests; the ones that no longer apply are taken down. */
    func reschedule() {
        guard let scope else { return }
        let due = TaskReminders.scheduled(tasks)
        waiting = Set(TaskReminders.waiting(tasks).map(\.id))
        notify { [weak self] mine in await self?.apply(due, scope: scope, generation: mine) }
    }

    /** Whether this task's reminder is one of the ones waiting, counted with the task as it stands. */
    func isWaiting(_ task: MailTask) -> Bool {
        var counted = tasks.filter { $0.id != task.id }
        counted.append(task)
        return TaskReminders.waiting(counted).contains { $0.id == task.id }
    }

    /** The reminder work queued so far, which the tests wait on. */
    func settled() async {
        await queued?.value
    }

    /**
     * Reminder work, one job at a time: each waits for the one before it, and the
     * token it carries goes stale the moment anything else is asked for, so a job
     * from before a deletion or a sign-out can't put its requests back.
     */
    private func notify(_ work: @escaping (Int) async -> Void) {
        generation += 1
        let mine = generation
        let previous = queued
        queued = Task {
            await previous?.value
            await work(mine)
        }
    }

    private func current(_ generation: Int) -> Bool { generation == self.generation }

    private func apply(_ due: [MailTask], scope: String, generation mine: Int) async {
        let status = await reminders.status()
        let allowed = [.authorized, .provisional, .ephemeral].contains(status)
        guard current(mine) else { return }
        let keep = allowed ? Set(due.map { TaskReminders.identifier($0.id, scope: scope) }) : []
        let stale = await reminders.pending().filter { TaskReminders.scope(of: $0) == scope && !keep.contains($0) }
        guard current(mine) else { return }
        await reminders.remove(pending: stale, delivered: [])
        guard allowed else { return }
        for task in due {
            guard current(mine) else { return }
            await reminders.add(task, scope: scope)
        }
    }

    /** Writes in the background, for the changes the list makes; a failure shows there. */
    private func persist() {
        guard let scope else { return }
        let keeping = tasks
        Task {
            do { try await write(keeping, scope: scope) } catch { failure = error.localizedDescription }
        }
    }

    private func write(_ tasks: [MailTask], scope: String) async throws {
        guard !unreadable else { throw Failure.unreadable }
        try await files.save(tasks, scope: scope)
    }

    private func persistProjects() {
        guard let scope else { return }
        let keeping = projects
        Task {
            do { try await writeProjects(keeping, scope: scope) } catch { failure = error.localizedDescription }
        }
    }

    private func writeProjects(_ projects: [TaskProject], scope: String) async throws {
        guard !unreadable else { throw Failure.unreadable }
        try await files.saveProjects(projects, scope: scope)
    }
}
