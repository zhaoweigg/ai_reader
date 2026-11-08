import SwiftUI

#if DEBUG
// Geometry and rendering-work probes the chat UI tests read through accessibility.
// ReaderChatPanel bridges to them through ChatHistoryTestMeasurement; nothing here runs in Release.

struct ChatHistoryMeasuredOffset: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

struct ChatHistoryTestMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

struct ChatHistoryOffsetProbe: UIViewRepresentable {
    let value: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "uitestChatHistoryGeometry"
        view.accessibilityLabel = "UI test chat scroll offset"
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { view.accessibilityValue = value }
}

/// How the history moves while it follows a streaming reply, for the follow test.
final class ChatFollowTrace {
    private var last: ChatHistoryTestMetrics?
    private var samples = 0, maxBack: CGFloat = 0, maxStep: CGFloat = 0, maxGap: CGFloat = 0, events: [String] = []
    func record(_ metrics: ChatHistoryTestMetrics, following: Bool, streamingText: Bool) {
        defer { last = metrics }
        guard let last, following, streamingText else { return }
        let delta = metrics.offset - last.offset
        samples += 1
        if delta < 0 { maxBack = max(maxBack, -delta) } else { maxStep = max(maxStep, delta) }
        maxGap = max(maxGap, metrics.contentHeight - metrics.offset - metrics.viewportHeight)
        events.append(String(format: "%.1f/%.1f", metrics.offset, metrics.contentHeight))
        if events.count > 60 { events.removeFirst() }
    }
    var json: String {
        let gap = (last.map { $0.contentHeight - $0.offset - $0.viewportHeight }) ?? -1
        return "{\"samples\":\(samples),\"maxBack\":\(maxBack),\"maxStep\":\(maxStep),\"maxGap\":\(maxGap),\"gap\":\(gap),\"events\":\"\(events.joined(separator: " "))\"}"
    }
}

final class ChatSwipeMetrics {
    var geometry = ChatHistoryTestMetrics()
    var phase = "idle"
    var json: String {
        "{\"offset\":\(geometry.offset),\"contentHeight\":\(geometry.contentHeight),\"viewportHeight\":\(geometry.viewportHeight),\"phase\":\"\(phase)\",\"updates\":\(ChatTextWork.updates),\"formats\":\(ChatTextWork.formats),\"measurements\":\(ChatTextWork.measurements)}"
    }
}

struct ChatFollowProbe: UIViewRepresentable {
    let trace: ChatFollowTrace
    func makeUIView(context: Context) -> ChatSwipeProbe.Probe {
        let view = ChatSwipeProbe.Probe()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "uitestChatHistoryGeometry"
        view.accessibilityLabel = "Chat follow trace"
        return view
    }
    func updateUIView(_ view: ChatSwipeProbe.Probe, context: Context) { view.read = { trace.json } }
}

struct ChatSwipeProbe: UIViewRepresentable {
    let metrics: ChatSwipeMetrics
    final class Probe: UIView {
        var read: (() -> String)?
        override var accessibilityValue: String? { get { read?() } set {} }
    }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "uitestChatSwipeWork"
        view.accessibilityLabel = "Chat swipe work"
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.read = { metrics.json } }
}

struct ChatSwipeMeasurement: ViewModifier {
    @State private var metrics = ChatSwipeMetrics()
    func body(content: Content) -> some View {
        if #available(iOS 18, *), ChatTextWork.enabled {
            content.onScrollGeometryChange(for: ChatHistoryTestMetrics.self) { geometry in
                ChatHistoryTestMetrics(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                       viewportHeight: geometry.containerSize.height)
            } action: { _, value in metrics.geometry = value }
                .onScrollPhaseChange { _, phase in metrics.phase = String(describing: phase) }
                .overlay(alignment: .topLeading) {
                    ChatSwipeProbe(metrics: metrics).frame(width: 1, height: 1).allowsHitTesting(false)
                }
        } else { content }
    }
}
#endif
