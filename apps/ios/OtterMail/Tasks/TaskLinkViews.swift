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
                Button("Unlink \(title)", systemImage: "xmark.circle.fill", action: onUnlink)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17))
                    .foregroundStyle(palette.muted)
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
        }
        .frame(minHeight: 44)
    }

    private var line: String? {
        guard unavailable else { return detail }
        return [detail, "Not available"].compactMap { $0 }.joined(separator: " · ")
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
        if link.scope == .series { detail = "Every occurrence · next \(detail)" }
        let reachable = CalendarStore.sources(store.shownMailboxes).contains { $0.email.lowercased() == link.account }
        return (live?.title ?? link.title, detail, live == nil && !reachable)
    }
}

/**
 * The task editor's links: every conversation and event the task is linked
 * to, each opened or unlinked in place, a series' link switched between the
 * one occurrence and the whole series, and more linked from the pickers.
 * Nothing is written until the editor's Save.
 */
struct TaskEditorLinks: View {
    @Environment(MailStore.self) private var store
    @Environment(CalendarStore.self) private var calendar
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette

    @Binding var task: MailTask
    let onEmail: (TaskEmail) -> Void
    let onEvent: (TaskEvent) -> Void

    private var labels: TaskLinkLabels {
        TaskLinkLabels(store: store, calendar: calendar, dates: CalendarDates(preferences: preferences.calendar))
    }
    private var hasCalendar: Bool { !CalendarStore.sources(store.shownMailboxes).isEmpty }

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
                    onOpen: label.unavailable ? nil : { onEvent(link) },
                    onUnlink: { task = TaskLinks.unlinking(task, event: link.key) }
                )
                if link.recurring {
                    Picker("Linked to", selection: Binding(
                        get: { link.scope },
                        set: { task = TaskLinks.rescoping(task, event: link.key, to: $0) }
                    )) {
                        ForEach(TaskEvent.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .font(.inter(.subheadline))
                    .accessibilityIdentifier("task-link-scope")
                }
            }
            NavigationLink {
                MailPicker(linked: Set(task.emails.map(\.key))) { task = TaskLinks.linking(task, email: $0) }
            } label: {
                Label("Link an email", systemImage: "envelope.badge")
            }
            if hasCalendar {
                NavigationLink {
                    EventPicker(linked: Set(task.events.map(\.key))) { task = TaskLinks.linking(task, event: $0) }
                } label: {
                    Label("Link an event", systemImage: "calendar.badge.plus")
                }
            }
        } header: {
            Text("Linked").sectionHeader()
        } footer: {
            Text(footer).sectionFooter()
        }
    }

    private var footer: String {
        if task.emails.isEmpty && task.events.isEmpty {
            return "Link the conversations and events this task is about. Links stay on this iPhone, with the task."
        }
        return "Links stay on this iPhone, with the task. Nothing is changed in the mail or the calendar."
    }
}

/** The conversations a task can be linked to: every mailbox's inbox, newest first, or what a search finds. */
struct MailPicker: View {
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let linked: Set<String>
    let onPick: (TaskEmail) -> Void

    @State private var query = ""

    private struct Pick: Identifiable {
        let thread: MailThread
        let mailbox: String
        var id: String { "\(mailbox.lowercased())|\(thread.id)" }
    }

    private var picks: [Pick] {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        var found: [Pick] = []
        for scope in store.shownScopes {
            let threads = terms.isEmpty ? store.threads(in: .inbox, scope: scope.email) : store.search(terms, scope: scope.email)
            for thread in threads.prefix(60) where seen.insert(thread.id).inserted {
                found.append(Pick(thread: thread, mailbox: scope.email))
            }
        }
        return Array(found.sorted { $0.thread.latest.date > $1.thread.latest.date }.prefix(100))
    }

