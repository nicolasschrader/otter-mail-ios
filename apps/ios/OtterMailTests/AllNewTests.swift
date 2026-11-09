import Foundation
import Testing
@testable import Otter_Mail

@MainActor
struct AllNewTests {
    private let mailbox = Mailbox(email: "me@example.com", name: "Me", displayName: "Me", color: "#336699", signature: "", labels: [])

    private func message(_ id: String, from: String, at date: Date, unread: Bool, labels: Set<String> = ["INBOX"], headers: [String: String] = [:]) -> Message {
        Message(id: id, from: Person(name: from, email: "\(from)@example.com"), to: [], cc: [], date: date,
                text: "", html: nil, attachments: [], unread: unread, starred: false, draft: false, headers: headers, labels: labels)
    }

    /** An older message in the trash, and a newer one in the inbox. */
    private var plans: MailThread {
        MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX", "TRASH"], messages: [
            message("old", from: "ann", at: .now - 10, unread: false, labels: ["TRASH"]),
            message("inbox", from: "bob", at: .now, unread: true),
        ])
    }

    private func store(_ threads: [MailThread]) throws -> MailStore {
        let suite = "AllNewTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return MailStore(preferences: Preferences(defaults: defaults), mailboxes: [mailbox], threads: threads, defaults: defaults)
    }

    private func synced(_ store: MailStore) -> AllNewProvider {
        let provider = AllNewProvider()
        let cache = MailCache(folder: URL.temporaryDirectory.appending(path: "AllNew-\(UUID())"))
        store.sync = MailSync(store: store, google: GoogleAuth(), cache: cache, providers: [mailbox.email: provider])
        return provider
    }

    private func listed(_ store: MailStore) -> [AllNew.Entry] {
        AllNew.entries(inboxes: [(scope: mailbox.email, threads: store.inboxMail(scope: mailbox.email))], mine: [:])
    }

    @Test func keepsInboxMailBesideTrashedMessagesAndArchivedCopies() throws {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX", "ARCHIVE", "TRASH"], messages: [
            message("old", from: "ann", at: t, unread: false, labels: ["TRASH"]),
            message("archived", from: "bob", at: t + 10, unread: false, labels: ["ARCHIVE"], headers: ["Message-ID": "<b@x>"]),
            message("inbox", from: "bob", at: t + 10, unread: true, labels: ["INBOX"], headers: ["Message-ID": "<b@x>"]),
        ])
        let store = try store([thread])

        #expect(store.threads(in: .inbox, scope: mailbox.email).isEmpty)
        #expect(listed(store).map(\.message.id) == ["inbox"])
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

    @Test func mailCachedWithoutEachMessagesLabelsIsFetchedAgain() async throws {
        let folder = URL.temporaryDirectory.appending(path: "AllNew-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX"], messages: [
            message("m", from: "ann", at: .now, unread: false),
        ])
        var state = MailboxState(historyID: "7", watchTopic: "topic")
        state.trashedFrom = ["m": "INBOX"]
        let old = MailCache.Snapshot(mailbox: mailbox, state: state, threads: [thread], version: nil)
        try JSONEncoder().encode(old).write(to: folder.appending(path: "me@example.com.json"))

        let loaded = try #require(await MailCache(folder: folder).load([mailbox.email]).first)

        #expect(loaded.threads.isEmpty)
        #expect(loaded.state.historyID == nil)
        #expect(loaded.state.watchTopic == "topic")
        #expect(loaded.state.trashedFrom == ["m": "INBOX"])
        #expect(loaded.version == MailCache.version)
    }

    @Test func trashingAndArchivingLeaveTheListAtOnceAndUndoBringsMailBack() throws {
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX"], messages: [
            message("m", from: "ann", at: .now, unread: true),
        ])
        let store = try store([thread])
        let ids = { self.listed(store).map(\.message.id) }

        store.trash("t")
        #expect(ids().isEmpty)
        store.undo()
        #expect(ids() == ["m"])
        store.archive("t")
        #expect(ids().isEmpty)
        store.undo()
        #expect(ids() == ["m"])
        #expect(store.thread("t")?.messages.first?.labels == ["INBOX"])
    }

    @Test func theReaderKeepsThePickedCopyOfADuplicatedMessage() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["INBOX", "ARCHIVE"], messages: [
            message("archived", from: "bob", at: t, unread: false, labels: ["ARCHIVE"], headers: ["Message-ID": "<b@x>"]),
            message("inbox", from: "bob", at: t, unread: false, labels: ["INBOX"], headers: ["Message-ID": "<b@x>"]),
            message("newer", from: "ann", at: t + 10, unread: false),
        ])

        #expect(thread.distinctMessages(picked: "inbox").map(\.id) == ["inbox", "newer"])
        #expect(thread.distinctMessages().map(\.id) == ["archived", "newer"])
    }

    @Test func theMenusKeepTheConversationsLabelsAndTakeOnlyWhereTheMessageIs() throws {
        var thread = plans
        thread.labels.formUnion(["Label_1", "IMPORTANT"])
        let entry = try #require(listed(try store([thread])).first)

        #expect(entry.message.id == "inbox")
        #expect(entry.acted.labels == ["INBOX", "Label_1", "IMPORTANT"])
    }

    @Test func trashingAnInboxMessageBesideATrashedOneTrashesItAndUndoBringsItBack() async throws {
        let store = try store([plans])
        let provider = synced(store)
        let entry = try #require(listed(store).first)

        store.trash(entry.acted.id)
        #expect(listed(store).isEmpty)
        #expect(store.undoAction?.trash == true)
        store.undo()
        #expect(listed(store).map(\.message.id) == ["inbox"])

        store.trash(entry.acted.id)
        store.commitPendingAction()
        for _ in 0..<100 where provider.changes.isEmpty { await Task.yield() }
        #expect(provider.changes == ["trash t"])
        #expect(listed(store).isEmpty)
    }

    // Gmail's Delete forever is DELETE threads/<id>: it would take the inbox message with the trashed one.

    @Test func theReaderFromAllNewDoesntOfferDeleteForeverForInboxMailBesideATrashedMessage() throws {
        let store = try store([plans])
        let entry = try #require(listed(store).first)

        // What the reader's More menu acts on, opened on the inbox message.
        #expect(!entry.acted.trashed)
        #expect(entry.acted.labels == ["INBOX"])
        #expect(store.canArchive(entry.acted))
    }

    @Test func theListsMenuInTrashDoesntOfferDeleteForeverWhileSomeOfItIsInTheInbox() async throws {
        let store = try store([plans])
        let provider = synced(store)
        let listed = try #require(store.threads(in: .trash, scope: mailbox.email).first)

        #expect(!listed.trashed)
        #expect(!listed.deletable)
        store.deleteForever(listed.id)
        for _ in 0..<20 { await Task.yield() }
        #expect(store.thread("t") != nil)
        #expect(provider.changes.isEmpty)
        #expect(!store.removedThreads.contains("t"))
    }

    @Test func aConversationWhollyInTheTrashIsDeletedForever() async throws {
        let thread = MailThread(id: "t", mailbox: mailbox.email, subject: "Plans", labels: ["TRASH"], messages: [
            message("old", from: "ann", at: .now - 10, unread: false, labels: ["TRASH"]),
            message("new", from: "bob", at: .now, unread: false, labels: ["TRASH"]),
        ])
        let store = try store([thread])
        let provider = synced(store)

        #expect(thread.trashed)
        store.deleteForever("t")
        for _ in 0..<100 where provider.changes.isEmpty { await Task.yield() }
        #expect(store.thread("t") == nil)
        #expect(provider.changes == ["delete t"])
    }
}

/** Takes every change, writing down the trashing and deleting it was asked for. */
@MainActor
private final class AllNewProvider: MailProvider {
    private(set) var changes: [String] = []

    var capabilities: MailCapabilities { .gmail }
    var takesTurns: Bool { false }
    var hasArchive: Bool { false }

    func apply(_ change: MailStore.Change, to thread: MailThread, _ state: inout MailboxState) async throws -> MailDelta {
        switch change {
        case .trash: changes.append("trash \(thread.id)")
        case .delete: changes.append("delete \(thread.id)")
        default: break
        }
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
