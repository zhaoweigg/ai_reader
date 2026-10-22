import XCTest
import SwiftUI
@testable import LeafReader

final class ReaderChatButtonAppearanceTests: XCTestCase {
    func testDefaultRetainsTheExistingTranslucentAppearance() {
        let appearance = ReaderChatButtonAppearance(transparency:0.88)
        XCTAssertEqual(appearance.fillOpacity,0.12,accuracy:0.0001)
        XCTAssertEqual(appearance.symbolOpacity,0.55,accuracy:0.0001)
        XCTAssertEqual(appearance.outlineOpacity,0.25,accuracy:0.0001)
        for theme in ReadingTheme.allCases { XCTAssertFalse(appearance.usesOnAccent(in:theme),theme.title) }
    }
    func testInvalidSavedPreferencesAreClampedAndButtonNeverBecomesInvisible() {
        for value in [Double.nan,Double.infinity,-Double.infinity] {
            XCTAssertEqual(ReaderChatButtonAppearance(transparency:value).transparency,0.88)
        }
        XCTAssertEqual(ReaderChatButtonAppearance(transparency:-1).transparency,0.2)
        XCTAssertEqual(ReaderChatButtonAppearance(transparency:5).transparency,0.95)
        let faint = ReaderChatButtonAppearance(transparency:0.95)
        XCTAssertGreaterThan(faint.fillOpacity,0)
        XCTAssertGreaterThan(faint.symbolOpacity,0.2)
    }
    func testTransparencyScalesEveryLayerAndUsesReadableSymbolForStrongerTint() {
        var previousFill = 1.0, previousSymbol = 1.0, previousOutline = 1.0
        for value in [0.2,0.4,0.6,0.8,0.88,0.95] {
            let appearance = ReaderChatButtonAppearance(transparency:value)
            XCTAssertLessThanOrEqual(appearance.fillOpacity,previousFill)
            XCTAssertLessThanOrEqual(appearance.symbolOpacity,previousSymbol)
            XCTAssertLessThanOrEqual(appearance.outlineOpacity,previousOutline)
            previousFill = appearance.fillOpacity;previousSymbol = appearance.symbolOpacity;previousOutline = appearance.outlineOpacity
        }
        for theme in ReadingTheme.allCases {
            XCTAssertTrue(ReaderChatButtonAppearance(transparency:0.2).usesOnAccent(in:theme),theme.title)
        }
    }
}

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
