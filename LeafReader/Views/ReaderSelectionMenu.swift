import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit
import PDFKit

enum ReaderSelectionIntent: String, CaseIterable {
    case ask, explain, summarize
    var title: String {
        switch self { case .ask: return "Ask a question"; case .explain: return "Explain selection"; case .summarize: return "Summarize selection" }
    }
    func prompt(for text: String) -> String {
        let chinese = ReaderChatMessage.usesChinese(text)
        switch self {
        case .ask: return ""
        case .explain: return chinese ? "请解释这段文字。" : "Explain this passage."
        case .summarize: return chinese ? "请总结这段文字。" : "Summarize this passage."
        }
    }
}

struct ReaderSelectionRequest: Identifiable, Equatable {
    let id = UUID()
    let intent: ReaderSelectionIntent
    let context: ReadingChatContext
}

enum ReaderAnnotationIntent: Equatable { case highlight, note }
struct ReaderListeningRequest: Equatable { let id = UUID(); let locator: String }

@MainActor private func showSelectionMenu(view: UIView, presenter: ReaderSelectionMenuPresenter, theme: ReadingTheme, context: ReadingChatContext?, action: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?, annotation: BookAnnotationSelection?, annotate: ((ReaderAnnotationIntent, BookAnnotationSelection) -> Void)?, position: String?, listen: ((String) -> Void)?) {
    #if DEBUG
    readerSelectionMenuTrace("request", source: view, context: context?.isEmpty == false)
    #endif
    guard let context, !context.isEmpty, let action else { return }
    guard !presenter.showsSystemMenu else { return }
    var actions = [ReaderSelectionAction(title: "Ask Leaf", image: "leaf", id: "ask") { action(.ask, context) }]
    if let position, let listen {
        actions.append(ReaderSelectionAction(title: "Listen from here", image: "headphones", id: "listen") { listen(position) })
    }
    if let annotation, let annotate {
        actions.append(ReaderSelectionAction(title: "Highlight", image: "highlighter", id: "highlight") { annotate(.highlight, annotation) })
        actions.append(ReaderSelectionAction(title: "Add Note", image: "square.and.pencil", id: "note") { annotate(.note, annotation) })
    }
    let copiedText = view.selectionText
    let responder = view.selectionFirstResponder ?? view
    actions.append(ReaderSelectionAction(title: "Copy", image: "doc.on.doc", id: "copy") { [weak responder, weak presenter] in
        if let copiedText { UIPasteboard.general.string = copiedText }
        else { responder?.perform(#selector(UIResponderStandardEditActions.copy(_:)), with: nil) }
        presenter?.observeCopiedSelection()
    })
    actions.append(ReaderSelectionAction(title: "iOS text actions", image: "ellipsis", id: "system") { [weak presenter] in presenter?.presentSystemMenu() })
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
        let identity = (view is PDFView && annotation?.pdfRanges.isEmpty == false)
            ? context.locator + "|" + (annotation?.pdfRanges.map { "\($0.page):\($0.location):\($0.length)" }.joined(separator: ",") ?? "")
            : context.locator
        for index in actions.indices { actions[index].testLocator = identity }
    }
    #endif
    presenter.schedule(on: view, actions: actions, theme: theme, selectedText: context.text)
}

private extension UIView {
    var selectionCharacterRanges: [PDFAnnotationRange] {
        guard let pdf = self as? PDFView, let document = pdf.document, let selection = pdf.currentSelection else { return [] }
        return selection.pages.flatMap { page in
            (0..<selection.numberOfTextRanges(on: page)).map { index in
                let range = selection.range(at: index, on: page)
                return PDFAnnotationRange(page: document.index(for: page), location: range.location, length: range.length)
            }
        }
    }
    var selectionStatusBarOwner: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
    var selectionFirstResponder: UIView? {
        if isFirstResponder { return self }
        return subviews.lazy.compactMap(\.selectionFirstResponder).first
    }
    var selectionEditMenu: UIEditMenuInteraction? {
        interactions.compactMap { $0 as? UIEditMenuInteraction }.first
            ?? subviews.lazy.compactMap(\.selectionEditMenu).first
    }
    var selectionText: String? {
        if let pdf = self as? PDFView { return pdf.currentSelection?.string }
        guard let input = selectionFirstResponder as? UITextInput, let range = input.selectedTextRange else { return nil }
        return input.text(in: range)
    }
    func selectionContains(_ point: CGPoint) -> Bool {
        if let pdf = self as? PDFView, let selection = pdf.currentSelection {
            return selection.pages.contains { pdf.convert(selection.bounds(for: $0), from: $0).insetBy(dx: -18, dy: -12).contains(point) }
        }
        guard let input = selectionFirstResponder as? (UIView & UITextInput), let range = input.selectedTextRange, !range.isEmpty else { return false }
        let local = input.convert(point, from: self)
        return input.selectionRects(for: range).contains { $0.rect.insetBy(dx: -18, dy: -12).contains(local) }
    }
    var selectionRectangles: [CGRect] {
        if let pdf = self as? PDFView, let selection = pdf.currentSelection {
            return selection.selectionsByLine().flatMap { line in
                line.pages.map { pdf.convert(line.bounds(for: $0), from: $0) }
            }
        }
        guard let input = selectionFirstResponder as? (UIView & UITextInput), let range = input.selectedTextRange else { return [] }
        return input.selectionRects(for: range).map { convert($0.rect, from: input) }.filter { !$0.isEmpty }
    }
    var selectionAnchor: CGRect {
        let rect = selectionRectangles.reduce(CGRect.null) { $0.union($1) }.intersection(bounds)
        return rect.isNull || rect.isEmpty ? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1) : rect
    }
    var nativeSelectionHandleViews: [UIView & UITextSelectionHandleView] {
        if let handle = self as? (UIView & UITextSelectionHandleView), window != nil, !isHidden, alpha > 0.01 { return [handle] }
        let displays = interactions.compactMap { $0 as? UITextSelectionDisplayInteraction }
        let handles = displays.flatMap(\.handleViews).filter { $0.window != nil && !$0.isHidden && $0.alpha > 0.01 }
        if !handles.isEmpty { return handles }
        return subviews.flatMap(\.nativeSelectionHandleViews)
    }
    var selectionHandles: [CGRect] {
        let native = nativeSelectionHandleViews
        if native.count == 2 { return native.map { convert($0.bounds, from: $0).insetBy(dx: -10, dy: -10) } }
        let rects = selectionRectangles
        guard let first = rects.first, let last = rects.last else { return [] }
        // Native selection stems/knobs extend beyond the selected glyphs. Keep
        // the menu clear of both endpoints, including a multi-line selection.
        return [CGRect(x: first.minX - 18, y: first.minY - 24, width: 36, height: first.height + 36),
                CGRect(x: last.maxX - 18, y: last.minY - 12, width: 36, height: last.height + 36)]
    }
    func selectionHandleContains(_ point: CGPoint) -> Bool {
        let handles = nativeSelectionHandleViews
        if handles.count == 2 {
            return handles.contains { convert($0.bounds, from: $0).insetBy(dx: -10, dy: -10).contains(point) }
        }
        return selectionHandles.contains { $0.contains(point) } && !selectionRectangles.contains { $0.contains(point) }
    }
}

