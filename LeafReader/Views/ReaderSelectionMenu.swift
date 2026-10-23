import UIKit
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
    actions.append(ReaderSelectionAction(title: "Copy", image: "doc.on.doc", id: "copy") { [weak responder] in
        if let copiedText { UIPasteboard.general.string = copiedText }
        else { responder?.perform(#selector(UIResponderStandardEditActions.copy(_:)), with: nil) }
    })
    actions.append(ReaderSelectionAction(title: "iOS text actions", image: "ellipsis", id: "system") { [weak presenter] in presenter?.presentSystemMenu() })
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
        for index in actions.indices { actions[index].testLocator = context.locator }
    }
    #endif
    presenter.schedule(on: view, actions: actions, theme: theme, selectedText: context.text)
}

private extension UIView {
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
    var selectionHandles: [CGRect] {
        let rects = selectionRectangles
        guard let first = rects.first, let last = rects.last else { return [] }
        // Native selection stems/knobs extend beyond the selected glyphs. Keep
        // the menu clear of both endpoints, including a multi-line selection.
        return [CGRect(x: first.minX - 18, y: first.minY - 24, width: 36, height: first.height + 36),
                CGRect(x: last.maxX - 18, y: last.minY - 12, width: 36, height: last.height + 36)]
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

@MainActor private final class ReaderSelectionMenuPresenter: NSObject, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    private weak var source: UIView?
    private weak var window: UIWindow?
    private var controller: ReaderSelectionActionsController?
    private var menuWindow: ReaderSelectionWindow?
    private var observers: [UIGestureRecognizer] = []
    private var deactivationObserver: NSObjectProtocol?
    private var systemMenuUntil = Date.distantPast
    private var systemInteraction: UIEditMenuInteraction?
    private var selectionPress: UILongPressGestureRecognizer?
    private var handleDrag: UIPanGestureRecognizer?
    private var requestMenu: (() async -> Void)?
    private var requestTask: Task<Void, Never>?
    private var revision = 0
    var showsSystemMenu: Bool { systemInteraction != nil || Date() < systemMenuUntil }
    var usesExpandedMenu: Bool { requestTask != nil || controller != nil }
    func observeSelection(on source: UIView, request: @escaping () async -> Void) {
        self.source = source; requestMenu = request
        guard selectionPress == nil else { return }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(selectionPressed(_:)))
        press.minimumPressDuration = 0.5; press.cancelsTouchesInView = false; press.delaysTouchesEnded = false
        press.delegate = self; source.addGestureRecognizer(press); selectionPress = press
        let drag = UIPanGestureRecognizer(target: self, action: #selector(selectionHandleDragged(_:)))
        drag.cancelsTouchesInView = false; drag.delaysTouchesEnded = false; drag.delegate = self
        source.addGestureRecognizer(drag); handleDrag = drag
        if let scene = source.window?.windowScene {
            deactivationObserver = NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
    }
    func detach() {
        dismiss()
        if let selectionPress { selectionPress.view?.removeGestureRecognizer(selectionPress) }
        if let handleDrag { handleDrag.view?.removeGestureRecognizer(handleDrag) }
        selectionPress = nil; handleDrag = nil; requestMenu = nil; source = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }; deactivationObserver = nil
    }
    func requestCurrentMenu() {
        guard let window = source?.window, window.windowScene?.activationState == .foregroundActive else { return }
        systemMenuUntil = .distantPast
        revision += 1; let expectedRevision = revision; requestTask?.cancel()
        installOutsideObservers(on: window)
        requestTask = Task { [weak self] in
            let request = self?.requestMenu
            await request?()
            guard let self, self.revision == expectedRevision else { return }
            self.requestTask = nil
            if self.controller == nil { self.removeOutsideObservers() }
        }
        UIMenuSystem.context.setNeedsRebuild()
    }
    @objc private func selectionPressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .ended, let source = press.view, !showsSystemMenu else { return }
        if source.selectionFirstResponder == nil { source.becomeFirstResponder() }
        let withinSelection = source.selectionContains(press.location(in: source))
        #if DEBUG
        readerSelectionMenuTrace("press", source: source, context: withinSelection)
        #endif
        guard withinSelection else { return }
        requestCurrentMenu()
    }
    @objc private func selectionHandleDragged(_ drag: UIPanGestureRecognizer) {
        if drag.state == .began { dismiss() }
        if drag.state == .ended {
            Task { @MainActor [weak self] in
                // Let the native text interaction commit its final range first.
                await Task.yield()
                self?.requestCurrentMenu()
            }
        }
    }
    func schedule(on source: UIView, actions: [ReaderSelectionAction], theme: ReadingTheme, selectedText: String) {
        guard !Task.isCancelled, let window = source.window, let scene = window.windowScene, scene.activationState == .foregroundActive else { return }
        self.source = source
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
    func dismiss() {
        if let interaction = systemInteraction {
            systemInteraction = nil; interaction.dismissMenu(); interaction.view?.removeInteraction(interaction)
        }
        systemMenuUntil = .distantPast
        revision += 1; requestTask?.cancel(); requestTask = nil
        #if DEBUG
        readerSelectionMenuTrace("dismiss", source: source)
        #endif
        removeOutsideObservers()
        menuWindow?.isHidden = true; menuWindow?.rootViewController = nil; menuWindow = nil
        controller = nil
        UIMenuSystem.context.setNeedsRebuild()
    }
    @objc private func outsideGesture(_ gesture: UIGestureRecognizer) {
        if gesture.state == .ended || gesture.state == .began { dismiss() }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === selectionPress || gestureRecognizer === handleDrag {
            guard let source else { return false }
            let point = touch.location(in: source)
            let onHandle = source.selectionHandles.contains { $0.contains(point) }
                && !source.selectionRectangles.contains { $0.contains(point) }
            // A second long press must not compete with UIKit's existing handle
            // interaction. A simultaneous pan only observes its completion.
            return gestureRecognizer === handleDrag ? onHandle : !onHandle
        }
        guard let view = touch.view else { return false }
        if let controller { return !view.isDescendant(of: controller.view) }
        return requestTask != nil
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

@MainActor private final class ReaderSelectionActionsController: UIViewController, UIScrollViewDelegate {
    private var actions: [ReaderSelectionAction]
    var choose: ((() -> Void) -> Void)?
    let scrollView = UIScrollView()
    private var buttons: [UIButton] = []
    private var dividers: [UIView] = []
    private let leadingHint = UIImageView(image: UIImage(systemName: "chevron.left"))
    private let trailingHint = UIImageView(image: UIImage(systemName: "chevron.right"))
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
        overlay.card.backgroundColor = UIColor(theme.surface); overlay.card.layer.cornerRadius = 14
        overlay.card.layer.shadowColor = UIColor.black.cgColor; overlay.card.layer.shadowOpacity = 0.16
        overlay.card.layer.shadowRadius = 12; overlay.card.layer.shadowOffset = CGSize(width: 0, height: 3)
        scrollView.delegate = self; scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true; scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "expandedSelectionMenu"
        scrollView.accessibilityLabel = "Selection actions"
        scrollView.accessibilityHint = "Swipe left or right for more actions."
        for hint in [leadingHint, trailingHint] {
            hint.tintColor = UIColor(theme.foreground).withAlphaComponent(0.55)
            hint.contentMode = .scaleAspectFit; hint.isUserInteractionEnabled = false
            hint.isAccessibilityElement = false; overlay.card.addSubview(hint)
        }
        rebuildButtons()
    }
    func update(actions: [ReaderSelectionAction], selectedText: String) {
        self.actions = actions; scrollView.accessibilityValue = selectedText
        rebuildButtons(); view.setNeedsLayout()
    }
    private func rebuildButtons() {
        for child in buttons.map({ $0 as UIView }) + dividers { child.removeFromSuperview() }
        buttons = []; dividers = []
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14, weight: .medium), maximumPointSize: 20)
        for (index, action) in actions.enumerated() {
            let button = UIButton(type: .system)
            let compact = action.id == "listen" ? "Listen" : action.id == "note" ? "Note" : action.id == "system" ? "More" : action.title
            button.setTitle(compact, for: .normal); button.setTitleColor(UIColor(theme.foreground), for: .normal)
            button.titleLabel?.font = font; button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.accessibilityLabel = action.title; button.accessibilityIdentifier = "selection-" + action.id
            #if DEBUG
            if action.id == "ask" { button.accessibilityValue = action.testLocator }
            #endif
            button.addAction(UIAction { [weak self] _ in
                guard let self, index < self.actions.count else { return }
                self.choose?(self.actions[index].perform)
            }, for: .touchUpInside)
            scrollView.addSubview(button); buttons.append(button)
            if index < actions.count - 1 {
                let line = UIView(); line.backgroundColor = UIColor(theme.foreground).withAlphaComponent(0.12)
                scrollView.addSubview(line); dividers.append(line)
            }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let source, let overlay = view as? ReaderSelectionOverlayView else { return }
        let safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 12, dy: 8)
        let anchor = source.convert(source.selectionAnchor, to: view)
        let handles = source.selectionHandles.map { source.convert($0, to: view) }
        let widths = buttons.map { max(44, ceil($0.intrinsicContentSize.width) + 20) }
        let contentWidth = widths.reduce(0, +) + CGFloat(max(0, buttons.count - 1))
        let height = max(44, ceil(buttons.first?.titleLabel?.font.lineHeight ?? 17) + 16)
        let width = min(contentWidth + 16, safe.width)
        let overflow = contentWidth + 16 > width
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
        let inset: CGFloat = overflow ? 18 : 8
        scrollView.frame = overlay.card.bounds.insetBy(dx: inset, dy: 0)
        var x: CGFloat = 0
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: x, y: 0, width: widths[index], height: height); x += widths[index]
            if index < dividers.count { dividers[index].frame = CGRect(x: x, y: 12, width: 1, height: height - 24); x += 1 }
        }
        scrollView.contentSize = CGSize(width: contentWidth, height: height)
        scrollView.contentOffset.x = min(max(0, scrollView.contentOffset.x), max(0, contentWidth - scrollView.bounds.width))
        leadingHint.frame = CGRect(x: 5, y: 16, width: 8, height: height - 32)
        trailingHint.frame = CGRect(x: width - 13, y: 16, width: 8, height: height - 32)
        updateScrollHints()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            // Geometry only, for real native handle drags; this does not create
            // a selection or intercept touches in the book.
            var markers: [UIAccessibilityElement] = []
            for (index, rect) in source.selectionRectangles.enumerated() where index == 0 || index == source.selectionRectangles.count - 1 {
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
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateScrollHints() }
    private func updateScrollHints() {
        leadingHint.isHidden = scrollView.contentOffset.x <= 1
        trailingHint.isHidden = scrollView.contentOffset.x + scrollView.bounds.width >= scrollView.contentSize.width - 1
    }
}

final class ReaderWebView: WKWebView {
    private let selectionMenu = ReaderSelectionMenuPresenter()
    var prepareSelection: (() async -> Void)?
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
@MainActor func readerSelectionMenuTrace(_ event: String, source: UIView?, context: Bool? = nil) {
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
    if let context { row["context"] = context }
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
