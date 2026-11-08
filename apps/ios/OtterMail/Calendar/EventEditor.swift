import SwiftUI

/**
 * An event, new or yours to change, in the calendar's own navigation (so the
 * bar stays under it), as event-panel.tsx's NewEvent and EventDetails edit
 * one: title, All-day, when it starts and ends, the calendar (picked for a new
 * one), where, and notes; an event of yours can be deleted. Nothing is written
 * until Save or Delete is tapped. Invitations from others open in `EventView`.
 */
struct EventEditor: View {
    @Environment(MailStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let events: CalendarStore
    /** The event being changed, or nil for a new one. */
    let event: CalendarEvent?
    /** The calendars a new event can go on. */
    let calendars: [EventCalendar]
    let dates: CalendarDates
    let color: (EventCalendar) -> Color
    var onSaved: (CalendarEvent) -> Void = { _ in }

    @State private var draft: EventDraft
    @State private var saving = false
    @State private var error: String?

    init(
        events: CalendarStore, draft: EventDraft, event: CalendarEvent? = nil, calendars: [EventCalendar],
        dates: CalendarDates, color: @escaping (EventCalendar) -> Color, onSaved: @escaping (CalendarEvent) -> Void = { _ in }
    ) {
        self.events = events
        self.event = event
        self.calendars = calendars
        self.dates = dates
        self.color = color
        self.onSaved = onSaved
        _draft = State(initialValue: draft)
    }

    private var original: EventDraft? { event.map(EventDraft.init(editing:)) }
    private var changed: Bool { original.map { draft.patch(from: $0, dates: dates) != EventInput() } ?? true }

    var body: some View {
        SettingsForm {
            Section {
                TextField("Title", text: $draft.title, axis: .vertical)
                    .font(.inter(.body).weight(.medium))
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier("event-title")
            }

            Section {
                Toggle(isOn: Binding(get: { draft.allDay }, set: { draft.setAllDay($0, dates: dates) })) {
                    Label("All-day", systemImage: "sun.max")
                }
                if draft.allDay {
                    DatePicker(selection: Binding(get: { draft.start }, set: { draft.move(to: dates.startOfDay($0)) }),
                               displayedComponents: [.date]) {
                        Label("Starts", systemImage: "arrow.right.circle")
                    }
                    DatePicker(selection: Binding(get: { draft.lastDay(dates: dates) }, set: { draft.setLastDay($0, dates: dates) }),
                               in: draft.start..., displayedComponents: [.date]) {
                        Label("Ends", systemImage: "arrow.left.circle")
                    }
                } else {
                    DatePicker(selection: Binding(get: { draft.start }, set: { draft.move(to: $0) })) {
                        Label("Starts", systemImage: "arrow.right.circle")
                    }
                    DatePicker(selection: $draft.end, in: draft.start...) {
                        Label("Ends", systemImage: "arrow.left.circle")
                    }
                }
            } header: {
                Text("When").sectionHeader()
            } footer: {
                if let problem = draft.problem {
                    Text(problem).sectionFooter().foregroundStyle(palette.error)
                } else if event?.recurring == true {
                    Text("Repeats. Changes apply to this one.").sectionFooter()
                } else if !draft.allDay {
                    Text(CalendarDates.durationLabel(draft.end.timeIntervalSince(draft.start))).sectionFooter()
                }
            }

            Section {
                calendarRow
                TextField("Location", text: $draft.location)
                    .font(.inter(.body))
                    .foregroundStyle(palette.text)
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .font(.inter(.subheadline))
                    .foregroundStyle(palette.text)
                    .frame(minHeight: 60, alignment: .topLeading)
            }

            if let event {
                LinkedTasks(source: .event(event), inForm: true)
                GrokJobCards(source: .event(event), inForm: true)
                extras(event)
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.inter(.subheadline))
                        .foregroundStyle(palette.error)
                }
            }

            if let event {
                Section {
                    Button("Delete event", systemImage: "trash", role: .destructive) {
                        Task { await delete(event) }
                    }
                    .disabled(saving)
                } footer: {
                    if event.hasGuests {
                        Text("The guests are told it's cancelled.").sectionFooter()
                    }
                }
            }
        }
        .navigationTitle(event == nil ? "New event" : "Event")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(saving || draft.problem != nil || !changed)
            }
        }
    }

    /** A new event's calendar is picked, by mailbox as the web's NewEvent lists them; an event's stays where it is. */
    @ViewBuilder private var calendarRow: some View {
        if event == nil, calendars.count > 1 {
            Picker(selection: $draft.calendar) {
                ForEach(CalendarStore.grouped(CalendarStore.sources(store.shownMailboxes), lists: lists), id: \.mailbox.email) { group in
                    if !group.calendars.isEmpty {
                        Section(group.mailbox.displayName) {
                            ForEach(group.calendars, id: \.key) { calendar in
                                Text(calendar.primary ? group.mailbox.displayName : calendar.name).tag(calendar)
                            }
                        }
                    }
                }
            } label: {
                calendarLabel
            }
        } else {
            LabeledContent {
                Text(draft.calendar.name).foregroundStyle(palette.muted)
            } label: {
                calendarLabel
            }
        }
    }

    private var calendarLabel: some View {
        Label {
            Text("Calendar")
        } icon: {
            Circle().fill(color(draft.calendar)).frame(width: 10, height: 10)
        }
    }

    private var lists: [String: [EventCalendar]] {
        Dictionary(grouping: calendars, by: \.account)
    }

    /** What the editor doesn't change but EventDetails shows: the meeting, who's coming, Google Calendar. */
    @ViewBuilder private func extras(_ event: CalendarEvent) -> some View {
        let guests = event.guests
        if event.meetingLink != nil || !guests.isEmpty || event.htmlLink != nil {
            Section {
                if let link = event.meetingLink, let url = URL(string: link) {
                    Link(destination: url) {
                        Label("Join \(Meetings.provider(link).title)", systemImage: "video")
                    }
                }
                if !guests.isEmpty {
                    LabeledContent {
                        Text(CalendarEvent.responseSummary(guests)).foregroundStyle(palette.muted)
                    } label: {
                        Label(guests.count == 1 ? "1 guest" : "\(guests.count) guests", systemImage: "person.2")
                    }
                }
                if let url = event.htmlLink.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
    }

    private func writer(_ account: String) -> EventWriter {
        events.writer(for: account, demo: store.isDemo, google: session.google)
    }

    /** Only once Google has it does the editor close; otherwise it stays, with the changes and why. */
    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let saved: CalendarEvent
            if let event {
                saved = try await events.update(event, to: draft, with: writer(event.calendar.account), demo: store.isDemo, dates: dates)
            } else {
                saved = try await events.create(draft, with: writer(draft.calendar.account), demo: store.isDemo, dates: dates)
            }
            onSaved(saved)
            dismiss()
        } catch {
            self.error = Self.message(error, creating: event == nil)
        }
    }

    private func delete(_ event: CalendarEvent) async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await events.delete(event, with: writer(event.calendar.account), demo: store.isDemo)
            dismiss()
        } catch {
            self.error = "Couldn't delete the event. \(error.localizedDescription)"
        }
    }

    private static func message(_ error: Error, creating: Bool) -> String {
        let what = creating ? "Couldn't create the event." : "Couldn't change the event."
        if error is GoogleCalendarAPI.NoAccess {
            return "\(what) Sign in to this mailbox again to let Otter Mail change its calendar."
        }
        if let problem = error as? EventProblem { return problem.message }
        return "\(what) \(error.localizedDescription)"
    }
}
