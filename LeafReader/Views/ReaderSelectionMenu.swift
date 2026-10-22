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

@MainActor private func addSelectionMenu(to builder: UIMenuBuilder, context: ReadingChatContext?, action: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?) {
    guard let context, !context.isEmpty, let action else { return }
    let group = UIMenu.Identifier("com.leafreader.selection")
    builder.remove(menu: group)
    let ask = UIAction(title: "Ask Leaf", image: UIImage(systemName: "leaf")) { _ in action(.ask, context) }
    builder.insertChild(UIMenu(title: "", identifier: group, options: .displayInline, children: [ask]), atStartOfMenu: .root)
}

final class ReaderWebView: WKWebView {
    var selectionContext: (() -> ReadingChatContext?)?
    var onSelectionAction: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        addSelectionMenu(to: builder, context: selectionContext?(), action: onSelectionAction)
    }
}

final class ReaderPDFView: PDFView {
    var selectionContext: (() -> ReadingChatContext?)?
    var onSelectionAction: ((ReaderSelectionIntent, ReadingChatContext) -> Void)?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        addSelectionMenu(to: builder, context: selectionContext?(), action: onSelectionAction)
    }
}
