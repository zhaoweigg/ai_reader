import XCTest

final class ZLibraryUITests: XCTestCase {
    @MainActor private func launch(feedFailure: Bool = false, details: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication();app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEAF_UI_ZLIB_MOCK"] = "1";app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = "1"
        if feedFailure { app.launchEnvironment["LEAF_UI_ZLIB_FEED_FAILURE"] = "1" }
        if let details { app.launchEnvironment["LEAF_UI_ZLIB_DETAILS"] = details }
        app.launch();return app
    }
    @MainActor private func capture(_ name:String) {
        let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot());attachment.name = name;attachment.lifetime = .keepAlways;add(attachment)
    }
    @MainActor private func search(_ query: String, app: XCUIApplication) {
        let field = app.textFields["zlibrarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout:5))
        // Tapping a long query places the caret in its middle. Use the product's clear
        // control instead of assuming repeated backspace starts at the end of the text.
        if app.buttons["zlibraryClearSearch"].exists { app.buttons["zlibraryClearSearch"].tap() }
        field.tap()
        field.typeText(query)
        XCTAssertEqual(field.value as? String,query)
        app.buttons["zlibrarySubmitSearch"].tap()
    }
    @MainActor func testPopularCatalogConnectsImportsAndPreservesExistingBook() {
        let app = launch()
        XCTAssertTrue(app.buttons["importBooks"].waitForExistence(timeout:10));app.buttons["importBooks"].tap()
        XCTAssertTrue(app.buttons["addFromZLibrary"].waitForExistence(timeout:5))
        capture("Add books sources")
        app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.staticTexts["Most popular"].waitForExistence(timeout:10))
        XCTAssertTrue(app.textFields["zlibrarySearchField"].exists)
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:10))
        capture("Most popular portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:5));capture("Most popular landscape")
        XCUIDevice.shared.orientation = .portrait
        search("The Art of Noticing",app:app)
        XCTAssertTrue(app.staticTexts["Search results"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:5))
        app.buttons["catalogBook-sample"].tap()
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout:5));app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.buttons["zlibraryPreviewConnect"].waitForExistence(timeout:5));app.buttons["zlibraryPreviewConnect"].tap()
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout:5))
        expectation(for:NSPredicate(format:"label == %@ AND hittable == true","Add to library"),evaluatedWith:app.buttons["catalogAddBook"])
        waitForExpectations(timeout:5)
        app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.staticTexts["catalogAdded"].waitForExistence(timeout:15))
        capture("Book added")
        app.navigationBars.buttons["Z-Library"].tap()
        let addedCard = app.buttons["catalogBook-sample"]
        XCTAssertTrue(addedCard.waitForExistence(timeout:5))
        XCTAssertTrue(addedCard.label.contains("In library"))
        XCTAssertTrue(addedCard.label.contains("1.8 MB"))
        XCTAssertTrue(addedCard.label.contains("52 ratings"))
        addedCard.tap()
        XCTAssertTrue(app.buttons["catalogViewLibrary"].waitForExistence(timeout:5))
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
    @MainActor func testBookCardsShowSizesRatingsAndHonestMissingDataInDarkAppearance() {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Night theme"].tap()
        XCTAssertTrue(app.buttons["Night theme"].isSelected)
        app.tabBars.buttons["Library"].tap()
        app.buttons["importBooks"].tap();app.buttons["addFromZLibrary"].tap()
        let rated = app.buttons["catalogBook-sample"], unrated = app.buttons["catalogBook-sample2"]
        XCTAssertTrue(rated.waitForExistence(timeout:10))
        XCTAssertTrue(rated.label.contains("EPUB · 1.8 MB"))
        XCTAssertTrue(rated.label.contains("English · 2026"))
        XCTAssertTrue(rated.label.contains("52 ratings"))
        XCTAssertTrue(unrated.label.contains("PDF · 2.4 MB"))
        XCTAssertTrue(unrated.label.contains("No rating provided"))
        capture("Catalog metadata dark portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for:NSPredicate { _,_ in app.frame.width > app.frame.height },evaluatedWith:app)
        waitForExpectations(timeout:5)
        let scroll = app.scrollViews.firstMatch
        let start = scroll.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.8))
        let end = scroll.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.2))
        start.press(forDuration:0.05,thenDragTo:end)
        start.press(forDuration:0.05,thenDragTo:end)
        // The bottom of each card contains its metadata. Existence alone also
        // passes when those lines are below the landscape viewport.
        for card in [rated,unrated] {
            XCTAssertGreaterThan(card.frame.maxY,scroll.frame.minY + 100)
            XCTAssertLessThanOrEqual(card.frame.maxY,scroll.frame.maxY - 4)
        }
        capture("Catalog metadata dark landscape")
        XCUIDevice.shared.orientation = .portrait
        expectation(for:NSPredicate { _,_ in app.frame.height > app.frame.width },evaluatedWith:app)
        waitForExpectations(timeout:5)
        app.swipeDown()
        search("The Art of Noticing",app:app)
        XCTAssertTrue(rated.waitForExistence(timeout:5));XCTAssertTrue(rated.label.contains("52 ratings"))
        capture("Search metadata dark portrait")
        rated.tap()
        XCTAssertTrue(app.staticTexts["Ratings & reviews"].waitForExistence(timeout:5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["File quality 4.2"].exists)
        XCTAssertTrue(app.staticTexts["Scores are supplied by Z-Library. Written reviews are not available through this connection."].exists)
        capture("Book rating and file quality details")
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
    @MainActor func testSparsePopularEntryResolvesDetailsThenImportsWithoutSearch() {
        let app = launch(details: "success")
        app.tabBars.buttons["Settings"].tap(); app.buttons["Sage theme"].tap()
        app.tabBars.buttons["Library"].tap()
        app.buttons["importBooks"].tap(); app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:10))
        app.buttons["catalogBook-sample"].tap()
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["EPUB · 1 MB"].exists)
        XCTAssertFalse(app.staticTexts["Leaf does not support this edition’s format. Choose another book or edition."].exists)
        capture("Sparse popular book resolved Sage portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout:5))
        capture("Sparse popular download action landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.buttons["zlibraryPreviewConnect"].waitForExistence(timeout:5));app.buttons["zlibraryPreviewConnect"].tap()
        expectation(for:NSPredicate(format:"label == %@ AND hittable == true","Add to library"),evaluatedWith:app.buttons["catalogAddBook"])
        waitForExpectations(timeout:5)
        app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.staticTexts["catalogAdded"].waitForExistence(timeout:15))
        capture("Sparse popular book added without search")
        app.buttons["catalogViewLibrary"].tap();app.swipeUp()
        XCTAssertEqual(app.buttons.matching(identifier:"book-The Art of Noticing").count,1)
        app.buttons["book-The Art of Noticing"].tap()
        let surface = app.webViews["bookWebView"]
        XCTAssertTrue(surface.waitForExistence(timeout:15))
        expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.staticTexts["Opening your book…"])
        waitForExpectations(timeout:20)
        for flow in ["Pages", "Scroll"] {
            if !app.buttons["closeBook"].exists { surface.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap() }
            XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout:5))
            expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:app.buttons["Appearance"]);waitForExpectations(timeout:20)
            app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            surface.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2)).tap()
            XCTAssertFalse(app.otherElements["readerError"].exists)
            capture("Sparse popular import opened in \(flow)")
        }
    }
    @MainActor func testSparsePopularDetailsFailureCanRetryAndUnsupportedIsDistinct() {
        for scenario in ["failure", "unsupported"] {
            let app = launch(details:scenario)
            app.buttons["importBooks"].tap();app.buttons["addFromZLibrary"].tap()
            XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:10));app.buttons["catalogBook-sample"].tap()
            if scenario == "failure" {
                XCTAssertTrue(app.staticTexts["catalogDetailsError"].waitForExistence(timeout:10))
                XCTAssertFalse(app.staticTexts["Leaf does not support this edition’s format. Choose another book or edition."].exists)
                app.buttons["retryCatalogDetails"].tap()
                XCTAssertTrue(app.staticTexts["catalogDetailsError"].waitForExistence(timeout:10))
                XCTAssertTrue(app.buttons["retryCatalogDetails"].isEnabled)
            } else {
                XCTAssertTrue(app.staticTexts["Leaf does not support this edition’s format. Choose another book or edition."].waitForExistence(timeout:10))
                XCTAssertFalse(app.buttons["retryCatalogDetails"].exists)
            }
            XCTAssertFalse(app.buttons["catalogAddBook"].exists)
            capture("Sparse popular details \(scenario)")
            app.navigationBars.buttons["Z-Library"].tap()
            XCTAssertTrue(app.staticTexts["Most popular"].waitForExistence(timeout:5))
            app.terminate()
        }
    }
    @MainActor func testWebsiteDismissalCapturesContextWithoutCheckConnectionAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["LEAF_UI_TEST_ID": UUID().uuidString, "LEAF_UI_ZLIB_MOCK": "1", "LEAF_UI_ZLIB_WEBSITE_FIXTURE": "1"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        app.buttons["importBooks"].tap(); app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["Z-Library connection"].waitForExistence(timeout: 10))
        app.buttons["Z-Library connection"].tap(); app.buttons["zlibraryPreviewConnect"].tap()
        XCTAssertTrue(app.buttons["zlibraryCheckWebsite"].waitForExistence(timeout: 10))
        app.buttons["zlibraryCheckWebsite"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Offline connection fixture"].waitForExistence(timeout: 10))
        let check = app.buttons["Check connection"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: check); waitForExpectations(timeout: 10)
        capture("Website identity ready before connection check")
        app.buttons["Cancel"].tap() // Refresh an already verified account without Check connection.
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["zlibraryCheckWebsite"].exists)
        capture("Catalog recovered by closing website")
        app.terminate(); app.launch()
        app.buttons["importBooks"].tap(); app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["zlibraryCheckWebsite"].exists)
        XCTAssertFalse(app.buttons["connectZLibrary"].exists)
        capture("Refreshed website session restored after relaunch")
    }
    @MainActor func testSavedConnectionLoadsWithoutWebsiteAfterRepeatedRelaunch() {
        let app = launch()
        app.buttons["importBooks"].tap(); app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["Z-Library connection"].waitForExistence(timeout: 10))
        app.buttons["Z-Library connection"].tap()
        app.buttons["zlibraryPreviewConnect"].tap()
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["connectZLibrary"].exists)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            app.terminate(); XCUIDevice.shared.orientation = orientation; app.launch()
            XCTAssertTrue(app.buttons["importBooks"].waitForExistence(timeout: 10))
            app.buttons["importBooks"].tap(); app.buttons["addFromZLibrary"].tap()
            XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["connectZLibrary"].exists)
            XCTAssertFalse(app.buttons["zlibraryCheckWebsite"].exists)
            app.buttons["Z-Library connection"].tap()
            XCTAssertTrue(app.staticTexts["Account connected"].waitForExistence(timeout: 5))
            capture("Restored catalog account \(orientation.rawValue)")
            app.buttons["Close connection"].tap()
            capture("Restored popular catalog \(orientation.rawValue)")
        }
        XCUIDevice.shared.orientation = .portrait
    }
    @MainActor func testVerifiedAccountWithUnavailableFeedShowsWebsiteAccessWithoutSigningOut() {
        let app = launch(feedFailure:true)
        app.buttons["importBooks"].tap();app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["Z-Library connection"].waitForExistence(timeout:10))
        app.buttons["Z-Library connection"].tap()
        XCTAssertTrue(app.buttons["zlibraryPreviewConnect"].waitForExistence(timeout:5))
        app.buttons["zlibraryPreviewConnect"].tap()
        XCTAssertTrue(app.staticTexts["Your account is connected, but the website did not return popular-book data. Open the website to check access, then try again."].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["zlibraryCheckWebsite"].exists)
        XCTAssertFalse(app.buttons["connectZLibrary"].exists)
        app.buttons["Request details"].tap()
        XCTAssertTrue(app.staticTexts["zlibraryRequestDiagnostic"].waitForExistence(timeout:5))
        capture("Verified account with feed unavailable portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("Verified account with feed unavailable landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Z-Library connection"].tap()
        XCTAssertTrue(app.staticTexts["Account connected"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Preview account"].exists)
        app.buttons["Close connection"].tap()
        app.terminate();app.launch()
        app.buttons["importBooks"].tap();app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["zlibraryCheckWebsite"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["connectZLibrary"].exists)
    }
    @MainActor func testSearchPaginationEmptyStateRetryAndReturnToPopular() {
        let app = launch()
        app.buttons["importBooks"].tap();app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:10))
        let field = app.textFields["zlibrarySearchField"]
        field.tap();field.typeText("9781234567890 + C++")
        capture("Catalog search composing")
        app.buttons["zlibrarySubmitSearch"].tap()
        XCTAssertTrue(app.staticTexts["Search results"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["catalogBook-sample2"].exists)
        capture("Catalog search results portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout:5))
        capture("Catalog search results landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["catalogBook-sample"].tap()
        XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout:5))
        app.navigationBars.buttons["Z-Library"].tap()
        XCTAssertTrue(app.staticTexts["Search results"].waitForExistence(timeout:5))
        XCTAssertEqual(field.value as? String,"9781234567890 + C++")
        XCTAssertTrue(app.buttons["zlibraryLoadMore"].waitForExistence(timeout:5))
        app.buttons["zlibraryLoadMore"].tap()
        XCTAssertTrue(app.buttons["catalogBook-sample2"].waitForExistence(timeout:5))
        XCTAssertEqual(app.buttons.matching(identifier:"catalogBook-sample").count,1)
        XCTAssertFalse(app.buttons["zlibraryLoadMore"].exists)
        search("no matches",app:app)
        XCTAssertTrue(app.staticTexts["No books found"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["catalogBook-sample"].exists)
        capture("Catalog search no results")
        search("unavailable",app:app)
        XCTAssertTrue(app.staticTexts["Could not search books"].waitForExistence(timeout:5))
        app.buttons["Request details"].tap()
        XCTAssertTrue(app.staticTexts["zlibraryRequestDiagnostic"].label.hasPrefix("POST /eapi/book/search"))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["Could not search books"].waitForExistence(timeout:5))
        XCTAssertEqual(field.value as? String,"unavailable")
        capture("Catalog search failure")
        app.buttons["zlibraryClearSearch"].tap()
        XCTAssertTrue(app.staticTexts["Most popular"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["catalogBook-sample2"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["Could not search books"].exists)
    }
    @MainActor func testCatalogAndConnectionUseTheSelectedAppTheme() {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Dusk theme"].tap()
        XCTAssertTrue(app.buttons["Dusk theme"].isSelected)
        app.tabBars.buttons["Library"].tap()
        app.buttons["importBooks"].tap()
        app.buttons["addFromZLibrary"].tap()
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout: 10))
        capture("Dusk catalog")
        let search = app.textFields["zlibrarySearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("stars")
        app.buttons["zlibrarySubmitSearch"].tap()
        XCTAssertTrue(app.staticTexts["Search results"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout: 5))
        capture("Dusk catalog search results")
        app.buttons["catalogBook-sample"].tap()
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 5))
        capture("Dusk book details and filled action")
        app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.textFields["zlibraryAddress"].waitForExistence(timeout: 5))
        capture("Dusk catalog connection")
    }

}
