import SwiftUI

enum ReadingTheme: String, CaseIterable, Identifiable {
    case day, paper, night
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var backgroundHex: String {
        switch self { case .day: return "#FFFFFF"; case .paper: return "#F4EDDD"; case .night: return "#17232E" }
    }
    var foregroundHex: String {
        switch self { case .day: return "#263440"; case .paper: return "#493F30"; case .night: return "#D7DEE4" }
    }
    var background: Color { Color(hex: backgroundHex) }
    var foreground: Color { Color(hex: foregroundHex) }
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
    var payload: [String: Any] {
        ["fontSize": fontSize, "lineHeight": lineHeight, "font": font,
         "background": theme.backgroundHex, "foreground": theme.foregroundHex, "scrolling": scrolling,
         "horizontalMargin": horizontalMargin, "verticalMargin": verticalMargin, "paragraphSpacing": paragraphSpacing]
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
