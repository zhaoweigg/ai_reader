import SwiftUI

enum ReaderChatPlacement {
    static let diameter: CGFloat = 52
    static let trailing: CGFloat = 18
    static let bottom: CGFloat = 112
    static func bounds(in size: CGSize) -> CGRect {
        let inset = diameter / 2 + 8
        return CGRect(x: min(inset, size.width / 2), y: min(inset, size.height / 2),
                      width: max(0, size.width - inset * 2), height: max(0, size.height - inset * 2))
    }
    static func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let bounds = bounds(in: size)
        return CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
                       y: min(bounds.maxY, max(bounds.minY, point.y)))
    }
    static func center(x: Double, y: Double, in size: CGSize) -> CGPoint {
        let bounds = bounds(in: size)
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            return clamp(CGPoint(x: size.width - trailing - diameter / 2,
                                 y: size.height - bottom - diameter / 2), in: size)
        }
        return CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
    }
    static func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let bounds = bounds(in: size), point = clamp(point, in: size)
        return CGPoint(x: bounds.width > 0 ? (point.x - bounds.minX) / bounds.width : 0.5,
                       y: bounds.height > 0 ? (point.y - bounds.minY) / bounds.height : 0.5)
    }
}

struct ReaderChatLauncher: View {
    @Environment(\.leafTheme) private var theme
    @Binding var isMoving: Bool
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("reader.chatButtonX") private var savedX = -1.0
    @AppStorage("reader.chatButtonY") private var savedY = -1.0
    @State private var dragOrigin: CGPoint?
    @State private var draggedCenter: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let center = draggedCenter ?? ReaderChatPlacement.center(x: savedX, y: savedY, in: geometry.size)
            Button { if !isMoving { action() } } label: { icon }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in isMoving = true })
            .simultaneousGesture(dragGesture(from: center, in: geometry.size))
            .position(center)
            .accessibilityLabel("Ask Leaf")
            .accessibilityValue(isMoving ? "Move mode" : "Stationary")
            .accessibilityHint(isMoving ? "Drag to move. Tap elsewhere to finish." : "Opens your reading companion. Long press to move.")
            .accessibilityIdentifier("openReaderChat")
            .accessibilityAction(named: "Move button") { isMoving = true }
            .accessibilityAction(named: "Move left") { move(center, dx: -24, dy: 0, in: geometry.size) }
            .accessibilityAction(named: "Move right") { move(center, dx: 24, dy: 0, in: geometry.size) }
            .accessibilityAction(named: "Move up") { move(center, dx: 0, dy: -24, in: geometry.size) }
            .accessibilityAction(named: "Move down") { move(center, dx: 0, dy: 24, in: geometry.size) }
            .accessibilityAction(named: "Finish moving") { isMoving = false }
            .onChange(of: geometry.size) { _, _ in dragOrigin = nil; draggedCenter = nil }
            .onChange(of: isMoving) { _, moving in
                if !moving {
                    if let draggedCenter { save(draggedCenter, in: geometry.size) }
                    dragOrigin = nil; draggedCenter = nil
                }
            }
        }
        .coordinateSpace(name: "chatButtonViewport")
        .sensoryFeedback(.selection, trigger: isMoving)
    }
    private var icon: some View {
        ZStack {
            // No material blur: book glyphs remain visible through the tint.
            Circle().fill(theme.accent.opacity(reduceTransparency ? 1 : 0.12))
            Image(systemName: isMoving ? "arrow.up.and.down.and.arrow.left.and.right" : "leaf.fill")
                .font(.system(size: isMoving ? 21 : 25, weight: .medium))
                .foregroundStyle((reduceTransparency ? theme.onAccent : theme.accent)
                    .opacity(reduceTransparency || contrast == .increased ? 1 : 0.55))
        }
        .frame(width: ReaderChatPlacement.diameter, height: ReaderChatPlacement.diameter)
        .overlay(Circle().stroke(theme.accent.opacity(isMoving || contrast == .increased ? 0.85 : 0.25),
                                 style: StrokeStyle(lineWidth: isMoving ? 1.5 : 0.5, dash: isMoving ? [4, 3] : [])))
        .contentShape(Circle())
    }
    private func dragGesture(from center: CGPoint, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("chatButtonViewport"))
            .onChanged { value in
                guard isMoving else { return }
                if dragOrigin == nil { dragOrigin = center }
                guard let origin = dragOrigin else { return }
                draggedCenter = ReaderChatPlacement.clamp(CGPoint(x: origin.x + value.translation.width,
                                                                  y: origin.y + value.translation.height), in: size)
            }
            .onEnded { _ in
                if let draggedCenter { save(draggedCenter, in: size) }
                dragOrigin = nil; draggedCenter = nil
            }
    }
    private func save(_ point: CGPoint, in size: CGSize) {
        let normalized = ReaderChatPlacement.normalized(point, in: size)
        savedX = normalized.x; savedY = normalized.y
    }
    private func move(_ center: CGPoint, dx: CGFloat, dy: CGFloat, in size: CGSize) {
        isMoving = true
        save(CGPoint(x: center.x + dx, y: center.y + dy), in: size)
    }
}