private struct ReaderSelectionAction {
    let title: String
    let image: String
    let id: String
    let perform: () -> Void
    #if DEBUG
    var testLocator: String?
    #endif
}

/// Observes completion without recognizing a gesture. WebKit/PDFKit keep sole
/// ownership of their long press, selection grips, scrolling, and cancellation.
private final class ReaderSelectionTouchObserver: UIGestureRecognizer {
    enum Phase { case began, moved, ended, cancelled }
    var observe: ((Phase, CGPoint, TimeInterval) -> Void)?
    private var tracking = false
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !tracking, touches.count == 1, event.allTouches?.count == 1, let touch = touches.first else {
            cancelObservation(); return
        }
        tracking = true; observe?(.began, touch.location(in: view), touch.timestamp)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking, let touch = touches.first else { return }
        guard event.allTouches?.count == 1 else { cancelObservation(); return }
        observe?(.moved, touch.location(in: view), touch.timestamp)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking, let touch = touches.first else { state = .failed; return }
        tracking = false; observe?(.ended, touch.location(in: view), touch.timestamp)
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancelObservation(touch: touches.first) }
    private func cancelObservation(touch: UITouch? = nil) {
        if tracking { observe?(.cancelled, touch?.location(in: view) ?? .zero, touch?.timestamp ?? 0) }
        tracking = false; state = .failed
    }
    override func reset() { tracking = false; super.reset() }
}

