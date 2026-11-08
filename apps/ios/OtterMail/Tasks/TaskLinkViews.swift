import SwiftUI

/** Where a task's link leads, opened by HomeView wherever it's tapped: the conversation, or the event in the calendar. */
nonisolated enum TaskTarget: Hashable {
    case email(TaskEmail)
    case event(TaskEvent)
}

extension EnvironmentValues {
    @Entry var openTaskTarget: (TaskTarget) -> Void = { _ in }
}

/**
 * One link of a task's, as a row: a conversation or an event, under the name
 * it has now when it's loaded, else the one kept with the link. One that can't
 * be reached (its mailbox gone or signed out) still reads, muted, and keeps
 * its place until it's unlinked: the task loses nothing.
 */
struct TaskLinkRow: View {
    @Environment(\.palette) private var palette

    let symbol: String
    let title: String
    var detail: String?
    var unavailable = false
    var onOpen: (() -> Void)?
    var onUnlink: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onOpen?()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.muted)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.inter(.subheadline))
                            .foregroundStyle(unavailable ? palette.muted : palette.text)
                            .lineLimit(2)
                        if let line {
                            Text(line)
                                .font(.inter(.footnote))
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
            .accessibilityElement(children: .combine)
            .accessibilityHint(onOpen == nil ? "" : "Opens it")
            if let onUnlink {
                UnlinkButton(title: title, action: onUnlink)
            }
        }
        .frame(minHeight: 44)
    }

    private var line: String? {
        guard unavailable else { return detail }
        return [detail, "Not available"].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct UnlinkButton: View {
    @Environment(\.palette) private var palette

    let title: String
    let action: () -> Void

    var body: some View {
        Button("Unlink \(title)", systemImage: "xmark.circle.fill", action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 17))
            .foregroundStyle(palette.muted)
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
    }
}

/** How a link is labelled: the live conversation's or event's own words when they're loaded, else the snapshot's. */
struct TaskLinkLabels {
    let store: MailStore
    let calendar: CalendarStore
    let dates: CalendarDates

    func email(_ email: TaskEmail) -> (title: String, detail: String, unavailable: Bool) {
        if let thread = store.thread(email.thread) {
            let subject = thread.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            return (subject.isEmpty ? email.subject : subject, email.mailbox, false)
        }
        let known = store.mailboxes.contains { $0.email.lowercased() == email.mailbox.lowercased() } || store.alias(email.mailbox) != nil
        return (email.subject, email.mailbox, !known)
    }

    func event(_ link: TaskEvent, now: Date = .now) -> (title: String, detail: String, unavailable: Bool) {
        let live = calendar.find(link, now: now)
        let start = live?.start ?? link.start
        let allDay = live?.allDay ?? link.allDay
        let day = dates.heading(start, now: now)
        var detail = allDay ? day : "\(day) · \(dates.timeLabel(start))"
        if link.scope == .series { detail = "Whole series · next \(detail)" }
        let reachable = CalendarStore.sources(store.shownMailboxes).contains { $0.email.lowercased() == link.account }
        return (live?.title ?? link.title, detail, live == nil && !reachable)
    }
}

/**
 * A task's links as chips under it in a list: every conversation and event,
 * each opening what it links to. One out of reach reads muted and struck
 * through, and still opens what the task kept of an event.
 */
struct TaskLinkChips: View {
    @Environment(MailStore.self) private var store
    @Environment(CalendarStore.self) private var calendar
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette

    let task: MailTask
    let onEmail: (TaskEmail) -> Void
    let onEvent: (TaskEvent) -> Void

    private var labels: TaskLinkLabels {
        TaskLinkLabels(store: store, calendar: calendar, dates: CalendarDates(preferences: preferences.calendar))
    }

