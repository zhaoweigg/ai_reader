import SwiftUI
import AVFoundation

/// Native text views clip their accessibility bounds to the screen. UI tests
/// measure the independently laid-out history instead of those clipped bounds.
private struct ChatHistoryTestMeasurement: ViewModifier {
    let following: Bool
    let selected: Bool
    var streamingText = false
    #if DEBUG
    @State private var metrics = ChatHistoryTestMetrics()
    @State private var follow = ChatFollowTrace()
    private var probe: some View {
        ChatHistoryOffsetProbe(value: "{\"offset\":\(metrics.offset),\"contentHeight\":\(metrics.contentHeight),\"viewportHeight\":\(metrics.viewportHeight),\"following\":\(following),\"selected\":\(selected)}")
            .frame(width: 1, height: 1).allowsHitTesting(false)
    }
    #endif
    func body(content: Content) -> some View {
        #if DEBUG
        if UITesting.flag(.chatFollow), #available(iOS 18, *) {
            // Every geometry change is recorded; the probe reads it lazily.
            content.onScrollGeometryChange(for: ChatHistoryTestMetrics.self) { geometry in
                ChatHistoryTestMetrics(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                       viewportHeight: geometry.containerSize.height)
            } action: { [follow, following, streamingText] _, value in follow.record(value, following: following, streamingText: streamingText) }
                .overlay(alignment: .topLeading) {
                    ChatFollowProbe(trace: follow).frame(width: 1, height: 1).allowsHitTesting(false)
                }
        } else if UITesting.flag(.chatScrollStream) {
            if #available(iOS 18, *) {
                content.onScrollGeometryChange(for: ChatHistoryTestMetrics.self) { geometry in
                    ChatHistoryTestMetrics(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                           viewportHeight: geometry.containerSize.height)
                } action: { _, value in metrics = value }
                    .overlay(alignment: .topLeading) { probe }
            } else {
                content.onPreferenceChange(ChatHistoryMeasuredOffset.self) { if let value = $0 { metrics.offset = value } }
                    .overlay(alignment: .topLeading) { probe }
            }
        } else { content }
        #else
        content
        #endif
    }
}

