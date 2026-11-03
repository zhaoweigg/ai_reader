import XCTest
import SwiftUI
@testable import LeafReader

final class ReaderChatButtonAppearanceTests: XCTestCase {
    func testBoldTextDefaultsOffAndIsIncludedInPreferences() {
        var regular = ReaderPreferences(fontSize: 19, lineHeight: 1.65, font: "Georgia", theme: .day, scrolling: false)
        XCTAssertEqual(regular.payload["boldText"] as? Bool, false)
        let original = regular; regular.boldText = true
        XCTAssertNotEqual(regular, original)
        XCTAssertEqual(regular.payload["boldText"] as? Bool, true)
        XCTAssertTrue(SyncedSettings.keys.contains("reader.boldText"))
    }
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
        for name in ["day", "paper", "night", "black"] { XCTAssertNotNil(ReadingTheme(rawValue: name)) }
        XCTAssertEqual(Set(ReadingTheme.allCases.map(\.backgroundHex)).count, ReadingTheme.allCases.count)
        // Black is pure black on the page and the canvas, dark, and keeps rows visible.
        XCTAssertEqual(ReadingTheme.black.backgroundHex, "#000000")
        XCTAssertEqual(ReadingTheme.black.canvasHex, "#000000")
        XCTAssertTrue(ReadingTheme.black.isDark)
        XCTAssertNotEqual(ReadingTheme.black.surface, ReadingTheme.black.canvas)
        for theme in ReadingTheme.allCases where theme != .black { XCTAssertEqual(theme.surface, theme.background, theme.title) }
        for theme in ReadingTheme.allCases {
            let prefs = ReaderPreferences(fontSize: 19, lineHeight: 1.65, font: "Georgia", theme: theme, scrolling: false)
            XCTAssertEqual(prefs.payload["colorScheme"] as? String, theme.isDark ? "dark" : "light")
            XCTAssertEqual(prefs.payload["accent"] as? String, theme.accentHex)
        }
    }

    func testBundledTypefacesRegisterNativelyShipLicensesAndReachThePage() throws {
        let reader = try XCTUnwrap(Bundle.main.url(forResource: "Reader", withExtension: nil))
        let shipped = Set(try FileManager.default.contentsOfDirectory(atPath: reader.appendingPathComponent("fonts").path))
        for name in ["Georgia", "Palatino", "System"] { XCTAssertNotNil(ReaderTypeface(rawValue: name), name) }
        XCTAssertEqual(ReaderTypeface.bundled.map(\.rawValue), ["LXGW WenKai Lite", "Noto Serif CJK SC", "LXGW Neo ZhiSong", "LXGW Neo XiHei"])
        for face in ReaderTypeface.bundled {
            let file = try XCTUnwrap(face.file, face.title)
            XCTAssertTrue(shipped.contains(file), "\(file) must ship in Reader/fonts")
            // Info.plist registers the same file, so native previews use the real face.
            let native = try XCTUnwrap(UIFont(name: face.rawValue, size: 17), "\(face.rawValue) is not registered through UIAppFonts")
            XCTAssertEqual(native.familyName, face.rawValue)
            XCTAssertNotNil(face.detail, face.title)
            let prefs = ReaderPreferences(fontSize: 19, lineHeight: 1.65, font: face.rawValue, theme: .day, scrolling: false)
            XCTAssertEqual(prefs.payload["fontFile"] as? String, file)
            XCTAssertEqual(prefs.payload["fontGeneric"] as? String, face.generic)
        }
        for prefix in ["LXGWWenKaiLite", "NotoSerifCJK", "LXGWNeoZhiSong", "LXGWNeoXiHei"] {
            XCTAssertTrue(shipped.contains { $0.hasPrefix(prefix) && $0.contains("LICENSE") }, "\(prefix) license must ship for Acknowledgments")
        }
        let georgia = ReaderPreferences(fontSize: 19, lineHeight: 1.65, font: "Georgia", theme: .day, scrolling: false)
        XCTAssertNil(georgia.payload["fontFile"])
        XCTAssertEqual(georgia.payload["fontGeneric"] as? String, "serif")
        XCTAssertEqual(ReaderPreferences(fontSize: 19, lineHeight: 1.65, font: "System", theme: .day, scrolling: false).payload["fontGeneric"] as? String, "sans-serif")
        // A name synced from a newer build still produces a usable payload.
        XCTAssertEqual(ReaderPreferences(fontSize: 19, lineHeight: 1.65, font: "Unknown Face", theme: .day, scrolling: false).typeface, .georgia)
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
