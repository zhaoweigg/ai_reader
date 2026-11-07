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
        for _ in 0..<8 {
            if element.exists {
                let frame = element.frame, visible = frame.intersection(app.bestsellerViewport)
                if !visible.isNull && visible.width >= 24 && visible.height >= 24 { return }
                if frame.height > 0 && frame.maxY <= app.bestsellerViewport.minY { app.swipeDown(); continue }
            }
            app.swipeUp()
        }
        XCTFail("Control has no visible tap area: \(element.identifier), frame \(element.frame), viewport \(app.bestsellerViewport)")
    }
    @MainActor private func open(_ app: XCUIApplication) {
        app.tabBars.buttons["Discover"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Discover"].isSelected)
        let picker = app.segmentedControls["zlibraryFeedPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8)); picker.buttons["Bestsellers"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["bestsellersHeading"].waitForExistence(timeout: 8))
    }
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element); waitForExpectations(timeout: 10)
    }
    @MainActor private func detail(_ app: XCUIApplication, rank: Int = 1) {
        let card = app.buttons["bestsellerBook-indie-nonfiction-\(rank)"]; reveal(card, app: app); card.bestsellerTapVisible(in: app)
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
        let shelf = app.buttons["bestsellerSeeAll"]; reveal(shelf, app: app); capture("Library bestseller shelf beside Z-Library recommendations"); shelf.bestsellerTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Discover"].isSelected)
        for source in ["Indie", "New York Times"] {
            app.segmentedControls["bestsellerSourcePicker"].buttons[source].bestsellerTapVisible(in: app)
            for genre in ["Fiction", "Nonfiction"] {
                app.segmentedControls["bestsellerGenrePicker"].buttons[genre].bestsellerTapVisible(in: app)
                let id = "bestsellerBook-\(source == "Indie" ? "indie" : "nyt")-\(genre.lowercased())-"
                let cards = (1...3).map { app.buttons[id + String($0)] }
                for card in cards { XCTAssertTrue(card.waitForExistence(timeout: 10)) }
                XCTAssertEqual(cards[0].frame.minY, cards[1].frame.minY, accuracy: 2)
                XCTAssertEqual(cards[1].frame.minY, cards[2].frame.minY, accuracy: 2)
                XCTAssertLessThan(cards[0].frame.midX, cards[1].frame.midX); XCTAssertLessThan(cards[1].frame.midX, cards[2].frame.midX)
                capture(source + " " + genre + " three cover columns")
            }
        }
        let field = app.textFields["zlibrarySearchField"]; field.bestsellerTapVisible(in: app); field.typeText("Simply Ina"); app.buttons["zlibrarySubmitSearch"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogBook-best-nonfiction1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Search results"].exists)
        app.buttons["zlibraryClearSearch"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].isSelected)
        app.segmentedControls["zlibraryFeedPicker"].buttons["Recommended"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["Recommended"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["catalogBook-best-nonfiction1"].waitForExistence(timeout: 10))
        app.segmentedControls["zlibraryFeedPicker"].buttons["Bestsellers"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
    }
    @MainActor func testQuickAddAndCrossSourceOwnershipAvoidDuplicateImports() {
        let app = launch(); open(app)
        let add = app.buttons["bestsellerAdd-indie-nonfiction-1"]; waitEnabled(add); add.bestsellerTapVisible(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["bestsellerOwned-indie-nonfiction-1"].firstMatch.waitForExistence(timeout: 15))
        detail(app)
        XCTAssertTrue(app.buttons["bestsellerViewLibrary"].waitForExistence(timeout: 8)); capture("Bestseller imported through existing catalog service")
        app.buttons["bestsellerViewLibrary"].bestsellerTapVisible(in: app); _ = assertLibraryBook("Simply Ina", app: app)
        open(app); app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].bestsellerTapVisible(in: app)
        let owned = app.descendants(matching: .any)["bestsellerOwned-nyt-nonfiction-6"].firstMatch; reveal(owned, app: app)
        XCTAssertFalse(app.buttons["bestsellerAdd-nyt-nonfiction-6"].exists)
        capture("Same work already owned on another bestseller list")
    }
    @MainActor func testAmbiguousEditionUsesExistingBookDetailsAndImport() {
        let app = launch(); open(app)
        let choose = app.buttons["bestsellerChoose-indie-nonfiction-2"]; waitEnabled(choose); choose.bestsellerTapVisible(in: app)
        let edition = app.buttons["bestsellerEdition-best-nonfiction2-other"]; reveal(edition, app: app)
        XCTAssertFalse(app.buttons["bestsellerDetailAdd"].exists); capture("Choose between two matching editions"); edition.bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["bestsellerRankings"].firstMatch.exists)
        app.buttons["catalogAddBook"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogViewLibrary"].waitForExistence(timeout: 15)); capture("Existing Z-Library edition imported from bestseller")
        app.buttons["catalogViewLibrary"].bestsellerTapVisible(in: app); _ = assertLibraryBook("The American Way of Killing", app: app)
    }
    @MainActor func testUnmatchedBookOffersIndependentManualCatalogSearch() {
        let app = launch(); open(app); detail(app, rank: 5)
        let search = app.buttons["bestsellerSearchCatalog"]; reveal(search, app: app); search.bestsellerTapVisible(in: app)
        let field = app.textFields["bestsellerCatalogQuery"]; XCTAssertTrue(field.waitForExistence(timeout: 8))
        let clear = app.buttons["bestsellerCatalogClear"]; XCTAssertTrue(clear.waitForExistence(timeout: 8)); clear.bestsellerTapVisible(in: app)
        field.bestsellerTapVisible(in: app); field.typeText("The Rush\n")
        let edition = app.buttons["bestsellerSearchEdition-best-nonfiction5"]; XCTAssertTrue(edition.waitForExistence(timeout: 10)); edition.bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["Search Z-Library"].bestsellerTapVisible(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 8)); XCTAssertEqual(field.value as? String, "The Rush")
        XCTAssertTrue(edition.waitForExistence(timeout: 8)); edition.bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 8)); app.buttons["catalogAddBook"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogViewLibrary"].waitForExistence(timeout: 15)); app.buttons["catalogViewLibrary"].bestsellerTapVisible(in: app)
        _ = assertLibraryBook("The Rush", app: app)
    }
    @MainActor func testDisconnectedCatalogConnectsWithoutLosingBestsellerSelection() {
        let app = launch(["DISCONNECTED"]); open(app)
        let connect = app.buttons["bestsellerConnect-indie-nonfiction-1"]; XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.bestsellerTapVisible(in: app)
        let preview = app.buttons["zlibraryPreviewConnect"]; XCTAssertTrue(preview.waitForExistence(timeout: 8)); preview.bestsellerTapVisible(in: app)
        waitEnabled(app.buttons["bestsellerAdd-indie-nonfiction-1"])
        XCTAssertTrue(app.segmentedControls["zlibraryFeedPicker"].buttons["Bestsellers"].isSelected)
        capture("Shared catalog connection preserves bestseller list")
    }
    @MainActor func testMissingNYTKeyShowsPrivateConnectionAndIndieStillWorks() {
        let app = launch(["MISSING_KEY"]); open(app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["bestsellerFeedError"].waitForExistence(timeout: 10))
        app.buttons["NYT Books connection"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.secureTextFields["nytAPIKey"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["saveNYTConnection"].isEnabled)
        capture("NYT Books private connection setup"); app.buttons["Done"].bestsellerTapVisible(in: app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["Indie"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10))
    }
    @MainActor func testFeedRetryAndDownloadFailureRemainRecoverable() {
        let app = launch(["FEED_FAILURE", "DOWNLOAD_FAILURE"]); open(app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["bestsellerFeedError"].waitForExistence(timeout: 10))
        app.buttons["Try again"].firstMatch.bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
        app.segmentedControls["bestsellerSourcePicker"].buttons["Indie"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10)); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.bestsellerTapVisible(in: app)
        let error = app.staticTexts["bestsellerImportError"]; reveal(error, app: app)
        XCTAssertTrue(error.label.contains("failed")); waitEnabled(add)
        XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists); capture("Failed download keeps retry available")
    }
    @MainActor func testQuotaFailureDoesNotMarkBookOwned() {
        let app = launch(["QUOTA"]); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.bestsellerTapVisible(in: app)
        let error = app.staticTexts["bestsellerImportError"]; reveal(error, app: app)
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("limit")); XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists)
        capture("Account quota prevents import without false ownership")
    }
    @MainActor func testCancellingDownloadLeavesBookAvailable() {
        let app = launch(["SLOW_DOWNLOAD"]); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.bestsellerTapVisible(in: app)
        let cancel = app.buttons["bestsellerCancelDownload"]; XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.bestsellerTapVisible(in: app)
        waitEnabled(add); XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists); capture("Cancelled bestseller download can be retried")
    }
    @MainActor func testBestsellerAppearanceInDay() { appearance("Day") }
    @MainActor func testBestsellerAppearanceInPaper() { appearance("Paper") }
    @MainActor func testBestsellerAppearanceInNight() { appearance("Night") }
    @MainActor private func appearance(_ theme: String) {
        let app = launch(); app.tabBars.buttons["Settings"].bestsellerTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        app.buttons[theme + " theme"].bestsellerTapVisible(in: app); open(app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10)); capture(theme + " bestseller covers portrait")
        setReaderOrientation(.landscapeLeft, app: app); capture(theme + " bestseller covers landscape geometry")
        detail(app); XCTAssertTrue(app.buttons["bestsellerDetailAdd"].waitForExistence(timeout: 10)); capture(theme + " bestseller details landscape geometry")
        setReaderOrientation(.portrait, app: app); capture(theme + " bestseller details portrait")
    }
    @MainActor func testAskLeafReadsTheBestsellerListAndSelectedWork() {
        let app = launch(agent: true); open(app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10))
        app.buttons["openLibraryChat"].bestsellerTapVisible(in: app)
        ask("Summarize these books", prefix: "Screen reply: Bestsellers · 1. Simply Ina", app: app)
        app.buttons["closeReaderChat"].bestsellerTapVisible(in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeReaderChat"]); waitForExpectations(timeout: 8)
        detail(app)
        app.buttons["openLibraryChat"].bestsellerTapVisible(in: app)
        ask("What is this book about?", prefix: "Screen reply: open book Simply Ina", app: app)
        capture("Ask Leaf reads selected bestseller metadata")
    }
    @MainActor private func ask(_ text: String, prefix: String, app: XCUIApplication) {
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.bestsellerTapVisible(in: app); input.typeText(text); app.buttons["sendReaderChat"].bestsellerTapVisible(in: app)
        let answer = app.textViews.matching(NSPredicate(format: "identifier == 'chatReply' AND label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
    }
    @MainActor func testImportedBestsellerOpensAndRestoresInPages() { readImported(flow: "Pages") }
    @MainActor func testImportedBestsellerOpensAndRestoresInScroll() { readImported(flow: "Scroll") }
    @MainActor private func readImported(flow: String) {
        let app = launch(); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.bestsellerTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerViewLibrary"].waitForExistence(timeout: 15)); app.buttons["bestsellerViewLibrary"].bestsellerTapVisible(in: app)
        assertLibraryBook("Simply Ina", app: app).bestsellerTapVisible(in: app)
        let web = app.webViews["bookWebView"]; XCTAssertTrue(web.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Opening your book…"]); waitForExpectations(timeout: 20)
        if !app.buttons["Appearance"].exists { web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        waitEnabled(app.buttons["Appearance"]); app.buttons["Appearance"].bestsellerTapVisible(in: app)
        app.segmentedControls["appearanceTabs"].buttons["Layout"].bestsellerTapVisible(in: app); app.segmentedControls["readingFlow"].buttons[flow].bestsellerTapVisible(in: app)
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 8)); capture("Imported bestseller rendered in " + flow)
        if !app.buttons["closeBook"].exists { web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        app.buttons["closeBook"].bestsellerTapVisible(in: app); assertLibraryBook("Simply Ina", app: app).bestsellerTapVisible(in: app)
        XCTAssertTrue(web.waitForExistence(timeout: 15)); XCTAssertFalse(app.otherElements["readerError"].exists)
        capture("Imported bestseller reopened in " + flow)
    }
}

// Keep native input targeted to the actual visible control. On the overloaded
// iOS 27.2 host Button.tap's automatic scrolling reported {-1,-1}, even on
// controls whose actions succeeded; using isHittable to scroll then overshot
// the first row. This records geometry and still requires a real on-screen tap.
@MainActor private extension XCUIApplication {
    var bestsellerViewport: CGRect {
        var visible = frame.insetBy(dx: 4, dy: 4)
        if navigationBars.firstMatch.exists {
            let top = navigationBars.firstMatch.frame.maxY
            if top > visible.minY && top < visible.maxY { visible = CGRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top) }
        }
        if tabBars.firstMatch.exists {
            let bottom = tabBars.firstMatch.frame.minY
            if bottom > visible.minY && bottom < visible.maxY { visible.size.height = bottom - visible.minY }
        }
        if keyboards.firstMatch.exists {
            let bottom = keyboards.firstMatch.frame.minY
            if bottom > visible.minY && bottom < visible.maxY { visible.size.height = bottom - visible.minY }
        }
        return visible
    }
}
@MainActor private extension XCUIElement {
    func bestsellerTapVisible(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: 10), "Missing control: \(identifier)", file: file, line: line)
        let bounds = frame, viewport = app.bestsellerViewport, visible = bounds.intersection(viewport)
        XCTContext.runActivity(named: "Native visible control: " + (identifier.isEmpty ? label : identifier)) { activity in
            let evidence = XCTAttachment(string: "control=\(bounds), app=\(app.frame), viewport=\(viewport), visible=\(visible), hittable=\(isHittable)")
            evidence.lifetime = .keepAlways; activity.add(evidence)
        }
        // Tab buttons are deliberately below the content viewport. Other
        // controls must not fall back to taps through a keyboard or tab bar.
        let tabFrame = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame : .null
        let isTab = ["Library", "Discover", "Bookmarks", "Settings"].contains(label) && bounds.intersects(tabFrame) && !app.keyboards.firstMatch.exists
        let target = isTab ? bounds.intersection(tabFrame).intersection(app.frame) : visible
        guard !target.isNull, target.width >= 20, target.height >= 20 else {
            XCTFail("Control has no visible tap area: \(identifier), frame \(bounds), app \(app.frame)", file: file, line: line); return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.midX - app.frame.minX, dy: target.midY - app.frame.minY)).tap()
    }
}
