import SwiftUI
import PDFKit

struct ReaderChatFrame: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

enum ReaderClearance {
    static func height(book: CGRect, chat: CGRect?) -> CGFloat {
        guard book.height > 0, let chat, book.intersects(chat) else { return 0 }
        // The panel's measured top includes its resize and keyboard position.
        return min(max(0, book.height - 44), max(0, book.maxY - chat.minY + 12))
    }
}

/// PDFKit owns layout and zoom. Only extend its native scroll range, never its
/// page bounds, so highlights, selected ranges and saved PDF locations stay valid.
@MainActor final class PDFReadingClearance {
    private weak var scroll: UIScrollView?
    private var baselineBottom: CGFloat = 0
    private var appliedBottom: CGFloat?
    private var amount: CGFloat = 0

    func apply(_ height: CGFloat, to view: PDFView) {
        func find(_ parent: UIView) -> UIScrollView? {
            for child in parent.subviews {
                if let scroll = child as? UIScrollView { return scroll }
                if let scroll = find(child) { return scroll }
            }
            return nil
        }
        guard let target = find(view) else { return }
        if scroll !== target {
            scroll = target; baselineBottom = target.contentInset.bottom; appliedBottom = nil; amount = 0
        } else if let appliedBottom, abs(target.contentInset.bottom - appliedBottom) > 0.5 {
            // PDFKit may recenter a short page after zoom or rotation.
            baselineBottom = target.contentInset.bottom
        }
        let next = min(max(0, view.bounds.height - 44), max(0, height.isFinite ? height : 0))
        let bottom = baselineBottom + next
        guard appliedBottom == nil || abs(target.contentInset.bottom - bottom) > 0.5 else { return }
        let oldMaximum = max(-target.adjustedContentInset.top,
            target.contentSize.height + target.adjustedContentInset.bottom - target.bounds.height)
        let followsEnd = amount > 0 && abs(target.contentOffset.y - oldMaximum) < 3
        var inset = target.contentInset; inset.bottom = bottom
        amount = next; appliedBottom = bottom
        target.contentInset = inset
        let maximum = max(-target.adjustedContentInset.top,
            target.contentSize.height + target.adjustedContentInset.bottom - target.bounds.height)
        let y = followsEnd ? maximum : min(target.contentOffset.y, maximum)
        if abs(y - target.contentOffset.y) > 0.5 { target.setContentOffset(CGPoint(x: target.contentOffset.x, y: y), animated: false) }
    }
}
