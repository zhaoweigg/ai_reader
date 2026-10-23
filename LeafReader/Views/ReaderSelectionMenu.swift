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

@MainActor private func addSelectionMenu(to builder: UIMenuBuilder, view: UIView, presenter: ReaderSelectionMenuPresenter, theme: ReadingTheme, context: ReadingChatContext?, action: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?, annotation: BookAnnotationSelection?, annotate: ((ReaderAnnotationIntent, BookAnnotationSelection) -> Void)?, position: String?, listen: ((String) -> Void)?) {
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
    // UIKit's edit toolbar paginates long labels horizontally. Keep its native
    // selection handles, and present Leaf's actions in a fully labelled list.
    builder.replaceChildren(ofMenu: .root) { _ in [] }
    presenter.schedule(on: view, actions: actions, theme: theme, selectedText: context.text)
}

private extension UIView {
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
    var selectionAnchor: CGRect {
        var rect = CGRect.null
        if let pdf = self as? PDFView, let selection = pdf.currentSelection,
           let page = selection.pages.first { rect = pdf.convert(selection.bounds(for: page), from: page) }
        else if let input = selectionFirstResponder as? (UIView & UITextInput), let range = input.selectedTextRange,
                let first = input.selectionRects(for: range).first { rect = convert(first.rect, from: input) }
        let clipped = rect.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1) : clipped
    }
}

private struct ReaderSelectionAction {
    let title: String
    let image: String
    let id: String
    let perform: () -> Void
}

@MainActor private final class ReaderSelectionMenuPresenter: NSObject, UIGestureRecognizerDelegate {
    private weak var source: UIView?
    private weak var window: UIWindow?
    private var controller: ReaderSelectionActionsController?
    private var menuWindow: ReaderSelectionWindow?
    private var observers: [UIGestureRecognizer] = []
    private var deactivationObserver: NSObjectProtocol?
    private var systemMenuUntil = Date.distantPast
    var showsSystemMenu: Bool { Date() < systemMenuUntil }
    func schedule(on source: UIView, actions: [ReaderSelectionAction], theme: ReadingTheme, selectedText: String) {
        self.source = source
        if let controller { controller.actions = actions; controller.tableView.accessibilityValue = selectedText; controller.tableView.reloadData(); controller.view.setNeedsLayout(); return }
        DispatchQueue.main.async { [weak self, weak source] in
            guard let self, let source, let window = source.window, let scene = window.windowScene, self.controller == nil else { return }
            let controller = ReaderSelectionActionsController(actions: actions, theme: theme, source: source)
            controller.choose = { [weak self] action in self?.dismiss(); action() }
            // Give UIKit its own root controller without presenting a modal or
            // taking key-window status from the book/composer's native responder.
            let menuWindow = ReaderSelectionWindow(windowScene: scene)
            menuWindow.backgroundColor = .clear; menuWindow.windowLevel = window.windowLevel + 1
            menuWindow.rootViewController = controller
            menuWindow.isHidden = false
            self.menuWindow = menuWindow
            controller.tableView.accessibilityValue = selectedText
            self.controller = controller; self.window = window
            self.deactivationObserver = NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
            // A modal popover consumes the first outside tap and can resign the
            // native selection responder. Observe dismissal without intercepting
            // the book, composer, keyboard, or draggable chat launcher underneath.
            let tap = UITapGestureRecognizer(target: self, action: #selector(self.outsideGesture(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.outsideGesture(_:)))
            self.observers = [tap, pan]
            for observer in self.observers {
                observer.cancelsTouchesInView = false; observer.delaysTouchesEnded = false
                observer.delegate = self; window.addGestureRecognizer(observer)
            }
        }
    }
    func dismiss() {
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }; deactivationObserver = nil
        for observer in observers { window?.removeGestureRecognizer(observer) }
        observers = []; window = nil
        menuWindow?.isHidden = true; menuWindow?.rootViewController = nil; menuWindow = nil
        controller = nil
    }
    @objc private func outsideGesture(_ gesture: UIGestureRecognizer) {
        if gesture.state == .ended || gesture.state == .began { dismiss() }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let controller, let view = touch.view else { return false }
        return !view.isDescendant(of: controller.view)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func presentSystemMenu() {
        guard let source else { return }
        systemMenuUntil = Date().addingTimeInterval(2)
        let rect = source.selectionAnchor
        source.selectionEditMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY)))
    }
}

private final class ReaderSelectionWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let root = rootViewController?.view else { return nil }
        return root.hitTest(convert(point, to: root), with: event)
    }
}