struct ReaderChatPanel: View {
    @Environment(\.leafTheme) private var theme
    @ObservedObject var session: ReaderChatSession
    @EnvironmentObject private var settings: AISettingsStore
    let bookTitle: String
    let isComposing: Bool
    let onClose: () -> Void
    let onSettings: () -> Void
    let onSend: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var confirmsClear = false

    private var accent: Color { theme.accent }
    private var question: String { session.draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        GeometryReader { geometry in
            content(compact: geometry.size.height < 200)
        }
    }
    private func content(compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 8) {
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity).frame(height: compact ? 6 : 16)
                .contentShape(Rectangle()).gesture(dismissDrag)
                .accessibilityElement().accessibilityLabel("Chat drag handle")
                .accessibilityIdentifier("readerChatDragHandle")
                .accessibilityAction(named: "Close chat", close)
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(accent)
                if compact, let selection = session.selectedContext {
                    Text(selection.text).font(.caption).lineLimit(1).layoutPriority(-1).accessibilityIdentifier("chatSelectedPassage")
                    Button { session.removeSelection() } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("Remove selected text").accessibilityIdentifier("removeChatSelection")
                    if !isComposing { selectionActions(compact: true) }
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
            .simultaneousGesture(dismissDrag)

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
                                    ReaderChatMessageBubble(message: message, accent: accent)
                                    if !message.isUser { Spacer(minLength: 0) }
                                }.id(message.id)
                            }
                            if session.messages.isEmpty && session.selectedContext == nil {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(ReaderChatMessage.usesChinese(bookTitle) ? "问我解释这段文字、梳理线索，或总结当前页面。" : "Ask about a passage, explore a character’s motives, or recap this page.")
                                        .font(.subheadline)
                                    Text(settings.configuration.sharePage ? "Sends the current passage with your question." : "Passage sharing is off.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("AI settings", action: onSettings).font(.subheadline)
                                }
                            }
                        }.padding(.vertical, 2)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("chatMessageHistory")
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
                if !isComposing {
                    selectionActions(compact: false)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(session.selectedContext == nil ? "Ask about this page…" : "Ask about the selected text…", text: $session.draft, axis: .vertical)
                    .font(.subheadline).lineLimit(1...(compact ? 1 : 3))
                    .focused($inputFocused).submitLabel(.send)
                    .onSubmit(send)
                    .padding(.leading, 14).padding(.vertical, 12)
                    .accessibilityIdentifier("readerChatInput")
                Button(action: session.isSending ? session.stop : send) {
                    Image(systemName: session.isSending ? "stop.fill" : "arrow.up").font(.system(size: 19, weight: .medium))
                        .foregroundStyle(question.isEmpty && !session.isSending ? Color.secondary : theme.onAccent)
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
        .padding(.horizontal, 16).padding(.vertical, compact ? 4 : 8)
        .foregroundStyle(.primary).tint(accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerChatPanel")
        .accessibilityAction(.escape, close)
        .confirmationDialog("Clear this book’s conversation?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { session.clear() }
                .accessibilityIdentifier("confirmClearConversation")
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes this book’s saved messages and draft from this device.") }
    }

    private func selectionActions(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 8) {
            ForEach([ReaderSelectionIntent.explain, .summarize], id: \.rawValue) { intent in
                Button { session.prepareSelectionPrompt(intent) } label: {
                    Text(intent == .explain ? "Explain" : "Summarize")
                        .font(.caption.weight(.medium)).lineLimit(1).fixedSize()
                        .foregroundStyle(accent).padding(.horizontal, compact ? 10 : 14).frame(height: 44)
                        .background(accent.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.2), lineWidth: 0.75))
                }
                .buttonStyle(.plain).accessibilityLabel(intent.title)
                .accessibilityIdentifier(intent == .explain ? "explainChatSelection" : "summarizeChatSelection")
            }
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 15).onEnded { gesture in
            if gesture.translation.height > 40, abs(gesture.translation.width) < gesture.translation.height { close() }
        }
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

private struct ReaderChatMessageBubble: View {
    let message: ReaderChatMessage
    let accent: Color
    @State private var quoteExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.isUser, let context = message.context, context.source == "selection", !context.isEmpty {
                Button { quoteExpanded.toggle() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Quoted text", systemImage: "text.quote").font(.caption2.weight(.medium))
                            Spacer(minLength: 8)
                            Image(systemName: quoteExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                        }.foregroundStyle(accent)
                        Text(context.text).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(quoteExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chatQuotedPassage")
                    }
                    .padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(quoteExpanded ? "Collapse quoted text" : "Expand quoted text")
                .accessibilityValue(context.text)
                .accessibilityIdentifier("toggleChatQuote")
            }
            Text(message.text.isEmpty ? (message.state == .streaming ? "Thinking…" : "No response text") : message.text)
                .font(.subheadline).lineSpacing(3).textSelection(.enabled)
                .accessibilityIdentifier(message.isUser ? "chatQuestion" : "chatReply")
        }
        .padding(message.isUser ? 10 : 0)
        .background(message.isUser ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 16))
    }
}
