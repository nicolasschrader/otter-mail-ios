import SwiftUI
import UIKit

/**
 * Give to Grok: what the bot should do, and everything it will receive, in
 * full, before anything leaves the phone. Only Send sends; the sheet keeps one
 * job id while it's open, so a second tap can't make a second job.
 */
struct GrokDelegateView: View {
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let source: GrokSource

    @State private var id = UUID()
    @State private var instruction = ""
    @State private var sending = false
    @State private var context: GrokContext?
    @State private var webhook = "—"
    @State private var service = "—"

    private var grok: GrokJobs { session.grok }
    private var trimmed: String { instruction.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SettingsForm {
            Section {
                TextField("What should Grok do?", text: $instruction, axis: .vertical)
                    .lineLimit(3...10)
                    .font(.inter(.body))
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier("grok-instruction")
            } header: {
                Text("Instruction").sectionHeader()
            } footer: {
                Text("\(instruction.count) of \(GrokContext.instructionLimit) characters")
                    .sectionFooter()
                    .foregroundStyle(instruction.count > GrokContext.instructionLimit ? palette.error : palette.muted)
            }

            Section {
                Text(verbatim: context?.preview() ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("grok-preview")
            } header: {
                Text("What Grok receives").sectionHeader()
            } footer: {
                Text(footer).sectionFooter()
            }
        }
        .navigationTitle("Give to Grok")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(sending ? "Sending…" : "Send") { Task { await send() } }
                    .fontWeight(.semibold)
                    .disabled(sending || trimmed.isEmpty || instruction.count > GrokContext.instructionLimit || context == nil)
                    .accessibilityIdentifier("grok-send")
            }
        }
        .interactiveDismissDisabled(sending)
        .onAppear {
            context = GrokContext.of(source, lists: session.tasks.lists)
            if let config = GrokConfig.load() {
                webhook = GrokConfig.display(config.webhookURL)
                service = GrokConfig.display(config.backendURL)
            }
        }
    }

    private var footer: String {
        if grok.demo {
            return "In the demo, a stand-in answers: nothing leaves this iPhone. With a bot set up, this, the instruction, a job id and a one-time callback token are sent to its webhook when you tap Send."
        }
        return "Sent only when you tap Send: first the job is registered with your job service (\(service)), then this, the instruction, the job's id and a one-time callback token go to the webhook (\(webhook)). Grok's answer comes back as text and is never acted on."
    }

    private func send() async {
        guard let context, !sending else { return }
        sending = true
        await grok.send(id: id, source: source, instruction: trimmed, context: context)
        sending = false
        dismiss()
    }
}

/**
 * The jobs given to Grok from this task, conversation or event, on it: sent,
 * running, done with the bot's answer (plain text, never acted on), or an
 * error, with Retry where sending stopped on this side. Pending ones are asked
 * after while the card is on screen, a bounded number of times.
 */
struct GrokJobCards: View {
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette

    let source: GrokSource
    var inForm = false

    @State private var delegating = false

    private var grok: GrokJobs { session.grok }
    private var jobs: [GrokJob] { grok.jobs(for: source.key) }
    private var pending: [UUID] { jobs.filter(\.isPending).map(\.id) }

    var body: some View {
        if grok.isAvailable || !jobs.isEmpty {
            content
                .task(id: pending) {
                    guard !pending.isEmpty else { return }
                    await grok.poll(source.key)
                }
                .sheet(isPresented: $delegating) {
                    NavigationStack { GrokDelegateView(source: source) }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if inForm {
            Section {
                rows
            } header: {
                Text("Grok").sectionHeader()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Grok")
                    .font(.inter(.footnote).weight(.medium))
                    .foregroundStyle(palette.muted)
                rows
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(palette.text.opacity(0.04), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("grok-jobs")
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(jobs) { job in
            GrokJobRow(job: job)
        }
        if grok.isAvailable {
            Button("Give to Grok", systemImage: "paperplane") { delegating = true }
                .font(.inter(.subheadline).weight(.medium))
                .foregroundStyle(palette.action)
                .buttonStyle(.plain)
                .frame(minHeight: 44, alignment: .leading)
        }
    }
}

/** One job's card: its status, what it was asked, and what came back. */
struct GrokJobRow: View {
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette

    let job: GrokJob

    private var grok: GrokJobs { session.grok }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(status)
                    .font(.inter(.footnote).weight(.medium))
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(job.updated, format: .relative(presentation: .named))
                    .font(.inter(.caption))
                    .foregroundStyle(palette.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("grok-status")
            Text(verbatim: job.instruction)
                .font(.inter(.subheadline))
                .foregroundStyle(palette.text)
                .lineLimit(3)
            if let problem = job.problem {
                Text(verbatim: problem).font(.inter(.footnote)).foregroundStyle(palette.error)
            }
            if let botError = job.botError {
                Text(verbatim: botError).font(.inter(.footnote)).foregroundStyle(palette.error).textSelection(.enabled)
            }
            if let result = job.result {
                // From outside: plain text, no links or formatting read into it, and nothing done with it.
                Text(verbatim: result)
                    .font(.inter(.subheadline))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.text.opacity(0.05), in: .rect(cornerRadius: 10))
                    .accessibilityIdentifier("grok-result")
            }
            HStack(spacing: 16) {
                if job.canRetry {
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await grok.retry(job) } }
                }
                if job.isPending {
                    Button("Check again", systemImage: "arrow.triangle.2.circlepath") { Task { await grok.check(job) } }
                }
                if let result = job.result {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = result }
                }
                Spacer(minLength: 0)
                Button("Remove", systemImage: "trash", role: .destructive) { grok.delete(job) }
                    .labelStyle(.iconOnly)
            }
            .font(.inter(.footnote).weight(.medium))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        switch job.status {
        case .sending: job.problem == nil ? "Sending…" : "Couldn't send"
        case .sent: "Sent · waiting for Grok"
        case .running: "Grok is working on it"
        case .done: "Done"
        case .error: "Grok reported an error"
        }
    }

    private var symbol: String {
        switch job.status {
        case .sending: job.problem == nil ? "paperplane" : "exclamationmark.triangle"
        case .sent: "paperplane.fill"
        case .running: "hourglass"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.octagon"
        }
    }

    private var tint: Color {
        switch job.status {
        case .done: palette.action
        case .error: palette.error
        case .sending where job.problem != nil: palette.error
        default: palette.muted
        }
    }
}

/**
 * Settings › Grok bot: the webhook, the header and key it checks the sender
 * by, and the job service with the app's token, kept in the Keychain on this
 * iPhone only. Once saved they're never shown again, not even the webhook's
 * path: only the hosts. A field left empty while changing keeps what's saved.
 */
struct GrokSettings: View {
    @Environment(Session.self) private var session
    @Environment(\.palette) private var palette

