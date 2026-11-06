import SwiftUI

/**
 * Tasks, opened full screen from the places bar
 * (⌃⌄ › Tasks) as the calendar is: what's open by when it's due, then what's done under a heading that
 * folds away. Swipe a row to finish it or to throw it away, tap it to change
 * it, tap the conversation under it to go back to the mail it came from.
 */
struct TasksView: View {
    @Environment(Session.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /** A task whose reminder was tapped: it opens on top of the list. */
    var opening: UUID?
    let onEmail: (TaskEmail) -> Void

    @State private var editing: MailTask?
    @State private var showDone = false
    @State private var now = Date.now

    private var tasks: TaskStore { session.tasks }
    private var dates: CalendarDates { CalendarDates(preferences: preferences.calendar) }
    private var sections: [TaskSection] { TaskList.sections(tasks.tasks, now: now, dates: dates) }
    private var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.18) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section {
                        if section.id != .done || showDone {
                            ForEach(section.tasks) { row($0) }
                        }
                    } header: {
                        header(section)
                    }
                    .textCase(nil)
                }
                if sections.isEmpty { empty }
            }
            .listStyle(.plain)
            .listSectionSeparator(.hidden, edges: .top)
            .scrollContentBackground(.hidden)
            .background(palette.canvas)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .navigationTitle("Tasks")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add task", systemImage: "plus") { editing = MailTask() }
                }
            }
            .sheet(item: $editing) { task in
                TaskEditor(task: task, onEmail: open)
            }
            .task {
                now = .now
                await tasks.checkReminders()
                await keepTime()
            }
            // Away for a while, the clock has moved on: Overdue and Today are read again.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { now = .now }
            }
            .onChange(of: opening, initial: true) { _, id in
                guard let id, let task = tasks.task(id) else { return }
                editing = task
            }
            .alert("Couldn't save the tasks", isPresented: .constant(tasks.failure != nil)) {
                Button("OK") { tasks.failure = nil }
            } message: {
                Text(tasks.failure ?? "")
            }
        }
    }

    /** A deadline passing, or midnight, while the list is open moves the rows under the right heading. */
    private func keepTime() async {
        while !Task.isCancelled {
            let ahead = 60 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
            do { try await Task.sleep(for: .seconds(ahead)) } catch { return }
            now = .now
        }
    }

    private func header(_ section: TaskSection) -> some View {
        let folds = section.id == .done
        return Button {
            guard folds else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showDone.toggle() }
        } label: {
            HStack(spacing: 6) {
                if folds {
                    Image(systemName: "chevron.down")
                        .font(.inter(.caption2))
                        .rotationEffect(.degrees(showDone ? 0 : -90))
                }
                Text(section.id.title)
                    .fontWeight(.medium)
                    .foregroundStyle(section.id == .overdue ? palette.error : palette.text)
                Spacer()
                Text("\(section.tasks.count)").monospacedDigit()
            }
            .font(.inter(.footnote))
            .foregroundStyle(palette.muted)
            .frame(minHeight: folds ? 44 : 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!folds)
        .accessibilityValue(folds ? (showDone ? "Expanded" : "Collapsed") : "")
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }

    private var empty: some View {
        ContentUnavailableView(
            "No tasks",
            systemImage: "checklist",
            description: Text("Add one here, or from a conversation's More menu. Tasks stay on this iPhone.")
        )
        .foregroundStyle(palette.muted)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.top, 40)
    }

    private func row(_ task: MailTask) -> some View {
        TaskRow(
            task: task,
            due: TaskList.dueLabel(task, now: now, dates: dates),
            overdue: TaskList.group(of: task, now: now, dates: dates) == .overdue,
            onToggle: { toggle(task) },
            onOpen: { editing = task },
            onEmail: open
        )
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(palette.canvas)
        .contextMenu {
            Button(task.done ? "Mark as not done" : "Mark as done",
                   systemImage: task.done ? "circle" : "checkmark.circle") { toggle(task) }
            Button("Edit", systemImage: "pencil") { editing = task }
            if let email = task.email {
                Button("Open the email", systemImage: "envelope") { open(email) }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation(animation) { tasks.delete(task) }
            }
        }
        .modifier(MailSwipeActions(leading: doneAction(task), trailing: deleteAction(task), square: preferences.fullWidthRows))
        .listRowBackground(palette.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    /** The mail list's swipe: away to the right finishes it, to the left it's gone. */
    private func doneAction(_ task: MailTask) -> MailSwipeAction {
        task.done
            ? MailSwipeAction(title: "Not done", symbol: "circle", tint: palette.focus) { toggle(task) }
            : MailSwipeAction(title: "Done", symbol: "checkmark.circle", tint: .green) { toggle(task) }
    }

    private func deleteAction(_ task: MailTask) -> MailSwipeAction {
        MailSwipeAction(title: "Delete", symbol: "trash", tint: .red) {
            withAnimation(animation) { tasks.delete(task) }
        }
    }

    private func toggle(_ task: MailTask) {
        withAnimation(animation) { tasks.setDone(!task.done, task) }
    }

    private func open(_ email: TaskEmail) {
        editing = nil
        onEmail(email)
    }
}

/**
 * One task, laid out like the mail rows (`ThreadRow`): a circle to finish it in
 * the gutter, then what it is, when it's due, and the conversation it came
 * from, which opens that conversation.
 */
struct TaskRow: View {
    @Environment(\.palette) private var palette

    let task: MailTask
    var due: String?
    var overdue = false
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onEmail: (TaskEmail) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(task.done ? palette.action : palette.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onOpen) { lines }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                if let email = task.email {
                    Button { onEmail(email) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "envelope")
                            Text(email.subject).lineLimit(1)
                        }
                        .font(.inter(.footnote))
                        .foregroundStyle(palette.muted)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("From \(email.subject)")
                    .accessibilityHint("Opens the conversation")
                }
            }
        }
        .contentShape(.rect)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.content)
                .font(.inter(.subheadline).weight(task.done ? .regular : .medium))
                .foregroundStyle(task.done ? palette.muted : palette.text)
                .strikethrough(task.done)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let due {
                    Label(due, systemImage: task.reminder && task.hasTime ? "bell" : "calendar")
                        .font(.inter(.footnote))
                        .foregroundStyle(overdue ? palette.error : palette.muted)
                        .monospacedDigit()
                }
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.inter(.footnote))
                        .foregroundStyle(palette.muted.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
