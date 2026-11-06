import SwiftUI

nonisolated enum CatchUp {
    static let labelName = "Bearbeiten"

    /** The inbox's unread conversations, in the list's order, less the ones already passed over. */
    static func queue(_ inbox: [MailThread], passed: Set<String> = []) -> [MailThread] {
        inbox.filter { $0.unread && !passed.contains($0.id) }
    }

    /** The mailbox's "Bearbeiten" label: by name, any case, or by id. */
    static func label(in labels: [MailLabel]) -> MailLabel? {
        labels.first { $0.name.caseInsensitiveCompare(labelName) == .orderedSame } ?? labels.first { $0.id == labelName }
    }

    enum Mark: Equatable {
        case label(String)
        case star
    }

    /** What swiping left turns on: the label where the mailbox has one, else the star; nothing when it's on already. */
    static func mark(_ thread: MailThread, labels: [MailLabel]) -> Mark? {
        if let label = label(in: labels) {
            return thread.labels.contains(label.id) ? nil : .label(label.id)
        }
        return thread.starred ? nil : .star
    }
}

/** Unread mail one conversation at a time: right to mark it read, left to keep it for later. */
struct CatchUpView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette

    let scope: String
    @Binding var draft: Draft?
    let onBack: () -> Void

    @State private var passed: Set<String> = []
    @State private var unsubscribing: Set<String> = []
    @State private var unsubscribed: Set<String> = []
    @State private var notice: Notice?

    private struct Notice: Equatable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        let queue = CatchUp.queue(inbox, passed: passed)
        Group {
            if let thread = queue.first, let mailbox = store.mailbox(thread.mailbox) {
                VStack(spacing: 12) {
                    Text("\(queue.count) left")
                        .font(.inter(.footnote).weight(.medium))
                        .foregroundStyle(palette.muted)
                        .monospacedDigit()
                    CatchUpCard(thread: thread, mailbox: mailbox, scope: scope, draft: $draft)
                        .modifier(MailSwipeActions(leading: readAction(thread), trailing: markAction(thread, mailbox)))
                        .id(thread.id)
                        .padding(.horizontal, 12)
                        .overlay(alignment: .bottom) {
                            if let notice {
                                NoticeBanner(text: notice.text).padding(.bottom, 12).id(notice.id)
                            }
                        }
                        .animation(.snappy(duration: 0.2), value: notice)
                    buttons(thread, mailbox)
                }
                .padding(.top, 4)
            } else {
                ContentUnavailableView {
                    Label("You're all caught up", systemImage: "checkmark.circle")
                } actions: {
                    Button("Back to Inbox", action: onBack)
                }
                .foregroundStyle(palette.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.inter(.body).weight(.semibold))
                            .foregroundStyle(palette.text)
                        PlaceTitle(title: "Catch up", scope: store.mailbox(for: scope)?.displayName ?? "")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Inbox")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: scope) { _, _ in passed.removeAll() }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            notice = nil
        }
    }

    /** The inbox as its list has it, so the count and the cards match it. */
    private var inbox: [MailThread] {
        let threads = store.threads(in: .inbox, scope: scope)
        return store.sync?.listed(threads, in: .inbox) ?? threads
    }

    private func readAction(_ thread: MailThread) -> MailSwipeAction {
        MailSwipeAction(title: "Read", symbol: "envelope.open", tint: palette.focus) {
            swiped()
            markRead(thread)
        }
    }

    private func markAction(_ thread: MailThread, _ mailbox: Mailbox) -> MailSwipeAction {
        let label = CatchUp.label(in: mailbox.labels)
        return MailSwipeAction(title: label?.leaf ?? mailbox.mark.capitalized, symbol: label == nil ? mailbox.mark : "tag", tint: .orange) {
            swiped()
            switch CatchUp.mark(thread, labels: mailbox.labels) {
            case .label(let id): store.toggleLabel(id, thread.id)
            case .star: store.toggleStar(thread.id)
            case nil: break
            }
            passed.insert(thread.id)
        }
    }

    private func swiped() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func markRead(_ thread: MailThread) {
        store.setRead(true, thread.id)
        passed.insert(thread.id)
    }

    private func buttons(_ thread: MailThread, _ mailbox: Mailbox) -> some View {
        HStack(spacing: 8) {
            button("Keep Unread", symbol: "envelope.badge") { passed.insert(thread.id) }
            if store.canArchive(thread) {
                // Out of the inbox, so the card goes by itself; Undo brings it back.
                button("Archive", symbol: "archivebox") { store.archive(thread.id) }
            }
            if unsubscribed.contains(thread.id) {
                button("Unsubscribed", symbol: "checkmark") {}.disabled(true)
            } else if let unsubscribe = Unsubscribe((thread.sent.last ?? thread.latest).headers) {
                let working = unsubscribing.contains(thread.id)
                button(working ? "Unsubscribing…" : "Unsubscribe", symbol: "hand.raised") {
                    run(unsubscribe, thread, mailbox)
                }
                .disabled(working)
            }
            button("Mark as Read", symbol: "envelope.open") { markRead(thread) }
        }
        .padding(.horizontal, 12)
    }

    private func run(_ unsubscribe: Unsubscribe, _ thread: MailThread, _ mailbox: Mailbox) {
        let shown = store.alias(scope).flatMap { $0.source == mailbox.email ? $0 : nil } ?? mailbox
        let sender = (thread.sent.last ?? thread.latest).from.label
        unsubscribing.insert(thread.id)
        Task {
            let outcome = await unsubscribe.run(from: shown, store: store)
            unsubscribing.remove(thread.id)
            if outcome == .done { unsubscribed.insert(thread.id) }
            outcome.haptic()
            notice = Notice(text: outcome.notice(from: sender))
        }
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.inter(.caption).weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}

/** One conversation, whole, as the reader shows it. */
private struct CatchUpCard: View {
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let thread: MailThread
    let mailbox: Mailbox
    let scope: String
    @Binding var draft: Draft?

    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(thread.subject)
                    .font(.inter(.title3).weight(.semibold))
                    .foregroundStyle(palette.text)
                    .padding(.bottom, 4)
                    .padding(.horizontal, MessageView.inset)
                Text(people)
                    .font(.inter(.footnote))
                    .foregroundStyle(palette.muted)
                    .lineLimit(2)
                    .padding(.bottom, 16)
                    .padding(.horizontal, MessageView.inset)

                let messages = thread.distinctMessages(preferring: store.alias(scope)?.email)
                ForEach(messages) { message in
                    let open = message.id == messages.last?.id || message.unread || expanded.contains(message.id)
                    MessageView(message: message, mailbox: mailbox, open: open) {
                        if message.draft {
                            draft = .resume(message, in: thread)
                        } else if !open {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { _ = expanded.insert(message.id) }
                        }
                    }
                    if message.id != messages.last?.id {
                        Spacer().frame(height: 20)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .scrollContentBackground(.hidden)
        .background(palette.raised)
        .clipShape(.rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.border))
    }

    private var people: String {
        let mine = Set(store.addresses(of: thread.mailbox))
        var names: [String] = []
        for message in thread.messages where !message.draft {
            for person in [message.from] + message.to + message.cc {
                let name = mine.contains(person.email.lowercased()) ? "me" : person.label
                if !names.contains(name) { names.append(name) }
            }
        }
        return names.joined(separator: ", ")
    }
}
