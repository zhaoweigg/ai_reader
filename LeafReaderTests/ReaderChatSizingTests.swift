import XCTest
@testable import LeafReader

final class ReaderChatSizingTests: XCTestCase {
    func testDefaultAndUserSizeLeaveTheBookVisible() {
        XCTAssertEqual(height(1.0 / 3), 800.0 / 3, accuracy: 0.1)
        XCTAssertEqual(height(0.6), 480, accuracy: 0.1)
        XCTAssertEqual(height(0.01), 200, accuracy: 0.1)
        XCTAssertEqual(height(0.01, selection: true), 260, accuracy: 0.1)
        XCTAssertLessThan(height(5), 800 - 100)
    }
    func testKeyboardCapsHeightWithoutChangingTheReadingPreference() {
        let saved = 0.6
        let typing = height(saved, available: 400, composing: true)
        XCTAssertLessThan(typing + 16, 400)
        XCTAssertGreaterThanOrEqual(typing, 300, "An expanded composer can reveal history")
        XCTAssertEqual(height(saved), 480, accuracy: 0.1, "Hiding the keyboard restores the preferred reading height")
        XCTAssertEqual(height(-1, available: 400, composing: true), 176, accuracy: 0.1)
        XCTAssertEqual(height(-1, available: 400, composing: true, selection: true), 216, accuracy: 0.1)
    }
    func testRotationRetainsFractionAndFitsCompactKeyboardViewport() {
        let fraction = 0.6
        XCTAssertEqual(height(fraction, full: 340, available: 340), 204, accuracy: 0.1)
        let limits = ReaderChatSizing.bounds(fullHeight: 340, availableHeight: 160, composing: true, hasSelection: true)
        XCTAssertGreaterThanOrEqual(limits.lowerBound, 132)
        XCTAssertLessThanOrEqual(height(fraction, full: 340, available: 160, composing: true, selection: true) + 16, 160)
        XCTAssertEqual(height(fraction), 480, accuracy: 0.1)
    }
    func testStalePreferencesAndTransientTinyViewportStayWithinBounds() {
        XCTAssertEqual(height(.nan), height(1.0 / 3))
        XCTAssertEqual(height(.infinity), height(1.0 / 3))
        XCTAssertEqual(height(0), height(1.0 / 3))
        XCTAssertEqual(height(0.8, available: 0), 0)
        XCTAssertLessThanOrEqual(height(0.8, available: 100, selection: true), 84)
    }
    private func height(_ fraction: Double, full: CGFloat = 800, available: CGFloat = 800, composing: Bool = false, selection: Bool = false) -> CGFloat {
        ReaderChatSizing.height(fraction: fraction, fullHeight: full, availableHeight: available, composing: composing, hasSelection: selection)
    }
}