    var body: some View {
        List {
            ForEach(picks) { pick in
                let email = TaskEmail(pick.thread, mailbox: pick.mailbox)
                let done = linked.contains(email.key)
                Button {
                    onPick(email)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(email.subject)
                                .font(.inter(.subheadline).weight(.medium))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                            Text("\(pick.thread.latest.from.label) · \(pick.mailbox)")
                                .font(.inter(.footnote))
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if done { Image(systemName: "checkmark").foregroundStyle(palette.action) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(done)
                .listRowBackground(palette.card)
            }
            if picks.isEmpty {
                ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search mail")
        .navigationTitle("Link an email")
        .toolbarTitleDisplayMode(.inline)
    }
}

/**
 * The events a task can be linked to: the agenda's days ahead, as the
 * calendar lists them. An event of a series asks, in its row, whether the
 * task is about this occurrence or every one.
 */
struct EventPicker: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(CalendarStore.self) private var calendar
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let linked: Set<String>
    let onPick: (TaskEvent) -> Void

    @State private var query = ""
    @State private var choosing: String?
    @State private var now = Date.now

    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }
    private var sources: [Mailbox] { CalendarStore.sources(store.shownMailboxes) }
    private var window: EventWindow { dates.window(.agenda, anchor: now) }

    private var days: [EventDay] {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = (calendar.events(in: window) ?? []).filter { event in
            event.status != .cancelled && (terms.isEmpty || event.title.localizedCaseInsensitiveContains(terms))
        }
        return EventDays.agenda(found, from: dates.startOfDay(now), now: now, dates: dates)
    }

    var body: some View {
        List {
            ForEach(days) { day in
                Section {
                    ForEach(day.events) { event in row(event) }
                } header: {
                    Text(dates.heading(day.id, now: now))
                        .font(.inter(.footnote).weight(.medium))
                        .foregroundStyle(palette.muted)
                }
                .textCase(nil)
            }
            if days.isEmpty {
                if calendar.events(in: window) == nil {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView(
                        query.isEmpty ? "No events ahead" : "No matching events", systemImage: "calendar"
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search events")
        .navigationTitle("Link an event")
        .toolbarTitleDisplayMode(.inline)
        .task { await calendar.load(window, sources: sources, demo: store.isDemo, google: session.google, dates: dates) }
    }

    @ViewBuilder private func row(_ event: CalendarEvent) -> some View {
        let occurrence = TaskEvent(event, scope: .occurrence)
        let series = TaskEvent(event, scope: .series)
        let done = linked.contains(occurrence.key) || (occurrence.recurring && linked.contains(series.key))
        Button {
            if occurrence.recurring {
                choosing = choosing == event.id ? nil : event.id
            } else {
                pick(occurrence)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.inter(.subheadline).weight(.medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(event.allDay ? event.calendar.name : "\(dates.timeLabel(event.start)) · \(event.calendar.name)")
                        .font(.inter(.footnote))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if done {
                    Image(systemName: "checkmark").foregroundStyle(palette.action)
                } else if occurrence.recurring {
                    Image(systemName: "repeat").foregroundStyle(palette.muted).accessibilityLabel("Repeats")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(done)
        .listRowBackground(palette.card)
        if choosing == event.id, !done {
            // Asked in place, and only for a series: the one occurrence, or every one of them.
            HStack(spacing: 8) {
                Button(TaskEvent.Scope.occurrence.title) { pick(occurrence) }
                    .buttonStyle(.bordered)
                Button(TaskEvent.Scope.series.title) { pick(series) }
                    .buttonStyle(.bordered)
            }
            .font(.inter(.footnote).weight(.medium))
            .listRowBackground(palette.card)
        }
    }

    private func pick(_ link: TaskEvent) {
        onPick(link)
        dismiss()
    }
}

/** The tasks an event or a conversation can be linked to: what's open first, then what's done. */
struct TaskPicker: View {
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let linked: Set<UUID>
    /** For an event of a series: whether the task is about this occurrence or every one. */
    var recurring = false
    let onPick: (MailTask, TaskEvent.Scope) -> Void

    @State private var query = ""
    @State private var scope: TaskEvent.Scope = .occurrence

    private var found: [MailTask] {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = session.tasks.tasks.filter { terms.isEmpty || $0.content.localizedCaseInsensitiveContains(terms) }
        return TaskList.sorted(open.filter { !$0.done }) + TaskList.sorted(open.filter(\.done))
    }

    var body: some View {
        List {
            if recurring {
                Section {
                    Picker("Link to", selection: $scope) {
                        ForEach(TaskEvent.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("This event repeats").sectionHeader()
                }
                .listRowBackground(palette.card)
            }
            Section {
                ForEach(found) { task in
                    let done = linked.contains(task.id)
                    Button {
                        onPick(task, scope)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: task.done ? "checkmark.circle.fill" : "circle").foregroundStyle(palette.muted)
                            Text(task.content)
                                .font(.inter(.subheadline))
                                .foregroundStyle(task.done ? palette.muted : palette.text)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            if done { Image(systemName: "checkmark").foregroundStyle(palette.action) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(done)
                }
                if found.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No tasks" : "No matching tasks", systemImage: "checklist")
                        .listRowBackground(Color.clear)
                }
            }
            .listRowBackground(palette.card)
        }
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tasks")
        .navigationTitle("Link a task")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
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
 * task starts linked, and an existing one is linked from the task picker.
 * For an event of a series, both ask whether it's this one or every one.
 */
struct LinkedTasks: View {
    @Environment(Session.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette
    @Environment(\.openTaskTarget) private var openTarget

    let source: TaskSource
    /** Rows in the editor's grouped form; otherwise a card in a scrolling page. */
    var inForm = false

    @State private var editing: MailTask?
    @State private var picking = false
    @State private var error: String?

    private var tasks: TaskStore { session.tasks }
    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }

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
            .sheet(isPresented: $picking) {
                NavigationStack {
                    TaskPicker(linked: Set(linked.map(\.id)), recurring: recurringEvent != nil) { task, scope in
                        Task { await link(task, scope: scope) }
                    }
                }
            }
            .alert("Couldn't change the task", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
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
                Button("Unlink \(task.content)", systemImage: "xmark.circle.fill") { Task { await unlink(task) } }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17))
                    .foregroundStyle(palette.muted)
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .padding(.vertical, 4)
        }
        HStack(spacing: 16) {
            if let event = recurringEvent {
                Menu {
                    Button(TaskEvent.Scope.occurrence.title) { editing = MailTask(from: event, scope: .occurrence) }
                    Button(TaskEvent.Scope.series.title) { editing = MailTask(from: event, scope: .series) }
                } label: {
                    Label("Add task", systemImage: "plus.circle")
                }
            } else {
                Button("Add task", systemImage: "plus.circle") { editing = newTask }
            }
            if !tasks.tasks.isEmpty {
                Button("Link a task", systemImage: "link") { picking = true }
            }
            Spacer(minLength: 0)
        }
        .font(.inter(.subheadline).weight(.medium))
        .foregroundStyle(palette.action)
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private var newTask: MailTask {
        switch source {
        case .event(let event): MailTask(from: event, scope: .occurrence)
        case .thread(let thread, let mailbox): MailTask(from: thread, mailbox: mailbox)
        }
    }

    private func opensHere(_ email: TaskEmail) -> Bool {
        guard case .thread(let thread, let mailbox) = source else { return false }
        return email.links(thread.id, mailbox: mailbox) || email.links(thread.id, mailbox: thread.mailbox)
    }

    private func link(_ task: MailTask, scope: TaskEvent.Scope) async {
        do {
            try await tasks.update(task.id) { task in
                switch source {
                case .event(let event): TaskLinks.linking(task, event: TaskEvent(event, scope: scope))
                case .thread(let thread, let mailbox): TaskLinks.linking(task, email: TaskEmail(thread, mailbox: mailbox))
                }
            }
        } catch {
            self.error = error.localizedDescription
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
        } catch {
            self.error = error.localizedDescription
        }
    }
}
