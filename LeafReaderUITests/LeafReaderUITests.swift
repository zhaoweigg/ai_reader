import XCTest

final class LeafReaderUITests: XCTestCase {
    @MainActor private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launch()
        return app
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testLibraryReaderBookmarksAndAppearance() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["importBooks"].waitForExistence(timeout: 10))
        capture("Library", app: app)
        app.swipeUp()
        capture("Book grid", app: app)
        for title in ["The Art of Noticing", "A Short History of Stars"] {
            let card = app.buttons["book-\(title)"]
            XCTAssertGreaterThanOrEqual(card.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(card.frame.maxX, app.frame.maxX)
        }
        app.buttons["book-The Art of Noticing"].tap()
        let bookmark = app.buttons["toggleBookmark"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 15))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: bookmark)
        waitForExpectations(timeout: 20)
        capture("EPUB day", app: app)
        let hadBookmark = bookmark.label == "Remove bookmark"
        if !hadBookmark { bookmark.tap() }
        XCTAssertEqual(bookmark.label, "Remove bookmark")
        app.buttons["Appearance"].tap()
        XCTAssertTrue(app.buttons["Night theme"].waitForExistence(timeout: 5))
        app.buttons["Night theme"].tap()
        app.buttons["Done"].tap()
        capture("EPUB night", app: app)
        app.buttons["closeBook"].tap()
        app.tabBars.buttons["Bookmarks"].tap()
        XCTAssertTrue(app.staticTexts["The Art of Noticing"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Day theme"].tap()
    }
    @MainActor func testLibrarySearchFiltersTitles() {
        let app = launchApp()
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Coast")
        XCTAssertTrue(app.buttons["book-Notes from the Coast"].exists)
        XCTAssertFalse(app.buttons["book-The Art of Noticing"].exists)
    }

    @MainActor func testPDFNavigationRestoresSavedPage() {
        let app = launchApp()
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Coast")
        app.buttons["book-Notes from the Coast"].tap()
        let bookmark = app.buttons["toggleBookmark"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: bookmark)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Page 1 of 4"].waitForExistence(timeout: 5))
        app.buttons["nextPage"].tap()
        XCTAssertTrue(app.staticTexts["Page 2 of 4"].waitForExistence(timeout: 5))
        capture("PDF", app: app)
        app.buttons["closeBook"].tap()
        app.buttons["book-Notes from the Coast"].tap()
        XCTAssertTrue(app.staticTexts["Page 2 of 4"].waitForExistence(timeout: 10))
    }
}
