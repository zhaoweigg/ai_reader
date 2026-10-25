import SwiftUI

struct AISettingsView: View {
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var settings: AISettingsStore
    @State private var configuration = ChatConfiguration()
    @State private var replacementKey = ""
    @State private var hasKey = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            Group {
                Section {
                    Picker("Provider", selection: $configuration.provider) {
                        ForEach(ChatProviderKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }.accessibilityIdentifier("aiProvider")
                    if configuration.provider != .chatGPT {
                        TextField("Model ID", text: $configuration.profile.model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("aiModel")
                        if configuration.provider == .anthropic {
                            Menu("Choose a Haiku model") {
                                Button("Haiku 5.5") { configuration.profile.model = "claude-haiku-5-5" }
                                Button("Haiku 4.5") { configuration.profile.model = "claude-haiku-4-5" }
                            }
                        }
                        TextField("Full HTTPS endpoint", text: $configuration.profile.endpoint, axis: .vertical)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("aiEndpoint")
                    }
                } header: { Text("Model connection") } footer: {
                    if configuration.provider == .chatGPT {
                        Text("Connect your ChatGPT account and choose a model available to your plan. No API key is needed.")
                    } else {
                        Text("Change the model ID without changing the reader. For another service, choose its API format and full endpoint. Each destination has its own saved key.")
                    }
                }
                if configuration.provider == .chatGPT {
                    ChatGPTConnectionView(accounts: settings.chatGPT, model: $configuration.profile.model)
                } else {
                    Section {
                        SecureField(hasKey ? "Replace saved key (optional)" : "Enter API key", text: $replacementKey)
                            .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("aiAPIKey")
                        if hasKey {
                            Label("Key saved in Keychain", systemImage: "lock.fill").font(.footnote)
                            Button("Remove saved key", role: .destructive) {
                                do { try settings.removeKey(for: configuration); refreshKey() }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    } header: { Text("API key") } footer: { Text("Your own provider key is stored on this device. API usage is billed by your provider. No key is bundled with Leaf.") }
                }
                Section("Reading context") {
                    Toggle("Include current passage", isOn: $configuration.sharePage).accessibilityIdentifier("aiSharePage")
                    Text("Sending shares your question, up to 12,000 characters of selected or visible text, nearby text and relevant earlier book passages, plus book details, approximate reading progress and recent or relevant earlier discussion. Character reminders look up earlier mentions locally. Images and entire books are not uploaded. Disable this to send questions and chat text only.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Conversations and drafts are saved on this device for each book until you clear them. Provider retention follows that provider’s policy.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if configuration.provider != .chatGPT {
                    Section("Response length") {
                        Stepper("Maximum output: \(configuration.profile.maxOutputTokens) tokens", value: $configuration.profile.maxOutputTokens, in: 256...8192, step: 256)
                        if configuration.provider == .chatCompletions {
                            Toggle("Use legacy max_tokens field", isOn: $configuration.profile.legacyTokenLimit)
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("aiSettingsError") } }
                if saved { Section { Label("AI settings saved", systemImage: "checkmark.circle").foregroundStyle(theme.accent) } }
                Section {
                    Button("Save AI settings", action: save).accessibilityIdentifier("saveAISettings")
                }
            }.listRowBackground(theme.surface)
        }.leafFormStyle()
        .toolbarBackground(theme.canvas, for: .navigationBar)
        .navigationTitle("AI settings").navigationBarTitleDisplayMode(.inline)
        .onAppear { configuration = settings.configuration; refreshKey() }
        .onChange(of: configuration.provider) { _, _ in replacementKey = ""; saved = false; refreshKey() }
        .onChange(of: configuration.profile.endpoint) { _, _ in saved = false; refreshKey() }
    }
    private func refreshKey() {
        guard configuration.provider != .chatGPT else { hasKey = false; return }
        do { hasKey = try settings.key(for: configuration) != nil }
        catch { hasKey = false; self.error = error.localizedDescription }
    }
    private func save() {
        do {
            try settings.save(configuration, replacementKey: replacementKey.isEmpty ? nil : replacementKey)
            replacementKey = ""; error = nil; saved = true; refreshKey()
        } catch { self.error = error.localizedDescription; saved = false }
    }
}
