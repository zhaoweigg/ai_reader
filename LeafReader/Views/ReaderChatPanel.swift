import SwiftUI
#if DEBUG
import GameController
#endif

#if DEBUG
/// Opt-in, read-only diagnostics. No text, focus requests, or keyboard changes.
@MainActor private enum ReaderComposerUITestTrace {
    private static var timer: Timer?
    private static var observers: [NSObjectProtocol] = []
    private static var focused = false
    private static var composing = false
    private static let writes = DispatchQueue(label: "Leaf.ComposerUITestTrace", qos: .utility)
    private static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing") &&
        ProcessInfo.processInfo.environment["LEAF_UI_COMPOSER_DIAGNOSTICS"] == "1"
    }
    static func start(focused: Bool, composing: Bool) {
        guard enabled else { return }
        update("appear", focused: focused, composing: composing)
        guard timer == nil else { return }
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                Task { @MainActor in record(name.rawValue, keyboardFrame: frame) }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in record("sample") }
        }
    }
    static func update(_ event: String, focused: Bool, composing: Bool) {
        guard enabled else { return }
        self.focused = focused; self.composing = composing
        record(event)
    }
    static func stop() {
        guard enabled else { return }
        record("disappear")
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
    }
    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        return view.subviews.lazy.compactMap { firstResponder(in: $0) }.first
    }
    private static func record(_ event: String, keyboardFrame: CGRect? = nil) {
        guard enabled, let testID = ProcessInfo.processInfo.environment["LEAF_UI_TEST_ID"],
              let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var row: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime, "focused": focused, "composing": composing,
            "hardwareKeyboardConnected": GCKeyboard.coalesced != nil,
            "windows": windows.map { window -> [String: Any] in
                var state: [String: Any] = ["class": String(describing: type(of: window)), "key": window.isKeyWindow,
                    "hidden": window.isHidden, "frame": String(describing: window.frame)]
                if let responder = firstResponder(in: window) {
                    state["responderClass"] = String(describing: type(of: responder))
                    state["responderIdentifier"] = responder.accessibilityIdentifier ?? ""
                    let frame = responder.convert(responder.bounds, to: window)
                    state["responderFrame"] = String(describing: frame)
                    if let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) {
                        state["responderCenterHitClass"] = String(describing: type(of: hit))
                    }
                }
                return state
            }]
        if let keyboardFrame { row["keyboardFrame"] = String(describing: keyboardFrame) }
        guard let rowData = try? JSONSerialization.data(withJSONObject: row) else { return }
        let url = cache.appendingPathComponent("ReaderComposerUITestTrace.json")
        writes.async {
            var rows: [[String: Any]] = []
            if let data = try? Data(contentsOf: url), let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               previous["testID"] as? String == testID { rows = previous["rows"] as? [[String: Any]] ?? [] }
            if let row = try? JSONSerialization.jsonObject(with: rowData) as? [String: Any] { rows.append(row) }
            let value: [String: Any] = ["testID": testID, "rows": Array(rows.suffix(400))]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
        }
    }
}
#endif

enum ReaderChatSizing {
    static func bounds(fullHeight: CGFloat, availableHeight: CGFloat, composing: Bool, hasSelection: Bool) -> ClosedRange<CGFloat> {
        let usable = max(0, availableHeight - 16)
        let minimum: CGFloat = fullHeight < 500 ? 132 : (composing ? (hasSelection ? 216 : 176) : (hasSelection ? 260 : 200))
        let lower = min(minimum, usable)
        return lower...max(lower, min(fullHeight * 0.85, usable * 0.88))
    }
    static func height(fraction: Double, fullHeight: CGFloat, availableHeight: CGFloat, composing: Bool, hasSelection: Bool) -> CGFloat {
        let limits = bounds(fullHeight: fullHeight, availableHeight: availableHeight, composing: composing, hasSelection: hasSelection)
        let desired: CGFloat
        if composing, !fraction.isFinite || fraction <= 0 {
            desired = min(fullHeight / 3, max(hasSelection ? 216 : 176, availableHeight * 0.35))
        } else { desired = fullHeight * CGFloat(fraction.isFinite && fraction > 0 ? fraction : 1.0 / 3) }
        return min(limits.upperBound, max(limits.lowerBound, desired))
    }
}

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
    static func center(x: Double, y: Double, in size: CGSize, bottom: CGFloat = ReaderChatPlacement.bottom) -> CGPoint {
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

struct ReaderChatButtonAppearance {
    static let defaultTransparency = 0.88
    static let transparencyRange = 0.2...0.95
    let transparency: Double
    init(transparency: Double) {
        self.transparency = transparency.isFinite ? min(0.95,max(0.2,transparency)) : Self.defaultTransparency
    }
    var fillOpacity: Double { 1 - transparency }
    var symbolOpacity: Double { min(1,fillOpacity * 0.55 / 0.12) }
    var outlineOpacity: Double { min(1,fillOpacity * 0.25 / 0.12) }
    func usesOnAccent(in theme: ReadingTheme) -> Bool {
        func rgb(_ hex: String) -> [Double] {
            let value = UInt32(hex.dropFirst(),radix:16) ?? 0
            return [Double((value >> 16) & 255),Double((value >> 8) & 255),Double(value & 255)].map { $0 / 255 }
        }
        func luminance(_ channels: [Double]) -> Double {
            zip(channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055,2.4) },[0.2126,0.7152,0.0722]).map(*).reduce(0,+)
        }
        let accent = rgb(theme.accentHex), background = rgb(theme.backgroundHex)
        let tint = zip(accent,background).map { $0 * fillOpacity + $1 * transparency }
        let tintLuminance = luminance(tint)
        func contrast(_ channels: [Double]) -> Double {
            let other = luminance(channels)
            return (max(tintLuminance,other)+0.05)/(min(tintLuminance,other)+0.05)
        }
        return contrast(rgb(theme.isDark ? theme.canvasHex : "#FFFFFF")) > contrast(accent)
    }
}