@MainActor private final class ReaderSelectionMenuPresenter: NSObject, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    private weak var source: UIView?
    private weak var window: UIWindow?
    private var controller: ReaderSelectionActionsController?
    private var menuWindow: ReaderSelectionWindow?
    private var observers: [UIGestureRecognizer] = []
    private var deactivationObserver: NSObjectProtocol?
    #if DEBUG
    private var orientationObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    #endif
    private var pdfSelectionObserver: NSObjectProtocol?
    private var pdfSelectionRanges: [PDFAnnotationRange] = []
    private var selectionRefreshTask: Task<Void, Never>?
    private var systemMenuUntil = Date.distantPast
    private var systemInteraction: UIEditMenuInteraction?
    private var selectionTouch: ReaderSelectionTouchObserver?
    private struct BookTouch {
        let start: CGPoint
        let timestamp: TimeInterval
        let beganOnHandle: Bool
        var distance: CGFloat = 0
        var selectionChanged = false
    }
    private var bookTouch: BookTouch?
    // UIKit can deliver a reader tap just after its native selection completes.
    // A short monotonic grace protects only that completed selection gesture.
    private var completedSelectionTouchUntil: TimeInterval = 0
    var isHandlingNativeSelectionGesture: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now < completedSelectionTouchUntil { return true }
        guard let touch = bookTouch else { return false }
        return touch.beganOnHandle || now - touch.timestamp >= 0.45 && touch.distance <= 20
    }
    private var adjustingSelectionHandle = false
    private var requestMenu: (() async -> Void)?
    private var requestTask: Task<Void, Never>?
    private var revision = 0
    var showsSystemMenu: Bool { systemInteraction != nil || Date() < systemMenuUntil }
    var usesExpandedMenu: Bool { requestTask != nil || selectionRefreshTask != nil || adjustingSelectionHandle || controller != nil }
    func observeSelection(on source: UIView, request: @escaping () async -> Void) {
        if self.source !== source { detach() }
        self.source = source; requestMenu = request
        guard selectionTouch == nil else { return }
        let touch = ReaderSelectionTouchObserver(target: nil, action: nil)
        touch.cancelsTouchesInView = false; touch.delaysTouchesBegan = false; touch.delaysTouchesEnded = false
        touch.requiresExclusiveTouchType = false; touch.delegate = self
        touch.observe = { [weak self] phase, point, timestamp in self?.observeBookTouch(phase, point: point, timestamp: timestamp) }
        source.addGestureRecognizer(touch); selectionTouch = touch
        if let pdf = source as? PDFView {
            pdfSelectionRanges = pdf.selectionCharacterRanges
            pdfSelectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdf, queue: .main) { [weak self, weak pdf] _ in
                Task { @MainActor in
                    guard let self, let pdf else { return }
                    let ranges = pdf.selectionCharacterRanges
                    guard ranges != self.pdfSelectionRanges else { return }
                    self.pdfSelectionRanges = ranges
                    self.selectionDidChange()
                }
            }
        }
        if let scene = source.window?.windowScene {
            deactivationObserver = NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    #if DEBUG
                    readerSelectionMenuTrace("sceneDeactivated", source: self?.source)
                    #endif
                    self?.dismiss()
                }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak source] _ in
                    Task { @MainActor in readerSelectionMenuTrace("deviceOrientationChanged", source: source) }
                }
                activationObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak source] _ in
                    Task { @MainActor in readerSelectionMenuTrace("sceneActivated", source: source) }
                }
            }
            #endif
        }
    }
    func detach() {
        #if DEBUG
        readerSelectionMenuTrace("sourceDetached", source: source)
        #endif
        dismiss()
        completedSelectionTouchUntil = 0
        if let selectionTouch { selectionTouch.observe = nil; selectionTouch.view?.removeGestureRecognizer(selectionTouch) }
        selectionTouch = nil; requestMenu = nil; source = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }; deactivationObserver = nil
        if let pdfSelectionObserver { NotificationCenter.default.removeObserver(pdfSelectionObserver) }; pdfSelectionObserver = nil
        #if DEBUG
        for observer in [orientationObserver, activationObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        orientationObserver = nil; activationObserver = nil
        #endif
    }
    func observeCopiedSelection() {
        guard let source, let window = source.window, window.windowScene?.activationState == .foregroundActive,
              source.selectionText?.isEmpty == false else { return }
        // Copy dismisses actions, while UIKit keeps its native range and grips.
        // Keep watching that range until an outside gesture or reader teardown.
        adjustingSelectionHandle = true
        installOutsideObservers(on: window)
    }
    func selectionDidChange() {
        if bookTouch != nil {
            bookTouch?.selectionChanged = true
            if controller != nil || adjustingSelectionHandle {
                adjustingSelectionHandle = true
                dismiss(keepingHandleObserver: true)
            }
            return
        }
        guard !showsSystemMenu, controller != nil || adjustingSelectionHandle else { return }
        adjustingSelectionHandle = true
        dismiss(keepingHandleObserver: true)
        let expectedRevision = revision
        selectionRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.revision == expectedRevision else { return }
            self.selectionRefreshTask = nil
            self.requestCurrentMenu()
        }
    }
    func requestCurrentMenu() {
        guard let window = source?.window, window.windowScene?.activationState == .foregroundActive else { return }
        selectionRefreshTask?.cancel(); selectionRefreshTask = nil
        systemMenuUntil = .distantPast
        revision += 1; let expectedRevision = revision; requestTask?.cancel()
        installOutsideObservers(on: window)
        requestTask = Task { [weak self] in
            let request = self?.requestMenu
            await request?()
            guard let self, self.revision == expectedRevision else { return }
            self.requestTask = nil
            if self.controller == nil { self.adjustingSelectionHandle = false; self.removeOutsideObservers() }
        }
        UIMenuSystem.context.setNeedsRebuild()
    }
    private func observeBookTouch(_ phase: ReaderSelectionTouchObserver.Phase, point: CGPoint, timestamp: TimeInterval) {
        guard let source, !showsSystemMenu else { bookTouch = nil; return }
        switch phase {
        case .began:
            completedSelectionTouchUntil = 0
            bookTouch = BookTouch(start: point, timestamp: timestamp, beganOnHandle: source.selectionHandleContains(point))
            #if DEBUG
            readerSelectionMenuTrace("bookTouchBegan", source: source, context: bookTouch?.beganOnHandle, point: point)
            #endif
        case .moved:
            guard var touch = bookTouch else { return }
            touch.distance = max(touch.distance, hypot(point.x - touch.start.x, point.y - touch.start.y))
            bookTouch = touch
            if touch.beganOnHandle, touch.distance > 3, controller != nil {
                adjustingSelectionHandle = true; dismiss(keepingHandleObserver: true)
            }
        case .ended:
            guard let touch = bookTouch else { return }
            bookTouch = nil
            let longPress = timestamp - touch.timestamp >= 0.45 && touch.distance <= 20
            let adjusted = touch.beganOnHandle && (touch.selectionChanged || touch.distance > 3)
            // The reader's single tap waits for double-tap failure and can arrive
            // >350ms later. A fresh book touch clears this grace immediately.
            if longPress || adjusted { completedSelectionTouchUntil = ProcessInfo.processInfo.systemUptime + 0.6 }
            #if DEBUG
            readerSelectionMenuTrace("bookTouchEnded", source: source, context: longPress || adjusted, point: point)
            #endif
            // Native selection can move/scroll under the finger. Snapshot its
            // current range after completion, never gate on the old touch rect.
            if longPress || adjusted { requestCurrentMenu() }
        case .cancelled:
            #if DEBUG
            readerSelectionMenuTrace("bookTouchCancelled", source: source, context: timestamp > 0, point: point,
                duration: bookTouch.map { timestamp - $0.timestamp }, distance: bookTouch?.distance)
            #endif
            bookTouch = nil; dismiss()
        }
    }
    func schedule(on source: UIView, actions: [ReaderSelectionAction], theme: ReadingTheme, selectedText: String) {
        guard !Task.isCancelled, let window = source.window, let scene = window.windowScene, scene.activationState == .foregroundActive else { return }
        self.source = source
        adjustingSelectionHandle = false
        // A completed user request drives presentation; building UIKit's cached
        // hierarchy has no presentation side effects. Native selection stays intact.
        source.selectionEditMenu?.dismissMenu()
        if let controller {
            controller.update(actions: actions, selectedText: selectedText); return
        }
        let controller = ReaderSelectionActionsController(actions: actions, theme: theme, source: source)
        controller.choose = { [weak self] action in self?.dismiss(); action() }
        let menuWindow = ReaderSelectionWindow(windowScene: scene)
        menuWindow.backgroundColor = .clear; menuWindow.windowLevel = window.windowLevel + 1
        menuWindow.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
        menuWindow.rootViewController = controller
        menuWindow.isHidden = false
        self.menuWindow = menuWindow
        controller.scrollView.accessibilityValue = selectedText
        self.controller = controller
        installOutsideObservers(on: window)
        #if DEBUG
        readerSelectionMenuTrace("shown", source: source)
        #endif
    }
    private func installOutsideObservers(on window: UIWindow) {
        guard observers.isEmpty else { return }
        self.window = window
        let tap = UITapGestureRecognizer(target: self, action: #selector(outsideGesture(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(outsideGesture(_:)))
        observers = [tap, pan]
        for observer in observers {
            observer.cancelsTouchesInView = false; observer.delaysTouchesEnded = false
            observer.delegate = self; window.addGestureRecognizer(observer)
        }
    }
    private func removeOutsideObservers() {
        for observer in observers { window?.removeGestureRecognizer(observer) }
        observers = []; window = nil
    }
    func dismiss(keepingHandleObserver: Bool = false) {
        selectionRefreshTask?.cancel(); selectionRefreshTask = nil
        if let interaction = systemInteraction {
            systemInteraction = nil; interaction.dismissMenu(); interaction.view?.removeInteraction(interaction)
        }
        systemMenuUntil = .distantPast
        revision += 1; requestTask?.cancel(); requestTask = nil
        #if DEBUG
        readerSelectionMenuTrace("dismiss", source: source)
        #endif
        if !keepingHandleObserver { bookTouch = nil; adjustingSelectionHandle = false; removeOutsideObservers() }
        menuWindow?.isHidden = true; menuWindow?.rootViewController = nil; menuWindow = nil
        controller = nil
        UIMenuSystem.context.setNeedsRebuild()
    }
    @objc private func outsideGesture(_ gesture: UIGestureRecognizer) {
        if gesture is UIPanGestureRecognizer && adjustingSelectionHandle {
            if gesture.state == .began { dismiss(keepingHandleObserver: true) }
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                let completed = gesture.state == .ended
                dismiss()
                let expectedRevision = revision
                if completed {
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        guard let self, self.revision == expectedRevision else { return }
                        self.requestCurrentMenu()
                    }
                }
            }
            return
        }
        if gesture.state == .ended || gesture.state == .began { dismiss() }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let source, let view = touch.view else { return false }
        let point = touch.location(in: source)
        let onHandle = source.selectionHandleContains(point)
        if gestureRecognizer === selectionTouch {
            var ancestor: UIView? = view
            while let current = ancestor, current !== source {
                if current is UIControl { return false }; ancestor = current.superview
            }
            return view.isDescendant(of: source)
        }
        // Native grip stems can overlap selected glyphs. Only the passive book
        // observer watches their completion; an outside pan losing arbitration
        // to UIKit must not dismiss the newly refreshed actions afterward.
        if onHandle { return false }
        if gestureRecognizer is UIPanGestureRecognizer { adjustingSelectionHandle = onHandle }
        #if DEBUG
        readerSelectionMenuTrace(onHandle ? "handleTouch" : "outsideTouch", source: source, point: point, target: view)
        #endif
        if let controller { return !view.isDescendant(of: controller.view) }
        return requestTask != nil || adjustingSelectionHandle
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func presentSystemMenu() {
        guard let source else { return }
        systemMenuUntil = Date().addingTimeInterval(2)
        #if DEBUG
        readerSelectionMenuTrace("systemRequested", source: source, context: source.selectionText?.isEmpty == false)
        #endif
        UIMenuSystem.context.setNeedsRebuild()
        // The WebKit-owned interaction carries its own configuration/session.
        // Present UIKit's current responder actions without replacing that delegate.
        let target = source.selectionFirstResponder ?? source
        let interaction = UIEditMenuInteraction(delegate: self)
        systemInteraction = interaction; target.addInteraction(interaction)
        let rect = target.convert(source.selectionAnchor, from: source)
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY)))
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        #if DEBUG
        readerSelectionMenuTrace("systemSuggestedActions", source: source, context: !suggestedActions.isEmpty)
        #endif
        return UIMenu(children: suggestedActions)
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let source, let target = interaction.view else { return .null }
        return target.convert(source.selectionAnchor, from: source)
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration, animator: UIEditMenuInteractionAnimating) {
        #if DEBUG
        readerSelectionMenuTrace("systemWillPresent", source: source)
        #endif
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self, weak interaction] in
            guard let self, let interaction, self.systemInteraction === interaction else { return }
            self.systemInteraction = nil; self.systemMenuUntil = .distantPast
            interaction.view?.removeInteraction(interaction)
            UIMenuSystem.context.setNeedsRebuild()
        }
    }
}

