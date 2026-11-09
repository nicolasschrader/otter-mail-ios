import SwiftUI

nonisolated enum AllNew {
    /** One message that came in, with the conversation it's in. */
    struct Entry: Identifiable, Hashable {
        let thread: MailThread
        let message: Message

        var id: String { "\(thread.id)/\(message.id)" }

        /** The message alone, as a conversation of one, so ThreadRow draws it as itself. */
        var row: MailThread {
            var row = thread
            row.messages = [message]
            return row
        }
    }

    /**
     * Every message that came in to these inboxes, one by one, newest first:
     * not drafts, not the mailbox's own replies. A tie goes by mailbox, then by
     * id, so the list holds still.
     */
    static func entries(inboxes: [[MailThread]], mine: [String: Set<String>]) -> [Entry] {
        var seen: Set<String> = []
        return inboxes.joined()
            .filter { seen.insert($0.id).inserted }
            .flatMap { thread in
                let own = mine[thread.mailbox] ?? [thread.mailbox.lowercased()]
                return thread.distinctMessages()
                    .filter { !$0.draft && !own.contains($0.from.email.lowercased()) }
                    .map { Entry(thread: thread, message: $0) }
            }
            .sorted { a, b in
                if a.message.date != b.message.date { return a.message.date > b.message.date }
                return (a.thread.mailbox, a.id) < (b.thread.mailbox, b.id)
            }
    }
}

/** All new: every shown mailbox's incoming inbox mail, a row per message, newest first. */
struct AllNewView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette

    let onTitle: () -> Void
    let onSettings: () -> Void

    private var mailboxes: [Mailbox] { store.shownMailboxes.filter { !$0.signedOut } }

    private var entries: [AllNew.Entry] {
        let inboxes = mailboxes.map { mailbox in
            let threads = store.threads(in: .inbox, scope: mailbox.email)
            return store.sync?.listed(threads, in: .inbox) ?? threads
        }
        let mine = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.email, Set(store.addresses(of: $0.email))) })
        return AllNew.entries(inboxes: inboxes, mine: mine)
    }

    var body: some View {
        let entries = self.entries
        List {
            ForEach(entries) { entry in
                row(entry)
            }
            if store.sync?.loadingCache == true && entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            } else if entries.isEmpty {
                ContentUnavailableView("No new mail", systemImage: "tray.2")
                    .foregroundStyle(palette.muted)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.top, 80)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) { SignedOutBanners() }
        .refreshable {
            await store.sync?.syncAll()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onTitle) {
                    PlaceTitle(title: "All new", scope: mailboxes.count == 1 ? mailboxes[0].displayName : "All mailboxes")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the mailboxes it covers")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Settings", systemImage: "gearshape", action: onSettings)
                }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .minimizingNavigationBar(enabled: false)
    }

    private func row(_ entry: AllNew.Entry) -> some View {
        let row = entry.row
        let mailbox = store.mailbox(row.mailbox)
        return NavigationLink(value: row.id) {
            ThreadRow(thread: row, mark: mailbox?.mark ?? "star", mine: Set(store.addresses(of: row.mailbox)), account: mailbox)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(ThreadRowBackground(unread: row.unread))
        .contextMenu { ThreadActions(thread: entry.thread) }
        .listRowBackground(palette.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }
}
