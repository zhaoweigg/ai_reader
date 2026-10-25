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
        XCTAssertEqual(height(-1, available: 400, composing: true), 224, accuracy: 0.1)
        XCTAssertEqual(height(-1, available: 400, composing: true, selection: true), 256, accuracy: 0.1)
    }
    func testRotationRetainsFractionAndFitsCompactKeyboardViewport() {
        let fraction = 0.6
        XCTAssertEqual(height(fraction, full: 340, available: 340), 204, accuracy: 0.1)
        let limits = ReaderChatSizing.bounds(fullHeight: 340, availableHeight: 160, composing: true, hasSelection: true)
        XCTAssertGreaterThanOrEqual(limits.lowerBound, 126)
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
    func testComposingMinimumKeepsRoomForMessagesAndBookAcrossViewports() {
        for selection in [false, true] {
            for (full, available) in [(CGFloat(800), CGFloat(400)), (932, 510), (393, 210), (340, 160)] {
                let value = height(0.01, full: full, available: available, composing: true, selection: selection)
                // A compact header+composer uses106pt; leave at least one readable line.
                XCTAssertGreaterThanOrEqual(value - 106, 20)
                XCTAssertGreaterThanOrEqual(available - value - 16, available * 0.1)
            }
        }
    }
    func testIndependentKeyboardPreferenceRestoresAfterRotationAndSelectionChanges() {
        let reading = 0.55, typing = 0.38
        XCTAssertEqual(height(reading), 440, accuracy: 0.1)
        XCTAssertEqual(height(typing, available: 450, composing: true), 304, accuracy: 0.1)
        _ = height(typing, full: 393, available: 210, composing: true, selection: true)
        XCTAssertEqual(height(typing, available: 450, composing: true, selection: true), 304, accuracy: 0.1)
        XCTAssertEqual(height(reading), 440, accuracy: 0.1)
    }
    private func height(_ fraction: Double, full: CGFloat = 800, available: CGFloat = 800, composing: Bool = false, selection: Bool = false) -> CGFloat {
        ReaderChatSizing.height(fraction: fraction, fullHeight: full, availableHeight: available, composing: composing, hasSelection: selection)
    }
}
