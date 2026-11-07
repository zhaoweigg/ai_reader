import SwiftUI
import UIKit

#if DEBUG
/// Read through accessibility by the focused swipe test; never publishes view state.
enum ChatTextWork {
    static var updates = 0
    static var formats = 0
    static var measurements = 0
    static var enabled: Bool { UITesting.flag("LEAF_UI_CHAT_SCROLL_PERF") }
}
#endif

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
        let view = SelectableChatTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        let coordinator = context.coordinator
        view.onSelectionEnd = { [weak view, weak coordinator] in
            guard let view else { return }
            coordinator?.endSelection(in: view)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        #if DEBUG
        if ChatTextWork.enabled { ChatTextWork.updates += 1 }
        #endif
        view.accessibilityIdentifier = identifier
        view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        view.tintColor = UIColor(tint)
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.update(source: text, markdown: markdown, traits: view.traitCollection, in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return context.coordinator.fittedSize(width: width, in: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.reportSelection(false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        static let fullWidthLength = 120
        var onSelectionChange: (Bool) -> Void = { _ in }
        private var latest = NSAttributedString()
        private var source: String?
        private var markdown = false
        private var traits: UITraitCollection?
        private var naturalWidth: CGFloat?
        private var sizes: [(width: CGFloat, size: CGSize)] = []
        private var hasSelection = false
        private var applying = false
        #if DEBUG
        private(set) var formatCount = 0
        private(set) var measurementCount = 0
        #endif

        func update(source: String, markdown: Bool, traits: UITraitCollection, in view: UITextView) {
            // Scroll/focus changes frequently update the representable. Parsing
            // unchanged Markdown here puts work directly on the gesture's frames.
            guard self.source != source || self.markdown != markdown || self.traits?.isEqual(traits) != true else { return }
            self.source = source; self.markdown = markdown; self.traits = traits
            #if DEBUG
            formatCount += 1
            if ChatTextWork.enabled { ChatTextWork.formats += 1 }
            #endif
            update(ChatMarkdown.selectableText(source, markdown: markdown, traits: traits), in: view)
        }

        func update(_ text: NSAttributedString, in view: UITextView) {
            latest = text
            // Streaming must not replace the text storage under selection handles.
            if !hasSelection { applyLatest(in: view) }
        }

        func fittedSize(width: CGFloat, in view: UITextView) -> CGSize {
            if let cached = sizes.first(where: { $0.width == width }) { return cached.size }
            #if DEBUG
            measurementCount += 1
            if ChatTextWork.enabled { ChatTextWork.measurements += 1 }
            #endif
            if naturalWidth == nil {
                let text: NSAttributedString = view.attributedText
                // Only a short single line can be narrower than the column. Measuring a long
                // reply's one-line extent laid the whole text out a second time per update.
                if text.length > Self.fullWidthLength || text.string.contains("\n") { naturalWidth = .greatestFiniteMagnitude }
                else {
                    let natural = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    naturalWidth = ceil(natural.width) + 1
                }
            }
            let fittedWidth = min(width, naturalWidth ?? width)
            let measured = view.sizeThatFits(CGSize(width: fittedWidth, height: .greatestFiniteMagnitude))
            let size = CGSize(width: fittedWidth, height: ceil(measured.height))
            // Bound each visible message's cache, including rotation/layout probes.
            if sizes.count == 4 { sizes.removeFirst() }
            sizes.append((width, size))
            return size
        }

        private func applyLatest(in view: UITextView) {
            guard !view.attributedText.isEqual(to: latest) else { return }
            applying = true
            view.attributedText = latest
            view.accessibilityLabel = latest.string
            naturalWidth = nil
            sizes.removeAll(keepingCapacity: true)
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

        func textViewDidEndEditing(_ textView: UITextView) { endSelection(in: textView) }

        func endSelection(in textView: UITextView) {
            applying = true
            textView.selectedRange = NSRange(location: 0, length: 0)
            applying = false
            reportSelection(false)
            applyLatest(in: textView)
        }
    }
}

final class SelectableChatTextView: UITextView {
    var onSelectionEnd: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // A selectable, non-editable view can become first responder without
        // beginning editing, so UITextViewDelegate.didEndEditing is insufficient.
        if resigned { onSelectionEnd?() }
        return resigned
    }
}
