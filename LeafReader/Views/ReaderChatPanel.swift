import SwiftUI
import AVFoundation

struct ChatScrollFollowing: Equatable {
    private(set) var followsLatest = true
    private var dragging = false
    private var atBottom = true

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

private struct ChatHistoryAtBottom: PreferenceKey {
    static var defaultValue: Bool? = nil
    static func reduce(value: inout Bool?, nextValue: () -> Bool?) { value = nextValue() ?? value }
}

#if DEBUG
private struct ChatHistoryMeasuredOffset: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

private struct ChatHistoryTestMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

private struct ChatHistoryOffsetProbe: UIViewRepresentable {
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
private final class ChatFollowTrace {
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

private final class ChatSwipeMetrics {
    var geometry = ChatHistoryTestMetrics()
    var phase = "idle"
    var json: String {
        "{\"offset\":\(geometry.offset),\"contentHeight\":\(geometry.contentHeight),\"viewportHeight\":\(geometry.viewportHeight),\"phase\":\"\(phase)\",\"updates\":\(ChatTextWork.updates),\"formats\":\(ChatTextWork.formats),\"measurements\":\(ChatTextWork.measurements)}"
    }
}

private struct ChatFollowProbe: UIViewRepresentable {
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

private struct ChatSwipeProbe: UIViewRepresentable {
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

private struct ChatSwipeMeasurement: ViewModifier {
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

/// Native text views clip their accessibility bounds to the screen. UI tests
/// measure the independently laid-out history instead of those clipped bounds.
private struct ChatHistoryTestMeasurement: ViewModifier {
    let following: Bool
    let selected: Bool
    var streamingText = false
    #if DEBUG
    @State private var metrics = ChatHistoryTestMetrics()
    @State private var follow = ChatFollowTrace()
    private var probe: some View {
        ChatHistoryOffsetProbe(value: "{\"offset\":\(metrics.offset),\"contentHeight\":\(metrics.contentHeight),\"viewportHeight\":\(metrics.viewportHeight),\"following\":\(following),\"selected\":\(selected)}")
            .frame(width: 1, height: 1).allowsHitTesting(false)
    }
    #endif
    func body(content: Content) -> some View {
        #if DEBUG
        if UITesting.flag("LEAF_UI_CHAT_FOLLOW"), #available(iOS 18, *) {
            // Every geometry change is recorded; the probe reads it lazily.
            content.onScrollGeometryChange(for: ChatHistoryTestMetrics.self) { geometry in
                ChatHistoryTestMetrics(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                       viewportHeight: geometry.containerSize.height)
            } action: { [follow, following, streamingText] _, value in follow.record(value, following: following, streamingText: streamingText) }
                .overlay(alignment: .topLeading) {
                    ChatFollowProbe(trace: follow).frame(width: 1, height: 1).allowsHitTesting(false)
                }
        } else if UITesting.flag("LEAF_UI_CHAT_SCROLL_STREAM") {
            if #available(iOS 18, *) {
                content.onScrollGeometryChange(for: ChatHistoryTestMetrics.self) { geometry in
                    ChatHistoryTestMetrics(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                           viewportHeight: geometry.containerSize.height)
                } action: { _, value in metrics = value }
                    .overlay(alignment: .topLeading) { probe }
            } else {
                content.onPreferenceChange(ChatHistoryMeasuredOffset.self) { if let value = $0 { metrics.offset = value } }
                    .overlay(alignment: .topLeading) { probe }
            }
        } else { content }
        #else
        content
        #endif
    }
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

private struct ChatHistoryFollowsLatest: ViewModifier {
    let following: Bool
    let paused: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18, *) { content.modifier(ChatHistoryFollowing(following: following, paused: paused)) }
        else { content }
    }
}

private struct ChatHistoryInteraction: ViewModifier {
    @Binding var following: ChatScrollFollowing
    @GestureState private var dragging = false

    static var usesNativeTracking: Bool {
        guard #available(iOS 18, *) else { return false }
        #if DEBUG
        return !UITesting.flag("LEAF_UI_CHAT_SCROLL_LEGACY")
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

enum ReaderChatPlacement {
    static let diameter: CGFloat = 52
    static let trailing: CGFloat = 18
    static let bottom: CGFloat = 112
    /// The small theme button joined to the big one like a drop, above it on the side nearer the screen edge.
    static let satelliteDiameter: CGFloat = 26
    static let satelliteDistance: CGFloat = 40
    static let satelliteAngle = Double.pi / 4
    /// How far the twin reaches from the big button's center toward its side and top edges.
    static var satelliteReach: CGFloat { satelliteDistance * CGFloat(sin(satelliteAngle)) + satelliteDiameter / 2 }
    static func bounds(in size: CGSize) -> CGRect {
        // The small button sits above the big one on the edge side, so it needs room there.
        let side = max(diameter / 2, satelliteReach) + 6, top = side, bottom = diameter / 2 + 8
        let left = min(side, size.width / 2), upper = min(top, size.height / 2)
        return CGRect(x: left, y: upper,
                      width: max(0, size.width - left * 2), height: max(0, size.height - upper - min(bottom, size.height / 2)))
    }
    static func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let bounds = bounds(in: size)
        return CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
                       y: min(bounds.maxY, max(bounds.minY, point.y)))
    }
    static func center(x: Double, y: Double, in size: CGSize, bottom: CGFloat = ReaderChatPlacement.bottom) -> CGPoint {
        let bounds = bounds(in: size)
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            return clamp(CGPoint(x: size.width - trailing - diameter / 2,
                                 y: size.height - bottom - diameter / 2), in: size)
        }
        return CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
    }
    static func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let bounds = bounds(in: size), point = clamp(point, in: size)
        return CGPoint(x: bounds.width > 0 ? (point.x - bounds.minX) / bounds.width : 0.5,
                       y: bounds.height > 0 ? (point.y - bounds.minY) / bounds.height : 0.5)
    }

