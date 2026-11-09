import SwiftUI

// The floating Ask Leaf button: placement and clamping, the joined theme satellite
// with its quick-theme arc, and the Floating button settings screen.

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
        static let track: CGFloat = swatch + 10
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
        // Room for the track around each choice, so the arc never runs off the screen edge.
        let margin = ThemeRing.track / 2 + 6
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
                // Round caps end the track just past the first and last choice.
                path.addRelativeArc(center: ring.center, radius: ReaderChatPlacement.ThemeRing.radius,
                                    startAngle: .radians(first), delta: .radians(last - first))
            }
            .stroke(theme.surface.opacity(0.94), style: StrokeStyle(lineWidth: ReaderChatPlacement.ThemeRing.track, lineCap: .round))
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
