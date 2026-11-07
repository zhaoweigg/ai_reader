import XCTest

final class BestsellerUITests: XCTestCase {
    @MainActor private func launch(_ flags: [String] = [], agent: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["LEAF_UI_TEST_ID": UUID().uuidString, "LEAF_UI_ZLIB_MOCK": "1", "LEAF_UI_CHAT_MOCK": "1",
                                 "LEAF_UI_BESTSELLERS_MOCK": "1", "LEAF_UI_EMPTY_LIBRARY": "1", "LEAF_UI_SCENE_GEOMETRY_FIXTURE": "1"]
        for flag in flags { app.launchEnvironment["LEAF_UI_BESTSELLERS_" + flag] = "1" }
        if agent { app.launchEnvironment["LEAF_UI_CHAT_AGENT"] = "1" }
        app.launch(); registerSceneGeometryCleanup(app: app); setReaderOrientation(.portrait, app: app)
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }
    @MainActor private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 8)); XCTAssertTrue(element.isHittable)
    }
    @MainActor private func open(_ app: XCUIApplication) {
        app.tabBars.buttons["Discover"].tap()
        let picker = app.segmentedControls["zlibraryFeedPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8)); picker.buttons["Bestsellers"].tap()
        XCTAssertTrue(app.staticTexts["bestsellersHeading"].waitForExistence(timeout: 8))
    }
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element); waitForExpectations(timeout: 10)
    }
    @MainActor private func detail(_ app: XCUIApplication, rank: Int = 1) {
        let card = app.buttons["bestsellerBook-indie-nonfiction-\(rank)"]; reveal(card, app: app); card.tap()
        XCTAssertTrue(app.staticTexts["bestsellerDetailTitle"].waitForExistence(timeout: 8))
    }
    @MainActor private func assertLibraryBook(_ title: String, app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        let book = app.buttons["book-" + title]; reveal(book, app: app)
        XCTAssertEqual(app.buttons.matching(identifier: "book-" + title).count, 1)
        return book
    }
    @MainActor func testLibraryShelfAndAllSourceCategoryFiltersPreserveCatalogSearch() {
        let app = launch()
        let shelf = app.buttons["bestsellerSeeAll"]; reveal(shelf, app: app); capture("Library bestseller shelf beside Z-Library recommendations"); shelf.tap()
        XCTAssertTrue(app.tabBars.buttons["Discover"].isSelected)
        for source in ["Indie", "New York Times"] {
            app.segmentedControls["bestsellerSourcePicker"].buttons[source].tap()
            for genre in ["Fiction", "Nonfiction"] {
                app.segmentedControls["bestsellerGenrePicker"].buttons[genre].tap()
                let id = "bestsellerBook-\(source == "Indie" ? "indie" : "nyt")-\(genre.lowercased())-"
                let cards = (1...3).map { app.buttons[id + String($0)] }
                for card in cards { XCTAssertTrue(card.waitForExistence(timeout: 10)) }
                XCTAssertEqual(cards[0].frame.minY, cards[1].frame.minY, accuracy: 2)
                XCTAssertEqual(cards[1].frame.minY, cards[2].frame.minY, accuracy: 2)
                XCTAssertLessThan(cards[0].frame.midX, cards[1].frame.midX); XCTAssertLessThan(cards[1].frame.midX, cards[2].frame.midX)
                capture(source + " " + genre + " three cover columns")
            }
        }
        let field = app.textFields["zlibrarySearchField"]; field.tap(); field.typeText("Simply Ina"); app.buttons["zlibrarySubmitSearch"].tap()
        XCTAssertTrue(app.buttons["catalogBook-best-nonfiction1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Search results"].exists)
        app.buttons["zlibraryClearSearch"].tap()
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].isSelected)
        app.segmentedControls["zlibraryFeedPicker"].buttons["Recommended"].tap()
        XCTAssertTrue(app.staticTexts["Recommended"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["catalogBook-best-nonfiction1"].waitForExistence(timeout: 10))
        app.segmentedControls["zlibraryFeedPicker"].buttons["Bestsellers"].tap()
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
    }
    @MainActor func testQuickAddAndCrossSourceOwnershipAvoidDuplicateImports() {
        let app = launch(); open(app)
        let add = app.buttons["bestsellerAdd-indie-nonfiction-1"]; waitEnabled(add); add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["bestsellerOwned-indie-nonfiction-1"].firstMatch.waitForExistence(timeout: 15))
        detail(app)
        XCTAssertTrue(app.buttons["bestsellerViewLibrary"].waitForExistence(timeout: 8)); capture("Bestseller imported through existing catalog service")
        app.buttons["bestsellerViewLibrary"].tap(); _ = assertLibraryBook("Simply Ina", app: app)
        open(app); app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].tap()
        let owned = app.descendants(matching: .any)["bestsellerOwned-nyt-nonfiction-6"].firstMatch; reveal(owned, app: app)
        XCTAssertFalse(app.buttons["bestsellerAdd-nyt-nonfiction-6"].exists)
        capture("Same work already owned on another bestseller list")
    }
    @MainActor func testAmbiguousEditionUsesExistingBookDetailsAndImport() {
        let app = launch(); open(app)
        let choose = app.buttons["bestsellerChoose-indie-nonfiction-2"]; waitEnabled(choose); choose.tap()
        let edition = app.buttons["bestsellerEdition-best-nonfiction2-other"]; reveal(edition, app: app)
        XCTAssertFalse(app.buttons["bestsellerDetailAdd"].exists); capture("Choose between two matching editions"); edition.tap()
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["bestsellerRankings"].firstMatch.exists)
        app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.buttons["catalogViewLibrary"].waitForExistence(timeout: 15)); capture("Existing Z-Library edition imported from bestseller")
        app.buttons["catalogViewLibrary"].tap(); _ = assertLibraryBook("The American Way of Killing", app: app)
    }
    @MainActor func testUnmatchedBookOffersIndependentManualCatalogSearch() {
        let app = launch(); open(app); detail(app, rank: 5)
        let search = app.buttons["bestsellerSearchCatalog"]; reveal(search, app: app); search.tap()
        let field = app.textFields["bestsellerCatalogQuery"]; XCTAssertTrue(field.waitForExistence(timeout: 8))
        let clear = app.buttons["bestsellerCatalogClear"]; XCTAssertTrue(clear.waitForExistence(timeout: 8)); clear.tap()
        field.tap(); field.typeText("The Rush\n")
        let edition = app.buttons["bestsellerSearchEdition-best-nonfiction5"]; XCTAssertTrue(edition.waitForExistence(timeout: 10)); edition.tap()
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 8)); app.buttons["catalogAddBook"].tap()
        XCTAssertTrue(app.buttons["catalogViewLibrary"].waitForExistence(timeout: 15)); app.buttons["catalogViewLibrary"].tap()
        _ = assertLibraryBook("The Rush", app: app)
    }
    @MainActor func testDisconnectedCatalogConnectsWithoutLosingBestsellerSelection() {
        let app = launch(["DISCONNECTED"]); open(app)
        let connect = app.buttons["bestsellerConnect-indie-nonfiction-1"]; XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.tap()
        let preview = app.buttons["zlibraryPreviewConnect"]; XCTAssertTrue(preview.waitForExistence(timeout: 8)); preview.tap()
        waitEnabled(app.buttons["bestsellerAdd-indie-nonfiction-1"])
        XCTAssertTrue(app.segmentedControls["zlibraryFeedPicker"].buttons["Bestsellers"].isSelected)
        capture("Shared catalog connection preserves bestseller list")
    }
    @MainActor func testMissingNYTKeyShowsPrivateConnectionAndIndieStillWorks() {
        let app = launch(["MISSING_KEY"]); open(app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].tap()
        XCTAssertTrue(app.staticTexts["bestsellerFeedError"].waitForExistence(timeout: 10))
        app.buttons["NYT Books connection"].tap()
        XCTAssertTrue(app.secureTextFields["nytAPIKey"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["saveNYTConnection"].isEnabled)
        capture("NYT Books private connection setup"); app.buttons["Done"].tap()
        app.segmentedControls["bestsellerSourcePicker"].buttons["Indie"].tap()
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10))
    }
    @MainActor func testFeedRetryAndDownloadFailureRemainRecoverable() {
        let app = launch(["FEED_FAILURE", "DOWNLOAD_FAILURE"]); open(app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].tap()
        XCTAssertTrue(app.staticTexts["bestsellerFeedError"].waitForExistence(timeout: 10))
        app.buttons["Try again"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
        app.segmentedControls["bestsellerSourcePicker"].buttons["Indie"].tap()
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10)); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.tap()
        let error = app.staticTexts["bestsellerImportError"]; reveal(error, app: app)
        XCTAssertTrue(error.label.contains("failed")); waitEnabled(add)
        XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists); capture("Failed download keeps retry available")
    }
    @MainActor func testQuotaFailureDoesNotMarkBookOwned() {
        let app = launch(["QUOTA"]); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.tap()
        let error = app.staticTexts["bestsellerImportError"]; reveal(error, app: app)
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("limit")); XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists)
        capture("Account quota prevents import without false ownership")
    }
    @MainActor func testCancellingDownloadLeavesBookAvailable() {
        let app = launch(["SLOW_DOWNLOAD"]); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.tap()
        let cancel = app.buttons["bestsellerCancelDownload"]; XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        waitEnabled(add); XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists); capture("Cancelled bestseller download can be retried")
    }
    @MainActor func testBestsellerAppearanceInDay() { appearance("Day") }
    @MainActor func testBestsellerAppearanceInPaper() { appearance("Paper") }
    @MainActor func testBestsellerAppearanceInNight() { appearance("Night") }
    @MainActor private func appearance(_ theme: String) {
        let app = launch(); app.tabBars.buttons["Settings"].tap(); app.buttons[theme + " theme"].tap(); open(app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10)); capture(theme + " bestseller covers portrait")
        setReaderOrientation(.landscapeLeft, app: app); capture(theme + " bestseller covers landscape geometry")
        detail(app); XCTAssertTrue(app.buttons["bestsellerDetailAdd"].waitForExistence(timeout: 10)); capture(theme + " bestseller details landscape geometry")
        setReaderOrientation(.portrait, app: app); capture(theme + " bestseller details portrait")
    }
    @MainActor func testAskLeafReadsTheBestsellerListAndSelectedWork() {
        let app = launch(agent: true); open(app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10))
        app.buttons["openLibraryChat"].tap()
        ask("Summarize these books", prefix: "Screen reply: Bestsellers · 1. Simply Ina", app: app)
        app.buttons["closeReaderChat"].tap(); detail(app)
        app.buttons["openLibraryChat"].tap()
        ask("What is this book about?", prefix: "Screen reply: open book Simply Ina", app: app)
        capture("Ask Leaf reads selected bestseller metadata")
    }
    @MainActor private func ask(_ text: String, prefix: String, app: XCUIApplication) {
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText(text); app.buttons["sendReaderChat"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "identifier == 'chatReply' AND label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
    }
    @MainActor func testImportedBestsellerOpensAndRestoresInPages() { readImported(flow: "Pages") }
    @MainActor func testImportedBestsellerOpensAndRestoresInScroll() { readImported(flow: "Scroll") }
    @MainActor private func readImported(flow: String) {
        let app = launch(); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.tap()
        XCTAssertTrue(app.buttons["bestsellerViewLibrary"].waitForExistence(timeout: 15)); app.buttons["bestsellerViewLibrary"].tap()
        assertLibraryBook("Simply Ina", app: app).tap()
        let web = app.webViews["bookWebView"]; XCTAssertTrue(web.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Opening your book…"]); waitForExpectations(timeout: 20)
        if !app.buttons["Appearance"].exists { web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        waitEnabled(app.buttons["Appearance"]); app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap(); app.segmentedControls["readingFlow"].buttons[flow].tap()
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 8)); capture("Imported bestseller rendered in " + flow)
        if !app.buttons["closeBook"].exists { web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        app.buttons["closeBook"].tap(); assertLibraryBook("Simply Ina", app: app).tap()
        XCTAssertTrue(web.waitForExistence(timeout: 15)); XCTAssertFalse(app.otherElements["readerError"].exists)
        capture("Imported bestseller reopened in " + flow)
    }
}
