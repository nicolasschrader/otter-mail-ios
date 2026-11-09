import Foundation
import Testing
@testable import Otter_Mail

struct AllNewTests {
    private func message(_ id: String, from: String, at date: Date, unread: Bool, labels: Set<String> = ["INBOX"], headers: [String: String] = [:]) -> Message {
        Message(id: id, from: Person(name: from, email: "\(from)@example.com"), to: [], cc: [], date: date,
                text: "", html: nil, attachments: [], unread: unread, starred: false, draft: false, headers: headers, labels: labels)
    }

    @Test func keepsInboxMailBesideTrashedMessagesAndArchivedCopies() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let mailbox = Mailbox(email: "me@example.com", name: "Me", displayName: "Me", color: "#336699", signature: "", labels: [])
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX", "ARCHIVE", "TRASH"], messages: [
            message("old", from: "ann", at: t, unread: false, labels: ["TRASH"]),
            message("archived", from: "bob", at: t + 10, unread: false, labels: ["ARCHIVE"], headers: ["Message-ID": "<b@x>"]),
            message("inbox", from: "bob", at: t + 10, unread: true, labels: ["INBOX"], headers: ["Message-ID": "<b@x>"]),
        ])
        let store = MailStore(preferences: Preferences(), mailboxes: [mailbox], threads: [thread])
        let entries = AllNew.entries(inboxes: [(scope: mailbox.email, threads: store.inboxMail(scope: mailbox.email))], mine: [:])

        #expect(store.threads(in: .inbox, scope: mailbox.email).isEmpty)
        #expect(entries.map(\.message.id) == ["inbox"])
    }

    @Test func anInboxMessageBesideATrashedOneIsActedOnAsInboxMail() throws {
        let mailbox = Mailbox(email: "me@example.com", name: "Me", displayName: "Me", color: "#336699", signature: "", labels: [])
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX", "TRASH"], messages: [
            message("old", from: "ann", at: .now - 10, unread: false, labels: ["TRASH"]),
            message("inbox", from: "bob", at: .now, unread: true),
        ])
        let store = MailStore(preferences: Preferences(), mailboxes: [mailbox], threads: [thread])
        let entry = try #require(AllNew.entries(inboxes: [(scope: mailbox.email, threads: store.inboxMail(scope: mailbox.email))], mine: [:]).first)

        #expect(entry.acted.labels == ["INBOX"])
        #expect(store.canArchive(entry.acted))
    }

    @MainActor @Test func trashingAnInboxMessageBesideATrashedOneTrashesItAndUndoBringsItBack() async throws {
        let mailbox = Mailbox(email: "me@example.com", name: "Me", displayName: "Me", color: "#336699", signature: "", labels: [])
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX", "TRASH"], messages: [
            message("old", from: "ann", at: .now - 10, unread: false, labels: ["TRASH"]),
            message("inbox", from: "bob", at: .now, unread: true),
        ])
        let store = MailStore(preferences: Preferences(), mailboxes: [mailbox], threads: [thread])
        let provider = TrashProvider()
        let cache = MailCache(folder: URL.temporaryDirectory.appending(path: "AllNew-\(UUID())"))
        store.sync = MailSync(store: store, google: GoogleAuth(), cache: cache, providers: [mailbox.email: provider])
        let listed = { AllNew.entries(inboxes: [(scope: mailbox.email, threads: store.inboxMail(scope: mailbox.email))], mine: [:]) }
        let entry = try #require(listed().first)

        store.trash(entry.acted.id)
        #expect(listed().isEmpty)
        #expect(store.undoAction?.trash == true)
        store.undo()
        #expect(listed().map(\.message.id) == ["inbox"])

        store.trash(entry.acted.id)
        store.commitPendingAction()
        for _ in 0..<100 where provider.trashed.isEmpty { await Task.yield() }
        #expect(provider.trashed == ["t"])
        #expect(listed().isEmpty)
    }

    @Test func trashingAndArchivingLeaveTheListAndUndoBringsMailBack() {
        let mailbox = Mailbox(email: "me@example.com", name: "Me", displayName: "Me", color: "#336699", signature: "", labels: [])
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX"], messages: [
            message("m", from: "ann", at: .now, unread: true),
        ])
        let store = MailStore(preferences: Preferences(), mailboxes: [mailbox], threads: [thread])
        let listed = { AllNew.entries(inboxes: [(scope: mailbox.email, threads: store.inboxMail(scope: mailbox.email))], mine: [:]).map(\.message.id) }

        store.trash("t")
        #expect(listed().isEmpty)
        store.undo()
        #expect(listed() == ["m"])
        store.archive("t")
        #expect(listed().isEmpty)
        store.undo()
        #expect(listed() == ["m"])
    }

    @Test func theReaderKeepsThePickedCopyOfADuplicatedMessage() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let thread = MailThread(id: "t", mailbox: "me@example.com", subject: "Plans", labels: ["INBOX", "ARCHIVE"], messages: [
            message("archived", from: "bob", at: t, unread: false, labels: ["ARCHIVE"], headers: ["Message-ID": "<b@x>"]),
            message("inbox", from: "bob", at: t, unread: false, labels: ["INBOX"], headers: ["Message-ID": "<b@x>"]),
            message("newer", from: "ann", at: t + 10, unread: false),
        ])

        #expect(thread.distinctMessages(picked: "inbox").map(\.id) == ["inbox", "newer"])
    }

    @Test func mailCachedWithoutEachMessagesLabelsIsFetchedAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mailbox = Mailbox(email: "me@example.com", name: "Me", displayName: "Me", color: "#336699", signature: "", labels: [])
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX"], messages: [
            message("m", from: "ann", at: .now, unread: false),
        ])
        let old = MailCache.Snapshot(mailbox: mailbox, state: MailboxState(historyID: "7", watchTopic: "topic"), threads: [thread], version: nil)
        try JSONEncoder().encode(old).write(to: folder.appending(path: "me@example.com.json"))

        let loaded = try #require(await MailCache(folder: folder).load([mailbox.email]).first)

        #expect(loaded.threads.isEmpty)
        #expect(loaded.state.historyID == nil)
        #expect(loaded.state.watchTopic == "topic")
    }

    @Test func listsBothMailboxesMessagesOneByOneNewestFirstWithReadOnesNotBold() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let home = MailThread(id: "h", mailbox: "me@example.com", subject: "Dinner", labels: ["INBOX"], messages: [
            message("h0", from: "ann", at: t - 10, unread: false, labels: []),
            message("h1", from: "ann", at: t, unread: false),
            message("h2", from: "me", at: t + 10, unread: false),
            message("h3", from: "ann", at: t + 30, unread: true),
        ])
        let work = MailThread(id: "w", mailbox: "work@example.com", subject: "Report", labels: ["INBOX"], messages: [
            message("w1", from: "bob", at: t + 20, unread: false),
        ])
        let entries = AllNew.entries(
            inboxes: [(scope: "me@example.com", threads: [home]), (scope: "work@example.com", threads: [work])],
            mine: ["me@example.com": ["me@example.com"], "work@example.com": ["work@example.com"]]
        )

        #expect(entries.map(\.message.id) == ["h3", "w1", "h1"])
        #expect(entries.map(\.row.unread) == [true, false, false])
        #expect(entries.map(\.row.mailbox) == ["me@example.com", "work@example.com", "me@example.com"])
        #expect(entries.allSatisfy { $0.row.messages.count == 1 })
        #expect(entries.map(\.opened.message) == ["h3", "w1", "h1"])
    }
}