    var body: some View {
        ChipFlow(spacing: 6) {
            ForEach(task.emails, id: \.key) { email in
                let label = labels.email(email)
                chip("envelope", label.title, unavailable: label.unavailable) { onEmail(email) }
                    .disabled(label.unavailable)
                    .accessibilityLabel(label.unavailable ? "\(label.title), not available" : "Email: \(label.title)")
                    .accessibilityHint(label.unavailable ? "" : "Opens the conversation")
            }
            ForEach(task.events, id: \.key) { link in
                let label = labels.event(link)
                chip(link.scope == .series ? "repeat" : "calendar", label.title, unavailable: label.unavailable) { onEvent(link) }
                    .accessibilityLabel("\(link.scope == .series ? "Every event" : "Event"): \(label.title)\(label.unavailable ? ", not available" : "")")
                    .accessibilityHint("Opens the event")
            }
        }
    }

    private func chip(_ symbol: String, _ title: String, unavailable: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).lineLimit(1).strikethrough(unavailable)
            }
            .font(.inter(.caption))
            .foregroundStyle(palette.muted.opacity(unavailable ? 0.7 : 1))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 220, alignment: .leading)
            .background(palette.text.opacity(0.06), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/** Chips in rows, wrapping to the next when one is full. */
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let chip = min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + chip > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? chip : row.width + spacing + chip
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/**
 * The task editor's links: every conversation and event the task is linked
 * to, each opened or unlinked in place, a series' link switched between the
 * one occurrence and the whole series, and more found and linked right here.
 * Nothing is written until the editor's Save.
 */
struct TaskEditorLinks: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(CalendarStore.self) private var calendar
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette

    @Binding var task: MailTask
    let onEmail: (TaskEmail) -> Void
    let onEvent: (TaskEvent) -> Void

    @State private var searching = false
    @State private var query = ""
    @State private var now = Date.now
    @FocusState private var focused: Bool

    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }
    private var labels: TaskLinkLabels { TaskLinkLabels(store: store, calendar: calendar, dates: dates) }
    private var sources: [Mailbox] { CalendarStore.sources(store.shownMailboxes) }
    private var window: EventWindow { dates.window(.agenda, anchor: now) }
    private var terms: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            ForEach(task.emails, id: \.key) { email in
                let label = labels.email(email)
                TaskLinkRow(
                    symbol: "envelope", title: label.title, detail: label.detail, unavailable: label.unavailable,
                    onOpen: label.unavailable ? nil : { onEmail(email) },
                    onUnlink: { task = TaskLinks.unlinking(task, email: email.key) }
                )
            }
            ForEach(task.events, id: \.key) { link in
                let label = labels.event(link)
                TaskLinkRow(
                    symbol: link.scope == .series ? "repeat" : "calendar", title: label.title, detail: label.detail,
                    unavailable: label.unavailable,
                    onOpen: { onEvent(link) },
                    onUnlink: { task = TaskLinks.unlinking(task, event: link.key) }
                )
                if link.recurring {
                    ScopePicker(scope: Binding(
                        get: { link.scope },
                        set: { task = TaskLinks.rescoping(task, event: link.key, to: $0) }
                    ))
                }
            }
            if searching {
                search
            } else {
                Button("Link an email or event", systemImage: "link") {
                    searching = true
                    focused = true
                }
                .accessibilityIdentifier("task-link-add")
            }
        } header: {
            Text("Linked").sectionHeader()
        } footer: {
            Text(footer).sectionFooter()
        }
        .task(id: searching) {
            guard searching, !sources.isEmpty else { return }
            now = .now
            await calendar.load(window, sources: sources, demo: store.isDemo, google: session.google, dates: dates)
        }
    }

    @ViewBuilder private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
            TextField(sources.isEmpty ? "Search mail" : "Search mail and events", text: $query)
                .font(.inter(.subheadline))
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("task-link-search")
            Button("Done") {
                searching = false
                query = ""
            }
            .font(.inter(.subheadline).weight(.medium))
            .buttonStyle(.borderless)
        }
        let emails = emailMatches
        let events = eventMatches
        ForEach(emails) { match in
            Button {
                task = TaskLinks.linking(task, email: match.email)
            } label: {
                result("envelope", match.email.subject, "\(match.from) · \(match.email.mailbox)")
            }
            .buttonStyle(.plain)
        }
        ForEach(events) { event in
            let occurrence = TaskEvent(event, scope: .occurrence)
            if occurrence.recurring {
                VStack(alignment: .leading, spacing: 6) {
                    result("repeat", event.title, eventLine(event))
                    // Asked in place, and only for a series: the one occurrence, or every one of them.
                    HStack(spacing: 8) {
                        ForEach(TaskEvent.Scope.allCases, id: \.self) { scope in
                            Button(scope.title) { task = TaskLinks.linking(task, event: TaskEvent(event, scope: scope)) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .font(.inter(.footnote).weight(.medium))
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    task = TaskLinks.linking(task, event: occurrence)
                } label: {
                    result("calendar", event.title, eventLine(event))
                }
                .buttonStyle(.plain)
            }
        }
        if emails.isEmpty && events.isEmpty {
            Text(terms.isEmpty ? "Nothing more to link." : "Nothing found for “\(terms)”.")
                .font(.inter(.footnote))
                .foregroundStyle(palette.muted)
        }
    }

    private func result(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(palette.muted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.inter(.subheadline).weight(.medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(detail)
                    .font(.inter(.footnote))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "plus.circle").foregroundStyle(palette.action)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private func eventLine(_ event: CalendarEvent) -> String {
        let day = dates.heading(event.start, now: now)
        return event.allDay ? "\(day) · \(event.calendar.name)" : "\(day) · \(dates.timeLabel(event.start)) · \(event.calendar.name)"
    }

    /** Every mailbox's inbox, newest first, or what a search finds; what's linked already is left out. */
    private struct EmailMatch: Identifiable {
        let email: TaskEmail
        let from: String
        let date: Date
        var id: String { email.key }
    }

    private var emailMatches: [EmailMatch] {
        let linked = Set(task.emails.map(\.key))
        var seen: Set<String> = []
        var found: [EmailMatch] = []
        for scope in store.shownScopes {
            let threads = terms.isEmpty ? store.threads(in: .inbox, scope: scope.email) : store.search(terms, scope: scope.email)
            for thread in threads.prefix(30) {
                let email = TaskEmail(thread, mailbox: scope.email)
                guard !linked.contains(email.key), seen.insert(thread.id).inserted else { continue }
                found.append(EmailMatch(email: email, from: thread.latest.from.label, date: thread.latest.date))
            }
        }
        return Array(found.sorted { $0.date > $1.date }.prefix(terms.isEmpty ? 3 : 6))
    }

    /** The agenda's days ahead, as the calendar lists them; an event of a series asks whether it's the one or all. */
    private var eventMatches: [CalendarEvent] {
        let linked = Set(task.events.map(\.key))
        let found = (calendar.events(in: window) ?? []).filter { event in
            guard event.status != .cancelled, terms.isEmpty || event.title.localizedCaseInsensitiveContains(terms) else { return false }
            let occurrence = TaskEvent(event, scope: .occurrence)
            return !linked.contains(occurrence.key) && !(occurrence.recurring && linked.contains(occurrence.scoped(.series).key))
        }
        return Array(EventDays.sorted(found).prefix(terms.isEmpty ? 3 : 6))
    }

    private var footer: String {
        if task.emails.isEmpty && task.events.isEmpty {
            return "Link the conversations and events this task is about. Links stay on this iPhone, with the task."
        }
        return "Links stay on this iPhone, with the task. Nothing is changed in the mail or the calendar."
    }
}

/** For an event of a series, in place: the task is about this occurrence, or every one. */
struct ScopePicker: View {
    @Binding var scope: TaskEvent.Scope

    var body: some View {
        Picker("Linked to", selection: $scope) {
            ForEach(TaskEvent.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .font(.inter(.subheadline))
        .accessibilityIdentifier("task-link-scope")
    }
}

/** What a list of linked tasks hangs off: an event (an occurrence of a series reaches the series' tasks too), or a conversation. */
enum TaskSource {
    case event(CalendarEvent)
    case thread(MailThread, mailbox: String)
}

/**
 * The tasks linked to an event or a conversation, shown on it: each opens in
 * the task editor over it, finishes from its circle, or is unlinked; a new
 * task is added, already linked, from the field under them, and an existing
 * one is found and linked in place. For an event of a series, both are for
 * this occurrence or every one, as the picker above them says.
 */
struct LinkedTasks: View {
    @Environment(Session.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette
    @Environment(\.openTaskTarget) private var openTarget

    let source: TaskSource
    /** Rows in the editor's grouped form; otherwise a card in a scrolling page. */
    var inForm = false
    /** Whether the search for a task to link is open, when the screen opens it (a conversation's More menu). */
    var linking: Binding<Bool>? = nil

    @State private var ownLinking = false
    @State private var editing: MailTask?
    @State private var adding = ""
    @State private var query = ""
    @State private var scope: TaskEvent.Scope = .occurrence
    @State private var error: String?
    /** A new task is being written: another submit waits for it rather than making a second. */
    @State private var submitting = false
    @FocusState private var searchFocused: Bool

    private var tasks: TaskStore { session.tasks }
    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }
    private var isLinking: Binding<Bool> { linking ?? $ownLinking }

    private var linked: [MailTask] {
        let found: [MailTask] = switch source {
        case .event(let event): tasks.linked(to: event)
        case .thread(let thread, let mailbox): tasks.linked(thread: thread.id, mailboxes: [mailbox, thread.mailbox])
        }
        return TaskList.sorted(found.filter { !$0.done }) + TaskList.sorted(found.filter(\.done))
    }

    private var recurringEvent: CalendarEvent? {
        if case .event(let event) = source, event.seriesId != nil { return event }
        return nil
    }

    /** The tasks a search finds to link, open ones first; those linked already are left out. */
    private var candidates: [MailTask] {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = Set(linked.map(\.id))
        let found = tasks.tasks.filter { !ids.contains($0.id) && (terms.isEmpty || $0.content.localizedCaseInsensitiveContains(terms)) }
        return Array((TaskList.sorted(found.filter { !$0.done }) + TaskList.sorted(found.filter(\.done))).prefix(6))
    }

    var body: some View {
        content
            .sheet(item: $editing) { task in
                NavigationStack {
                    TaskEditor(task: task, onEmail: { email in
                        editing = nil
                        if !opensHere(email) { openTarget(.email(email)) }
                    })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { editing = nil }
                        }
                    }
                }
            }
            .onChange(of: isLinking.wrappedValue, initial: true) { _, open in
                if open { searchFocused = true }
            }
    }

    @ViewBuilder private var content: some View {
        if inForm {
            Section {
                rows
            } header: {
                Text("Tasks").sectionHeader()
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tasks")
                    .font(.inter(.footnote).weight(.medium))
                    .foregroundStyle(palette.muted)
                    .padding(.bottom, 4)
                rows
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(palette.text.opacity(0.04), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("linked-tasks")
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(linked) { task in
            HStack(spacing: 8) {
                TaskRow(
                    task: task,
                    due: TaskList.dueLabel(task, now: .now, dates: dates),
                    overdue: TaskList.group(of: task, now: .now, dates: dates) == .overdue,
                    showsLinks: false,
                    onToggle: { tasks.setDone(!task.done, task) },
                    onOpen: { editing = task },
                    onEmail: { _ in }
                )
                if let event = recurringEvent, TaskLinks.links(of: task, to: event).contains(where: { $0.scope == .series }) {
                    Image(systemName: "repeat")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.muted)
                        .accessibilityLabel("For the whole series")
                }
                UnlinkButton(title: task.content) { Task { await unlink(task) } }
            }
            .padding(.vertical, 4)
        }
        if recurringEvent != nil {
            ScopePicker(scope: $scope)
                .padding(.vertical, 4)
        }
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(palette.action)
            TextField(newTask.content.isEmpty ? "Add a task" : "Add task: \(newTask.content)", text: $adding)
                .font(.inter(.subheadline))
                .submitLabel(.done)
                .onSubmit { Task { await add() } }
                .accessibilityIdentifier("linked-task-add")
            Button("Add") { Task { await add() } }
                .disabled(submitting)
                .font(.inter(.subheadline).weight(.medium))
                .foregroundStyle(palette.action)
                .buttonStyle(.borderless)
        }
        .frame(minHeight: 44)
        if isLinking.wrappedValue {
            linkSearch
        } else if tasks.tasks.contains(where: { task in !linked.contains { $0.id == task.id } }) {
            Button("Link a task", systemImage: "link") { isLinking.wrappedValue = true }
                .font(.inter(.subheadline).weight(.medium))
                .foregroundStyle(palette.action)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.inter(.footnote))
                .foregroundStyle(palette.error)
        }
    }

    @ViewBuilder private var linkSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
            TextField("Search tasks", text: $query)
                .font(.inter(.subheadline))
                .focused($searchFocused)
                .autocorrectionDisabled()
                .accessibilityIdentifier("linked-task-search")
            Button("Done") {
                isLinking.wrappedValue = false
                query = ""
            }
            .font(.inter(.subheadline).weight(.medium))
            .buttonStyle(.borderless)
        }
        .frame(minHeight: 44)
        ForEach(candidates) { task in
            Button {
                Task { await link(task) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: task.done ? "checkmark.circle.fill" : "circle").foregroundStyle(palette.muted)
                    Text(task.content)
                        .font(.inter(.subheadline))
                        .foregroundStyle(task.done ? palette.muted : palette.text)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "link").foregroundStyle(palette.action)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Link \(task.content)")
        }
        if candidates.isEmpty {
            Text("No matching tasks.")
                .font(.inter(.footnote))
                .foregroundStyle(palette.muted)
        }
    }

    private var newTask: MailTask {
        switch source {
        case .event(let event): MailTask(from: event, scope: scope)
        case .thread(let thread, let mailbox): MailTask(from: thread, mailbox: mailbox)
        }
    }

    private func opensHere(_ email: TaskEmail) -> Bool {
        guard case .thread(let thread, let mailbox) = source else { return false }
        return email.links(thread.id, mailbox: mailbox) || email.links(thread.id, mailbox: thread.mailbox)
    }

    /** A new task, already linked: what was typed, or the event's title or the conversation's subject. */
    private func add() async {
        guard !submitting else { return }
        submitting = true
        defer { submitting = false }
        let submitted = adding
        var task = newTask
        let typed = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { task.content = typed }
        do {
            try await tasks.save(task)
            adding = Self.remaining(adding, after: submitted)
            error = nil
        } catch {
            self.error = "Couldn't add the task. \(error.localizedDescription)"
        }
    }

    /** The field once a task is added: cleared of what was sent, not of what was typed during the save. */
    static func remaining(_ field: String, after submitted: String) -> String {
        field == submitted ? "" : field
    }

    /** The link is made from the scope as it was tapped, not as the picker stands once it's written. */
    private func link(_ task: MailTask) async {
        let scope = scope
        do {
            try await tasks.update(task.id) { task in
                switch source {
                case .event(let event): TaskLinks.linking(task, event: TaskEvent(event, scope: scope))
                case .thread(let thread, let mailbox): TaskLinks.linking(task, email: TaskEmail(thread, mailbox: mailbox))
                }
            }
            error = nil
        } catch {
            self.error = "Couldn't link the task. \(error.localizedDescription)"
        }
    }

    /** Every link of the task's that reaches this event or conversation goes; the task stays. */
    private func unlink(_ task: MailTask) async {
        do {
            try await tasks.update(task.id) { task in
                var task = task
                switch source {
                case .event(let event):
                    let keys = Set(TaskLinks.links(of: task, to: event).map(\.key))
                    task.events.removeAll { keys.contains($0.key) }
                case .thread(let thread, let mailbox):
                    task.emails.removeAll { $0.links(thread.id, mailbox: mailbox) || $0.links(thread.id, mailbox: thread.mailbox) }
                }
                return task
            }
            error = nil
        } catch {
            self.error = "Couldn't unlink the task. \(error.localizedDescription)"
        }
    }
}
