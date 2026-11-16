import XCTest
@testable import LeafReader

final class ReaderTranslationTests: XCTestCase {
    func testPassageJoinsWrappedLinesAndKeepsParagraphs() {
        XCTAssertEqual(ReaderTranslation.passage("Walls are lined"), "Walls are lined")
        XCTAssertEqual(ReaderTranslation.passage("  marble Statues,\nhundreds upon\r\nhundreds  of them \n"), "marble Statues, hundreds upon hundreds of them")
        XCTAssertEqual(ReaderTranslation.passage("First line\nstill first.\n\n  \nSecond paragraph."), "First line still first.\n\nSecond paragraph.")
    }
    func testPassageDoesNotPutSpacesIntoWrappedChinese() {
        XCTAssertEqual(ReaderTranslation.passage("月亮升起的时候，\n我去了第九前厅。"), "月亮升起的时候，我去了第九前厅。")
        XCTAssertEqual(ReaderTranslation.passage("第三\n北厅"), "第三北厅")
        XCTAssertEqual(ReaderTranslation.passage("你好 世界"), "你好 世界", "A space the author wrote inside a line stays")
        XCTAssertEqual(ReaderTranslation.passage("阅读\nLeaf 的书"), "阅读 Leaf 的书")
    }
    func testPassageIsMissingWithoutReadableText() {
        XCTAssertNil(ReaderTranslation.passage(nil))
        XCTAssertNil(ReaderTranslation.passage(""))
        XCTAssertNil(ReaderTranslation.passage(" \n\t\n "))
    }
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
    @MainActor func testTranslateHookRaisesARequestForTheChosenPassage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, seedSamples: false)
        let model = ReaderModel(bookID: UUID(), library: store, initialLocator: nil)
        XCTAssertNil(model.translationRequest)
        let translate = try XCTUnwrap(model.selectionHooks.translate)
        translate("Walls are lined")
        let first = try XCTUnwrap(model.translationRequest)
        XCTAssertEqual(first.text, "Walls are lined")
        translate("Walls are lined")
        XCTAssertNotEqual(model.translationRequest, first, "Choosing Translate again on the same passage opens the sheet again")
        XCTAssertEqual(ReaderTranslation.isAvailable, ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0)))
    }
}