private final class ReaderSelectionWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let root = rootViewController?.view else { return nil }
        return root.hitTest(convert(point, to: root), with: event)
    }
}

private final class ReaderSelectionOverlayView: UIView {
    let card = UIView()
    var selectionHandleRects: [CGRect] = []
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if selectionHandleRects.contains(where: { $0.contains(point) }) { return nil }
        let local = convert(point, to: card)
        return card.bounds.contains(local) ? card.hitTest(local, with: event) : nil
    }
}

@MainActor private final class ReaderSelectionActionsController: UIViewController {
    private var actions: [ReaderSelectionAction]
    var choose: ((() -> Void) -> Void)?
    let scrollView = UIScrollView()
    private var buttons: [UIButton] = []
    private var dividers: [UIView] = []
    private let material = UIVisualEffectView(effect: nil)
    private let theme: ReadingTheme
    private weak var source: UIView?
    private let hidesStatusBar: Bool
    private let statusBarStyle: UIStatusBarStyle
    override var prefersStatusBarHidden: Bool { hidesStatusBar }
    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }
    init(actions: [ReaderSelectionAction], theme: ReadingTheme, source: UIView) {
        self.actions = actions; self.theme = theme; self.source = source
        let status = source.window?.windowScene?.statusBarManager
        var hiddenOwner = source.selectionStatusBarOwner, styleOwner = hiddenOwner
        while let child = hiddenOwner?.childForStatusBarHidden { hiddenOwner = child }
        while let child = styleOwner?.childForStatusBarStyle { styleOwner = child }
        hidesStatusBar = hiddenOwner?.prefersStatusBarHidden ?? status?.isStatusBarHidden ?? true
        statusBarStyle = styleOwner?.preferredStatusBarStyle ?? status?.statusBarStyle ?? .default
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = ReaderSelectionOverlayView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let overlay = view as! ReaderSelectionOverlayView
        overlay.addSubview(overlay.card); overlay.card.addSubview(scrollView)
        overlay.card.backgroundColor = .clear; overlay.card.layer.cornerRadius = 22
        overlay.card.layer.shadowColor = UIColor.black.cgColor; overlay.card.layer.shadowOpacity = 0.16
        overlay.card.layer.shadowRadius = 16; overlay.card.layer.shadowOffset = CGSize(width: 0, height: 5)
        material.effect = UIAccessibility.isReduceTransparencyEnabled ? nil : UIBlurEffect(style: .systemThinMaterial)
        material.contentView.backgroundColor = UIColor(theme.surface).withAlphaComponent(UIAccessibility.isReduceTransparencyEnabled ? 1 : 0.8)
        material.layer.cornerRadius = 22; material.clipsToBounds = true; material.isUserInteractionEnabled = false
        overlay.card.insertSubview(material, at: 0)
        scrollView.showsHorizontalScrollIndicator = false; scrollView.showsVerticalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true; scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "expandedSelectionMenu"
        scrollView.accessibilityLabel = "Selection actions"
        scrollView.accessibilityHint = "Choose an action for the selected passage."
        rebuildButtons()
    }
    func update(actions: [ReaderSelectionAction], selectedText: String) {
        self.actions = actions; scrollView.accessibilityValue = selectedText
        rebuildButtons(); view.setNeedsLayout()
    }
    private func rebuildButtons() {
        for child in buttons.map({ $0 as UIView }) + dividers { child.removeFromSuperview() }
        buttons = []; dividers = []
        for (index, action) in actions.enumerated() {
            let primary = action.id == "ask" || action.id == "listen"
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.title = action.id == "listen" ? "Listen" : action.id == "note" ? "Note" : action.id == "system" ? "More" : action.title
            configuration.image = UIImage(systemName: action.image)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: primary ? 17 : 19, weight: .regular)
            configuration.imagePlacement = primary ? .leading : .top
            configuration.imagePadding = primary ? 8 : 5
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 5, bottom: 7, trailing: 5)
            configuration.baseForegroundColor = UIColor(action.id == "ask" ? theme.onAccent : theme.foreground)
            configuration.background.backgroundColor = action.id == "ask" ? UIColor(theme.accent) : primary ? UIColor(theme.accent).withAlphaComponent(0.1) : .clear
            configuration.background.cornerRadius = 14
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = UIFontMetrics(forTextStyle: primary ? .subheadline : .caption1).scaledFont(
                    for: .systemFont(ofSize: primary ? 15 : 11, weight: primary ? .medium : .regular), maximumPointSize: primary ? 20 : 16)
                return result
            }
            button.configuration = configuration
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.accessibilityLabel = action.title; button.accessibilityIdentifier = "selection-" + action.id
            #if DEBUG
            if action.id == "ask" { button.accessibilityValue = action.testLocator }
            #endif
            button.addAction(UIAction { [weak self] _ in
                guard let self, index < self.actions.count else { return }
                self.choose?(self.actions[index].perform)
            }, for: .touchUpInside)
            scrollView.addSubview(button); buttons.append(button)
        }
        let line = UIView(); line.backgroundColor = UIColor(theme.foreground).withAlphaComponent(0.1)
        scrollView.addSubview(line); dividers = [line]
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let source, let overlay = view as? ReaderSelectionOverlayView else { return }
        let safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 12, dy: 8)
        let anchor = source.convert(source.selectionAnchor, to: view)
        let handles = source.selectionHandles.map { source.convert($0, to: view) }
        let primaryIndices = actions.indices.filter { actions[$0].id == "ask" || actions[$0].id == "listen" }
        let secondaryIndices = actions.indices.filter { !primaryIndices.contains($0) }
        let primaryHeight = max(48, ceil(primaryIndices.map { buttons[$0].intrinsicContentSize.height }.max() ?? 48))
        let secondaryHeight = max(56, ceil(secondaryIndices.map { buttons[$0].intrinsicContentSize.height }.max() ?? 56))
        let secondaryTop = primaryHeight + 13
        let contentHeight = secondaryTop + secondaryHeight
        let height = min(contentHeight + 16, safe.height)
        let width = min(360, safe.width)
        // Prefer above the entire selection, with enough clearance for its
        // start knob. If it reaches the top, place below its end knob instead.
        let selectionTop = min(anchor.minY, handles.map(\.minY).min() ?? anchor.minY)
        let selectionBottom = max(anchor.maxY, handles.map(\.maxY).max() ?? anchor.maxY)
        let above = selectionTop - height - 8, below = selectionBottom + 8
        let left = min(max(safe.minX, anchor.midX - width / 2), safe.maxX - width)
        let candidates = [above, below, safe.minY, safe.maxY - height]
            + handles.flatMap { [$0.minY - height - 8, $0.maxY + 8] }
        let top = candidates.first { y in
            let rect = CGRect(x: left, y: y, width: width, height: height)
            return y >= safe.minY && rect.maxY <= safe.maxY && !handles.contains { $0.intersects(rect) }
        } ?? safe.minY
        let frame = CGRect(x: left, y: top, width: width, height: height)
        // Even an unusually short viewport must pass handle touches through.
        overlay.selectionHandleRects = handles
        overlay.card.frame = frame
        overlay.card.layer.shadowPath = UIBezierPath(roundedRect: overlay.card.bounds, cornerRadius: 22).cgPath
        material.frame = overlay.card.bounds
        scrollView.frame = overlay.card.bounds.insetBy(dx: 8, dy: 8)
        let rowWidth = scrollView.bounds.width
        let primaryWidth = (rowWidth - CGFloat(max(0, primaryIndices.count - 1)) * 8) / CGFloat(max(1, primaryIndices.count))
        for (column, index) in primaryIndices.enumerated() {
            buttons[index].frame = CGRect(x: CGFloat(column) * (primaryWidth + 8), y: 0, width: primaryWidth, height: primaryHeight)
        }
        dividers.first?.frame = CGRect(x: 0, y: primaryHeight + 8, width: rowWidth, height: 1)
        let secondaryWidth = rowWidth / CGFloat(max(1, secondaryIndices.count))
        for (column, index) in secondaryIndices.enumerated() {
            buttons[index].frame = CGRect(x: CGFloat(column) * secondaryWidth, y: secondaryTop, width: secondaryWidth, height: secondaryHeight)
        }
        // Only unusually short accessibility/keyboard viewports scroll, and
        // only vertically. All six actions fit without paging in normal use.
        scrollView.contentSize = CGSize(width: rowWidth, height: contentHeight)
        scrollView.isScrollEnabled = contentHeight > scrollView.bounds.height
        scrollView.contentOffset = CGPoint(x: 0, y: min(scrollView.contentOffset.y, max(0, contentHeight - scrollView.bounds.height)))
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            // Geometry only, for real native handle drags; this does not create
            // a selection or intercept touches in the book.
            var markers: [UIAccessibilityElement] = []
            let nativeHandles = source.nativeSelectionHandleViews
            if nativeHandles.count == 2 {
                for (index, handle) in nativeHandles.enumerated() {
                    let rect = handle.convert(handle.bounds, to: view)
                    let start = handle.direction.contains(.leading) || index == 0 && !handle.direction.contains(.trailing)
                    let marker = UIAccessibilityElement(accessibilityContainer: overlay)
                    marker.accessibilityIdentifier = start ? "selection-start-geometry" : "selection-end-geometry"
                    marker.accessibilityLabel = start ? "Selection start geometry" : "Selection end geometry"
                    marker.accessibilityValue = "native"
                    marker.accessibilityFrameInContainerSpace = rect
                    markers.append(marker)
                }
            }
            for (index, rect) in source.selectionRectangles.enumerated() where nativeHandles.count != 2 && (index == 0 || index == source.selectionRectangles.count - 1) {
                let converted = source.convert(rect, to: view)
                let start = index == 0
                let marker = UIAccessibilityElement(accessibilityContainer: overlay)
                marker.accessibilityIdentifier = start ? "selection-start-geometry" : "selection-end-geometry"
                marker.accessibilityLabel = start ? "Selection start geometry" : "Selection end geometry"
                marker.accessibilityFrameInContainerSpace = CGRect(x: (start ? converted.minX - 2 : converted.maxX), y: converted.midY - 1, width: 2, height: 2)
                markers.append(marker)
                if source.selectionRectangles.count == 1 {
                    let end = UIAccessibilityElement(accessibilityContainer: overlay)
                    end.accessibilityIdentifier = "selection-end-geometry"; end.accessibilityLabel = "Selection end geometry"
                    end.accessibilityFrameInContainerSpace = CGRect(x: converted.maxX, y: converted.midY - 1, width: 2, height: 2); markers.append(end)
                }
            }
            overlay.accessibilityElements = [scrollView] + markers
        }
        #endif
    }

}