    /// Whether the small button belongs on the right: the half of the screen the big one is in,
    /// with a little hysteresis so a drag along the middle does not make it flip back and forth.
    static func satelliteOnRight(_ center: CGPoint, in size: CGSize, wasRight: Bool) -> Bool {
        let middle = size.width / 2, hysteresis: CGFloat = 12
        return wasRight ? center.x > middle - hysteresis : center.x > middle + hysteresis
    }
    /// The small button's angle from straight up: positive to the right, negative to the left.
    static func satelliteAngle(right: Bool) -> Double { right ? satelliteAngle : -satelliteAngle }
    static func satelliteOffset(angle: Double) -> CGSize {
        CGSize(width: satelliteDistance * CGFloat(sin(angle)), height: -satelliteDistance * CGFloat(cos(angle)))
    }
    /// The outline of both buttons as one drop: the big circle, the small one, and a smooth
    /// waist between them (a metaball). One contour, so a translucent fill never doubles up.
    static func twinOutline(center c1: CGPoint, angle: Double) -> Path {
        let r1 = Double(diameter / 2), r2 = Double(satelliteDiameter / 2), d = Double(satelliteDistance)
        let offset = satelliteOffset(angle: angle)
        let c2 = CGPoint(x: c1.x + offset.width, y: c1.y + offset.height)
        func point(_ c: CGPoint, _ a: Double, _ r: Double) -> CGPoint { CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)) }
        var u1 = 0.0, u2 = 0.0
        if d < r1 + r2 {
            u1 = acos((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d))
            u2 = acos((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d))
        }
        let between = atan2(Double(c2.y - c1.y), Double(c2.x - c1.x)), spread = acos((r1 - r2) / d), v = 0.6
        let a1 = between + u1 + (spread - u1) * v, a2 = between - u1 - (spread - u1) * v
        let a3 = between + .pi - u2 - (.pi - u2 - spread) * v, a4 = between - .pi + u2 + (.pi - u2 - spread) * v
        let p1 = point(c1, a1, r1), p2 = point(c1, a2, r1), p3 = point(c2, a3, r2), p4 = point(c2, a4, r2)
        let gap = hypot(Double(p1.x - p3.x), Double(p1.y - p3.y))
        let handle = min(v * 2.4, gap / (r1 + r2)) * min(1, d * 2 / (r1 + r2))
        let h1 = point(p1, a1 - .pi / 2, r1 * handle), h2 = point(p2, a2 + .pi / 2, r1 * handle)
        let h3 = point(p3, a3 + .pi / 2, r2 * handle), h4 = point(p4, a4 - .pi / 2, r2 * handle)
        var path = Path()
        path.move(to: p1)
        path.addCurve(to: p3, control1: h1, control2: h3)
        // Around the far side of the small circle, then back along the waist and the big circle.
        path.addRelativeArc(center: c2, radius: r2, startAngle: .radians(a3), delta: .radians(a4 - a3))
        path.addCurve(to: p2, control1: h4, control2: h2)
        path.addRelativeArc(center: c1, radius: r1, startAngle: .radians(a2), delta: .radians(-(2 * .pi - (a1 - a2))))
        path.closeSubpath()
        return path
    }

    /// Where the theme choices sit: an arc around the big button that opens toward the middle
    /// of the screen, moved as a whole when needed so every choice stays on screen.
    struct ThemeRing: Equatable {
        static let radius: CGFloat = 104
        static let swatch: CGFloat = 36
        let center: CGPoint
        let angles: [Double]
        var points: [CGPoint] {
            angles.map { CGPoint(x: center.x + Self.radius * CGFloat(cos($0)), y: center.y + Self.radius * CGFloat(sin($0))) }
        }
    }
    static func themeRing(count: Int, around center: CGPoint, in size: CGSize) -> ThemeRing {
        let toward = atan2(center.y > size.height / 2 ? -1.0 : 1.0, center.x > size.width / 2 ? -1.0 : 1.0)
        let span = 150 * Double.pi / 180
        let angles = (0..<max(count, 1)).map { toward - span / 2 + span * Double($0) / Double(max(count - 1, 1)) }
        let unshifted = ThemeRing(center: center, angles: angles).points
        let margin = ThemeRing.swatch / 2 + 8
        let safe = CGRect(origin: .zero, size: size).insetBy(dx: min(margin, size.width / 2), dy: min(margin, size.height / 2))
        let minX = unshifted.map(\.x).min() ?? center.x, maxX = unshifted.map(\.x).max() ?? center.x
        let minY = unshifted.map(\.y).min() ?? center.y, maxY = unshifted.map(\.y).max() ?? center.y
        let dx = max(0, safe.minX - minX) - max(0, maxX - safe.maxX)
        let dy = max(0, safe.minY - minY) - max(0, maxY - safe.maxY)
        return ThemeRing(center: CGPoint(x: center.x + dx, y: center.y + dy), angles: angles)
    }
}

struct ReaderChatButtonAppearance {
    static let defaultTransparency = 0.88
    static let transparencyRange = 0.2...0.95
    let transparency: Double
    init(transparency: Double) {
        self.transparency = transparency.isFinite ? min(0.95,max(0.2,transparency)) : Self.defaultTransparency
    }
    var fillOpacity: Double { 1 - transparency }
    var symbolOpacity: Double { min(1,fillOpacity * 0.55 / 0.12) }
    var outlineOpacity: Double { min(1,fillOpacity * 0.25 / 0.12) }
    func usesOnAccent(in theme: ReadingTheme) -> Bool {
        func rgb(_ hex: String) -> [Double] {
            let value = UInt32(hex.dropFirst(),radix:16) ?? 0
            return [Double((value >> 16) & 255),Double((value >> 8) & 255),Double(value & 255)].map { $0 / 255 }
        }
        func luminance(_ channels: [Double]) -> Double {
            zip(channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055,2.4) },[0.2126,0.7152,0.0722]).map(*).reduce(0,+)
        }
        let accent = rgb(theme.accentHex), background = rgb(theme.backgroundHex)
        let tint = zip(accent,background).map { $0 * fillOpacity + $1 * transparency }
        let tintLuminance = luminance(tint)
        func contrast(_ channels: [Double]) -> Double {
            let other = luminance(channels)
            return (max(tintLuminance,other)+0.05)/(min(tintLuminance,other)+0.05)
        }
        return contrast(rgb(theme.isDark ? theme.canvasHex : "#FFFFFF")) > contrast(accent)
    }
}

