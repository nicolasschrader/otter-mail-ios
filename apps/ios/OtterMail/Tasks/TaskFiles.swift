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

    /**
     * The scope's tasks, read on the writing queue so it always sees the last
     * save: nil when the scope has no file yet, and a throw when there is one
     * that can't be read or decoded, which the store leaves alone rather than
     * writing an empty list over.
     */
    func load(_ scope: String) throws -> [MailTask]? {
        try queue.sync {
            let file = file(scope)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try JSONDecoder().decode([MailTask].self, from: try Data(contentsOf: file))
        }
    }

    /** Returns once the file is on disk, so a failure reaches whoever asked for the save. */
    func save(_ tasks: [MailTask], scope: String) async throws {
        let (folder, file) = (folder, file(scope))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(tasks)
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