final class ReaderWebView: WKWebView {
    private let selectionMenu = ReaderSelectionMenuPresenter()
    var prepareSelection: (() async -> Void)?
    func selectionDidChange() { selectionMenu.selectionDidChange() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { selectionMenu.detach() }
        else {
            selectionMenu.observeSelection(on: self) { [weak self] in
                let prepare = self?.prepareSelection
                await prepare?()
                guard !Task.isCancelled, let self, self.window != nil else { return }
                self.showSelectionActions()
            }
        }
    }
    var selectionTheme: (() -> ReadingTheme)?
    var listeningPosition: (() -> String?)?
    var onListen: ((String) -> Void)?
    var selectionContext: (() -> ReadingChatContext?)?
    var onSelectionAction: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?
    var annotationSelection: (() -> BookAnnotationSelection?)?
    var onAnnotationAction: ((ReaderAnnotationIntent, BookAnnotationSelection) -> Void)?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        #if DEBUG
        readerSelectionMenuTrace(selectionMenu.showsSystemMenu ? "systemBuild" : "build", source: self, context: selectionContext?()?.isEmpty == false)
        #endif
        if selectionMenu.showsSystemMenu {
            #if DEBUG
            readerSelectionMenuTrace("systemHasDefaultItems", source: self, context: builder.menu(for: .root)?.children.isEmpty == false)
            readerSelectionMenuTrace("systemCanCopy", source: self, context: selectionFirstResponder?.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil) == true)
            #endif
            return
        }
        if selectionMenu.usesExpandedMenu {
            builder.replaceChildren(ofMenu: .root) { _ in [] }; return
        }
        // Menu hierarchies are cached. The handler snapshots the current selection
        // when invoked, including accessibility and keyboard edit-menu requests.
        let action = UIAction(title: "Leaf actions", image: UIImage(systemName: "leaf")) { [weak self] _ in self?.selectionMenu.requestCurrentMenu() }
        builder.insertChild(UIMenu(options: .displayInline, children: [action]), atStartOfMenu: .root)
    }
    private func showSelectionActions() {
        showSelectionMenu(view: self, presenter: selectionMenu, theme: selectionTheme?() ?? .day, context: selectionContext?(), action: onSelectionAction, annotation: annotationSelection?(), annotate: onAnnotationAction, position: listeningPosition?(), listen: onListen)
    }
}

