import SwiftUI

nonisolated enum AllNew {
    /** One message that came in, with the conversation it's in and the inbox (a mailbox or an alias mailbox) it's listed under. */
    struct Entry: Identifiable, Hashable {
        let scope: String
        let thread: MailThread
        let message: Message

        var id: String { "\(thread.id)/\(message.id)" }

        /** The message alone, as a conversation of one, so ThreadRow draws it as itself. */
        var row: MailThread {
            var row = thread
            row.messages = [message]
            return row
        }

        var acted: MailThread { thread.acted(on: message) }

        var opened: Opened { Opened(thread: thread.id, scope: scope, message: message.id) }
    }

    /** What the reader opens: the conversation, and the message picked in it. */
    struct Opened: Hashable {
        let thread: String
        let scope: String
        var message: String?
    }

    /**
     * Every message that came in to these inboxes and is still in one, one by
     * one, newest first: not drafts, not the mailbox's own replies. Where a
     * mailbox (`more`) has older pages still to load, nothing older than its
     * oldest conversation here is listed yet, so another's older mail doesn't
     * sit above mail of its still to come. A tie goes by inbox, then by id, so
     * the list holds still. Each message is listed under the inbox it came in
     * to (`receives`), so a conversation can sit under two.
     */
    static func entries(
        inboxes: [(scope: String, threads: [MailThread])], mine: [String: Set<String>], more: Set<String> = [],
        receives: (Message, String) -> Bool = { _, _ in true }
    ) -> [Entry] {
        let listed = inboxes.flatMap { inbox in inbox.threads.map { (scope: inbox.scope, thread: $0) } }
        let since = more.compactMap { mailbox in
            listed.filter { $0.thread.mailbox == mailbox }.map(\.thread.latest.date).min()
        }.max()
        var seen: Set<String> = []
        return listed
            .flatMap { item in
                let (scope, thread) = item
                let own = mine[thread.mailbox] ?? [thread.mailbox.lowercased()]
                return thread.distinctMessages(preferring: scope == thread.mailbox ? nil : scope) { message in
                    !message.draft && !own.contains(message.from.email.lowercased()) && thread.inInbox(message) && receives(message, scope)
                }
                .filter { message in
                    since.map { message.date >= $0 } != false
                        && seen.insert("\(thread.id)/\(message.headers["Message-ID"] ?? message.id)").inserted
                }
                .map { Entry(scope: scope, thread: thread, message: $0) }
            }
            .sorted { a, b in
                if a.message.date != b.message.date { return a.message.date > b.message.date }
                return (a.scope, a.id) < (b.scope, b.id)
            }
    }
}

/** What Mail lists, in its ⋯: its conversations, or All new. */
struct MailViewPicker: View {
    let allNew: Bool
    let onSwitch: () -> Void

    var body: some View {
        Picker("View", selection: Binding(get: { allNew }, set: { if $0 != allNew { onSwitch() } })) {
            Label("Conversations", systemImage: "bubble.left.and.bubble.right").tag(false)
            Label("All new", systemImage: "tray.2").tag(true)
        }
    }
}

/** All new, a view of Mail: every shown inbox's incoming mail, a row per message, newest first. */
struct AllNewView: View {
    @Environment(MailStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onTitle: () -> Void
    let onCompose: () -> Void
    let onSettings: () -> Void
    let onConversations: () -> Void

    /** Redraws the rows when a shown code goes stale. */
    @State private var codesChecked = Date.now

    private var mailboxes: [Mailbox] { store.shownMailboxes.filter { !$0.signedOut } }

    /** The mailboxes and the alias mailboxes shown apart from them. */
    private var scopes: [Mailbox] {
        let signedIn = Set(mailboxes.map(\.email))
        return store.shownScopes.filter { signedIn.contains($0.source) }
    }

    /** The mailboxes whose inbox has older pages to load. */
    private var more: [String] {
        guard let sync = store.sync else { return [] }
        return mailboxes.map(\.email).filter { sync.hasMore(.inbox, scope: $0) }
    }

    private var entries: [AllNew.Entry] {
        let inboxes = scopes.map { scope in
            let threads = store.inboxMail(scope: scope.email)
            return (scope: scope.email, threads: store.sync?.listed(threads, in: .inbox) ?? threads)
        }
        let mine = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.email, Set(store.addresses(of: $0.email))) })
        return AllNew.entries(inboxes: inboxes, mine: mine, more: Set(more), receives: { store.receives($0, in: $1) })
    }

    private var actionAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.18) }

    var body: some View {
        let entries = self.entries
        let more = self.more
        let codesExpire = entries.compactMap { $0.row.freshVerificationCode() == nil ? nil : $0.message.date.addingTimeInterval(MailThread.freshCodeAge) }.min()
        List {
            ForEach(entries) { entry in
                row(entry)
            }
            if let sync = store.sync, !more.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .task(id: more.map { sync.cursor(.inbox, scope: $0) }) {
                        for email in more { await sync.loadMore(.inbox, scope: email) }
                    }
            } else if store.sync?.loadingCache == true && entries.isEmpty {
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
        .task {
            for mailbox in mailboxes { await store.sync?.open(.inbox, scope: mailbox.email) }
        }
        .task(id: [codesExpire, codesChecked]) {
            guard let codesExpire else { return }
            try? await Task.sleep(for: .seconds(max(0, codesExpire.timeIntervalSinceNow) + 1))
            if !Task.isCancelled { codesChecked = .now }
        }
        .refreshable {
            await store.sync?.syncAll()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onTitle) {
                    PlaceTitle(title: "All new", scope: scopes.count == 1 ? scopes[0].displayName : "All mailboxes")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows every folder and label")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Compose", systemImage: "square.and.pencil", action: onCompose)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    MailViewPicker(allNew: true, onSwitch: onConversations)
                    Button("Settings", systemImage: "gearshape", action: onSettings)
                }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .minimizingNavigationBar(enabled: false)
    }

    private func row(_ entry: AllNew.Entry) -> some View {
        let row = entry.row
        let mailbox = store.mailbox(for: entry.scope)
        let code = row.freshVerificationCode()
        let acted = entry.acted
        return VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: entry.opened) {
                ThreadRow(thread: row, mark: mailbox?.mark ?? "star", mine: Set(store.addresses(of: row.mailbox)), preview: code == nil, account: mailbox)
            }
            .navigationLinkIndicatorVisibility(.hidden)
            if let code {
                CodeCard(code: code, onTrash: {
                    withAnimation(actionAnimation) { store.trash(entry.thread.id) }
                })
                .padding(.leading, 48)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(ThreadRowBackground(unread: row.unread))
        .contextMenu { ThreadActions(thread: acted) }
        .modifier(MailSwipeActions(
            leading: store.canArchive(acted)
                ? MailSwipeAction(title: "Archive", symbol: "archivebox", tint: .indigo, perform: {
                    withAnimation(actionAnimation) { store.archive(entry.thread.id) }
                })
                : nil,
            trailing: MailSwipeAction(title: "Trash", symbol: "trash", tint: .red, perform: {
                withAnimation(actionAnimation) { store.trash(entry.thread.id) }
            }),
            square: preferences.fullWidthRows
        ))
        .listRowBackground(palette.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }
}
