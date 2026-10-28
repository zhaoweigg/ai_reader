#if DEBUG
import SwiftUI
import UIKit

/// What the reader saw at its last book touch, and where those native
/// scroll views are now. Read lazily by the slow-slide tap test only.
@MainActor enum ReaderScrollTouchTrace {
    private final class Entry {
        weak var scroll: UIScrollView?
        let summary: String
        init(_ scroll: UIScrollView, _ summary: String) { self.scroll = scroll; self.summary = summary }
    }
    private static var entries: [Entry] = []
    private static var accepted = "none"

    static func record(_ scrolls: [UIScrollView], accepted: Bool, coastAge: (UIScrollView) -> TimeInterval?) {
        guard UITesting.flag("LEAF_UI_SCROLL_TOUCH_TRACE") else { return }
        self.accepted = accepted ? "tap" : "stop"
        entries = scrolls.map { scroll in
            var animating = false
            if #available(iOS 17.4, *) { animating = scroll.isScrollAnimating }
            let age = coastAge(scroll).map { String(format: "%.3f", $0) } ?? "null"
            return Entry(scroll, "\"coastAge\":\(age),\"type\":\"\(type(of: scroll))\",\"dragging\":\(scroll.isDragging),\"tracking\":\(scroll.isTracking),\"decelerating\":\(scroll.isDecelerating),\"animating\":\(animating),\"offset\":\(scroll.contentOffset.y),\"height\":\(scroll.bounds.height),\"contentHeight\":\(scroll.contentSize.height)")
        }
    }

    static var json: String {
        let views = entries.map { entry in "{\(entry.summary),\"now\":\(entry.scroll?.contentOffset.y ?? -1)}" }
        return "{\"result\":\"\(accepted)\",\"views\":[\(views.joined(separator: ","))]}"
    }
}

struct UITestScrollTouchProbe: UIViewRepresentable {
    final class Probe: UIView {
        override var accessibilityValue: String? { get { ReaderScrollTouchTrace.json } set {} }
    }
    func makeUIView(context: Context) -> UIView {
        let view = Probe()
        view.isUserInteractionEnabled = false
        if UITesting.flag("LEAF_UI_SCROLL_TOUCH_TRACE") {
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "uitestScrollTouch"
            view.accessibilityLabel = "Scroll touch trace"
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
