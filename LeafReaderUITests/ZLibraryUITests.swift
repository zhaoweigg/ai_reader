import XCTest

final class ZLibraryUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication();app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEAF_UI_ZLIB_MOCK"] = "1";app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = "1"
        app.launch();return app
    }
    @MainActor private func capture(_ name:String) {
        let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot());attachment.name = name;attachment.lifetime = .keepAlways;add(attachment)
    }
    @MainActor func testPopularCatalogConnectsImportsAndPreservesExistingBook() {
        let app = launch()
        XCTAssertTrue(app.buttons["importBooks"].waitForExistence(timeout:10));app.buttons["importBooks"].tap()
        XCTAssertTrue(app.buttons["addFromZLibrary"].waitForExistence(timeout:5))
        capture("Add books sources")
        app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.staticTexts["Most popular"].waitForExistence(timeout:10))
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:10))
        capture("Most popular portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:5));capture("Most popular landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["catalogBook-sample"].tap()
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout:5));app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.buttons["zlibraryPreviewConnect"].waitForExistence(timeout:5));app.buttons["zlibraryPreviewConnect"].tap()
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout:5))
        expectation(for:NSPredicate(format:"label == %@ AND hittable == true","Add to library"),evaluatedWith:app.buttons["catalogAddBook"])
        waitForExpectations(timeout:5)
        app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.staticTexts["catalogAdded"].waitForExistence(timeout:15))
        capture("Book added")
        app.buttons["catalogViewLibrary"].tap()
        XCTAssertTrue(app.buttons["importBooks"].waitForExistence(timeout:5))
        // The same EPUB already exists in the seeded library; it must not be duplicated.
        app.swipeUp()
        XCTAssertEqual(app.buttons.matching(identifier:"book-The Art of Noticing").count,1)
        app.buttons["book-The Art of Noticing"].tap()
        let surface = app.webViews["bookWebView"]
        XCTAssertTrue(surface.waitForExistence(timeout:15))
        expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.staticTexts["Opening your book…"])
        waitForExpectations(timeout:20)
        XCTAssertFalse(app.otherElements["readerError"].exists)
        for flow in ["Pages","Scroll"] {
            if !app.buttons["closeBook"].exists { surface.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap() }
            XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout:5))
            expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:app.buttons["Appearance"]);waitForExpectations(timeout:20)
            app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            let reader = app.webViews["bookWebView"]
            reader.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2)).tap()
            capture("Imported book \(flow)")
        }
    }
    @MainActor func testConnectionRejectsUnsafeAddressAndCancellingKeepsCatalog() {
        let app = launch();app.buttons["importBooks"].tap();app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["Z-Library connection"].waitForExistence(timeout:10));app.buttons["Z-Library connection"].tap()
        let address = app.textFields["zlibraryAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5));address.tap()
        if let value = address.value as? String { address.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:value.count)) }
        address.typeText("http://wrong.example")
        app.buttons["Save website address"].tap()
        XCTAssertTrue(app.staticTexts["Enter an HTTPS website address without a path, port, or sign-in details."].waitForExistence(timeout:5))
        app.buttons["Close connection"].tap()
        XCTAssertTrue(app.staticTexts["Most popular"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["catalogBook-sample"].exists)
    }
}