    @State private var saved: GrokConfig?
    @State private var changing = false
    @State private var webhook = ""
    @State private var header = ""
    @State private var key = ""
    @State private var backend = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        SettingsForm {
            if let saved, !changing {
                Section {
                    LabeledContent("Webhook", value: GrokConfig.display(saved.webhookURL))
                    LabeledContent("Sender header", value: saved.senderHeader)
                    LabeledContent("Sender key", value: "Saved")
                    LabeledContent("Job service", value: GrokConfig.display(saved.backendURL))
                    LabeledContent("App token", value: "Saved")
                } footer: {
                    Text("Kept in this iPhone's Keychain, for this device only, and never synced. Saved keys aren't shown again.").sectionFooter()
                }
                Section {
                    Button("Change…", systemImage: "pencil") { changing = true }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        GrokConfig.remove()
                        self.saved = nil
                        session.grok.reloadConfig()
                    }
                }
            } else {
                Section {
                    SecureField("Webhook URL", text: $webhook)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Sender header", text: $header, prompt: Text(saved?.senderHeader ?? "Authorization"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Sender key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Bot webhook").sectionHeader()
                } footer: {
                    Text("The routine's own sign-in isn't settled yet: set the header and key it checks the sender by. The key is sent as it is, so include “Bearer ” if the header needs one.").sectionFooter()
                }
                Section {
                    SecureField("Job service URL", text: $backend)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("App token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Job service").sectionHeader()
                } footer: {
                    Text("Your own Grok job service (tools/grok-jobs in the Otter Mail repository), which gives each job its one-time callback. https, or http on this device's own network.").sectionFooter()
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(palette.error)
                    }
                }
                Section {
                    Button("Save", systemImage: "checkmark") { save() }
                    if saved != nil {
                        Button("Cancel") {
                            clear()
                            changing = false
                        }
                    }
                } footer: {
                    Text(saved == nil ? "" : "Leave a field empty to keep what's saved.").sectionFooter()
                }
            }
            if session.grok.demo {
                Section {
                    EmptyView()
                } footer: {
                    Text("In the demo, Give to Grok uses a stand-in: nothing is sent anywhere.").sectionFooter()
                }
            }
        }
        .navigationTitle("Grok bot")
        .toolbarTitleDisplayMode(.inline)
        .onAppear { saved = GrokConfig.load() }
        .onDisappear(perform: clear)
    }

    private func save() {
        let pick = { (entered: String, kept: String?) in
            let value = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? kept ?? "" : value
        }
        let config = GrokConfig(
            webhookURL: pick(webhook, saved?.webhookURL),
            senderHeader: pick(header, saved?.senderHeader ?? "Authorization"),
            senderKey: pick(key, saved?.senderKey),
            backendURL: pick(backend, saved?.backendURL),
            appToken: pick(token, saved?.appToken)
        )
        if let problem = config.problem {
            error = problem
            return
        }
        guard config.save() else {
            error = "The Keychain didn't take the settings. Try again."
            return
        }
        clear()
        saved = GrokConfig.load()
        changing = false
        session.grok.reloadConfig()
    }

    private func clear() {
        webhook = ""
        header = ""
        key = ""
        backend = ""
        token = ""
        error = nil
    }
}
