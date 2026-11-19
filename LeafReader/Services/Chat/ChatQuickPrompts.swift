import Foundation

/// A one-tap request about the selected text, shown as a button in Ask Leaf.
struct ChatQuickPrompt: Codable, Identifiable, Equatable {
    static let limit = 12, titleLimit = 24, promptLimit = 500
    static let defaults = [
        ChatQuickPrompt(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, title: "Explain", builtIn: ReaderSelectionIntent.explain.rawValue),
        ChatQuickPrompt(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, title: "Summarize", builtIn: ReaderSelectionIntent.summarize.rawValue),
    ]

    var id = UUID()
    var title = ""
    /// What is sent. A built-in prompt left empty asks in the language of the passage.
    var prompt = ""
    /// The built-in request this prompt started as.
    var builtIn: String?

    private var intent: ReaderSelectionIntent? { builtIn.flatMap(ReaderSelectionIntent.init(rawValue:)) }
    var label: String { String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.titleLimit)) }
    private var ownPrompt: String { String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.promptLimit)) }
    /// The built-in wording, shown where the reader has not written their own.
    var builtInPrompt: String? { intent?.prompt(for: "") }
    var isUsable: Bool { !label.isEmpty && (!ownPrompt.isEmpty || intent != nil) }
    /// The request sent about `passage`.
    func text(for passage: String) -> String { ownPrompt.isEmpty ? intent?.prompt(for: passage) ?? "" : ownPrompt }
    /// Trimmed and within the limits, as it is saved.
    var normalized: ChatQuickPrompt { ChatQuickPrompt(id: id, title: label, prompt: ownPrompt, builtIn: builtIn) }
    /// Built-in prompts keep the identifiers they had before prompts were editable.
    func chipIdentifier(at index: Int) -> String { builtIn.map { $0 + "ChatSelection" } ?? "customChatSelection-\(index)" }
}
