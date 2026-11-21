import SwiftUI
import UIKit

/// The chat history is one conversation the reader scrolls through. This brings older
/// messages in as they scroll back (and newer ones on the way down again, after a long
/// trip back let them go), and keeps what is on screen where it is while rows join or
/// leave above it.
///
/// A scroll view keeps its offset from the top when its content changes, so rows added
/// above would push the text being read down by their height. The scroll view underneath
/// reports its new content height during layout, before anything is drawn; moving the
/// offset by the same amount there leaves every visible row in place, under a finger
/// and during a coast alike.
struct ChatHistoryWindow: UIViewRepresentable {
    struct Actions {
        var loadEarlier: () -> Bool
        var loadNewer: () -> Bool
        var releaseNewest: () -> Bool
        var releaseOldest: () -> Bool
    }
    /// Lets a control in the history ask for a step by hand, with the same anchoring.
    @MainActor final class Handle {
        fileprivate weak var probe: Probe?
        nonisolated init() {}
        /// Loads older messages. False when no scroll view is watched, so the caller loads them itself.
        func loadEarlier() -> Bool {
            guard let probe, probe.isAttached else { return false }
            probe.loadEarlierByHand(); return true
        }
    }
    let handle: Handle
    let hasEarlier: Bool
    let hasNewer: Bool
    let actions: Actions

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false; view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        handle.probe = view
        view.hasEarlier = hasEarlier; view.hasNewer = hasNewer; view.actions = actions
        view.attach(); view.scheduleCheck()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView {
        var hasEarlier = false, hasNewer = false
        var actions: Actions?
        private weak var scroll: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        /// Rows are joining or leaving above the reader: when the content height changes,
        /// the offset changes with it.
        private var anchorsTop = false
        /// One change at a time; the next waits until this one has been laid out.
        private var busy = false
        private var settle: Task<Void, Never>?
        private var checkScheduled = false
        /// Nothing loads until the reader has moved the history themselves, so opening a
        /// conversation costs one page however long it is.
        private var moved = false
        /// The offset just set for rows above, and the one it replaced. A layout pass that
        /// puts the old one back is corrected once.
        private var held: (offset: CGFloat, replaced: CGFloat)?

        var isAttached: Bool { scroll != nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }
        func attach() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let found = ancestor as? UIScrollView, found !== scroll else { return }
            detach(); scroll = found
            observations = [
                found.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                    guard let old = change.oldValue?.height, let new = change.newValue?.height, abs(new - old) > 0.5 else { return }
                    MainActor.assumeIsolated { self?.heightChanged(from: old, to: new) }
                },
                found.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
                    guard let new = change.newValue?.y, change.oldValue?.y != new else { return }
                    MainActor.assumeIsolated { self?.offsetChanged(to: new) }
                }
            ]
        }
        func detach() {
            observations.forEach { $0.invalidate() }; observations = []
            settle?.cancel(); settle = nil
            scroll = nil; busy = false; anchorsTop = false; held = nil; moved = false
        }

        private func heightChanged(from old: CGFloat, to new: CGFloat) {
            guard let scroll else { return }
            if anchorsTop {
                let top = -scroll.adjustedContentInset.top
                let end = max(top, new + scroll.adjustedContentInset.bottom - scroll.bounds.height)
                let before = scroll.contentOffset.y, offset = min(end, max(top, before + new - old))
                if abs(offset - before) > 0.01 {
                    held = (offset, before)
                    // Assigning the offset moves the content without ending a coast.
                    scroll.contentOffset.y = offset
                    DispatchQueue.main.async { [weak self] in self?.held = nil }
                }
            }
            if busy { finish() }
        }
        private func offsetChanged(to y: CGFloat) {
            guard let scroll else { return }
            if let held, abs(y - held.replaced) < 0.5, abs(y - held.offset) > 0.5, !scroll.isTracking {
                self.held = nil
                scroll.contentOffset.y = held.offset
                return
            }
            if scroll.isTracking || scroll.isDragging || scroll.isDecelerating { moved = true }
            scheduleCheck()
        }
        private func finish() {
            settle?.cancel(); settle = nil
            anchorsTop = false; busy = false
            scheduleCheck()
        }
        func scheduleCheck() {
            guard !checkScheduled, scroll != nil else { return }
            checkScheduled = true
            // Not inside the scroll view's own callback or SwiftUI's layout pass.
            DispatchQueue.main.async { [weak self] in self?.check() }
        }
        func loadEarlierByHand() {
            moved = true
            guard !busy, let actions else { return }
            perform(anchoringTop: true, actions.loadEarlier)
        }

        private func check() {
            checkScheduled = false
            guard let scroll, let actions, moved, !busy, window != nil, scroll.bounds.height > 40 else { return }
            let above = scroll.contentOffset.y + scroll.adjustedContentInset.top
            let below = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y - scroll.bounds.height
            // A viewport ahead of the reader, so rows are in place before they come into view.
            let reach = min(600, max(240, scroll.bounds.height))
            if hasEarlier, above < reach {
                // Room first, at the far end; the older messages follow once that is laid out.
                if !perform(anchoringTop: false, actions.releaseNewest) { perform(anchoringTop: true, actions.loadEarlier) }
            } else if hasNewer, below < reach {
                if !perform(anchoringTop: true, actions.releaseOldest) { perform(anchoringTop: false, actions.loadNewer) }
            }
        }
        @discardableResult private func perform(anchoringTop: Bool, _ change: () -> Bool) -> Bool {
            anchorsTop = anchoringTop
            guard change() else { anchorsTop = false; return false }
            busy = true
            // Content shorter than its viewport does not change height; do not wait for it.
            settle?.cancel()
            settle = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.finish()
            }
            return true
        }
    }
}