/// Both buttons as one drop. The angle animates, so the small button glides over the top.
private struct ReaderChatTwinShape: Shape {
    var angle: Double
    var animatableData: Double { get { angle } set { angle = newValue } }
    func path(in rect: CGRect) -> Path { ReaderChatPlacement.twinOutline(center: CGPoint(x: rect.midX, y: rect.midY), angle: angle) }
}

/// Moves a view along the small button's orbit, so it follows the drop's waist as it turns.
private struct ReaderChatOrbit: GeometryEffect {
    var angle: Double
    var animatableData: Double { get { angle } set { angle = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = ReaderChatPlacement.satelliteOffset(angle: angle)
        return ProjectionTransform(CGAffineTransform(translationX: offset.width, y: offset.height))
    }
}

private struct ReaderChatButtonIcon: View {
    @Environment(\.leafTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let appearance: ReaderChatButtonAppearance
    var isMoving = false
    var satelliteAngle = ReaderChatPlacement.satelliteAngle
    var menuOpen = false
    private var symbolColor: Color {
        (reduceTransparency || appearance.usesOnAccent(in:theme) ? theme.onAccent : theme.accent)
            .opacity(reduceTransparency || contrast == .increased ? 1 : appearance.symbolOpacity)
    }
    var body: some View {
        ZStack {
            // A color tint, never material blur: the underlying book stays sharp.
            ReaderChatTwinShape(angle:satelliteAngle).fill(theme.accent.opacity(reduceTransparency ? 1 : appearance.fillOpacity))
            ReaderChatTwinShape(angle:satelliteAngle)
                .stroke(theme.accent.opacity(reduceTransparency ? 1 : isMoving || contrast == .increased ? 0.85 : appearance.outlineOpacity),
                        style:StrokeStyle(lineWidth:isMoving ? 1.5 : 0.5,dash:isMoving ? [4,3] : []))
            Image(systemName:isMoving ? "arrow.up.and.down.and.arrow.left.and.right" : "leaf.fill")
                .font(.system(size:isMoving ? 21 : 25,weight:.medium))
                .foregroundStyle(symbolColor)
            ZStack {
                if menuOpen { Circle().fill(theme.accent.opacity(reduceTransparency ? 1 : max(0.22,appearance.fillOpacity * 1.8))) }
                Image(systemName:"paintpalette.fill").font(.system(size:12,weight:.semibold))
                    .foregroundStyle(menuOpen && !reduceTransparency ? theme.accent : symbolColor)
            }
            .frame(width:ReaderChatPlacement.satelliteDiameter,height:ReaderChatPlacement.satelliteDiameter)
            .modifier(ReaderChatOrbit(angle:satelliteAngle))
        }
        .frame(width:ReaderChatPlacement.diameter,height:ReaderChatPlacement.diameter)
        .contentShape(Circle())
    }
}

/// Quick theme choices on an arc around the button: each shows its page and ink as “Aa”.
private struct ReaderChatThemeRing: View {
    @Environment(\.leafTheme) private var theme
    let ring: ReaderChatPlacement.ThemeRing
    let selected: ReadingTheme
    let choose: (ReadingTheme) -> Void
    var body: some View {
        let points = ring.points, swatch = ReaderChatPlacement.ThemeRing.swatch
        ZStack {
            Path { path in
                guard let first = ring.angles.first, let last = ring.angles.last else { return }
                let overhang = 0.22
                path.addRelativeArc(center: ring.center, radius: ReaderChatPlacement.ThemeRing.radius,
                                    startAngle: .radians(first - overhang), delta: .radians(last - first + overhang * 2))
            }
            .stroke(theme.surface.opacity(0.94), style: StrokeStyle(lineWidth: swatch + 14, lineCap: .round))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            .allowsHitTesting(false)
            ForEach(Array(ReadingTheme.allCases.enumerated()), id: \.element) { index, option in
                Button { choose(option) } label: {
                    Text("Aa").font(.system(size: 14, design: .serif)).foregroundStyle(option.foreground)
                        .frame(width: swatch, height: swatch)
                        .background(option.background, in: Circle())
                        .overlay(Circle().strokeBorder(option == selected ? theme.accent : Color.primary.opacity(0.22),
                                                       lineWidth: option == selected ? 2.5 : 0.5))
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .position(points[index])
                .accessibilityLabel("\(option.title) theme")
                .accessibilityAddTraits(option == selected ? .isSelected : [])
                .accessibilityIdentifier("quickTheme-\(option.rawValue)")
            }
        }
    }
}

struct ReaderChatButtonSettings: View {
    @Environment(\.leafTheme) private var theme
    @AppStorage("reader.chatButtonTransparency") private var transparency = ReaderChatButtonAppearance.defaultTransparency
    private var appearance: ReaderChatButtonAppearance { ReaderChatButtonAppearance(transparency:transparency) }
    var body: some View {
        Form {
            Section {
                ZStack(alignment:.trailing) {
                    Text("A little room to read.\nLet the page stay in view.\nKeep your companion close.")
                        .font(.system(size:18,design:.serif)).lineSpacing(8).frame(maxWidth:.infinity,alignment:.leading)
                    ReaderChatButtonIcon(appearance:appearance).padding(.trailing,30).padding(.top,30)
                }.padding(.vertical,18).foregroundStyle(theme.foreground).accessibilityHidden(true)
            } header: { Text("Preview") }
                .listRowBackground(theme.surface)
            Section {
                HStack {
                    Text("Transparency")
                    Spacer()
                    Text(appearance.transparency,format:.percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value:Binding(get: { appearance.transparency },set: { transparency = $0 }),in:ReaderChatButtonAppearance.transparencyRange,step:0.01)
                    .accessibilityLabel("Floating button transparency")
                    .accessibilityValue(Text(appearance.transparency,format:.percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("chatButtonTransparency")
                HStack { Text("More visible");Spacer();Text("More transparent") }.font(.caption).foregroundStyle(.secondary)
                Button("Reset transparency") { transparency = ReaderChatButtonAppearance.defaultTransparency }
                    .accessibilityIdentifier("resetChatButtonTransparency")
            } footer: {
                Text("Applies immediately to the floating Ask Leaf button in Library and every book. Each view remembers its own position. Long press the button to move it. The small palette button above it switches the reading theme; it sits on the side nearer the screen edge. Reduce Transparency in iOS uses a solid button.")
            }
            .listRowBackground(theme.surface)
        }.leafFormStyle()
        .navigationTitle("Floating button").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.canvas,for:.navigationBar)
    }
}

struct ReaderChatLauncher: View {
    enum Location {
        case reader, library
        var storagePrefix: String { self == .reader ? "reader" : "library" }
        var identifier: String { self == .reader ? "openReaderChat" : "openLibraryChat" }
        var themeIdentifier: String { self == .reader ? "openReaderThemes" : "openLibraryThemes" }
        var bottom: CGFloat { self == .reader ? ReaderChatPlacement.bottom : 24 }
    }
    @Environment(\.leafTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isMoving: Bool
    let location: Location
    let action: () -> Void
    @AppStorage("reader.chatButtonTransparency") private var transparency = ReaderChatButtonAppearance.defaultTransparency
    @AppStorage("reader.theme") private var themeName = ReadingTheme.day.rawValue
    @AppStorage private var savedX: Double
    @AppStorage private var savedY: Double
    @State private var dragOrigin: CGPoint?
    @State private var draggedCenter: CGPoint?
    @State private var satelliteRight = true
    @State private var themesOpen = false

    init(isMoving: Binding<Bool>, location: Location = .reader, action: @escaping () -> Void) {
        _isMoving = isMoving; self.location = location; self.action = action
        _savedX = AppStorage(wrappedValue: -1, "\(location.storagePrefix).chatButtonX")
        _savedY = AppStorage(wrappedValue: -1, "\(location.storagePrefix).chatButtonY")
    }
    private var selectedTheme: ReadingTheme { ReadingTheme(rawValue: themeName) ?? .day }
    private var satelliteAngle: Double { ReaderChatPlacement.satelliteAngle(right: satelliteRight) }

    var body: some View {
        GeometryReader { geometry in
            let center = draggedCenter ?? ReaderChatPlacement.center(x: savedX, y: savedY, in: geometry.size, bottom: location.bottom)
            ZStack {
                if themesOpen {
                    // A tap anywhere else closes the choices without turning a page.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { closeThemes() }
                        .accessibilityLabel("Close themes").accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("closeQuickThemes")
                }
                Button { if !isMoving { closeThemes(); action() } } label: {
                    ReaderChatButtonIcon(appearance:ReaderChatButtonAppearance(transparency:transparency),isMoving:isMoving,
                                         satelliteAngle:satelliteAngle,menuOpen:themesOpen)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in closeThemes(); isMoving = true })
                .simultaneousGesture(dragGesture(from: center, in: geometry.size))
                .position(center)
                .accessibilityLabel("Ask Leaf")
                .accessibilityValue(isMoving ? "Move mode" : "Stationary")
                .accessibilityHint(isMoving ? "Drag to move. Tap elsewhere to finish." : "Opens your reading companion. Long press to move.")
                .accessibilityIdentifier(location.identifier)
                .accessibilityAction(named: "Move button") { isMoving = true }
                .accessibilityAction(named: "Move left") { move(center, dx: -24, dy: 0, in: geometry.size) }
                .accessibilityAction(named: "Move right") { move(center, dx: 24, dy: 0, in: geometry.size) }
                .accessibilityAction(named: "Move up") { move(center, dx: 0, dy: -24, in: geometry.size) }
                .accessibilityAction(named: "Move down") { move(center, dx: 0, dy: 24, in: geometry.size) }
                .accessibilityAction(named: "Finish moving") { isMoving = false }
                // The small button: a 44 pt target over the drawn 26 pt circle, riding the same orbit.
                Button { toggleThemes() } label: { Color.clear.frame(width: 44, height: 44).contentShape(Circle()) }
                    .buttonStyle(.plain)
                    .modifier(ReaderChatOrbit(angle: satelliteAngle))
                    .position(center)
                    .allowsHitTesting(!isMoving)
                    .accessibilityLabel("Reading theme")
                    .accessibilityValue(selectedTheme.title)
                    .accessibilityHint(themesOpen ? "Hides the theme choices." : "Shows quick theme choices.")
                    .accessibilityAddTraits(themesOpen ? .isSelected : [])
                    .accessibilityIdentifier(location.themeIdentifier)
                if themesOpen {
                    let ring = ReaderChatPlacement.themeRing(count: ReadingTheme.allCases.count, around: center, in: geometry.size)
                    let small = ReaderChatPlacement.satelliteOffset(angle: satelliteAngle)
                    ReaderChatThemeRing(ring: ring, selected: selectedTheme) { choice in
                        themeName = choice.rawValue
                        closeThemes()
                    }
                    .transition(.scale(scale: 0.2, anchor: UnitPoint(x: (center.x + small.width) / max(geometry.size.width, 1),
                                                                     y: (center.y + small.height) / max(geometry.size.height, 1)))
                        .combined(with: .opacity))
                    .accessibilityAction(.escape) { closeThemes() }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { satelliteRight = ReaderChatPlacement.satelliteOnRight(center, in: geometry.size, wasRight: center.x > geometry.size.width / 2) }
            .onChange(of: center) { _, point in
                let right = ReaderChatPlacement.satelliteOnRight(point, in: geometry.size, wasRight: satelliteRight)
                guard right != satelliteRight else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.72)) { satelliteRight = right }
            }
            .onChange(of: geometry.size) { _, _ in dragOrigin = nil; draggedCenter = nil; closeThemes() }
            .onChange(of: isMoving) { _, moving in
                if !moving {
                    if let draggedCenter { save(draggedCenter, in: geometry.size) }
                    dragOrigin = nil; draggedCenter = nil
                }
            }
        }
        .coordinateSpace(name: "chatButtonViewport")
        .sensoryFeedback(.impact(weight:.heavy,intensity:0.85),trigger:isMoving) { wasMoving,moving in !wasMoving && moving }
        .sensoryFeedback(.selection, trigger: themeName)
    }
    private func toggleThemes() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.8)) { themesOpen.toggle() }
    }
    private func closeThemes() {
        guard themesOpen else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.9)) { themesOpen = false }
    }
    private func dragGesture(from center: CGPoint, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("chatButtonViewport"))
            .onChanged { value in
                guard isMoving else { return }
                if dragOrigin == nil { dragOrigin = center }
                guard let origin = dragOrigin else { return }
                draggedCenter = ReaderChatPlacement.clamp(CGPoint(x: origin.x + value.translation.width,
                                                                  y: origin.y + value.translation.height), in: size)
            }
            .onEnded { _ in
                if let draggedCenter { save(draggedCenter, in: size) }
                dragOrigin = nil; draggedCenter = nil
            }
    }
    private func save(_ point: CGPoint, in size: CGSize) {
        let normalized = ReaderChatPlacement.normalized(point, in: size)
        savedX = normalized.x; savedY = normalized.y
    }
    private func move(_ center: CGPoint, dx: CGFloat, dy: CGFloat, in size: CGSize) {
        isMoving = true
        save(CGPoint(x: center.x + dx, y: center.y + dy), in: size)
    }
}