private struct ReaderChatButtonIcon: View {
    @Environment(\.leafTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let appearance: ReaderChatButtonAppearance
    var isMoving = false
    var body: some View {
        ZStack {
            // A color tint, never material blur: the underlying book stays sharp.
            Circle().fill(theme.accent.opacity(reduceTransparency ? 1 : appearance.fillOpacity))
            Image(systemName:isMoving ? "arrow.up.and.down.and.arrow.left.and.right" : "leaf.fill")
                .font(.system(size:isMoving ? 21 : 25,weight:.medium))
                .foregroundStyle((reduceTransparency || appearance.usesOnAccent(in:theme) ? theme.onAccent : theme.accent)
                    .opacity(reduceTransparency || contrast == .increased ? 1 : appearance.symbolOpacity))
        }
        .frame(width:ReaderChatPlacement.diameter,height:ReaderChatPlacement.diameter)
        .overlay(Circle().stroke(theme.accent.opacity(reduceTransparency ? 1 : isMoving || contrast == .increased ? 0.85 : appearance.outlineOpacity),
                                 style:StrokeStyle(lineWidth:isMoving ? 1.5 : 0.5,dash:isMoving ? [4,3] : [])))
        .contentShape(Circle())
    }
}

struct ReaderChatButtonSettings: View {
    @Environment(\.leafTheme) private var theme
    @AppStorage("reader.chatButtonTransparency") private var transparency = ReaderChatButtonAppearance.defaultTransparency
    private var appearance: ReaderChatButtonAppearance { ReaderChatButtonAppearance(transparency:transparency) }
    var body: some View {
        Form {
            Section {
                ZStack(alignment:.trailing) {
                    Text("A little room to read.\nLet the page stay in view.\nKeep your companion close.")
                        .font(.system(size:18,design:.serif)).lineSpacing(8).frame(maxWidth:.infinity,alignment:.leading)
                    ReaderChatButtonIcon(appearance:appearance).padding(.trailing,12)
                }.padding(.vertical,18).foregroundStyle(theme.foreground).accessibilityHidden(true)
            } header: { Text("Preview") }
                .listRowBackground(theme.surface)
            Section {
                HStack {
                    Text("Transparency")
                    Spacer()
                    Text(appearance.transparency,format:.percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value:Binding(get: { appearance.transparency },set: { transparency = $0 }),in:ReaderChatButtonAppearance.transparencyRange,step:0.01)
                    .accessibilityLabel("Floating button transparency")
                    .accessibilityValue(Text(appearance.transparency,format:.percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("chatButtonTransparency")
                HStack { Text("More visible");Spacer();Text("More transparent") }.font(.caption).foregroundStyle(.secondary)
                Button("Reset transparency") { transparency = ReaderChatButtonAppearance.defaultTransparency }
                    .accessibilityIdentifier("resetChatButtonTransparency")
            } footer: {
                Text("Applies immediately to the floating Ask Leaf button in Library and every book. Each view remembers its own position. Long press the button to move it. Reduce Transparency in iOS uses a solid button.")
            }
            .listRowBackground(theme.surface)
        }.leafFormStyle()
        .navigationTitle("Floating button").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.canvas,for:.navigationBar)
    }
}

struct ReaderChatLauncher: View {
    enum Location {
        case reader, library
        var storagePrefix: String { self == .reader ? "reader" : "library" }
        var identifier: String { self == .reader ? "openReaderChat" : "openLibraryChat" }
        var bottom: CGFloat { self == .reader ? ReaderChatPlacement.bottom : 24 }
    }
    @Environment(\.leafTheme) private var theme
    @Binding var isMoving: Bool
    let location: Location
    let action: () -> Void
    @AppStorage("reader.chatButtonTransparency") private var transparency = ReaderChatButtonAppearance.defaultTransparency
    @AppStorage private var savedX: Double
    @AppStorage private var savedY: Double
    @State private var dragOrigin: CGPoint?
    @State private var draggedCenter: CGPoint?

    init(isMoving: Binding<Bool>, location: Location = .reader, action: @escaping () -> Void) {
        _isMoving = isMoving; self.location = location; self.action = action
        _savedX = AppStorage(wrappedValue: -1, "\(location.storagePrefix).chatButtonX")
        _savedY = AppStorage(wrappedValue: -1, "\(location.storagePrefix).chatButtonY")
    }

    var body: some View {
        GeometryReader { geometry in
            let center = draggedCenter ?? ReaderChatPlacement.center(x: savedX, y: savedY, in: geometry.size, bottom: location.bottom)
            Button { if !isMoving { action() } } label: {
                ReaderChatButtonIcon(appearance:ReaderChatButtonAppearance(transparency:transparency),isMoving:isMoving)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in isMoving = true })
            .simultaneousGesture(dragGesture(from: center, in: geometry.size))
            .position(center)
            .accessibilityLabel("Ask Leaf")
            .accessibilityValue(isMoving ? "Move mode" : "Stationary")
            .accessibilityHint(isMoving ? "Drag to move. Tap elsewhere to finish." : "Opens your reading companion. Long press to move.")
            .accessibilityIdentifier(location.identifier)
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
        .sensoryFeedback(.impact(weight:.heavy,intensity:0.85),trigger:isMoving) { wasMoving,moving in !wasMoving && moving }
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
    enum Context { case reader, libraryBook, general }
    @Environment(\.leafTheme) private var theme
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

    private var accent: Color { theme.accent }
    private var question: String { session.draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var contextHint: String {
        switch context {
        case .reader: return settings.configuration.sharePage ? "Sends the current passage with your question." : "Passage sharing is off."
        case .libraryBook:
            return settings.configuration.sharePage ? "Continues this book’s saved chat. Library shares only its title and author; open the book to quote a new passage." : "Continues this book’s saved chat. Passage sharing is off."
        case .general: return "This conversation is separate from your book chats. No books are attached automatically."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            content(compact: geometry.size.height < 200, showsHistory: geometry.size.height >= 200 && (!isComposing || geometry.size.height >= 300))
        }
    }
    private func content(compact: Bool, showsHistory: Bool) -> some View {
        VStack(spacing: compact ? 4 : 8) {
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
                    if compact, let selection = session.selectedContext {
                        Text(selection.text).font(.caption).lineLimit(1).layoutPriority(-1).accessibilityIdentifier("chatSelectedPassage")
                        Button { session.removeSelection() } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                            .accessibilityLabel("Remove selected text").accessibilityIdentifier("removeChatSelection")
                        if !isComposing { selectionActions(compact: true) }
                    } else { Text("Ask Leaf").font(.subheadline.weight(.semibold)).foregroundStyle(accent).lineLimit(1) }
                    Spacer(minLength: 4)
                    if let onChooseConversation, !isComposing {
                        Button(action: onChooseConversation) {
                            HStack(spacing: 4) {
                                Text(context == .general ? "General chat" : bookTitle).lineLimit(1)
                                Image(systemName: "chevron.down")
                            }.font(.caption).frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("Choose conversation").accessibilityValue(context == .general ? "General chat" : bookTitle)
                            .accessibilityIdentifier("chooseLibraryConversation")
                    }
                    if context == .reader && !isComposing && !compact {
                        Text(settings.configuration.profile.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !isComposing && !compact {
                        Menu {
                            Button("AI settings", systemImage: "gearshape", action: onSettings)
                            Button("Floating button",systemImage:"circle.lefthalf.filled",action:onButtonSettings)
                                .accessibilityIdentifier("configureChatButton")
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
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Close chat").accessibilityIdentifier("closeReaderChat")
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dismissDrag)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("readerChatHeader")
            }

            if !showsHistory { Spacer(minLength: 0) }
            if showsHistory {
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
                TextField(session.selectedContext != nil ? "Ask about the selected text…" : context == .general ? "Ask Leaf…" : context == .libraryBook ? "Ask about this book…" : "Ask about this page…", text: $session.draft, axis: .vertical)
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
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, compact ? 4 : 8)
        .foregroundStyle(.primary).tint(accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerChatPanel")
        .accessibilityAction(.escape, close)
        #if DEBUG
        .onAppear { ReaderComposerUITestTrace.start(focused: inputFocused, composing: isComposing) }
        .onChange(of: inputFocused) { _, value in ReaderComposerUITestTrace.update("focus", focused: value, composing: isComposing) }
        .onChange(of: isComposing) { _, value in ReaderComposerUITestTrace.update("layout", focused: inputFocused, composing: value) }
        .onDisappear { ReaderComposerUITestTrace.stop() }
        #endif
        .confirmationDialog(context == .general ? "Clear your general conversation?" : "Clear this book’s conversation?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { session.clear() }
                .accessibilityIdentifier("confirmClearConversation")
            Button("Cancel", role: .cancel) {}
        } message: { Text(context == .general ? "This deletes the general chat’s saved messages and draft from this device. Book conversations are kept." : "This deletes this book’s saved messages and draft from this device.") }
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
