import Foundation

/**
 * Each mailbox's events on disk, by window, so the calendar shows what it had
 * at once after a restart while Google is asked again. Written atomically as
 * `MailCache` and `TaskFiles` write theirs.
 */
nonisolated final class CalendarFiles: Sendable {
    static let live = CalendarFiles(folder: URL.cachesDirectory.appending(path: "calendar", directoryHint: .isDirectory))

    private let folder: URL
    private let queue = DispatchQueue(label: "app.otter.mail.calendar", qos: .utility)

    init(folder: URL) { self.folder = folder }

    private func file(_ account: String) -> URL { folder.appending(path: "\(account.lowercased()).json") }

    /** Read on the writing queue, so it sees the last save. */
    func load(_ account: String) -> [EventWindow: [CalendarEvent]] {
        queue.sync {
            guard let data = try? Data(contentsOf: file(account)) else { return [:] }
            return (try? JSONDecoder().decode([EventWindow: [CalendarEvent]].self, from: data)) ?? [:]
        }
    }

    func save(_ windows: [EventWindow: [CalendarEvent]], account: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(windows)
                .write(to: self.file(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func remove(_ account: String) {
        queue.async { try? FileManager.default.removeItem(at: self.file(account)) }
    }

    func removeAll() {
        queue.async { try? FileManager.default.removeItem(at: self.folder) }
    }
}