/// Hosts the chat panel at the bottom of its container at the saved, resizable
/// height of one placement. Reading and keyboard-open heights are stored
/// separately per placement; a drag of the grabber resizes within the bounds
/// `ReaderChatSizing` allows for the current viewport.
struct ResizableChatPanel: View {
    @ObservedObject var session: ReaderChatSession
    let location: ReaderChatLauncher.Location
    /// The full viewport height, measured outside the keyboard safe area.
    let fullHeight: CGFloat
    let bookTitle: String
    let context: ReaderChatPanel.Context
    let onChooseConversation: (() -> Void)?
    let onClose: () -> Void
    let onSettings: () -> Void
    let onButtonSettings: () -> Void
    let onSend: () -> Void
    @Environment(\.leafTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage private var heightFraction: Double
    @AppStorage private var composingHeightFraction: Double
    @State private var resizeOrigin: CGFloat?
    @State private var resizedHeight: CGFloat?

    init(session: ReaderChatSession, location: ReaderChatLauncher.Location, fullHeight: CGFloat, bookTitle: String,
         context: ReaderChatPanel.Context = .reader, onChooseConversation: (() -> Void)? = nil,
         onClose: @escaping () -> Void, onSettings: @escaping () -> Void, onButtonSettings: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.session = session; self.location = location; self.fullHeight = fullHeight; self.bookTitle = bookTitle
        self.context = context; self.onChooseConversation = onChooseConversation
        self.onClose = onClose; self.onSettings = onSettings; self.onButtonSettings = onButtonSettings; self.onSend = onSend
        // Start the new reader dock at its approved size once. Subsequent user
        // resizes persist independently of the existing keyboard preference.
        _heightFraction = AppStorage(wrappedValue: location == .reader ? ReaderChatSizing.dockedReadingFraction : 1.0 / 3,
            location == .reader ? "reader.dockedChatHeightFraction" : "library.chatHeightFraction")
        _composingHeightFraction = AppStorage(wrappedValue: -1, "\(location.storagePrefix).chatComposingHeightFraction")
    }

    var body: some View {
        GeometryReader { geometry in
            let full = max(fullHeight, geometry.size.height)
            let composing = geometry.size.height < full - 80
            let hasSelection = session.selectedContext != nil
            let hasStatus = session.notice != nil || session.error != nil || session.historyError != nil
            let limits = ReaderChatSizing.bounds(fullHeight: full, availableHeight: geometry.size.height, composing: composing, hasSelection: hasSelection, hasStatus: hasStatus)
            let preferred = ReaderChatSizing.height(fraction: composing ? composingHeightFraction : heightFraction,
                fullHeight: full, availableHeight: geometry.size.height, composing: composing, hasSelection: hasSelection, hasStatus: hasStatus)
            let height = min(limits.upperBound, max(limits.lowerBound, resizedHeight ?? preferred))
            ReaderChatPanel(session: session, bookTitle: bookTitle, isComposing: composing, context: context, onChooseConversation: onChooseConversation,
                onClose: onClose, onSettings: onSettings, onButtonSettings: onButtonSettings, onSend: onSend,
                onResize: { translation, ended in
                    if resizeOrigin == nil { resizeOrigin = height }
                    let resized = min(limits.upperBound, max(limits.lowerBound, (resizeOrigin ?? height) - translation))
                    resizedHeight = resized
                    if ended { save(resized, fullHeight: full, composing: composing) }
                }, onResizeStep: { step in
                    save(min(limits.upperBound, max(limits.lowerBound, height + step)), fullHeight: full, composing: composing)
                }, onResetSize: {
                    if composing { composingHeightFraction = -1 }
                    else { heightFraction = location == .reader ? ReaderChatSizing.dockedReadingFraction : 1.0 / 3 }
                    resizeOrigin = nil; resizedHeight = nil
                })
                .frame(height: height)
                .background {
                    GeometryReader { frame in
                        Color.clear.preference(key: ReaderChatFrame.self, value: location == .reader ? frame.frame(in: .global) : nil)
                    }
                }
                .background {
                    if reduceTransparency { location == .reader ? theme.background : theme.canvas }
                    else { Rectangle().fill(.ultraThinMaterial) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .onChange(of: geometry.size) { _, _ in resizeOrigin = nil; resizedHeight = nil }
                .onDisappear { resizeOrigin = nil; resizedHeight = nil }
        }
    }
    private func save(_ height: CGFloat, fullHeight: CGFloat, composing: Bool) {
        guard fullHeight > 0 else { return }
        if composing { composingHeightFraction = Double(height / fullHeight) }
        else { heightFraction = Double(height / fullHeight) }
        resizeOrigin = nil; resizedHeight = nil
    }
}

struct ReaderChatPanel: View {
    enum Context { case reader, libraryBook, general }
    @Environment(\.leafTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var dictation = ChatDictationSession()
    @AppStorage("chat.dictationLanguage") private var dictationLanguage = DictationLanguage.system.rawValue
    @ObservedObject var session: ReaderChatSession
    @EnvironmentObject private var settings: AISettingsStore
    let bookTitle: String
    let isComposing: Bool
    var context: Context = .reader
    var onChooseConversation: (() -> Void)? = nil
    let onClose: () -> Void
    let onSettings: () -> Void
    let onButtonSettings: () -> Void
    let onSend: () -> Void
    let onResize: (CGFloat, Bool) -> Void
    let onResizeStep: (CGFloat) -> Void
    let onResetSize: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var confirmsClear = false
    @State private var scrollFollowing = ChatScrollFollowing()
    @State private var selectedMessage: UUID?

    private var accent: Color { theme.accent }
    private var question: String { session.draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var spokenLocale: String {
        if dictation.isActive, let active = dictation.localeIdentifier { return active }
        return (DictationLanguage(rawValue: dictationLanguage) ?? .system).resolvedLocale(bookTitle: bookTitle, selectedText: session.selectedContext?.text)
    }
    private var contextHint: String {
        switch context {
        case .reader: return settings.configuration.sharePage ? "Sends the current passage with your question." : "Passage sharing is off."
        case .libraryBook:
            return settings.configuration.sharePage ? "Continues this book’s saved chat. Library shares only its title and author; open the book to quote a new passage." : "Continues this book’s saved chat. Passage sharing is off."
        case .general: return "Separate from your book chats. Leaf can read this screen’s list when you ask about it."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            content(compact: geometry.size.height < 200)
        }
    }
    private func content(compact: Bool) -> some View {
        VStack(spacing: compact ? 2 : 8) {
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity).frame(height: 12)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { onResize($0.translation.height, false) }
                        .onEnded { onResize($0.translation.height, true) })
                    .accessibilityElement().accessibilityLabel("Resize chat")
                    .accessibilityHint("Drag up to expand or down to shrink. Swipe down on the header to close.")
                    .accessibilityIdentifier("readerChatDragHandle")
                    .accessibilityAdjustableAction { direction in
                        switch direction { case .increment: onResizeStep(56); case .decrement: onResizeStep(-56); @unknown default: break }
                    }
                    .accessibilityAction(named: "Reset chat size", onResetSize)
                    .accessibilityAction(named: "Close chat", close)
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill").font(.system(size: 15, weight: .medium)).foregroundStyle(accent).accessibilityHidden(true)
                    if compact || isComposing, let selection = session.selectedContext {
                        Text(selection.previewText).font(.caption).lineLimit(1).layoutPriority(-1)
                            .accessibilityLabel(selection.text).accessibilityIdentifier("chatSelectedPassage")
                        Button { session.removeSelection() } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                            .accessibilityLabel("Remove selected text").accessibilityIdentifier("removeChatSelection")
                        if !isComposing { selectionActions(compact: true) }
                    } else { Text("Ask Leaf").font(.subheadline.weight(.semibold)).foregroundStyle(accent).lineLimit(1) }
                    Spacer(minLength: 4)
                    Menu { dictationLanguagePicker } label: {
                        HStack(spacing: 3) {
                            Text(DictationLanguage.shortLabel(locale: spokenLocale))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(.caption.weight(.medium)).foregroundStyle(accent).frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(dictation.isActive)
                    .accessibilityLabel("Dictation language")
                    .accessibilityValue(DictationLanguage(rawValue: dictationLanguage)?.title ?? "Automatic")
                    .accessibilityIdentifier("dictationLanguageButton")
                    if let onChooseConversation, !isComposing {
                        Button { dictation.cancel(); onChooseConversation() } label: {
                            HStack(spacing: 4) {
                                Text(context == .general ? "General chat" : bookTitle).lineLimit(1)
                                Image(systemName: "chevron.down")
                            }.font(.caption).frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("Choose conversation").accessibilityValue(context == .general ? "General chat" : bookTitle)
                            .accessibilityIdentifier("chooseLibraryConversation")
                    }
                    if dictation.isActive {
                        Text(dictation.status).font(.caption).foregroundStyle(accent).lineLimit(1)
                            .accessibilityIdentifier("chatDictationStatus")
                    } else if context == .reader && !isComposing && !compact {
                        Text(settings.configuration.profile.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !isComposing && !compact {
                        Menu {
                            dictationLanguagePicker
                            Button("AI settings", systemImage: "gearshape") { dictation.cancel(); onSettings() }
                            Button("Floating button",systemImage:"circle.lefthalf.filled") { dictation.cancel(); onButtonSettings() }
                                .accessibilityIdentifier("configureChatButton")
                            Button("Clear conversation", systemImage: "trash", role: .destructive) { dictation.cancel(); confirmsClear = true }
                                .accessibilityIdentifier("requestClearConversation")
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        }.accessibilityLabel("Chat options").accessibilityIdentifier("chatOptions")
                    }
                    if isComposing {
                        Button { inputFocused = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .frame(width: 44, height: 44).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Hide keyboard")
                    }
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Close chat").accessibilityIdentifier("closeReaderChat")
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dismissDrag)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("readerChatHeader")
            }

            Group {
                if session.hasEarlierMessages || session.hasNewerMessages {
                    HStack {
                        Button("Earlier") { session.loadEarlier() }
                            .disabled(!session.hasEarlierMessages || session.isSending)
                            .accessibilityLabel("Earlier messages").accessibilityIdentifier("earlierChatMessages")
                        Spacer()
                        if session.hasNewerMessages {
                            Button("Latest") { session.loadLatest() }.disabled(session.isSending)
                                .accessibilityLabel("Latest messages").accessibilityIdentifier("latestChatMessages")
                            Spacer()
                        }
                        Button("Newer") { session.loadNewer() }
                            .disabled(!session.hasNewerMessages || session.isSending)
                            .accessibilityLabel("Newer messages").accessibilityIdentifier("newerChatMessages")
                    }.font(.caption)
                }
                ScrollViewReader { proxy in
                    GeometryReader { viewport in
                        ScrollView {
                            // The history is paged (24 messages), so every row is laid out.
                            // A lazy stack estimated the rows it had not laid out yet: when
                            // the panel grew after sending from the keyboard it guessed the
                            // new question and placeholder at the height of the long reply
                            // above them, followed that phantom bottom, and showed a blank
                            // panel until the reply's first token re-laid the rows out.
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(session.messages) { message in
                                    HStack {
                                        if message.isUser { Spacer(minLength: 32) }
                                        ReaderChatMessageBubble(message: message, accent: accent, imageURL: session.imageURL,
                                                                activity: message.id == session.messages.last?.id ? session.activity : nil) { selected in
                                            if selected { selectedMessage = message.id }
                                            else if selectedMessage == message.id { selectedMessage = nil }
                                        }
                                        if !message.isUser { Spacer(minLength: 0) }
                                    }.id(message.id)
                                }
                                if session.messages.isEmpty && session.selectedContext == nil {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if context == .reader {
                                            Text(ReaderChatMessage.usesChinese(bookTitle) ? "问我解释这段文字、梳理线索，或总结当前页面。" : "Ask about a passage, explore a character’s motives, or recap this page.")
                                                .font(.subheadline)
                                        }
                                        Text(contextHint)
                                            .font(.caption).foregroundStyle(.secondary)
                                        Button("AI settings", action: onSettings).font(.subheadline)
                                    }
                                }
                            }.padding(.vertical, 2)
                                // A short chat grows inside a viewport-tall, bottom-aligned
                                // frame, so streaming does not move the scroll offset at all.
                                .frame(minHeight: viewport.size.height, alignment: .bottom)
                                .background {
                                    if !ChatHistoryInteraction.usesNativeTracking {
                                        GeometryReader { content in
                                            Color.clear.preference(key: ChatHistoryAtBottom.self,
                                                value: content.frame(in: .named("chatHistoryViewport")).maxY - viewport.size.height <= 4)
                                                .overlay {
                                                    #if DEBUG
                                                    Color.clear.preference(key: ChatHistoryMeasuredOffset.self,
                                                        value: -content.frame(in: .named("chatHistoryViewport")).minY)
                                                    #endif
                                                }
                                        }
                                    }
                                }
                        }
                        .coordinateSpace(name: "chatHistoryViewport")
                        .defaultScrollAnchor(.bottom)
                        .scrollDismissesKeyboard(isComposing ? .never : .interactively)
                        .accessibilityIdentifier("chatMessageHistory")
                        .accessibilityValue(scrollFollowing.followsLatest ? "Following latest" : "Reading earlier")
                        .modifier(ChatHistoryTestMeasurement(following: scrollFollowing.followsLatest, selected: selectedMessage != nil,
                                                             streamingText: session.messages.last.map { $0.state == .streaming && !$0.text.isEmpty } ?? false))
                        #if DEBUG
                        .modifier(ChatSwipeMeasurement())
                        #endif
                        .modifier(ChatHistoryInteraction(following: $scrollFollowing))
                        .modifier(ChatHistoryFollowsLatest(following: scrollFollowing.followsLatest, paused: selectedMessage != nil))
                        .onPreferenceChange(ChatHistoryAtBottom.self) { atBottom in
                            if !ChatHistoryInteraction.usesNativeTracking, let atBottom { scrollFollowing.updateAtBottom(atBottom) }
                        }
                        .onChange(of: session.messages.last?.text) { _, _ in
                            // iOS 18 follows actual content growth (ChatHistoryFollowing).
                            guard #unavailable(iOS 18) else { return }
                            // Let the new text lay out first, then slide to it.
                            DispatchQueue.main.async {
                                if selectedMessage == nil, scrollFollowing.followsLatest, let last = session.messages.last {
                                    withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                        }
                        .onChange(of: session.isSending) { _, sending in
                            if sending {
                                scrollFollowing.resume()
                                if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: ObjectIdentifier(session)) { _, _ in
                            scrollFollowing = ChatScrollFollowing()
                            if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                        .onChange(of: inputFocused) { _, focused in
                            if focused, let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                        .onChange(of: isComposing) { _, composing in
                            if composing, let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }.frame(maxHeight: .infinity)
                if let historyError = session.historyError {
                    HStack {
                        Text(historyError).font(.caption).foregroundStyle(.red).lineLimit(3)
                            .accessibilityIdentifier("chatHistoryError")
                        if session.canSaveHistory {
                            Button("Try saving again") { session.flush() }.font(.caption.bold())
                        }
                    }
                }
                if let error = session.error {
                    HStack(spacing: 8) {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).accessibilityIdentifier("readerChatError")
                        if session.canRetry { Button("Retry") { session.retry(settings: settings) }.font(.caption.bold()) }
                    }
                } else if let notice = session.notice {
                    HStack(spacing: 8) {
                        Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if session.canRetry { Button("Retry") { session.retry(settings: settings) }.font(.caption.bold()) }
                    }
                }
            }

            if !compact, !isComposing, let selection = session.selectedContext {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.quote").foregroundStyle(accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.configuration.sharePage ? "Selected text" : "Selected text · passage sharing is off")
                            .font(.caption.weight(.medium))
                        Text(selection.previewText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .accessibilityLabel(selection.text)
                            .accessibilityIdentifier("chatSelectedPassage")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.removeSelection() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Remove selected text").accessibilityIdentifier("removeChatSelection")
                }.padding(.leading, 8)
                if !isComposing {
                    selectionActions(compact: false)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(session.selectedContext != nil ? "Ask about the selected text…" : context == .general ? "Ask Leaf…" : context == .libraryBook ? "Ask about this book…" : "Ask about this page…", text: $session.draft, axis: .vertical)
                    .font(.subheadline).lineLimit(1...(compact ? 1 : 3))
                    .focused($inputFocused).submitLabel(.send)
                    .disabled(dictation.isActive)
                    .onSubmit(send)
                    .padding(.leading, 14).padding(.vertical, compact ? 6 : 12)
                    .accessibilityIdentifier("readerChatInput")
                Button(action: toggleDictation) {
                    Image(systemName: dictation.isActive ? "stop.circle.fill" : "mic")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(dictation.isActive ? Color.red : accent)
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(session.isSending)
                .accessibilityLabel(dictation.isActive ? "Stop dictation" : "Dictate question")
                .accessibilityValue(dictation.isActive ? dictation.status : (DictationLanguage(rawValue: dictationLanguage) ?? .system).title)
                .accessibilityHint("Speak to add text to your draft. Stop and review it before sending. Touch and hold to choose a language.")
                .accessibilityIdentifier("dictateChatQuestion")
                .contextMenu { dictationLanguagePicker }
                Button(action: session.isSending ? session.stop : send) {
                    Image(systemName: session.isSending ? "stop.fill" : "arrow.up").font(.system(size: 19, weight: .medium))
                        .foregroundStyle(question.isEmpty && !session.isSending ? Color.secondary : theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(question.isEmpty && !session.isSending ? accent.opacity(0.1) : accent, in: Circle())
                }
                .buttonStyle(.plain).disabled(dictation.isActive || (question.isEmpty && !session.isSending))
                .accessibilityLabel(session.isSending ? "Stop response" : "Send message").accessibilityIdentifier("sendReaderChat")
            }
            .padding(compact ? 0 : 4)
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(.secondary.opacity(0.3), lineWidth: 0.75))
        }
        .padding(.horizontal, 16).padding(.top, compact ? 0 : 4).padding(.bottom, compact ? 2 : 8)
        .foregroundStyle(.primary).tint(accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerChatPanel")
        .accessibilityAction(.escape, close)
        .onDisappear { dictation.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dictation.suspend(background: phase == .background) } }
        .onChange(of: ObjectIdentifier(session)) { _, _ in dictation.cancel() }
        .onChange(of: dictationLanguage) { _, _ in dictation.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: ReadAloudAudioSession.willActivate)) { _ in dictation.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { dictation.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            if (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { dictation.cancel() }
        }
        .alert("Dictation unavailable", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            if dictation.needsSettings { Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } }
            Button("OK", role: .cancel) { dictation.error = nil }
        } message: { Text(dictation.error ?? "") }
        .confirmationDialog(context == .general ? "Clear your general conversation?" : "Clear this book’s conversation?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { session.clear() }
                .accessibilityIdentifier("confirmClearConversation")
            Button("Cancel", role: .cancel) {}
        } message: { Text(context == .general ? "This deletes the general chat’s saved messages and draft from this device. Book conversations are kept." : "This deletes this book’s saved messages and draft from this device.") }
    }

    private var dictationLanguagePicker: some View {
        Picker("Dictation language", selection: $dictationLanguage) {
            ForEach(DictationLanguage.allCases) { language in Text(language.title).tag(language.rawValue) }
        }.accessibilityIdentifier("dictationLanguage")
    }
    private func toggleDictation() {
        if dictation.isActive { dictation.finish(); return }
        inputFocused = false
        dictation.start(draft: session.draft, language: DictationLanguage(rawValue: dictationLanguage) ?? .system, bookTitle: bookTitle, selectedText: session.selectedContext?.text) { [weak session] text in
            session?.draft = text
        }
    }

    private func selectionActions(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 8) {
            ForEach([ReaderSelectionIntent.explain, .summarize], id: \.rawValue) { intent in
                Button { session.prepareSelectionPrompt(intent) } label: {
                    Text(intent.shortTitle)
                        .font(.caption.weight(.medium)).lineLimit(1).fixedSize()
                        .foregroundStyle(accent).padding(.horizontal, compact ? 10 : 14).frame(height: 44)
                        .background(accent.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.2), lineWidth: 0.75))
                }
                .buttonStyle(.plain).accessibilityLabel(intent.title)
                .accessibilityIdentifier("\(intent.rawValue)ChatSelection")
            }
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 15).onEnded { gesture in
            if gesture.translation.height > 40, abs(gesture.translation.width) < gesture.translation.height { close() }
        }
    }

    private func close() {
        dictation.cancel()
        inputFocused = false
        onClose()
    }

    private func send() {
        guard !question.isEmpty, !session.isSending, !dictation.isActive else { return }
        inputFocused = false
        onSend()
    }
}

/// A picture the model drew, with the system share sheet for saving or sending it.
private struct ChatGeneratedImage: View {
    let url: URL?
    let accent: Color
    @State private var picture: UIImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let picture {
                VStack(alignment: .leading, spacing: 4) {
                    Image(uiImage: picture).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Generated picture").accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("chatReplyImage")
                    ShareLink(item: Image(uiImage: picture), preview: SharePreview("Picture from Leaf", image: Image(uiImage: picture))) {
                        Label("Share or save", systemImage: "square.and.arrow.up").font(.caption.weight(.medium))
                    }
                    .tint(accent).frame(minHeight: 44)
                    .accessibilityIdentifier("shareChatImage")
                }
            } else if missing {
                // Synced history carries the reply but not the picture file.
                Label("This picture is not on this device.", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("missingChatImage")
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.opacity(0.08))
                    .frame(maxWidth: .infinity).frame(height: 160)
            }
        }
        .task(id: url) {
            guard let url else { missing = true; return }
            let loaded = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
            if let loaded { picture = loaded } else { missing = true }
        }
    }
}

private struct ReaderChatMessageBubble: View {
    let message: ReaderChatMessage
    let accent: Color
    var imageURL: (String) -> URL? = { _ in nil }
    var activity: String? = nil
    var onSelectionChange: (Bool) -> Void = { _ in }
    @State private var quoteExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.isUser, let context = message.context, context.source == "selection", !context.isEmpty {
                Button { quoteExpanded.toggle() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Quoted text", systemImage: "text.quote").font(.caption2.weight(.medium))
                            Spacer(minLength: 8)
                            Image(systemName: quoteExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                        }.foregroundStyle(accent)
                        Text(quoteExpanded ? context.text : context.previewText).font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(context.text)
                            .lineLimit(quoteExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chatQuotedPassage")
                    }
                    .padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(quoteExpanded ? "Collapse quoted text" : "Expand quoted text")
                .accessibilityValue(context.text)
                .accessibilityIdentifier("toggleChatQuote")
            }
            ForEach(message.images ?? [], id: \.self) { name in
                ChatGeneratedImage(url: imageURL(name), accent: accent)
            }
            // A finished reply that is only a picture needs no caption.
            if !(message.text.isEmpty && message.hasImages && message.state != .streaming) {
                SelectableChatText(text: displayText, markdown: !message.isUser,
                                   identifier: message.isUser ? "chatQuestion" : "chatReply",
                                   tint: accent,
                                   onSelectionChange: onSelectionChange)
            }
            // Which reading-context design produced this reply, for comparison.
            if !message.isUser, message.state != .streaming, let trace = message.trace {
                Label(trace.caption, systemImage: trace.harness == .agent ? "magnifyingglass" : "text.book.closed")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityElement(children: .ignore).accessibilityLabel(trace.caption)
                    .accessibilityIdentifier("chatReplyTrace")
            }
        }
        .padding(message.isUser ? 10 : 0)
        .background(message.isUser ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 16))
    }

    private var displayText: String {
        message.text.isEmpty ? (message.state == .streaming ? activity ?? "Thinking…" : "No response text") : message.text
    }
}