final class ReaderPDFView: PDFView {
    private let selectionMenu = ReaderSelectionMenuPresenter()
    var isHandlingNativeSelectionGesture: Bool { selectionMenu.isHandlingNativeSelectionGesture }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { selectionMenu.detach() }
        else {
            selectionMenu.observeSelection(on: self) { [weak self] in
                guard !Task.isCancelled, let self, self.window != nil else { return }
                self.showSelectionActions()
            }
        }
    }
    var selectionTheme: (() -> ReadingTheme)?
    var listeningPosition: (() -> String?)?
    var onListen: ((String) -> Void)?
    var selectionContext: (() -> ReadingChatContext?)?
    var onSelectionAction: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?
    var annotationSelection: (() -> BookAnnotationSelection?)?
    var onAnnotationAction: ((ReaderAnnotationIntent, BookAnnotationSelection) -> Void)?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        #if DEBUG
        readerSelectionMenuTrace(selectionMenu.showsSystemMenu ? "systemBuild" : "build", source: self, context: selectionContext?()?.isEmpty == false)
        #endif
        if selectionMenu.showsSystemMenu {
            #if DEBUG
            readerSelectionMenuTrace("systemHasDefaultItems", source: self, context: builder.menu(for: .root)?.children.isEmpty == false)
            readerSelectionMenuTrace("systemCanCopy", source: self, context: selectionFirstResponder?.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil) == true)
            #endif
            return
        }
        if selectionMenu.usesExpandedMenu {
            builder.replaceChildren(ofMenu: .root) { _ in [] }; return
        }
        // Menu hierarchies are cached. The handler snapshots the current selection
        // when invoked, including accessibility and keyboard edit-menu requests.
        let action = UIAction(title: "Leaf actions", image: UIImage(systemName: "leaf")) { [weak self] _ in self?.selectionMenu.requestCurrentMenu() }
        builder.insertChild(UIMenu(options: .displayInline, children: [action]), atStartOfMenu: .root)
    }
    private func showSelectionActions() {
        showSelectionMenu(view: self, presenter: selectionMenu, theme: selectionTheme?() ?? .day, context: selectionContext?(), action: onSelectionAction, annotation: annotationSelection?(), annotate: onAnnotationAction, position: listeningPosition?(), listen: onListen)
    }
}


