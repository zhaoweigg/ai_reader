import SwiftUI

/// Stable raw values keep existing reading preferences compatible with app-wide themes.
enum ReadingTheme: String, CaseIterable, Identifiable {
    case day, paper, night, sepia, sage, dusk
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .day: return "Crisp white, clear ink."
        case .paper: return "A warm page for unhurried reading."
        case .night: return "Soft ink on deep blue."
        case .sepia: return "Warm brown ink on a mellow page."
        case .sage: return "A quiet green with a gentle contrast."
        case .dusk: return "Cool gray for the end of the day."
        }
    }
    var isDark: Bool { self == .night || self == .dusk }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var backgroundHex: String {
        switch self {
        case .day: return "#FFFFFF"
        case .paper: return "#F4EDDD"
        case .night: return "#17232E"
        case .sepia: return "#EBD9BB"
        case .sage: return "#E5EEE7"
        case .dusk: return "#242633"
        }
    }
    var foregroundHex: String {
        switch self {
        case .day: return "#263440"
        case .paper: return "#493F30"
        case .night: return "#D7DEE4"
        case .sepia: return "#493522"
        case .sage: return "#283E33"
        case .dusk: return "#E0DFEC"
        }
    }
    var canvasHex: String {
        switch self {
        case .day: return "#F2F4F5"
        case .paper: return "#EDE5D5"
        case .night: return "#111B24"
        case .sepia: return "#E2CDAA"
        case .sage: return "#D8E4DC"
        case .dusk: return "#1B1D28"
        }
    }
    var accentHex: String {
        switch self {
        case .day, .paper: return "#24776A"
        case .night: return "#93CABB"
        case .sepia: return "#785033"
        case .sage: return "#326C57"
        case .dusk: return "#B2BCEB"
        }
    }
    var featuredHex: String {
        switch self {
        case .day: return "#203C4D"
        case .paper: return "#414D43"
        case .night: return "#283F4C"
        case .sepia: return "#59432F"
        case .sage: return "#2D4D3D"
        case .dusk: return "#3B3F60"
        }
    }
    var background: Color { Color(hex: backgroundHex) }
    var foreground: Color { Color(hex: foregroundHex) }
    var canvas: Color { Color(hex: canvasHex) }
    var surface: Color { background }
    var accent: Color { Color(hex: accentHex) }
    var onAccent: Color { isDark ? canvas : .white }
    var featured: Color { Color(hex: featuredHex) }
}

private struct LeafThemeKey: EnvironmentKey {
    static let defaultValue = ReadingTheme.day
}
extension EnvironmentValues {
    var leafTheme: ReadingTheme {
        get { self[LeafThemeKey.self] }
        set { self[LeafThemeKey.self] = newValue }
    }
}

private struct LeafFormStyle: ViewModifier {
    @Environment(\.leafTheme) private var theme
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(theme.canvas)
    }
}
extension View {
    func leafFormStyle() -> some View { modifier(LeafFormStyle()) }
}

/// Typefaces the reader offers. The raw value is the saved `reader.font` preference and
/// the CSS family name, so the three original choices keep their stored values. Chinese
/// faces ship in `Reader/fonts`; the page declares them with `@font-face` and Info.plist
/// registers the same files for native previews.
enum ReaderTypeface: String, CaseIterable, Identifiable {
    case georgia = "Georgia", palatino = "Palatino", system = "System"
    case wenKai = "LXGW WenKai Lite", notoSerif = "Noto Serif CJK SC"
    case zhiSong = "LXGW Neo ZhiSong", xiHei = "LXGW Neo XiHei"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .georgia, .palatino, .system: return rawValue
        case .wenKai: return "霞鹜文楷"
        case .notoSerif: return "思源宋体"
        case .zhiSong: return "霞鹜新致宋"
        case .xiHei: return "霞鹜新晰黑"
        }
    }
    var detail: String? {
        switch self {
        case .georgia, .palatino, .system: return nil
        case .wenKai: return "楷体 · WenKai"
        case .notoSerif: return "宋体 · Noto Serif"
        case .zhiSong: return "宋体 · ZhiSong"
        case .xiHei: return "黑体 · XiHei"
        }
    }
    /// The bundled file under `Reader/fonts`; nil for faces the system provides.
    var file: String? {
        switch self {
        case .georgia, .palatino, .system: return nil
        case .wenKai: return "LXGWWenKaiLite-Regular.ttf"
        case .notoSerif: return "NotoSerifCJKsc-Regular.otf"
        case .zhiSong: return "LXGWNeoZhiSong.ttf"
        case .xiHei: return "LXGWNeoXiHei.ttf"
        }
    }
    /// The generic family that fills in glyphs the face lacks.
    var generic: String { self == .system || self == .xiHei ? "sans-serif" : "serif" }
    static let bundled = allCases.filter { $0.file != nil }
    static func named(_ name: String) -> ReaderTypeface { ReaderTypeface(rawValue: name) ?? .georgia }
    func font(size: CGFloat) -> Font { self == .system ? .system(size: size) : .custom(rawValue, size: size) }
}

struct ReaderPreferences: Equatable {
    var fontSize: Double
    var lineHeight: Double
    var font: String
    var theme: ReadingTheme
    var scrolling: Bool
    var horizontalMargin: Double = 20
    var verticalMargin: Double = 12
    var paragraphSpacing: Double = 0.65
    var typeface: ReaderTypeface { ReaderTypeface.named(font) }
    var payload: [String: Any] {
        var value: [String: Any] = ["fontSize": fontSize, "lineHeight": lineHeight, "font": font, "fontGeneric": typeface.generic,
         "background": theme.backgroundHex, "foreground": theme.foregroundHex, "scrolling": scrolling,
         "colorScheme": theme.isDark ? "dark" : "light", "accent": theme.accentHex,
         "horizontalMargin": horizontalMargin, "verticalMargin": verticalMargin, "paragraphSpacing": paragraphSpacing]
        if let file = typeface.file { value["fontFile"] = file }
        return value
    }
}

enum LeafStyle {
    static let ink = Color(hex: "#20364A")
    static let accent = Color(hex: "#24776A")
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let palettes: [(Color, Color)] = [
        (Color(hex: "#214E61"), Color(hex: "#90C7C2")),
        (Color(hex: "#674B70"), Color(hex: "#E0B4CA")),
        (Color(hex: "#8B542F"), Color(hex: "#EFCE8B")),
        (Color(hex: "#365A44"), Color(hex: "#B6C79B")),
        (Color(hex: "#354B7A"), Color(hex: "#B3C8E9"))
    ]
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}
