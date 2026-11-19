import SwiftUI

/// Lists the reader's quick prompts: rename, rewrite, add, delete and reorder.
/// Every change is saved at once; a prompt without a name or a request is not shown in chat.
struct QuickPromptsEditor: View {
    @Environment(\.leafTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AISettingsStore
    /// True in the sheet opened from chat, which needs its own way out.
    let closes: Bool
    @State private var prompts: [ChatQuickPrompt] = []
    @State private var added = ChatQuickPrompt()
    @State private var adds = false

    var body: some View {
        List {
            Group {
            Section {
                ForEach(prompts) { prompt in
                    NavigationLink { QuickPromptForm(prompt: prompt, onChange: update) } label: { row(prompt) }
                        .accessibilityIdentifier("quickPrompt-" + prompt.label)
                }
                .onMove { prompts.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { prompts.remove(atOffsets: $0) }
                if prompts.count < ChatQuickPrompt.limit {
                    Button { added = ChatQuickPrompt(); adds = true } label: { Label("Add prompt", systemImage: "plus") }
                        .accessibilityIdentifier("addQuickPrompt")
                }
            } footer: {
                Text("Ask Leaf shows these when text is selected. Tapping one sends it with the passage. Swipe a prompt to delete it, or tap Edit to reorder.")
            }
            Section {
                Button("Reset to defaults") { prompts = ChatQuickPrompt.defaults }
                    .disabled(prompts == ChatQuickPrompt.defaults).accessibilityIdentifier("resetQuickPrompts")
            }
            }.listRowBackground(theme.surface)
        }
        .leafFormStyle()
        .toolbarBackground(theme.canvas, for: .navigationBar)
        .navigationTitle("Quick prompts").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: closes ? .topBarLeading : .topBarTrailing) { EditButton() }
            if closes {
                ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closeQuickPrompts") }
            }
        }
        .navigationDestination(isPresented: $adds) { QuickPromptForm(prompt: added, onChange: update).id(added.id) }
        .onAppear { if prompts.isEmpty { prompts = settings.quickPrompts } }
        .onChange(of: prompts) { _, prompts in settings.saveQuickPrompts(prompts) }
    }

    private func row(_ prompt: ChatQuickPrompt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(prompt.label.isEmpty ? "Unnamed" : prompt.label)
            Text(prompt.isUsable ? prompt.text(for: "") : "Needs a name and a request to appear in chat")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    /// A new prompt joins the list once it can be shown.
    private func update(_ prompt: ChatQuickPrompt) {
        if let index = prompts.firstIndex(where: { $0.id == prompt.id }) { prompts[index] = prompt.normalized }
        else if prompt.isUsable { prompts.append(prompt.normalized) }
    }
}

/// One quick prompt's name and request. Works on its own copy, so saving while
/// the reader types never disturbs the field.
private struct QuickPromptForm: View {
    @Environment(\.leafTheme) private var theme
    @State private var draft: ChatQuickPrompt
    let onChange: (ChatQuickPrompt) -> Void
    init(prompt: ChatQuickPrompt, onChange: @escaping (ChatQuickPrompt) -> Void) {
        _draft = State(initialValue: prompt); self.onChange = onChange
    }

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("Name on the button", text: $draft.title).accessibilityIdentifier("quickPromptName")
                } header: { Text("Name") } footer: { Text("Up to \(ChatQuickPrompt.titleLimit) characters.") }
                Section {
                    TextField(draft.builtInPrompt ?? "What Leaf should do with the selected text", text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...8).accessibilityIdentifier("quickPromptRequest")
                } header: { Text("Request") } footer: {
                    if let builtIn = draft.builtInPrompt {
                        Text("Left empty, Leaf asks “\(builtIn)” in the language of the selected text. Write your own to always send those exact words.")
                    } else {
                        Text("Sent with the selected text as soon as you tap the button.")
                    }
                }
            }.listRowBackground(theme.surface)
        }.leafFormStyle()
        .toolbarBackground(theme.canvas, for: .navigationBar)
        .navigationTitle(draft.label.isEmpty ? "New prompt" : draft.label).navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft) { _, draft in onChange(draft) }
    }
}
