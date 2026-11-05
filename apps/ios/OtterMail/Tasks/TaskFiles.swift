import Foundation

/**
 * The tasks on disk: one JSON file a scope (the signed-in Otter account, or
 * the demo), written atomically as the mail cache and the draft recovery
 * copies are (`MailCache`, `MailStore.saveRecovery`). Nothing leaves the
 * phone.
 */
nonisolated final class TaskFiles: Sendable {
    static let live = TaskFiles(folder: URL.applicationSupportDirectory.appending(path: "tasks", directoryHint: .isDirectory))

    private let folder: URL
    private let queue = DispatchQueue(label: "app.otter.mail.tasks", qos: .utility)

    init(folder: URL) { self.folder = folder }

    private func file(_ scope: String) -> URL { folder.appending(path: "\(scope).json") }

    func exists(_ scope: String) -> Bool {
        queue.sync { FileManager.default.fileExists(atPath: file(scope).path) }
    }

    /** Reads on the writing queue, so it always sees the last save. */
    func load(_ scope: String) -> [MailTask] {
        queue.sync {
            guard let data = try? Data(contentsOf: file(scope)) else { return [] }
            return (try? JSONDecoder().decode([MailTask].self, from: data)) ?? []
        }
    }

    func save(_ tasks: [MailTask], scope: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(tasks) else { return }
            try? data.write(to: self.file(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