private final class ReaderSelectionOverlayView: UIView {
    let card = UIView()
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let local = convert(point, to: card)
        return card.bounds.contains(local) ? card.hitTest(local, with: event) : nil
    }
}

@MainActor private final class ReaderSelectionActionsController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var actions: [ReaderSelectionAction]
    var choose: ((() -> Void) -> Void)?
    let tableView = UITableView(frame: .zero, style: .plain)
    private let theme: ReadingTheme
    private weak var source: UIView?
    init(actions: [ReaderSelectionAction], theme: ReadingTheme, source: UIView) {
        self.actions = actions; self.theme = theme; self.source = source; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = ReaderSelectionOverlayView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let overlay = view as! ReaderSelectionOverlayView
        overlay.addSubview(overlay.card); overlay.card.addSubview(tableView)
        overlay.card.layer.shadowColor = UIColor.black.cgColor; overlay.card.layer.shadowOpacity = 0.18
        overlay.card.layer.shadowRadius = 18; overlay.card.layer.shadowOffset = CGSize(width: 0, height: 5)
        tableView.backgroundColor = UIColor(theme.surface); tableView.layer.cornerRadius = 18
        tableView.dataSource = self; tableView.delegate = self
        tableView.rowHeight = 44; tableView.estimatedRowHeight = 44
        tableView.separatorColor = UIColor(theme.foreground).withAlphaComponent(0.1)
        tableView.accessibilityIdentifier = "expandedSelectionMenu"
        tableView.contentInsetAdjustmentBehavior = .never
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let source, let overlay = view as? ReaderSelectionOverlayView else { return }
        let safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 12, dy: 8)
        let anchor = source.convert(source.selectionAnchor, to: view)
        let width = min(260, safe.width), height = min(CGFloat(actions.count) * 44, safe.height)
        let below = anchor.maxY + 10
        let top = below + height <= safe.maxY ? below : anchor.minY - height - 10
        overlay.card.frame = CGRect(x: min(max(safe.minX, anchor.midX - width / 2), safe.maxX - width),
            y: min(max(safe.minY, top), safe.maxY - height), width: width, height: height)
        tableView.frame = overlay.card.bounds
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { actions.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let action = actions[indexPath.row], cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = action.title; config.image = UIImage(systemName: action.image); config.imagePadding = 12
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        config.baseForegroundColor = UIColor(theme.foreground)
        button.configuration = config; button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "selection-" + action.id
        button.addAction(UIAction { [weak self] _ in self?.chooseAction(indexPath.row) }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(button)
        NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor), button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor), button.topAnchor.constraint(equalTo: cell.contentView.topAnchor), button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)])
        cell.backgroundColor = UIColor(theme.surface); cell.isAccessibilityElement = false
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { chooseAction(indexPath.row) }
    private func chooseAction(_ index: Int) { choose?(actions[index].perform) }
}

final class ReaderWebView: WKWebView {
    private let selectionMenu = ReaderSelectionMenuPresenter()
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { selectionMenu.dismiss() } }
    var selectionTheme: (() -> ReadingTheme)?
    var listeningPosition: (() -> String?)?
    var onListen: ((String) -> Void)?
    var selectionContext: (() -> ReadingChatContext?)?
    var onSelectionAction: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?
    var annotationSelection: (() -> BookAnnotationSelection?)?
    var onAnnotationAction: ((ReaderAnnotationIntent, BookAnnotationSelection) -> Void)?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        addSelectionMenu(to: builder, view: self, presenter: selectionMenu, theme: selectionTheme?() ?? .day, context: selectionContext?(), action: onSelectionAction, annotation: annotationSelection?(), annotate: onAnnotationAction, position: listeningPosition?(), listen: onListen)
    }
}

final class ReaderPDFView: PDFView {
    private let selectionMenu = ReaderSelectionMenuPresenter()
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { selectionMenu.dismiss() } }
    var selectionTheme: (() -> ReadingTheme)?
    var listeningPosition: (() -> String?)?
    var onListen: ((String) -> Void)?
    var selectionContext: (() -> ReadingChatContext?)?
    var onSelectionAction: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?
    var annotationSelection: (() -> BookAnnotationSelection?)?
    var onAnnotationAction: ((ReaderAnnotationIntent, BookAnnotationSelection) -> Void)?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        addSelectionMenu(to: builder, view: self, presenter: selectionMenu, theme: selectionTheme?() ?? .day, context: selectionContext?(), action: onSelectionAction, annotation: annotationSelection?(), annotate: onAnnotationAction, position: listeningPosition?(), listen: onListen)
    }
}
