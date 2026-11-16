import XCTest
@testable import LeafReader

final class ReaderSelectionRowTests: XCTestCase {
    func testShortRowKeepsEqualShares() {
        let widths = ReaderSelectionRow.widths(fitting: [55, 43, 57, 36, 40, 38], in: 366)
        XCTAssertEqual(widths, Array(repeating: 61, count: 6))
    }
    func testCrowdedRowGivesLongLabelsTheShortLabelsSpareWidth() {
        let natural: [CGFloat] = [55, 43, 57, 36, 40, 56, 38]
        let widths = ReaderSelectionRow.widths(fitting: natural, in: 366)
        XCTAssertEqual(widths.reduce(0, +), 366, accuracy: 0.001)
        for (width, wanted) in zip(widths, natural) {
            XCTAssertGreaterThanOrEqual(width, max(ReaderSelectionRow.minimum, wanted), "No label is squeezed while the row has room")
        }
        XCTAssertGreaterThan(widths[2], widths[3], "Highlight is wider than Note")
    }
    func testRowTooNarrowForEveryLabelStillFillsItAndKeepsTouchTargets() {
        let natural: [CGFloat] = [70, 43, 72, 36, 40, 71, 38]
        let widths = ReaderSelectionRow.widths(fitting: natural, in: 339)
        XCTAssertEqual(widths.reduce(0, +), 339, accuracy: 0.001)
        for width in widths { XCTAssertGreaterThanOrEqual(width, ReaderSelectionRow.minimum - 0.001) }
        let cramped = ReaderSelectionRow.widths(fitting: natural, in: 280)
        XCTAssertEqual(cramped.reduce(0, +), 280, accuracy: 0.001)
        for width in cramped { XCTAssertGreaterThanOrEqual(width, 40 - 0.001, "Below seven touch targets every action keeps an equal floor") }
        XCTAssertEqual(ReaderSelectionRow.widths(fitting: [], in: 300), [])
    }
}
