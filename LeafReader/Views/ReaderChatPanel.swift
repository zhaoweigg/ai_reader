import SwiftUI

enum ReaderChatPlacement {
    static let diameter: CGFloat = 52
    static let trailing: CGFloat = 18
    static let bottom: CGFloat = 112
    static func exclusion(in size: CGSize) -> CGRect {
        CGRect(x: size.width - trailing - diameter, y: size.height - bottom - diameter, width: diameter, height: diameter)
    }
}

struct ReaderChatLauncher: View {
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(colorScheme == .dark ? Color(hex: "#243F44") : Color(hex: "#E7EFEB"))
                Image(systemName: "leaf.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(colorScheme == .dark ? Color(hex: "#9ACFC0") : LeafStyle.accent)
            }
            .frame(width: ReaderChatPlacement.diameter, height: ReaderChatPlacement.diameter)
            .overlay(Circle().stroke(LeafStyle.accent.opacity(contrast == .increased ? 1 : 0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Leaf")
        .accessibilityHint("Opens your reading companion")
        .accessibilityIdentifier("openReaderChat")
    }
}

struct ReaderChatPanel: View {
    @ObservedObject var session: ReaderChatSession
    @EnvironmentObject private var settings: AISettingsStore
    let bookTitle: String
    let isComposing: Bool
    let onClose: () -> Void
    let onSettings: () -> Void
    let onSend: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var confirmsClear = false

    private var accent: Color { colorScheme == .dark ? Color(hex: "#93CABB") : LeafStyle.accent }
    @Environment(\.colorScheme) private var colorScheme
    private var question: String { session.draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        GeometryReader { geometry in
            content(compact: geometry.size.height < 200)
        }
    }
    private func content(compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 8) {
            if !compact {
                Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity).accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(accent)
                if compact, let selection = session.selectedContext {
                    Text(selection.text).font(.caption).lineLimit(1).accessibilityIdentifier("chatSelectedPassage")
                    Button { session.removeSelection() } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("Remove selected text").accessibilityIdentifier("removeChatSelection")
                } else { Text("Ask Leaf").font(.headline).foregroundStyle(accent) }
                Spacer(minLength: 4)
                if !isComposing && !compact {
                    Text(settings.configuration.profile.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if !isComposing && !compact {
                    Menu {
                        Button("AI settings", systemImage: "gearshape", action: onSettings)
                        Button("Clear conversation", systemImage: "trash", role: .destructive) { confirmsClear = true }
                            .accessibilityIdentifier("requestClearConversation")
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }.accessibilityLabel("Chat options").accessibilityIdentifier("chatOptions")
                }
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

            if isComposing || compact { Spacer(minLength: 0) }
            if !isComposing && !compact {
                if session.hasEarlierMessages || session.hasNewerMessages {
                    HStack {
                        Button("Earlier") { session.loadEarlier() }
                            .disabled(!session.hasEarlierMessages || session.isSending)
                            .accessibilityLabel("Earlier messages").accessibilityIdentifier("earlierChatMessages")
                        Spacer()
                        if session.hasNewerMessages {
                            Button("Latest") { session.loadLatest() }.disabled(session.isSending)
                                .accessibilityLabel("Latest messages").accessibilityIdentifier("latestChatMessages")
                            Spacer()
                        }
                        Button("Newer") { session.loadNewer() }
                            .disabled(!session.hasNewerMessages || session.isSending)
                            .accessibilityLabel("Newer messages").accessibilityIdentifier("newerChatMessages")
                    }.font(.caption)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.messages) { message in
                                HStack {
                                    if message.isUser { Spacer(minLength: 32) }
                                    Text(message.text.isEmpty ? (message.state == .streaming ? "Thinking…" : "No response text") : message.text)
                                        .font(.subheadline).lineSpacing(3)
                                        .textSelection(.enabled)
                                        .padding(message.isUser ? 10 : 0)
                                        .background(message.isUser ? accent.opacity(0.1) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 16))
                                        .accessibilityIdentifier(message.isUser ? "chatQuestion" : "chatReply")
                                    if !message.isUser { Spacer(minLength: 0) }
                                }.id(message.id)
                            }
                            if session.messages.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(session.selectedContext != nil
                                         ? (ReaderChatMessage.usesChinese(bookTitle) ? "针对选中的文字提问。" : "Ask a question about the selected text.")
                                         : (ReaderChatMessage.usesChinese(bookTitle) ? "问我解释这段文字、梳理线索，或总结当前页面。" : "Ask about a passage, explore a character’s motives, or recap this page."))
                                        .font(.subheadline)
                                    if session.selectedContext == nil {
                                        Text(settings.configuration.sharePage ? "Sends the current passage with your question." : "Passage sharing is off.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Button("AI settings", action: onSettings).font(.subheadline)
                                }
                            }
                        }.padding(.vertical, 2)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: session.messages.last?.text) { _, _ in
                        if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }.frame(maxHeight: .infinity)
                if let historyError = session.historyError {
                    HStack {
                        Text(historyError).font(.caption).foregroundStyle(.red).lineLimit(3)
                            .accessibilityIdentifier("chatHistoryError")
                        if session.canSaveHistory {
                            Button("Try saving again") { session.flush() }.font(.caption.bold())
                        }
                    }
                }
                if let error = session.error {
                    HStack(spacing: 8) {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).accessibilityIdentifier("readerChatError")
                        if session.canRetry { Button("Retry") { session.retry(settings: settings) }.font(.caption.bold()) }
                    }
                } else if let notice = session.notice {
                    HStack(spacing: 8) {
                        Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if session.canRetry { Button("Retry") { session.retry(settings: settings) }.font(.caption.bold()) }
                    }
                }
            }

            if !compact, let selection = session.selectedContext {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.quote").foregroundStyle(accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.configuration.sharePage ? "Selected text" : "Selected text · passage sharing is off")
                            .font(.caption.weight(.medium))
                        Text(selection.text).font(.caption).foregroundStyle(.secondary).lineLimit(isComposing ? 1 : 2)
                            .accessibilityIdentifier("chatSelectedPassage")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.removeSelection() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Remove selected text").accessibilityIdentifier("removeChatSelection")
                }.padding(.leading, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this page…", text: $session.draft, axis: .vertical)
                    .font(.subheadline).lineLimit(1...(compact ? 1 : 3))
                    .focused($inputFocused).submitLabel(.send)
                    .onSubmit(send)
                    .padding(.leading, 14).padding(.vertical, 12)
                    .accessibilityIdentifier("readerChatInput")
                Button(action: session.isSending ? session.stop : send) {
                    Image(systemName: session.isSending ? "stop.fill" : "arrow.up").font(.system(size: 19, weight: .medium))
                        .foregroundStyle(question.isEmpty && !session.isSending ? Color.secondary : Color.white)
                        .frame(width: 44, height: 44)
                        .background(question.isEmpty && !session.isSending ? accent.opacity(0.1) : accent, in: Circle())
                }
                .buttonStyle(.plain).disabled(question.isEmpty && !session.isSending)
                .accessibilityLabel(session.isSending ? "Stop response" : "Send message").accessibilityIdentifier("sendReaderChat")
            }
            .padding(4)
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(.secondary.opacity(0.3), lineWidth: 0.75))
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .foregroundStyle(.primary).tint(accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerChatPanel")
        .accessibilityAction(.escape, close)
        .confirmationDialog("Clear this book’s conversation?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { session.clear() }
                .accessibilityIdentifier("confirmClearConversation")
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes this book’s saved messages and draft from this device.") }
    }

    private func close() {
        inputFocused = false
        onClose()
    }

    private func send() {
        guard !question.isEmpty, !session.isSending else { return }
        inputFocused = false
        onSend()
    }
}
