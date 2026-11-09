import SwiftUI

// How the chat history follows a streaming reply, pauses for the reader's own
// scrolling, and how tall the panel may be. The panel itself is ReaderChatPanel.

struct ChatScrollFollowing: Equatable {
    private(set) var followsLatest = true
    private var dragging = false
    private var atBottom = true

    /// The reader's finger or momentum is moving the history.
    var isScrolling: Bool { dragging }

    mutating func beginDragging() { dragging = true; followsLatest = false }
    mutating func endDragging() { dragging = false; followsLatest = atBottom }
    mutating func updateBottomDistance(_ distance: CGFloat) {
        updateAtBottom(distance <= 4)
    }
    mutating func updateAtBottom(_ atBottom: Bool) {
        self.atBottom = atBottom
        // Appending text can move the bottom away. Only a user drag pauses
        // following; reaching the bottom again resumes it, including momentum.
        if !dragging, atBottom { followsLatest = true }
    }
    mutating func resume() { followsLatest = true }
}

struct ChatHistoryAtBottom: PreferenceKey {
    static var defaultValue: Bool? = nil
    static func reduce(value: inout Bool?, nextValue: () -> Bool?) { value = nextValue() ?? value }
}

enum ReaderChatSizing {
    static let dockedReadingFraction = 0.36
    static func bounds(fullHeight: CGFloat, availableHeight: CGFloat, composing: Bool, hasSelection: Bool, hasStatus: Bool = false) -> ClosedRange<CGFloat> {
        let usable = max(0, availableHeight - 16)
        // Leave actual book text above an expanded portrait composer, rather
        // than just the status area or the chapter's top whitespace.
        let bookReserve = composing && fullHeight >= 500 ? min(220, fullHeight * 0.26, max(0, usable - 176)) : 0
        let maximum = min(fullHeight * 0.85, usable * 0.88, max(0, usable - bookReserve))
        // A stopped reply's notice and Retry row must not consume every
        // message line in a compact landscape panel.
        let minimum: CGFloat = composing ? (fullHeight < 500 ? 176 : (hasSelection ? 256 : 224)) : (fullHeight < 500 ? (hasStatus ? 176 : 132) : (hasSelection ? 260 : 200))
        let lower = min(minimum, maximum)
        return lower...maximum
    }
    static func height(fraction: Double, fullHeight: CGFloat, availableHeight: CGFloat, composing: Bool, hasSelection: Bool, hasStatus: Bool = false) -> CGFloat {
        let limits = bounds(fullHeight: fullHeight, availableHeight: availableHeight, composing: composing, hasSelection: hasSelection, hasStatus: hasStatus)
        let desired: CGFloat
        if composing, !fraction.isFinite || fraction <= 0 {
            desired = max(limits.lowerBound, min(fullHeight / 3, availableHeight * 0.5))
        } else { desired = fullHeight * CGFloat(fraction.isFinite && fraction > 0 ? fraction : 1.0 / 3) }
        return min(limits.upperBound, max(limits.lowerBound, desired))
    }
}

struct ChatHistoryFollowsLatest: ViewModifier {
    let following: Bool
    let paused: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18, *) { content.modifier(ChatHistoryFollowing(following: following, paused: paused)) }
        else { content }
    }
}

struct ChatHistoryInteraction: ViewModifier {
    @Binding var following: ChatScrollFollowing
    @GestureState private var dragging = false

    static var usesNativeTracking: Bool {
        guard #available(iOS 18, *) else { return false }
        #if DEBUG
        return !UITesting.flag(.chatScrollLegacy)
        #else
        return true
        #endif
    }

    func body(content: Content) -> some View {
        if #available(iOS 18, *), Self.usesNativeTracking {
            content
                // Only crossing the bottom threshold changes follow state.
                // Publishing every pixel invalidates the chat during the swipe.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height + geometry.contentInsets.bottom - geometry.contentOffset.y - geometry.containerSize.height <= 4
                } action: { _, atBottom in following.updateAtBottom(atBottom) }
                .onScrollPhaseChange { _, phase, context in
                    switch phase {
                    case .tracking, .interacting, .decelerating: following.beginDragging()
                    case .idle:
                        let geometry = context.geometry
                        following.updateBottomDistance(geometry.contentSize.height + geometry.contentInsets.bottom - geometry.contentOffset.y - geometry.containerSize.height)
                        following.endDragging()
                    case .animating: break
                    @unknown default: break
                    }
                }
        } else {
            content
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .updating($dragging) { _, dragging, _ in dragging = true })
                .onChange(of: dragging) { _, dragging in
                    // Let the final content-offset preference arrive first.
                    if dragging { following.beginDragging() }
                    else { DispatchQueue.main.async { following.endDragging() } }
                }
        }
    }
}

/// Keeps the newest line visible while following. A bottom-edge scroll
/// position stays pinned in the same layout pass as the reply grows, so the
/// history no longer trails a line behind, catches up in jumps, or overshoots
/// and snaps back. Growth re-pins it after the reader returns to the bottom
/// (a no-op while pinned). Not animated: a programmatic slide is read as the
/// reader scrolling, and re-pinning on that would feed back.
@available(iOS 18, *)
private struct ChatHistoryFollowing: ViewModifier {
    let following: Bool
    let paused: Bool
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var offset = Offset()

    /// Read only when pausing; publishing every pixel would invalidate the chat.
    private final class Offset { var y: CGFloat = 0 }

    private struct Extent: Equatable {
        var contentHeight: CGFloat
        var gap: CGFloat
        var container: CGFloat
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { [offset] _, y in offset.y = y }
            .onScrollGeometryChange(for: Extent.self) { geometry in
                Extent(contentHeight: geometry.contentSize.height,
                       gap: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.contentOffset.y - geometry.containerSize.height,
                       container: geometry.containerSize.height)
            } action: { old, new in
                // Only when growth left the newest line below the bottom: a pinned
                // history needs no change, and a collapsed panel has no bottom to follow.
                guard new.contentHeight > old.contentHeight + 0.5, new.gap > 1, new.container > 40, following, !paused else { return }
                position.scrollTo(edge: .bottom)
            }
            .onChange(of: paused) { _, paused in
                // Selected text must not move under its handles while the reply grows.
                if paused { position.scrollTo(y: offset.y) }
            }
    }
}
