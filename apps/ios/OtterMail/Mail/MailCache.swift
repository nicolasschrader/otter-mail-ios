import Foundation

nonisolated final class MailCache: Sendable {
    struct Snapshot: Codable, Sendable {
        var mailbox: Mailbox
        var state: MailboxState
        var threads: [MailThread]
        var version: Int? = MailCache.version

        /**
         * Mail cached before each message carried its own labels gives it its thread's, and
         * sync only fetches threads that change: it's fetched again instead, keeping what
         * the mailbox's watches and Trash need.
         */
        var current: Snapshot {
            guard version != MailCache.version else { return self }
            var fresh = MailboxState(watchedAt: state.watchedAt, watchExpiresAt: state.watchExpiresAt, watchTopic: state.watchTopic)
            fresh.trashedFrom = state.trashedFrom
            fresh.subscription = state.subscription
            return Snapshot(mailbox: mailbox, state: fresh, threads: [])
        }
    }

    static let version = 2

    static let live = MailCache(folder: URL.applicationSupportDirectory.appending(path: "mail", directoryHint: .isDirectory))
    private let folder: URL
    private let queue = DispatchQueue(label: "app.otter.mail.cache", qos: .utility)

    init(folder: URL) { self.folder = folder }

    private func file(_ email: String) -> URL { folder.appending(path: "\(email.lowercased()).json") }

    func load(_ emails: [String]) async -> [Snapshot] {
        await withCheckedContinuation { continuation in
            queue.async {
                let snapshots = emails.compactMap { email -> Snapshot? in
                    guard let data = try? Data(contentsOf: self.file(email)) else { return nil }
                    return (try? JSONDecoder().decode(Snapshot.self, from: data))?.current
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    func save(_ snapshots: [Snapshot]) {
        queue.async {
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            for var cached in snapshots {
                cached.threads = Array(cached.threads.sorted { $0.latest.date > $1.latest.date }.prefix(400))
                try? JSONEncoder().encode(cached).write(to: self.file(cached.mailbox.email), options: .atomic)
            }
        }
    }

    func remove(_ email: String) {
        queue.async { try? FileManager.default.removeItem(at: self.file(email)) }
    }

    func removeAll() {
        queue.async { try? FileManager.default.removeItem(at: self.folder) }
    }
}