/// Hosts the chat panel at the bottom of its container at the saved, resizable
/// height of one placement. Reading and keyboard-open heights are stored
/// separately per placement; a drag of the grabber resizes within the bounds
/// `ReaderChatSizing` allows for the current viewport.
struct ResizableChatPanel: View {
    @ObservedObject var session: ReaderChatSession
    let location: ReaderChatLauncher.Location
    /// The full viewport height, measured outside the keyboard safe area.
    let fullHeight: CGFloat
    let bookTitle: String
    let context: ReaderChatPanel.Context
    let onChooseConversation: (() -> Void)?
    let onClose: () -> Void
    let onSettings: () -> Void
    let onButtonSettings: () -> Void
    let onSend: () -> Void
    @Environment(\.leafTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage private var heightFraction: Double
    @AppStorage private var composingHeightFraction: Double
    @State private var resizeOrigin: CGFloat?
    @State private var resizedHeight: CGFloat?

    init(session: ReaderChatSession, location: ReaderChatLauncher.Location, fullHeight: CGFloat, bookTitle: String,
         context: ReaderChatPanel.Context = .reader, onChooseConversation: (() -> Void)? = nil,
         onClose: @escaping () -> Void, onSettings: @escaping () -> Void, onButtonSettings: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.session = session; self.location = location; self.fullHeight = fullHeight; self.bookTitle = bookTitle
        self.context = context; self.onChooseConversation = onChooseConversation
        self.onClose = onClose; self.onSettings = onSettings; self.onButtonSettings = onButtonSettings; self.onSend = onSend
        // Start the new reader dock at its approved size once. Subsequent user
        // resizes persist independently of the existing keyboard preference.
        _heightFraction = AppStorage(wrappedValue: location == .reader ? ReaderChatSizing.dockedReadingFraction : 1.0 / 3,
            location == .reader ? "reader.dockedChatHeightFraction" : "library.chatHeightFraction")
        _composingHeightFraction = AppStorage(wrappedValue: -1, "\(location.storagePrefix).chatComposingHeightFraction")
    }

    var body: some View {
        GeometryReader { geometry in
            let full = max(fullHeight, geometry.size.height)
            let composing = geometry.size.height < full - 80
            let hasSelection = session.selectedContext != nil
            let hasStatus = session.notice != nil || session.error != nil || session.historyError != nil
            let limits = ReaderChatSizing.bounds(fullHeight: full, availableHeight: geometry.size.height, composing: composing, hasSelection: hasSelection, hasStatus: hasStatus)
            let preferred = ReaderChatSizing.height(fraction: composing ? composingHeightFraction : heightFraction,
                fullHeight: full, availableHeight: geometry.size.height, composing: composing, hasSelection: hasSelection, hasStatus: hasStatus)
            let height = min(limits.upperBound, max(limits.lowerBound, resizedHeight ?? preferred))
            ReaderChatPanel(session: session, bookTitle: bookTitle, isComposing: composing, context: context, onChooseConversation: onChooseConversation,
                onClose: onClose, onSettings: onSettings, onButtonSettings: onButtonSettings, onSend: onSend,
                onResize: { translation, ended in
                    if resizeOrigin == nil { resizeOrigin = height }
                    let resized = min(limits.upperBound, max(limits.lowerBound, (resizeOrigin ?? height) - translation))
                    resizedHeight = resized
                    if ended { save(resized, fullHeight: full, composing: composing) }
                }, onResizeStep: { step in
                    save(min(limits.upperBound, max(limits.lowerBound, height + step)), fullHeight: full, composing: composing)
                }, onResetSize: {
                    if composing { composingHeightFraction = -1 }
                    else { heightFraction = location == .reader ? ReaderChatSizing.dockedReadingFraction : 1.0 / 3 }
                    resizeOrigin = nil; resizedHeight = nil
                })
                .frame(height: height)
                .background {
                    GeometryReader { frame in
                        Color.clear.preference(key: ReaderChatFrame.self, value: location == .reader ? frame.frame(in: .global) : nil)
                    }
                }
                .background {
                    if reduceTransparency { location == .reader ? theme.background : theme.canvas }
                    else { Rectangle().fill(.ultraThinMaterial) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .onChange(of: geometry.size) { _, _ in resizeOrigin = nil; resizedHeight = nil }
                .onDisappear { resizeOrigin = nil; resizedHeight = nil }
        }
    }
    private func save(_ height: CGFloat, fullHeight: CGFloat, composing: Bool) {
        guard fullHeight > 0 else { return }
        if composing { composingHeightFraction = Double(height / fullHeight) }
        else { heightFraction = Double(height / fullHeight) }
        resizeOrigin = nil; resizedHeight = nil
    }
}

struct ReaderChatPanel: View {
    enum Context { case reader, libraryBook, general }
    @Environment(\.leafTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var dictation = ChatDictationSession()
    @AppStorage("chat.dictationLanguage") private var dictationLanguage = DictationLanguage.system.rawValue
    @ObservedObject var session: ReaderChatSession
    @EnvironmentObject private var settings: AISettingsStore
    let bookTitle: String
    let isComposing: Bool
    var context: Context = .reader
    var onChooseConversation: (() -> Void)? = nil
    let onClose: () -> Void
    let onSettings: () -> Void
    let onButtonSettings: () -> Void
    let onSend: () -> Void
    let onResize: (CGFloat, Bool) -> Void
    let onResizeStep: (CGFloat) -> Void
    let onResetSize: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var confirmsClear = false
    @State private var scrollFollowing = ChatScrollFollowing()
    @State private var selectedMessage: UUID?
    @State private var editsQuickPrompts = false

    private var accent: Color { theme.accent }
    private var question: String { session.draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var spokenLocale: String {
        if dictation.isActive, let active = dictation.localeIdentifier { return active }
        return (DictationLanguage(rawValue: dictationLanguage) ?? .system).resolvedLocale(bookTitle: bookTitle, selectedText: session.selectedContext?.text)
    }
    private var contextHint: String {
        switch context {
        case .reader: return settings.configuration.sharePage ? "Sends the current passage with your question." : "Passage sharing is off."
        case .libraryBook:
            return settings.configuration.sharePage ? "Continues this book’s saved chat. Library shares only its title and author; open the book to quote a new passage." : "Continues this book’s saved chat. Passage sharing is off."
        case .general: return "Separate from your book chats. Leaf can read this screen’s list when you ask about it."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            content(compact: geometry.size.height < 200)
        }
    }
    private func content(compact: Bool) -> some View {
        VStack(spacing: compact ? 2 : 8) {
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity).frame(height: 12)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { onResize($0.translation.height, false) }
                        .onEnded { onResize($0.translation.height, true) })
                    .accessibilityElement().accessibilityLabel("Resize chat")
                    .accessibilityHint("Drag up to expand or down to shrink. Swipe down on the header to close.")
                    .accessibilityIdentifier("readerChatDragHandle")
                    .accessibilityAdjustableAction { direction in
                        switch direction { case .increment: onResizeStep(56); case .decrement: onResizeStep(-56); @unknown default: break }
                    }
                    .accessibilityAction(named: "Reset chat size", onResetSize)
                    .accessibilityAction(named: "Close chat", close)
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill").font(.system(size: 15, weight: .medium)).foregroundStyle(accent).accessibilityHidden(true)
                    if compact || isComposing, let selection = session.selectedContext {
                        Text(selection.previewText).font(.caption).lineLimit(1).layoutPriority(-1)
                            .accessibilityLabel(selection.text).accessibilityIdentifier("chatSelectedPassage")
                        Button { session.removeSelection() } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                            .accessibilityLabel("Remove selected text").accessibilityIdentifier("removeChatSelection")
                        if !isComposing { selectionActions(compact: true).layoutPriority(1) }
                    } else { Text("Ask Leaf").font(.subheadline.weight(.semibold)).foregroundStyle(accent).lineLimit(1) }
                    Spacer(minLength: 4)
                    Menu { dictationLanguagePicker } label: {
                        HStack(spacing: 3) {
                            Text(DictationLanguage.shortLabel(locale: spokenLocale))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(.caption.weight(.medium)).foregroundStyle(accent).frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(dictation.isActive)
                    .accessibilityLabel("Dictation language")
                    .accessibilityValue(DictationLanguage(rawValue: dictationLanguage)?.title ?? "Automatic")
                    .accessibilityIdentifier("dictationLanguageButton")
                    if let onChooseConversation, !isComposing {
                        Button { dictation.cancel(); onChooseConversation() } label: {
                            HStack(spacing: 4) {
                                Text(context == .general ? "General chat" : bookTitle).lineLimit(1)
                                Image(systemName: "chevron.down")
                            }.font(.caption).frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("Choose conversation").accessibilityValue(context == .general ? "General chat" : bookTitle)
                            .accessibilityIdentifier("chooseLibraryConversation")
                    }
                    if dictation.isActive {
                        Text(dictation.status).font(.caption).foregroundStyle(accent).lineLimit(1)
                            .accessibilityIdentifier("chatDictationStatus")
                    } else if context == .reader && !isComposing && !compact {
                        Text(settings.configuration.profile.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !isComposing && !compact {
                        Menu {
                            dictationLanguagePicker
                            Button("AI settings", systemImage: "gearshape") { dictation.cancel(); onSettings() }
                            Button("Floating button",systemImage:"circle.lefthalf.filled") { dictation.cancel(); onButtonSettings() }
                                .accessibilityIdentifier("configureChatButton")
                            Button("Clear conversation", systemImage: "trash", role: .destructive) { dictation.cancel(); confirmsClear = true }
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
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Close chat").accessibilityIdentifier("closeReaderChat")
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dismissDrag)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("readerChatHeader")
            }

            Group {
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
                    GeometryReader { viewport in
                        ScrollView {
                            // The history is paged (24 messages), so every row is laid out.
                            // A lazy stack estimated the rows it had not laid out yet: when
                            // the panel grew after sending from the keyboard it guessed the
                            // new question and placeholder at the height of the long reply
                            // above them, followed that phantom bottom, and showed a blank
                            // panel until the reply's first token re-laid the rows out.
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(session.messages) { message in
                                    HStack {
                                        if message.isUser { Spacer(minLength: 32) }
                                        ReaderChatMessageBubble(message: message, accent: accent, imageURL: session.imageURL,
                                                                activity: message.id == session.messages.last?.id ? session.activity : nil) { selected in
                                            if selected { selectedMessage = message.id }
                                            else if selectedMessage == message.id { selectedMessage = nil }
                                        }.equatable()
                                        if !message.isUser { Spacer(minLength: 0) }
                                    }.id(message.id)
                                }
                                if session.messages.isEmpty && session.selectedContext == nil {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if context == .reader {
                                            Text(ReaderChatMessage.usesChinese(bookTitle) ? "问我解释这段文字、梳理线索，或总结当前页面。" : "Ask about a passage, explore a character’s motives, or recap this page.")
                                                .font(.subheadline)
                                        }
                                        Text(contextHint)
                                            .font(.caption).foregroundStyle(.secondary)
                                        Button("AI settings", action: onSettings).font(.subheadline)
                                    }
                                }
                            }.padding(.vertical, 2)
                                // A short chat grows inside a viewport-tall, bottom-aligned
                                // frame, so streaming does not move the scroll offset at all.
                                .frame(minHeight: viewport.size.height, alignment: .bottom)
                                .background {
                                    if !ChatHistoryInteraction.usesNativeTracking {
                                        GeometryReader { content in
                                            Color.clear.preference(key: ChatHistoryAtBottom.self,
                                                value: content.frame(in: .named("chatHistoryViewport")).maxY - viewport.size.height <= 4)
                                                .overlay {
                                                    #if DEBUG
                                                    Color.clear.preference(key: ChatHistoryMeasuredOffset.self,
                                                        value: -content.frame(in: .named("chatHistoryViewport")).minY)
                                                    #endif
                                                }
                                        }
                                    }
                                }
                        }
                        .coordinateSpace(name: "chatHistoryViewport")
                        .defaultScrollAnchor(.bottom)
                        .scrollDismissesKeyboard(isComposing ? .never : .interactively)
                        .accessibilityIdentifier("chatMessageHistory")
                        .accessibilityValue(scrollFollowing.followsLatest ? "Following latest" : "Reading earlier")
                        .modifier(ChatHistoryTestMeasurement(following: scrollFollowing.followsLatest, selected: selectedMessage != nil,
                                                             streamingText: session.messages.last.map { $0.state == .streaming && !$0.text.isEmpty } ?? false))
                        #if DEBUG
                        .modifier(ChatSwipeMeasurement())
                        #endif
                        .modifier(ChatHistoryInteraction(following: $scrollFollowing))
                        // Streamed text waits while the history is being scrolled, so the
                        // scroll keeps its frames; releasing shows what arrived meanwhile.
                        .onChange(of: scrollFollowing.isScrolling) { _, scrolling in session.holdsStreamedText = scrolling }
                        .onDisappear { session.holdsStreamedText = false }
                        .modifier(ChatHistoryFollowsLatest(following: scrollFollowing.followsLatest, paused: selectedMessage != nil))
                        .onPreferenceChange(ChatHistoryAtBottom.self) { atBottom in
                            if !ChatHistoryInteraction.usesNativeTracking, let atBottom { scrollFollowing.updateAtBottom(atBottom) }
                        }
                        .onChange(of: session.messages.last?.text) { _, _ in
                            // iOS 18 follows actual content growth (ChatHistoryFollowing).
                            guard #unavailable(iOS 18) else { return }
                            // Let the new text lay out first, then slide to it.
                            DispatchQueue.main.async {
                                if selectedMessage == nil, scrollFollowing.followsLatest, let last = session.messages.last {
                                    withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                        }
                        .onChange(of: session.isSending) { _, sending in
                            if sending {
                                scrollFollowing.resume()
                                if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: ObjectIdentifier(session)) { _, _ in
                            scrollFollowing = ChatScrollFollowing()
                            if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                        .onChange(of: inputFocused) { _, focused in
                            if focused, let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                        .onChange(of: isComposing) { _, composing in
                            if composing, let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
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

            if !compact, !isComposing, let selection = session.selectedContext {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.quote").foregroundStyle(accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.configuration.sharePage ? "Selected text" : "Selected text · passage sharing is off")
                            .font(.caption.weight(.medium))
                        Text(selection.previewText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .accessibilityLabel(selection.text)
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
                TextField(session.selectedContext != nil ? "Ask about the selected text…" : context == .general ? "Ask Leaf…" : context == .libraryBook ? "Ask about this book…" : "Ask about this page…", text: $session.draft, axis: .vertical)
                    .font(.subheadline).lineLimit(1...(compact ? 1 : 3))
                    .focused($inputFocused).submitLabel(.send)
                    .disabled(dictation.isActive)
                    .onSubmit(send)
                    .padding(.leading, 14).padding(.vertical, compact ? 6 : 12)
                    .accessibilityIdentifier("readerChatInput")
                Button(action: toggleDictation) {
                    Image(systemName: dictation.isActive ? "stop.circle.fill" : "mic")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(dictation.isActive ? Color.red : accent)
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(session.isSending)
                .accessibilityLabel(dictation.isActive ? "Stop dictation" : "Dictate question")
                .accessibilityValue(dictation.isActive ? dictation.status : (DictationLanguage(rawValue: dictationLanguage) ?? .system).title)
                .accessibilityHint("Speak to add text to your draft. Stop and review it before sending. Touch and hold to choose a language.")
                .accessibilityIdentifier("dictateChatQuestion")
                .contextMenu { dictationLanguagePicker }
                Button(action: session.isSending ? session.stop : send) {
                    Image(systemName: session.isSending ? "stop.fill" : "arrow.up").font(.system(size: 19, weight: .medium))
                        .foregroundStyle(question.isEmpty && !session.isSending ? Color.secondary : theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(question.isEmpty && !session.isSending ? accent.opacity(0.1) : accent, in: Circle())
                }
                .buttonStyle(.plain).disabled(dictation.isActive || (question.isEmpty && !session.isSending))
                .accessibilityLabel(session.isSending ? "Stop response" : "Send message").accessibilityIdentifier("sendReaderChat")
            }
            .padding(compact ? 0 : 4)
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(.secondary.opacity(0.3), lineWidth: 0.75))
        }
        .padding(.horizontal, 16).padding(.top, compact ? 0 : 4).padding(.bottom, compact ? 2 : 8)
        .foregroundStyle(.primary).tint(accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerChatPanel")
        .accessibilityAction(.escape, close)
        .onDisappear { dictation.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dictation.suspend(background: phase == .background) } }
        .onChange(of: ObjectIdentifier(session)) { _, _ in dictation.cancel() }
        .onChange(of: dictationLanguage) { _, _ in dictation.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: ReadAloudAudioSession.willActivate)) { _ in dictation.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: VoiceNoteSession.willActivate)) { _ in dictation.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { dictation.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            if (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { dictation.cancel() }
        }
        .alert("Dictation unavailable", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            if dictation.needsSettings { Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } }
            Button("OK", role: .cancel) { dictation.error = nil }
        } message: { Text(dictation.error ?? "") }
        .confirmationDialog(context == .general ? "Clear your general conversation?" : "Clear this book’s conversation?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { session.clear() }
                .accessibilityIdentifier("confirmClearConversation")
            Button("Cancel", role: .cancel) {}
        } message: { Text(context == .general ? "This deletes the general chat’s saved messages and draft from this device. Book conversations are kept." : "This deletes this book’s saved messages and draft from this device.") }
        .sheet(isPresented: $editsQuickPrompts) {
            NavigationStack { QuickPromptsEditor(closes: true) }
                .environment(\.leafTheme, theme).tint(theme.accent)
        }
    }

    private var dictationLanguagePicker: some View {
        Picker("Dictation language", selection: $dictationLanguage) {
            ForEach(DictationLanguage.allCases) { language in Text(language.title).tag(language.rawValue) }
        }.accessibilityIdentifier("dictationLanguage")
    }
    private func toggleDictation() {
        if dictation.isActive { dictation.finish(); return }
        inputFocused = false
        dictation.start(draft: session.draft, language: DictationLanguage(rawValue: dictationLanguage) ?? .system, bookTitle: bookTitle, selectedText: session.selectedContext?.text) { [weak session] text in
            session?.draft = text
        }
    }

    /// The reader's quick prompts for the selected text. Tapping one sends it at once,
    /// after anything already typed; the pencil opens the editor. Extra prompts scroll
    /// sideways instead of wrapping.
    private func selectionActions(compact: Bool) -> some View {
        let row = quickPromptRow(compact: compact)
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
    }
    private func quickPromptRow(compact: Bool) -> some View {
        let passage = session.selectedContext?.text ?? ""
        return HStack(spacing: compact ? 4 : 8) {
            ForEach(Array(settings.quickPrompts.enumerated()), id: \.element.id) { index, prompt in
                Button {
                    if session.applyQuickPrompt(prompt.text(for: passage)) { send() }
                } label: {
                    quickPromptChip(compact: compact) { Text(prompt.label).font(.caption.weight(.medium)).lineLimit(1).fixedSize() }
                }
                .buttonStyle(.plain).accessibilityLabel(prompt.label).accessibilityHint("Asks this about the selected text")
                .accessibilityIdentifier(prompt.chipIdentifier(at: index))
            }
            if !compact {
                Button { editsQuickPrompts = true } label: {
                    quickPromptChip(compact: false) { Image(systemName: "pencil").font(.caption.weight(.semibold)) }
                }
                .buttonStyle(.plain).accessibilityLabel("Edit quick prompts").accessibilityIdentifier("editQuickPrompts")
            }
        }
    }
    private func quickPromptChip(compact: Bool, @ViewBuilder label: () -> some View) -> some View {
        label()
            .foregroundStyle(accent).padding(.horizontal, compact ? 10 : 14).frame(minWidth: 44).frame(height: 44)
            .background(accent.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.2), lineWidth: 0.75))
            .contentShape(Capsule())
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 15).onEnded { gesture in
            if gesture.translation.height > 40, abs(gesture.translation.width) < gesture.translation.height { close() }
        }
    }

    private func close() {
        dictation.cancel()
        inputFocused = false
        onClose()
    }

    private func send() {
        guard !question.isEmpty, !session.isSending, !dictation.isActive else { return }
        inputFocused = false
        onSend()
    }
}

/// A picture the model drew, with the system share sheet for saving or sending it.
private struct ChatGeneratedImage: View {
    let url: URL?
    let accent: Color
    @State private var picture: UIImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let picture {
                VStack(alignment: .leading, spacing: 4) {
                    Image(uiImage: picture).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Generated picture").accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("chatReplyImage")
                    ShareLink(item: Image(uiImage: picture), preview: SharePreview("Picture from Leaf", image: Image(uiImage: picture))) {
                        Label("Share or save", systemImage: "square.and.arrow.up").font(.caption.weight(.medium))
                    }
                    .tint(accent).frame(minHeight: 44)
                    .accessibilityIdentifier("shareChatImage")
                }
            } else if missing {
                // Synced history carries the reply but not the picture file.
                Label("This picture is not on this device.", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("missingChatImage")
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.opacity(0.08))
                    .frame(maxWidth: .infinity).frame(height: 160)
            }
        }
        .task(id: url) {
            guard let url else { missing = true; return }
            let loaded = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
            if let loaded { picture = loaded } else { missing = true }
        }
    }
}

private struct ReaderChatMessageBubble: View, Equatable {
    let message: ReaderChatMessage
    let accent: Color
    var imageURL: (String) -> URL? = { _ in nil }
    var activity: String? = nil
    var onSelectionChange: (Bool) -> Void = { _ in }
    @State private var quoteExpanded = false

    // A streaming reply re-publishes the whole history several times a second; only
    // the bubble whose message changed needs its body and its text view updated.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.accent == rhs.accent && lhs.activity == rhs.activity
    }

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
                        Text(quoteExpanded ? context.text : context.previewText).font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(context.text)
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
            ForEach(message.images ?? [], id: \.self) { name in
                ChatGeneratedImage(url: imageURL(name), accent: accent)
            }
            // A finished reply that is only a picture needs no caption.
            if !(message.text.isEmpty && message.hasImages && message.state != .streaming) {
                SelectableChatText(text: displayText, markdown: !message.isUser,
                                   identifier: message.isUser ? "chatQuestion" : "chatReply",
                                   tint: accent,
                                   onSelectionChange: onSelectionChange)
            }
            // Which reading-context design produced this reply, for comparison.
            if !message.isUser, message.state != .streaming, let trace = message.trace {
                Label(trace.caption, systemImage: trace.usedTools ? "magnifyingglass" : "text.book.closed")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityElement(children: .ignore).accessibilityLabel(trace.caption)
                    .accessibilityIdentifier("chatReplyTrace")
            }
        }
        .padding(message.isUser ? 10 : 0)
        .background(message.isUser ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 16))
    }

    private var displayText: String {
        message.text.isEmpty ? (message.state == .streaming ? activity ?? "Thinking…" : "No response text") : message.text
    }
}
