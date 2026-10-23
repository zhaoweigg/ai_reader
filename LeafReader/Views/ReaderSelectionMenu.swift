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
    let responder = view.selectionFirstResponder ?? view
    actions.append(ReaderSelectionAction(title: "Copy", image: "doc.on.doc", id: "copy") { [weak responder] in
        responder?.perform(#selector(UIResponderStandardEditActions.copy(_:)), with: nil)
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

@MainActor private final class ReaderSelectionMenuPresenter: NSObject, UIPopoverPresentationControllerDelegate {
    private weak var view: UIView?
    private weak var controller: ReaderSelectionActionsController?
    private var systemMenuUntil = Date.distantPast
    var showsSystemMenu: Bool { Date() < systemMenuUntil }
    func schedule(on view: UIView, actions: [ReaderSelectionAction], theme: ReadingTheme, selectedText: String) {
        self.view = view
        if let controller { controller.actions = actions; controller.tableView.accessibilityValue = selectedText; controller.tableView.reloadData(); return }
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, view.window != nil, self.controller == nil,
                  var parent = view.window?.rootViewController else { return }
            while let next = parent.presentedViewController { parent = next }
            guard !parent.isBeingDismissed else { return }
            let controller = ReaderSelectionActionsController(actions: actions, theme: theme)
            controller.tableView.accessibilityValue = selectedText
            controller.modalPresentationStyle = .popover
            controller.preferredContentSize = CGSize(width: 260, height: CGFloat(actions.count) * 44)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = view; popover.sourceRect = view.selectionAnchor
                popover.permittedArrowDirections = [.up, .down]; popover.delegate = self
                popover.backgroundColor = UIColor(theme.surface)
            }
            self.controller = controller
            parent.present(controller, animated: true)
        }
    }
    func presentSystemMenu() {
        guard let view else { return }
        systemMenuUntil = Date().addingTimeInterval(2)
        let rect = view.selectionAnchor
        view.selectionEditMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY)))
    }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}

@MainActor private final class ReaderSelectionActionsController: UITableViewController {
    var actions: [ReaderSelectionAction]
    private let theme: ReadingTheme
    init(actions: [ReaderSelectionAction], theme: ReadingTheme) { self.actions = actions; self.theme = theme; super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor(theme.surface)
        tableView.rowHeight = 44; tableView.estimatedRowHeight = 44
        tableView.separatorColor = UIColor(theme.foreground).withAlphaComponent(0.1)
        tableView.accessibilityIdentifier = "expandedSelectionMenu"
        tableView.contentInsetAdjustmentBehavior = .never
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { actions.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let action = actions[indexPath.row], cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = action.title; config.image = UIImage(systemName: action.image); config.imagePadding = 12
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        config.baseForegroundColor = UIColor(theme.foreground)
        button.configuration = config; button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "selection-" + action.id
        button.addAction(UIAction { [weak self] _ in self?.choose(indexPath.row) }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(button)
        NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor), button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor), button.topAnchor.constraint(equalTo: cell.contentView.topAnchor), button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)])
        cell.backgroundColor = UIColor(theme.surface); cell.isAccessibilityElement = false
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        choose(indexPath.row)
    }
    private func choose(_ index: Int) {
        let action = actions[index].perform
        dismiss(animated: true, completion: action)
    }
}

final class ReaderWebView: WKWebView {
    private let selectionMenu = ReaderSelectionMenuPresenter()
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