#if DEBUG
private let selectionMenuTraceQueue = DispatchQueue(label: "Leaf.SelectionMenuTrace", qos: .utility)
@MainActor private var selectionMenuTraceStarted = false
/// Bounded, boolean-only UI-test evidence. No book text, quotes, CFIs, or credentials.
@MainActor func readerSelectionMenuTrace(_ event: String, source: UIView?, context: Bool? = nil, point: CGPoint? = nil, target: UIView? = nil, duration: TimeInterval? = nil, distance: CGFloat? = nil) {
    guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
          let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
    let url = cache.appendingPathComponent("SelectionMenuUITestTrace.json")
    let reset = !selectionMenuTraceStarted; selectionMenuTraceStarted = true
    let input = source?.selectionFirstResponder as? UITextInput
    var row: [String: Any] = ["event": event, "time": ProcessInfo.processInfo.systemUptime,
        "sourceKey": source?.window?.isKeyWindow ?? false, "hasInputResponder": input != nil,
        "hasNativeRange": input?.selectedTextRange != nil, "nativeRangeEmpty": input?.selectedTextRange?.isEmpty ?? true, "nativeEditInteraction": source?.selectionEditMenu != nil,
        "legacyMenuVisible": UIMenuController.shared.isMenuVisible,
        "visibleMenuWindow": source?.window?.windowScene?.windows.contains(where: { $0 is ReaderSelectionWindow && !$0.isHidden }) ?? false]
    if let source {
        if let pdf = source as? PDFView, let page = pdf.currentPage, let document = pdf.document {
            row["pdfPage"] = document.index(for: page)
        }
        row["deviceOrientation"] = UIDevice.current.orientation.rawValue
        if let scene = source.window?.windowScene {
            row["interfaceOrientation"] = scene.effectiveGeometry.interfaceOrientation.rawValue
            let sceneBounds: CGRect
            if #available(iOS 26, *) { sceneBounds = scene.effectiveGeometry.coordinateSpace.bounds }
            else { sceneBounds = scene.coordinateSpace.bounds }
            row["sceneWidth"] = sceneBounds.width; row["sceneHeight"] = sceneBounds.height
            row["windows"] = scene.windows.prefix(8).map { window in
                var controller = window.rootViewController
                var masks: [UInt] = [], types: [String] = []
                while let current = controller, masks.count < 8 {
                    masks.append(current.supportedInterfaceOrientations.rawValue)
                    types.append(String(describing: type(of: current)))
                    controller = current.presentedViewController
                }
                return ["key": window.isKeyWindow, "hidden": window.isHidden, "width": window.bounds.width,
                        "height": window.bounds.height, "controllerMasks": masks, "controllerTypes": types] as [String: Any]
            }
        }
        row["nativeHandles"] = source.nativeSelectionHandleViews.prefix(2).map { handle in
            let rect = source.convert(handle.bounds, from: handle)
            return ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height, "direction": CGFloat(handle.direction.rawValue)]
        }
        row["selectionRects"] = source.selectionRectangles.prefix(8).map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
    }
    if let context { row["context"] = context }
    if let duration { row["touchDuration"] = duration }
    if let distance { row["touchDistance"] = distance }
    if let point { row["x"] = point.x; row["y"] = point.y }
    if let target { row["touchView"] = String(describing: type(of: target)); row["touchInBook"] = source.map { target.isDescendant(of: $0) } ?? false }
    guard let record = try? JSONSerialization.data(withJSONObject: row) else { return }
    selectionMenuTraceQueue.async {
        guard let row = try? JSONSerialization.jsonObject(with: record) as? [String: Any] else { return }
        var rows = reset ? [] : ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? [])
        rows.append(row)
        if rows.count > 80 { rows.removeFirst(rows.count - 80) }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}
#endif
