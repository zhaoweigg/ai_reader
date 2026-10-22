import XCTest
import SwiftUI
@testable import LeafReader

final class ThemeTests: XCTestCase {
    func testThemesKeepReadableTextAndActionContrast() {
        for theme in ReadingTheme.allCases {
            XCTAssertGreaterThanOrEqual(contrast(theme.foregroundHex, theme.backgroundHex), 7, theme.title)
            XCTAssertGreaterThanOrEqual(contrast(theme.accentHex, theme.backgroundHex), 4.5, theme.title)
            XCTAssertGreaterThanOrEqual(contrast(theme.accentHex, theme.isDark ? theme.canvasHex : "#FFFFFF"), 4.5, theme.title)
        }
    }

    func testExistingStoredThemesRemainValidAndAllChoicesHaveDistinctPages() {
        for name in ["day", "paper", "night"] { XCTAssertNotNil(ReadingTheme(rawValue: name)) }
        XCTAssertEqual(Set(ReadingTheme.allCases.map(\.backgroundHex)).count, ReadingTheme.allCases.count)
        for theme in ReadingTheme.allCases {
            let prefs = ReaderPreferences(fontSize: 19, lineHeight: 1.65, font: "Georgia", theme: theme, scrolling: false)
            XCTAssertEqual(prefs.payload["colorScheme"] as? String, theme.isDark ? "dark" : "light")
            XCTAssertEqual(prefs.payload["accent"] as? String, theme.accentHex)
        }
    }

    private func contrast(_ first: String, _ second: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let value = UInt32(hex.dropFirst(), radix: 16)!
            let channels = [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)].map { value -> Double in
                let s = value / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return zip(channels, [0.2126, 0.7152, 0.0722]).map(*).reduce(0, +)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
