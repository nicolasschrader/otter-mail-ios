import SwiftUI

struct PlacesBar: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette
    @Namespace private var glass

    let place: Place
    let section: HomeSection
    let menuOpen: Bool
    /** The calendar's own list of calendars is up, which is what its ⌃⌄ opens. */
    let calendarListing: Bool
    let showsAgent: Bool
    let onPlace: (Place) -> Void
    let onMailbox: (Mailbox) -> Void
    let onSearch: () -> Void
    let onThreads: () -> Void
    let onCalendar: () -> Void
    let onTasks: () -> Void
    let onSettings: () -> Void
    let onMenu: () -> Void
    let onAgent: () -> Void

    var body: some View {
        // One glass: the bar grows into the menu and shrinks back (Linear's).
        GlassEffectContainer(spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    if menuOpen {
                        Group {
                            if section == .threads {
                                CatchUpScopePanel()
                            } else {
                                PlacesPanel(place: place, section: section, onSelect: onPlace, onMailbox: onMailbox,
                                            onSearch: onSearch, onSettings: onSettings)
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

    /** Threads, Mail, Calendar (when any mailbox has one), Tasks, and ⌃⌄ for what's in front. */
    private var tabs: some View {
        let mailbox = store.mailbox(for: place.scope)
        let mail = section == .mail
        return HStack(spacing: 0) {
            Button(action: onThreads) { tabLabel("rectangle.stack", selected: section == .threads) }
                .buttonStyle(.plain)
                .accessibilityLabel("Threads")
                .accessibilityHint("Catches up on every mailbox")
            Button { onPlace(Place(scope: place.scope, folder: .inbox)) } label: {
                tabLabel(Folder.inbox.symbol(in: mailbox), selected: mail && place.folder == .inbox,
                         dot: store.badge(in: .inbox, scope: place.scope) > 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mail")
            if !CalendarStore.sources(store.shownMailboxes).isEmpty {
                Button(action: onCalendar) { tabLabel("calendar", selected: section == .calendar) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Calendar")
            }
            Button(action: onTasks) {
                let open = session.tasks.tasks.count(where: { !$0.done })
                tabLabel("checklist", selected: section == .tasks, badge: open)
                    .accessibilityLabel(open > 0 ? "Tasks, \(open) open" : "Tasks")
            }
            .buttonStyle(.plain)
            // Tasks has nothing to scope; the others' ⌃⌄ opens what they're scoped by.
            if section != .tasks {
                Button(action: onMenu) {
                    tabLabel("chevron.up.chevron.down", selected: scopeLit)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(scopeLabel)
            }
        }
        .padding(4)
    }

    /** Lit for a mail place the bar doesn't pin, and while the calendar lists its calendars. */
    private var scopeLit: Bool {
        switch section {
        case .mail: place.folder != .inbox
        case .calendar: calendarListing
        case .threads, .tasks: false
        }
    }

    private var scopeLabel: String {
        switch section {
        case .calendar: "Calendars"
        case .threads: "Mailboxes in Catch up"
        case .mail, .tasks: "All places"
        }
    }

    private func tabLabel(_ symbol: String, selected: Bool, dot: Bool = false, badge: Int = 0) -> some View {
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
                .frame(width: 56, height: 48)
                .background(selected ? palette.text.opacity(0.1) : .clear, in: .capsule)
                .contentShape(.capsule)
                .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PlacesPanel: View {
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette

    let place: Place
    let section: HomeSection
    let onSelect: (Place) -> Void
    let onMailbox: (Mailbox) -> Void
    let onSearch: () -> Void
    let onSettings: () -> Void

    var body: some View {
        let mailbox = store.mailbox(for: place.scope)
        VStack(alignment: .leading, spacing: 0) {
            header(mailbox)
                .padding(.horizontal, 16)
                .frame(height: 56)
            Divider().overlay(palette.border).padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
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
                    row("Search", symbol: "magnifyingglass", action: onSearch)
                    row("Settings", symbol: "gearshape", action: onSettings)
                    SyncStatusLine(scope: mailbox?.source ?? place.scope)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 340)
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
            Text(mailbox?.provider == .gmail ? "Labels" : "Folders")
                .font(.inter(.footnote))
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
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

/** A row of the panels over the bar: an icon, a title, a count. */
private struct PlaceRow<Icon: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var count = 0
    var selected = false
    var indent = 0
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
            if count > 0 {
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
            Button(action: action) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

/** What Threads covers: every shown mailbox, read-only (no mailbox filter yet). */
private struct CatchUpScopePanel: View {
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Catch up")
                .font(.inter(.headline))
                .foregroundStyle(palette.text)
                .padding(.horizontal, 16)
                .frame(height: 56)
            Divider().overlay(palette.border).padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unread mail in every inbox, and invitations waiting on your answer, from all of these.")
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
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 340)
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
