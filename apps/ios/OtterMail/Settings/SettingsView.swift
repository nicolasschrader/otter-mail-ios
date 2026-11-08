import SwiftUI

/**
 * Settings: a page pushed in place from a section's ⋯ (`inPlace`, the bar
 * still under it, back to leave), or its own sheet with Close where the agent
 * and search sheets open it.
 */
struct SettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(Session.self) private var session
    @Environment(MailStore.self) private var store
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ErrorReports.enabledKey) private var errorReports = true

    var inPlace = false

    var body: some View {
        if inPlace {
            form
        } else {
            NavigationStack {
                form.toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
            }
        }
    }

    private var form: some View {
        @Bindable var preferences = preferences
        return SettingsForm {
            Section {
                VStack(spacing: 8) {
                    ProfilePicture(url: session.user?.picture, size: 64)
                    Text(session.user.map { $0.name ?? $0.email } ?? "Demo mailbox")
                        .font(.inter(.headline))
                        .foregroundStyle(palette.text)
                    Text(session.user?.email ?? "Pretend mail, to try Otter Mail. Nothing here reaches Google.")
                        .font(.inter(.subheadline))
                        .foregroundStyle(palette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink {
                    MailboxesSettings()
                } label: {
                    LabeledContent {
                        Text("\(store.shownScopes.count) on")
                    } label: {
                        Label("Mailboxes", systemImage: "tray.2")
                    }
                }
                Picker(selection: $preferences.notifications) {
                    ForEach(Preferences.Notifications.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Notifications", systemImage: "bell")
                }
                if !store.isDemo {
                    NavigationLink("Background notification setup") { MailboxesSettings() }
                }
                Picker(selection: $preferences.advance) {
                    ForEach(Preferences.Advance.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("After archive", systemImage: "arrow.turn.down.right")
                }
            } header: {
                Text("Mail").sectionHeader()
            } footer: {
                Group {
                    if !store.isDemo {
                        Text("Connect background notifications for each mailbox to receive alerts while the app is closed. Alerts are sent only for verified new mail; sender and preview load on this iPhone.")
                    }
                }
                .sectionFooter()
            }

            Section {
                NavigationLink {
                    LanguagesSettings()
                } label: {
                    LabeledContent {
                        Text(languageSummary)
                    } label: {
                        Label("Languages I read", systemImage: "character.bubble")
                    }
                }
                Toggle(isOn: $preferences.autoTranslate) {
                    Label("Translate automatically", systemImage: "translate")
                }
            } header: {
                Text("Translation").sectionHeader()
            } footer: {
                Text("Mail in other languages is translated on this iPhone, by Apple's Translation.").sectionFooter()
            }

            Section {
                NavigationLink {
                    AgentSettings()
                } label: {
                    LabeledContent {
                        Text(session.agent.isOn && session.agent.status == .ready ? session.agent.providerName : "Off")
                    } label: {
                        Label("Agents", image: "OtterAgent")
                    }
                }
                NavigationLink {
                    GrokSettings()
                } label: {
                    LabeledContent {
                        Text(session.grok.isConfigured ? "On" : "Off")
                    } label: {
                        Label("Grok bot", systemImage: "paperplane")
                    }
                }
            }

            Section {
                Picker(selection: $preferences.scheme) {
                    ForEach(Preferences.Scheme.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Color scheme", systemImage: "circle.lefthalf.filled")
                }
                NavigationLink {
                    ThemeSettings()
                } label: {
                    LabeledContent {
                        Text(themeSummary)
                    } label: {
                        Label("Theme", systemImage: "paintpalette")
                    }
                }
                Toggle(isOn: $preferences.fullWidthMessages) {
                    Label("Full-width messages", systemImage: "arrow.left.and.right")
                }
            } header: {
                Text("Appearance").sectionHeader()
            }

            Section {
                Toggle(isOn: $preferences.groupMessagesByDay) {
                    Text("Group messages by day")
                    Text("Separate messages by day. Tap a day's heading to collapse or expand it.")
                        .font(.inter(.footnote)).foregroundStyle(palette.muted)
                }
                Toggle(isOn: $preferences.fullWidthRows) {
                    Text("Full-width rows")
                    Text("Run each message edge to edge with a line between them, instead of cards.")
                        .font(.inter(.footnote)).foregroundStyle(palette.muted)
                }
            } header: {
                Text("Message list").sectionHeader()
            }

            if ErrorReports.isRunning {
                Section {
                    Toggle(isOn: $errorReports) {
                        Label("Send error reports", systemImage: "ant")
                    }
                } header: {
                    Text("Support").sectionHeader()
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When something fails, tell Otterware what broke and where. Never your mail, addresses or passwords.")
                        Text("Report ID \(ErrorReports.reportID)").textSelection(.enabled)
                    }
                    .sectionFooter()
                }
            }

            Section {
                if session.user != nil {
                    NavigationLink {
                        AccountSettings()
                    } label: {
                        Label("Otter account", systemImage: "person.crop.circle")
                    }
                } else {
                    Button {
                        dismiss()
                        session.leaveDemo()
                    } label: {
                        Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                LabeledContent {
                    Text(Bundle.main.version)
                } label: {
                    Label("Version", systemImage: "info.circle")
                }
            } header: {
                Text("Account").sectionHeader()
            }
        }
        .foregroundStyle(palette.text)
        .navigationTitle("Settings")
        .onChange(of: preferences.notifications) { _, mode in
            if mode != .off { Task { await session.requestNotifications() } }
        }
        .toolbarTitleDisplayMode(.inline)
    }

    private var languageSummary: String {
        let names = preferences.effectiveReadLanguages.compactMap { Locale.current.localizedString(forLanguageCode: $0) }
        return names.count > 2 ? "\(names[0]) +\(names.count - 1)" : names.joined(separator: ", ")
    }

    private var themeSummary: String {
        // A theme this app doesn't have (made elsewhere, not synced yet) is worn as the initial one.
        let label = { (id: String) in (preferences.theme(id) ?? Theme.named(Preferences.initialTheme))?.label ?? "" }
        let light = label(preferences.lightTheme)
        let dark = label(preferences.darkTheme)
        return light == dark ? light : "\(light), \(dark)"
    }
}

/** The calendar's route to Settings in its own navigation path. */
struct SettingsPage: Hashable {}

struct SettingsForm<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content.listRowBackground(palette.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
    }
}
