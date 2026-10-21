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
    @MainActor private func readingSurface(_ app: XCUIApplication) -> XCUIElement {
        let web = app.webViews["bookWebView"]
        if web.waitForExistence(timeout: 2) { return web }
        return app.descendants(matching: .any)["bookPDFView"].firstMatch
    }
    @MainActor private func waitForBook(_ app: XCUIApplication) {
        XCTAssertTrue(readingSurface(app).waitForExistence(timeout: 10))
        let loading = app.staticTexts["Opening your book…"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
        waitForExpectations(timeout: 20)
        XCTAssertFalse(app.otherElements["readerError"].exists)
    }
    @MainActor private func showReaderControls(_ app: XCUIApplication) {
        waitForBook(app)
        if !app.buttons["closeBook"].exists {
            readingSurface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 5))
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
        showReaderControls(app)
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
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        XCTAssertTrue(app.buttons["Night theme"].waitForExistence(timeout: 5))
        app.buttons["Night theme"].tap()
        capture("Aa Night controls", app: app)
        app.buttons["Done"].tap()
        capture("EPUB night", app: app)
        showReaderControls(app)
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

    @MainActor func testPageLayoutSettingsPersistAcrossRelaunch() {
        let app = launchApp()
        app.swipeUp()
        app.buttons["book-The Art of Noticing"].tap()
        showReaderControls(app)
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Appearance"])
        waitForExpectations(timeout: 20)
        app.buttons["Appearance"].tap()
        let tabs = app.segmentedControls["appearanceTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        capture("Aa Font controls", app: app)
        app.buttons["increaseTextSize"].tap()
        XCTAssertEqual(app.sliders["fontSize"].value as? String, "20 points")
        tabs.buttons["Layout"].tap()
        app.buttons["margins-Wide"].tap()
        XCTAssertTrue(app.buttons["margins-Wide"].isSelected)
        app.buttons["margins-Narrow"].tap()
        XCTAssertTrue(app.buttons["margins-Narrow"].isSelected)
        capture("Aa Layout controls", app: app)
        let preview = XCTAttachment(string: app.debugDescription)
        preview.name = "Reader preview layout"; preview.lifetime = .keepAlways; add(preview)
        tabs.buttons["Themes"].tap()
        let compact = app.buttons["compactLayout"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        compact.tap()
        XCTAssertTrue(compact.isSelected)
        capture("Aa Themes controls", app: app)
        app.buttons["Done"].tap()
        capture("Compact reading page", app: app)
        app.terminate()
        app.launch()
        app.buttons["featuredBook"].tap()
        showReaderControls(app)
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Appearance"])
        waitForExpectations(timeout: 20)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        XCTAssertTrue(app.buttons["compactLayout"].isSelected)
    }

    @MainActor func testPDFNavigationRestoresSavedPage() {
        let app = launchApp()
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Coast")
        app.buttons["book-Notes from the Coast"].tap()
        showReaderControls(app)
        let bookmark = app.buttons["toggleBookmark"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: bookmark)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Page 1 of 4"].waitForExistence(timeout: 5))
        app.buttons["nextPage"].tap()
        showReaderControls(app)
        XCTAssertTrue(app.staticTexts["Page 2 of 4"].waitForExistence(timeout: 5))
        capture("PDF", app: app)
        app.buttons["closeBook"].tap()
        app.buttons["book-Notes from the Coast"].tap()
        showReaderControls(app)
        XCTAssertTrue(app.staticTexts["Page 2 of 4"].waitForExistence(timeout: 10))
    }

    @MainActor func testImmersiveReadingTogglesControlsWithoutMovingThePage() {
        let app = launchApp()
        app.buttons["featuredBook"].tap()
        waitForBook(app)
        let surface = readingSurface(app)
        XCTAssertFalse(app.buttons["closeBook"].exists)
        XCTAssertFalse(app.buttons["Appearance"].exists)
        let fullHeight = surface.frame.height
        XCTAssertGreaterThan(fullHeight, app.frame.height * 0.8)
        capture("Immersive EPUB", app: app)
        showReaderControls(app)
        XCTAssertEqual(surface.frame.height, fullHeight, accuracy: 1)
        app.buttons["toggleBookmark"].tap()
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
        capture("Reading controls overlay", app: app)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeBook"])
        waitForExpectations(timeout: 5)
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeBook"])
        waitForExpectations(timeout: 5)
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Add bookmark")
        surface.swipeLeft()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeBook"])
        waitForExpectations(timeout: 5)
        capture("Immersive page turn", app: app)
    }
}
