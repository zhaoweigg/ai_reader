import SwiftUI

struct ReaderChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String

    static func usesChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    static func introduction(chinese: Bool) -> ReaderChatMessage {
        ReaderChatMessage(isUser: false, text: chinese
            ? "示例回答：先看这一页明确写出的条件，再区分人物的猜测。你可以继续问我解释文字或梳理人物关系。"
            : "A useful clue can be what a rule leaves unsaid. Ask me to explain a passage or untangle a character’s motives.")
    }

    static func reply(to question: String, chinese: Bool) -> ReaderChatMessage {
        let recap = question.localizedCaseInsensitiveContains("summar") || question.contains("总结")
        let text: String
        if chinese {
            text = recap
                ? "示例总结：这一页提出问题、梳理已知线索，再把明确的条件与人物的假设分开。可以接着关注哪些问题仍未得到解答。"
                : "示例回答：可以先找出这段文字明确说了什么，再想一想人物为什么这样判断。留意他们掌握的信息，以及尚未证实的假设。"
        } else {
            text = recap
                ? "Sample recap: the passage raises a question, weighs the available clues, and separates stated conditions from assumptions. Notice which questions remain open."
                : "Sample reply: start with what the passage explicitly says, then consider why the character reaches that conclusion. Separate what they know from what they assume."
        }
        return ReaderChatMessage(isUser: false, text: text)
    }
}

struct ReaderChatLauncher: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(LeafStyle.accent.opacity(reduceTransparency || contrast == .increased ? 1 : 0.42))
                Image(systemName: "bubble.left")
                    .font(.system(size: 24, weight: .medium))
                    .overlay {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 10, weight: .medium)).offset(y: -2)
                    }
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: 48, height: 48)
            .overlay(Circle().stroke(LeafStyle.accent.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Leaf")
        .accessibilityHint("Opens a sample reading chat")
        .accessibilityIdentifier("openReaderChat")
    }
}

struct ReaderChatPanel: View {
    @Binding var messages: [ReaderChatMessage]
    @Binding var draft: String
    let bookTitle: String
    let isComposing: Bool
    let onClose: () -> Void
    @FocusState private var inputFocused: Bool

    private var accent: Color { colorScheme == .dark ? Color(hex: "#93CABB") : LeafStyle.accent }
    @Environment(\.colorScheme) private var colorScheme
    private var question: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 8) {
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity).accessibilityHidden(true)
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(accent)
                Text("Ask Leaf").font(.headline).foregroundStyle(accent)
                Spacer(minLength: 4)
                if !isComposing { Text("Sample chat").font(.caption).foregroundStyle(.secondary) }
                if isComposing {
                    Button { inputFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .frame(width: 44, height: 44).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Hide keyboard")
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(.primary.opacity(0.04), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close chat").accessibilityIdentifier("closeReaderChat")
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 15).onEnded { gesture in
                if gesture.translation.height > 40, abs(gesture.translation.width) < gesture.translation.height { close() }
            })

            if !isComposing {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                HStack {
                                    if message.isUser { Spacer(minLength: 32) }
                                    Text(message.text)
                                        .font(.subheadline).lineSpacing(3)
                                        .textSelection(.enabled)
                                        .padding(message.isUser ? 10 : 0)
                                        .background(message.isUser ? accent.opacity(0.1) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 16))
                                        .accessibilityIdentifier(message.isUser ? "chatQuestion" : "chatReply")
                                    if !message.isUser { Spacer(minLength: 0) }
                                }.id(message.id)
                            }
                        }.padding(.vertical, 2)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }.frame(maxHeight: .infinity)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this page…", text: $draft, axis: .vertical)
                    .font(.subheadline).lineLimit(1...3)
                    .focused($inputFocused).submitLabel(.send)
                    .onSubmit(send)
                    .padding(.leading, 14).padding(.vertical, 12)
                    .accessibilityIdentifier("readerChatInput")
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 19, weight: .medium))
                        .foregroundStyle(question.isEmpty ? Color.secondary : Color.white)
                        .frame(width: 44, height: 44)
                        .background(question.isEmpty ? accent.opacity(0.1) : accent, in: Circle())
                }
                .buttonStyle(.plain).disabled(question.isEmpty)
                .accessibilityLabel("Send message").accessibilityIdentifier("sendReaderChat")
            }
            .padding(4)
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(.secondary.opacity(0.3), lineWidth: 0.75))
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .foregroundStyle(.primary).tint(accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerChatPanel")
        .accessibilityAction(.escape, close)
    }

    private func close() {
        inputFocused = false
        onClose()
    }

    private func send() {
        guard !question.isEmpty else { return }
        let text = question
        messages.append(ReaderChatMessage(isUser: true, text: text))
        messages.append(.reply(to: text, chinese: ReaderChatMessage.usesChinese(text + bookTitle)))
        draft = ""
        inputFocused = false
    }
}
