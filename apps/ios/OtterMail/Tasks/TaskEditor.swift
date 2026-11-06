import SwiftUI
import UIKit

/**
 * A task, new or being changed, in Settings' grouped form (`SettingsForm`):
 * what it is, a note, when it's due and whether it reminds. Notifications are
 * asked for here, the moment a reminder is turned on, and never before.
 */
struct TaskEditor: View {
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let onEmail: (TaskEmail) -> Void

    @State private var task: MailTask
    @State private var fallback: Date
    @State private var saving = false
    @State private var error: String?

    init(task: MailTask, onEmail: @escaping (TaskEmail) -> Void) {
        _task = State(initialValue: task)
        _fallback = State(initialValue: task.due ?? Self.nextHour())
        self.onEmail = onEmail
    }

    private var tasks: TaskStore { session.tasks }
    private var existing: Bool { tasks.contains(task.id) }
    private var passed: Bool { (task.reminderAt ?? .distantFuture) < .now }

    var body: some View {
        NavigationStack {
            SettingsForm {
                Section {
                    TextField("Task", text: $task.content, axis: .vertical)
                        .font(.inter(.body))
                        .foregroundStyle(palette.text)
                    TextField("Notes", text: $task.notes, axis: .vertical)
                        .font(.inter(.subheadline))
                        .foregroundStyle(palette.text)
                        .frame(minHeight: 60, alignment: .topLeading)
                }

                if !tasks.projects.isEmpty {
                    Section {
                        Picker(selection: $task.projectId) {
                            ForEach(tasks.lists) { list in
                                Text(list.name).tag(list.id == TaskProject.inbox.id ? nil : Optional(list.id))
                            }
                        } label: {
                            Label("List", systemImage: "list.bullet")
                        }
                    }
                }

                Section {
                    Toggle(isOn: hasDue) { Label("Due date", systemImage: "calendar") }
                    if task.due != nil {
                        DatePicker(
                            selection: due,
                            displayedComponents: task.hasTime ? [.date, .hourAndMinute] : [.date]
                        ) {
                            Label("Due", systemImage: "arrow.right.circle")
                        }
                        Toggle(isOn: hasTime) { Label("At a time", systemImage: "clock") }
                    }
                    if task.hasTime {
                        Toggle(isOn: reminds) { Label("Remind me", systemImage: "bell") }
                    }
                    if task.reminder && tasks.remindersDenied {
                        Button("Open iPhone Settings", systemImage: "bell.slash") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("When").sectionHeader()
                } footer: {
                    Text(whenFooter).sectionFooter()
                }

                if let email = task.email {
                    Section {
                        Button { onEmail(email) } label: {
                            LabeledContent {
                                Image(systemName: "chevron.right").font(.inter(.footnote)).foregroundStyle(palette.muted)
                            } label: {
                                Label(email.subject, systemImage: "envelope").lineLimit(2)
                            }
                        }
                    } header: {
                        Text("From").sectionHeader()
                    } footer: {
                        Text("The conversation this task came from, in \(email.mailbox).").sectionFooter()
                    }
                }

                if existing {
                    Section {
                        Button("Delete task", systemImage: "trash", role: .destructive) {
                            tasks.delete(task)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing ? "Task" : "New task")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(saving || task.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { await tasks.checkReminders() }
            .alert("Couldn't save the task", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    /** The sheet closes only once the task is on disk; otherwise it stays, with the changes. */
    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await tasks.save(task)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var whenFooter: String {
        if task.reminder && tasks.remindersDenied {
            return "Notifications are off for Otter Mail, so this reminder can't arrive. Turn them on in iPhone Settings."
        }
        if task.reminder && passed {
            return "This time has passed, so no reminder is sent. Pick a later one."
        }
        if task.reminder && tasks.isWaiting(task) {
            return "This iPhone keeps the \(TaskReminders.limit) nearest reminders, and more are set before this one. It's asked for once an earlier reminder has arrived and Otter Mail has been opened."
        }
        if task.reminder { return "A reminder arrives on this iPhone at that time. Nothing is sent anywhere." }
        if task.hasTime { return "Turn on Remind me to be told at that time." }
        return "A due date keeps the task in order. Give it a time to be reminded."
    }

    private var hasDue: Binding<Bool> {
        Binding {
            task.due != nil
        } set: { on in
            task.due = on ? fallback : nil
            if !on {
                task.hasTime = false
                task.reminder = false
            }
        }
    }

    private var hasTime: Binding<Bool> {
        Binding {
            task.hasTime
        } set: { on in
            task.hasTime = on
            if on {
                task.due = Self.sameDay(task.due ?? fallback, time: fallback)
            } else {
                task.reminder = false
            }
        }
    }

    private var reminds: Binding<Bool> {
        Binding {
            task.reminder
        } set: { on in
            task.reminder = on
            if on { Task { await tasks.askForReminders() } }
        }
    }

    private var due: Binding<Date> {
        Binding {
            task.due ?? fallback
        } set: { picked in
            task.due = picked
            fallback = picked
        }
    }

    private static func nextHour() -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: .now)?.end ?? .now.addingTimeInterval(3600)
        return hour
    }

    /** Keeps the day being picked and takes the time from `fallback`, so turning the time on doesn't move it. */
    private static func sameDay(_ day: Date, time: Date) -> Date {
        let calendar = Calendar.current
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: clock.hour ?? 9, minute: clock.minute ?? 0, second: 0, of: day) ?? day
    }
}
