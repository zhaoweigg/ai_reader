import SwiftUI
import UIKit

/// A read-only text view gives chat the native range handles and Copy menu.
/// The surrounding SwiftUI history owns scrolling, including long replies.
struct SelectableChatText: UIViewRepresentable {
    let text: String
    let markdown: Bool
    let identifier: String
    var tint: Color = .accentColor
    var onSelectionChange: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.accessibilityIdentifier = identifier
        view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        view.tintColor = UIColor(tint)
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.update(ChatMarkdown.selectableText(text, markdown: markdown, traits: view.traitCollection), in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // Keep short user bubbles fitted to their text, as before. Long replies
        // take the available width and let the outer history scroll vertically.
        let natural = uiView.attributedText.boundingRect(with: CGSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let fittedWidth = min(width, ceil(natural.width) + 1)
        let size = uiView.sizeThatFits(CGSize(width: fittedWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: fittedWidth, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.reportSelection(false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelectionChange: (Bool) -> Void = { _ in }
        private var latest = NSAttributedString()
        private var hasSelection = false
        private var applying = false

        func update(_ text: NSAttributedString, in view: UITextView) {
            latest = text
            // Streaming must not replace the text storage under selection handles.
            if !hasSelection { applyLatest(in: view) }
        }

        private func applyLatest(in view: UITextView) {
            guard !view.attributedText.isEqual(to: latest) else { return }
            applying = true
            view.attributedText = latest
            view.accessibilityLabel = latest.string
            view.invalidateIntrinsicContentSize()
            applying = false
        }

        func reportSelection(_ selected: Bool) {
            guard selected != hasSelection else { return }
            hasSelection = selected
            let callback = onSelectionChange
            // UIKit can also notify while SwiftUI updates/dismantles its view.
            DispatchQueue.main.async { callback(selected) }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying else { return }
            reportSelection(textView.selectedRange.length > 0)
            if !hasSelection { applyLatest(in: textView) }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            reportSelection(false)
            applyLatest(in: textView)
        }
    }
}
