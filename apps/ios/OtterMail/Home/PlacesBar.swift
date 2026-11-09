import SwiftUI

struct PlacesBar: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette
    @Namespace private var glass

    let place: Place
    let section: HomeSection
    let menuOpen: Bool
    /** What the calendar's ⌃⌄ panel lists and scopes. */
    let calendar: CalendarStore
    let calendarShown: CalendarShown
    let showsAgent: Bool
    let onPlace: (Place) -> Void
    let onMailbox: (Mailbox) -> Void
    let onThreads: () -> Void
    let onAllNew: () -> Void
    let onCalendar: () -> Void
    let onTasks: () -> Void
    let onMenu: () -> Void
    /** A choice in the calendar's or tasks' panel that is the whole errand: the panel folds back into the bar. */
    let onDone: () -> Void
    let onAgent: () -> Void

    var body: some View {
        // One glass: the bar grows into the menu and shrinks back (Linear's).
        GlassEffectContainer(spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    if menuOpen {
                        Group {
                            switch section {
                            case .threads:
                                MailboxesScopePanel(
                                    title: "Catch up",
                                    about: "Unread mail in every inbox, and invitations waiting on your answer, from all of these."
                                )
                            case .allNew:
                                MailboxesScopePanel(title: "All new", about: "Every message that came in to each inbox, one by one, from all of these.")
                            case .calendar:
                                CalendarScopePanel(events: calendar, visibility: calendarShown, onDone: onDone)
                            case .tasks:
                                TaskListsPanel(onDone: onDone)
                            case .mail:
                                PlacesPanel(place: place, section: section, onSelect: onPlace, onMailbox: onMailbox)
                            }
                        }
                        .frame(maxHeight: 560)
                        .fixedSize(horizontal: false, vertical: true)
                        .glassEffect(.regular, in: .rect(cornerRadius: 32))
                        .glassEffectID("places", in: glass)
                    } else {
                        tabs
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectID("places", in: glass)
                    }
                }
                // The bar's height either way, so the open menu rises over the list without moving it.
                .frame(height: 56, alignment: .bottomLeading)

                Spacer(minLength: 0)

                if showsAgent {
                    Button(action: onAgent) {
                        Image("OtterAgent")
                            .resizable().scaledToFit()
                            .frame(width: 24, height: 24)
                            .foregroundStyle(palette.text)
                            .frame(width: 56, height: 56)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Agent")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    /** Threads, All new, Mail, Calendar (when any mailbox has one), Tasks, and ⌃⌄ for what's in front. */
    private var tabs: some View {
        let mailbox = store.mailbox(for: place.scope)
        let mail = section == .mail
        let hasCalendar = !CalendarStore.sources(store.shownMailboxes).isEmpty
        // Six tabs and the agent's button fit a 390pt-wide iPhone only at the 44pt touch minimum.
        let width: CGFloat = hasCalendar ? 44 : 56
        return HStack(spacing: 0) {
            Button(action: onThreads) { tabLabel("rectangle.stack", width: width, selected: section == .threads) }
                .buttonStyle(.plain)
                .accessibilityLabel("Threads")
                .accessibilityHint("Catches up on every mailbox")
            Button(action: onAllNew) { tabLabel("tray.2", width: width, selected: section == .allNew) }
                .buttonStyle(.plain)
                .accessibilityLabel("All new")
                .accessibilityHint("Lists every mailbox's incoming mail, one message at a time")
            Button { onPlace(Place(scope: place.scope, folder: .inbox)) } label: {
                tabLabel(Folder.inbox.symbol(in: mailbox), width: width, selected: mail && place.folder == .inbox,
                         dot: store.badge(in: .inbox, scope: place.scope) > 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mail")
            if hasCalendar {
                Button(action: onCalendar) { tabLabel("calendar", width: width, selected: section == .calendar) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Calendar")
            }
            Button(action: onTasks) {
                let open = session.tasks.tasks.count(where: { !$0.done })
                tabLabel("checklist", width: width, selected: section == .tasks, badge: open)
                    .accessibilityLabel(open > 0 ? "Tasks, \(open) open" : "Tasks")
            }
            .buttonStyle(.plain)
            // ⌃⌄ opens what the one in front is scoped by, in the same panel for each.
            Button(action: onMenu) {
                tabLabel("chevron.up.chevron.down", width: width, selected: scopeLit)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(scopeLabel)
            .accessibilityIdentifier("places-scope")
        }
        .padding(4)
    }

    /** Lit for a mail place the bar doesn't pin, a calendar scoped to one mailbox, a task list picked. */
    private var scopeLit: Bool {
        switch section {
        case .mail: place.folder != .inbox
        case .calendar: calendarShown.account != nil
        case .tasks: session.tasks.selected != nil
        case .threads, .allNew: false
        }
    }

    private var scopeLabel: String {
        switch section {
        case .calendar: "Calendars"
        case .threads: "Mailboxes in Catch up"
        case .allNew: "Mailboxes in All new"
        case .tasks: "Task lists"
        case .mail: "All places"
        }
    }

    private func tabLabel(_ symbol: String, width: CGFloat, selected: Bool, dot: Bool = false, badge: Int = 0) -> some View {
        Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle(palette.text)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(.red, in: .capsule)
                            .offset(x: 8, y: -6)
                            .accessibilityHidden(true)
                    } else if dot {
                        Circle().fill(palette.focus).frame(width: 9, height: 9).offset(x: 6, y: -4)
                    }
                }
                .frame(width: width, height: 48)
                .background(selected ? palette.text.opacity(0.1) : .clear, in: .capsule)
                .contentShape(.capsule)
                .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/** The mail's places: mailboxes, folders and labels. Search and Settings are in the toolbar (Search, ⋯). */
struct PlacesPanel: View {
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette

    let place: Place
    let section: HomeSection
    let onSelect: (Place) -> Void
    let onMailbox: (Mailbox) -> Void

    var body: some View {
        let mailbox = store.mailbox(for: place.scope)
        ScopePanel {
            header(mailbox)
        } rows: {
            mailboxes
            if let mailbox = mailbox.flatMap({ store.mailbox($0.source) }), mailbox.signedOut {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.warning)
                    Text(signedOutTitle(mailbox)).font(.inter(.subheadline)).lineLimit(1)
                    Spacer(minLength: 8)
                    SignInAgainButton(mailbox: mailbox)
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
            }
            ForEach(mailbox?.folders ?? [], id: \.self) { folder in
                row(folder.title(in: mailbox), symbol: folder.symbol(in: mailbox),
                    count: store.badge(in: folder, scope: place.scope), selected: section == .mail && place.folder == folder) {
                    onSelect(Place(scope: place.scope, folder: folder))
                }
            }
            labels(mailbox)
            SyncStatusLine(scope: mailbox?.source ?? place.scope)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
    }

    private func header(_ mailbox: Mailbox?) -> some View {
        HStack(spacing: 10) {
            MailboxAvatar(mailbox: mailbox, size: 24)
            Text(mailbox?.displayName ?? "Mailbox")
                .font(.inter(.headline))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /** Where switching mailboxes went from the bar: each one, its unread count, the current one lit. */
    @ViewBuilder
    private var mailboxes: some View {
        let scopes = store.shownScopes
        if scopes.count > 1 {
            ForEach(scopes) { mailbox in
                let current = mailbox.email == place.scope
                PlaceRow(title: mailbox.displayName, count: store.badge(in: .inbox, scope: mailbox.email), selected: current) {
                    MailboxAvatar(mailbox: mailbox, size: 24)
                } action: {
                    onMailbox(mailbox)
                }
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            Divider().overlay(palette.border).padding(.vertical, 6).padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func labels(_ mailbox: Mailbox?) -> some View {
        let labels = mailbox?.labels ?? []
        if !labels.isEmpty {
            PanelHeading(title: mailbox?.provider == .gmail ? "Labels" : "Folders")
            ForEach(labels) { label in
                let folder = Folder.label(id: label.id, name: label.name)
                row(folder.title, symbol: folder.symbol, color: label.color,
                    count: store.badge(in: folder, scope: place.scope), selected: section == .mail && place.folder == folder,
                    indent: label.depth) {
                    onSelect(Place(scope: place.scope, folder: folder))
                }
            }
            Divider().overlay(palette.border).padding(.vertical, 6).padding(.horizontal, 4)
        }
    }

    private func row(_ title: String, symbol: String, color: String? = nil, count: Int = 0,
                     selected: Bool = false, indent: Int = 0, action: @escaping () -> Void) -> some View {
        PlaceRow(title: title, count: count, selected: selected, indent: indent) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(color.map(Color.init(hex:)) ?? palette.text)
        } action: {
            action()
        }
    }
}

/**
 * What every panel over the bar is drawn in (the mail's places, Catch up's
 * mailboxes, the calendars, the task lists): a header, a hairline, and its
 * rows scrolling under it once they're taller than the panel.
 */
struct ScopePanel<Header: View, Rows: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder let header: Header
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .frame(height: 56)
            Divider().overlay(palette.border).padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { rows }
                    .padding(8)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 340)
    }
}

/** A panel's own heading over a group of rows ("Labels"). */
struct PanelHeading: View {
    @Environment(\.palette) private var palette
    let title: String

    var body: some View {
        Text(title)
            .font(.inter(.footnote))
            .foregroundStyle(palette.muted)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

/** A row of the panels over the bar: an icon, a title, a count, or a check for one that switches on and off. */
struct PlaceRow<Icon: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var count = 0
    var selected = false
    var indent = 0
    var checked: Bool?
    @ViewBuilder let icon: Icon
    var action: (() -> Void)?

    var body: some View {
        let label = HStack(spacing: 14) {
            icon.frame(width: 24)
            Text(title)
                .font(.inter(.body))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(checked ? palette.text : palette.muted)
                    .accessibilityHidden(true)
            } else if count > 0 {
                Text("\(count)")
                    .font(.inter(.footnote).weight(.medium))
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 12 + CGFloat(indent) * 20)
        .padding(.trailing, 12)
        .frame(height: 48)
        .background(selected ? palette.text.opacity(0.1) : .clear, in: .rect(cornerRadius: 16))
        .contentShape(.rect)
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(checked.map { $0 ? "Shown" : "Hidden" } ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            label
        }
    }
}

/** What Threads or All new covers: every shown mailbox, read-only (no mailbox filter yet). */
private struct MailboxesScopePanel: View {
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette
    let title: String
    let about: String

    var body: some View {
        ScopePanel {
            Text(title)
                .font(.inter(.headline))
                .foregroundStyle(palette.text)
        } rows: {
            Text(about)
                .font(.inter(.footnote))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            ForEach(store.shownMailboxes) { mailbox in
                PlaceRow(title: mailbox.displayName, count: store.badge(in: .inbox, scope: mailbox.email)) {
                    MailboxAvatar(mailbox: mailbox, size: 24)
                }
            }
        }
    }
}

struct MailboxAvatar: View {
    let mailbox: Mailbox?
    var size: CGFloat = 30

    var body: some View {
        if let mailbox, let picture = mailbox.customImage {
            Image(uiImage: picture)
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
        } else if let mailbox, let url = mailbox.picture.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                MailboxMark(mailbox: mailbox, size: size)
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
        } else if let mailbox {
            MailboxMark(mailbox: mailbox, size: size)
        }
    }
}