/** Takes every change, writing down the conversations it was asked to trash. */
@MainActor
private final class TrashProvider: MailProvider {
    private(set) var trashed: [String] = []

    var capabilities: MailCapabilities { .gmail }
    var takesTurns: Bool { false }
    var hasArchive: Bool { false }

    func apply(_ change: MailStore.Change, to thread: MailThread, _ state: inout MailboxState) async throws -> MailDelta {
        if case .trash = change { trashed.append(thread.id) }
        return MailDelta()
    }

    func sync(_ state: inout MailboxState, known: [MailThread]) async throws -> MailDelta { MailDelta() }
    func loadMore(_ folder: Folder, _ state: inout MailboxState, known: [MailThread]) async throws -> MailDelta { MailDelta() }
    func search(_ query: String, known: [MailThread]) async throws -> (ids: [String], threads: [MailThread]) { ([], []) }
    func labels() async throws -> [MailLabel] { [] }
    func signature() async throws -> String? { nil }
    func setSignature(_ html: String) async throws -> String { html }
    func refresh(_ thread: MailThread, _ state: inout MailboxState, known: [MailThread]) async throws -> MailDelta { MailDelta() }
    func send(_ message: Outgoing, _ state: inout MailboxState, known: [MailThread]) async throws -> MailDelta { MailDelta() }
    func saveDraft(_ message: Outgoing, _ state: inout MailboxState, known: [MailThread]) async throws -> MailDelta { MailDelta() }
    func deleteDraft(_ messageID: String, _ state: inout MailboxState) async throws {}
    func attachment(_ attachment: Otter_Mail.Attachment, of message: Message) async throws -> Data { Data() }
    func watch(pushTopic: String?, _ state: inout MailboxState, onChange: @escaping () -> Void) async -> Task<Void, Never>? { nil }
}
