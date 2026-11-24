import XCTest

final class BestsellerUITests: XCTestCase {
    @MainActor private func launch(_ flags: [String] = [], agent: Bool = false, catalogFlags: [String] = [], emptyLibrary: Bool = true,
                                   webNovels: Bool = false, webNovelFeedFailure: Bool = false, reviewsFailure: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["LEAF_UI_TEST_ID": UUID().uuidString, "LEAF_UI_ZLIB_MOCK": "1", "LEAF_UI_CHAT_MOCK": "1",
                                 "LEAF_UI_BESTSELLERS_MOCK": "1", "LEAF_UI_ZLIB_SHELF": "1", "LEAF_UI_EMPTY_LIBRARY": "1", "LEAF_UI_SCENE_GEOMETRY_FIXTURE": "1"]
        for flag in flags { app.launchEnvironment["LEAF_UI_BESTSELLERS_" + flag] = "1" }
        for flag in catalogFlags { app.launchEnvironment["LEAF_UI_ZLIB_" + flag] = "1" }
        if !emptyLibrary { app.launchEnvironment.removeValue(forKey: "LEAF_UI_EMPTY_LIBRARY") }
        if agent { app.launchEnvironment["LEAF_UI_CHAT_AGENT"] = "1" }
        if reviewsFailure { app.launchEnvironment["LEAF_UI_BOOK_REVIEWS_FAILURE"] = "1" }
        if webNovels {
            // The 中文 fixture brings its own catalog editions in place of the bestseller ones.
            app.launchEnvironment.removeValue(forKey: "LEAF_UI_BESTSELLERS_MOCK"); app.launchEnvironment.removeValue(forKey: "LEAF_UI_ZLIB_SHELF")
            app.launchEnvironment["LEAF_UI_WEB_NOVELS_MOCK"] = "1"
            if webNovelFeedFailure { app.launchEnvironment["LEAF_UI_WEB_NOVELS_FEED_FAILURE"] = "1" }
        }
        app.launch(); registerSceneGeometryCleanup(app: app); setReaderOrientation(.portrait, app: app)
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            // Lazy Library cards have no AX snapshot before they scroll into
            // view. Do not read identifier/frame to find their parent yet.
            if element.exists {
                let frame = element.frame, viewport = app.leafContentViewport
                let visible = frame.intersection(viewport)
                // leafTapVisible aims at the middle of what is inside the window, so that
                // point has to be clear of the tab bar too, not just a strip of the control.
                let aim = frame.intersection(app.frame.insetBy(dx: 2, dy: 2))
                if frame.width > 1 && frame.height > 1 && !visible.isNull,
                   visible.width + 0.5 >= min(24, frame.width), visible.height + 0.5 >= min(24, frame.height),
                   !aim.isNull, viewport.contains(CGPoint(x: aim.midX, y: aim.midY)) { return }
                let scroll = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
                // Bring up what sits low or behind the tab bar; bring down what is behind the navigation bar.
                app.leafDragContent(up: aim.isNull ? frame.maxY > viewport.minY : aim.midY >= viewport.minY, in: scroll)
            } else { app.leafDragContent(up: true) }
        }
        XCTContext.runActivity(named: "Unreachable discovery control") { activity in
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; activity.add(screenshot)
        }
        let description = element.exists ? "\(element.identifier), frame \(element.frame)" : "lazy control has not materialized"
        XCTFail("Control has no visible tap area: \(description), viewport \(app.leafContentViewport)")
    }
    @MainActor private func open(_ app: XCUIApplication) {
        app.tabBars.buttons["Discover"].leafTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Discover"].isSelected)
        let picker = app.segmentedControls["zlibraryFeedPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8)); picker.buttons["Bestsellers"].leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["bestsellersHeading"].waitForExistence(timeout: 8))
    }
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element); waitForExpectations(timeout: 10)
    }
    @MainActor private func detail(_ app: XCUIApplication, rank: Int = 1) {
        let card = app.buttons["bestsellerBook-indie-nonfiction-\(rank)"]; reveal(card, app: app); card.leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["bestsellerDetailTitle"].waitForExistence(timeout: 8))
    }
    @MainActor private func assertLibraryBook(_ title: String, app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        let book = app.buttons["book-" + title]; reveal(book, app: app)
        XCTAssertEqual(app.buttons.matching(identifier: "book-" + title).count, 1)
        return book
    }
    @MainActor private func libraryShelf(_ app: XCUIApplication, book: String) {
        let tab = app.tabBars.buttons["Library"]; tab.leafTapVisible(in: app); XCTAssertTrue(tab.isSelected)
        let title = app.staticTexts["discoverShelfTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label == %@", "Recommended for you"), evaluatedWith: title); waitForExpectations(timeout: 10)
        let card = app.buttons["discoverShelfBook-" + book]; reveal(card, app: app)
        XCTAssertTrue(card.exists)
    }
    @MainActor private func connectCatalog(_ app: XCUIApplication) {
        open(app)
        app.buttons["Z-Library connection"].leafTapVisible(in: app)
        app.buttons["zlibraryPreviewConnect"].leafTapVisible(in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["zlibraryPreviewConnect"]); waitForExpectations(timeout: 8)
    }
    @MainActor func testLibraryRecommendationsRefreshAfterConnectingAndReconnecting() {
        let app = launch(["DISCONNECTED"], catalogFlags: ["SHELF_REFRESH"], emptyLibrary: false)
        app.tabBars.buttons["Settings"].leafTapVisible(in: app); app.buttons["Paper theme"].leafTapVisible(in: app)
        app.tabBars.buttons["Library"].leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["discoverShelfTitle"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["discoverShelfTitle"].label, "Popular on Z-Library")
        connectCatalog(app); libraryShelf(app, book: "shelf-initial")
        capture("Library recommendations appear after connecting")
        connectCatalog(app); libraryShelf(app, book: "shelf-refreshed")
        XCTAssertFalse(app.buttons["discoverShelfBook-shelf-initial"].exists)
        let bestseller = app.buttons["bestsellerShelfBook-1"]; reveal(bestseller, app: app); XCTAssertTrue(bestseller.exists)
        capture("Paper Library reconnect updates recommendations beside bestsellers")
    }
    @MainActor func testLibraryRecommendationFailureShowsRetryAndRecoversWithBestsellersIntact() {
        let app = launch(["DISCONNECTED"], catalogFlags: ["SHELF_RETRY"])
        app.tabBars.buttons["Settings"].leafTapVisible(in: app); app.buttons["Night theme"].leafTapVisible(in: app)
        connectCatalog(app); app.tabBars.buttons["Library"].leafTapVisible(in: app)
        let error = app.staticTexts["discoverShelfError"]; XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["retryDiscoverShelf"].isEnabled); capture("Night Library shows recoverable recommendation error")
        app.buttons["retryDiscoverShelf"].leafTapVisible(in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: error); waitForExpectations(timeout: 10)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discoverShelfBook-"))
        expectation(for: NSPredicate { _, _ in cards.count > 0 }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertEqual(app.staticTexts["discoverShelfTitle"].label, "Recommended for you")
        let bestseller = app.buttons["bestsellerShelfBook-1"]; reveal(bestseller, app: app); XCTAssertTrue(bestseller.exists)
        capture("Night Library retry restores recommendations and keeps bestseller covers")
    }
    @MainActor func testLibraryPullToRefreshRequestsFreshRecommendationsAndKeepsBestsellers() {
        let app = launch(catalogFlags: ["SHELF_REFRESH"])
        libraryShelf(app, book: "shelf-initial")
        // Start on the plain Library header and drag down within its visible
        // vertical scroll surface, above the horizontal recommendation row.
        let viewport = app.leafContentViewport, origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: app.frame.midX, dy: viewport.minY + 70))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: viewport.maxY - 70)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let updated = app.buttons["discoverShelfBook-shelf-refreshed"]; XCTAssertTrue(updated.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["discoverShelfBook-shelf-initial"].exists)
        let bestseller = app.buttons["bestsellerShelfBook-1"]; reveal(bestseller, app: app); XCTAssertTrue(bestseller.exists)
        capture("Library pull refresh updates recommendations beside bestseller shelf")
    }
    @MainActor func testLibraryEmptyRecommendationsHaveAnHonestStateAndKeepBestsellers() {
        let app = launch(catalogFlags: ["SHELF_EMPTY"])
        let empty = app.staticTexts["discoverShelfEmpty"]; XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["discoverShelfError"].exists)
        XCTAssertEqual(app.staticTexts["discoverShelfTitle"].label, "Recommended for you")
        let bestseller = app.buttons["bestsellerShelfBook-1"]; reveal(bestseller, app: app); XCTAssertTrue(bestseller.exists)
        capture("Connected empty recommendations keep the public bestseller shelf")
    }
    @MainActor func testLibraryShelfAndAllSourceCategoryFiltersPreserveCatalogSearch() {
        let app = launch()
        let shelf = app.buttons["bestsellerSeeAll"]; reveal(shelf, app: app); capture("Library bestseller shelf beside Z-Library recommendations"); shelf.leafTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Discover"].isSelected)
        for source in ["Indie", "New York Times"] {
            app.segmentedControls["bestsellerSourcePicker"].buttons[source].leafTapVisible(in: app)
            for genre in ["Fiction", "Nonfiction"] {
                app.segmentedControls["bestsellerGenrePicker"].buttons[genre].leafTapVisible(in: app)
                let id = "bestsellerBook-\(source == "Indie" ? "indie" : "nyt")-\(genre.lowercased())-"
                let cards = (1...3).map { app.buttons[id + String($0)] }
                for card in cards { XCTAssertTrue(card.waitForExistence(timeout: 10)) }
                XCTAssertEqual(cards[0].frame.minY, cards[1].frame.minY, accuracy: 2)
                XCTAssertEqual(cards[1].frame.minY, cards[2].frame.minY, accuracy: 2)
                XCTAssertLessThan(cards[0].frame.midX, cards[1].frame.midX); XCTAssertLessThan(cards[1].frame.midX, cards[2].frame.midX)
                capture(source + " " + genre + " three cover columns")
            }
        }
        let field = app.textFields["zlibrarySearchField"]; field.leafTapVisible(in: app); field.typeText("Simply Ina"); app.buttons["zlibrarySubmitSearch"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogBook-best-nonfiction1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Search results"].exists)
        app.buttons["zlibraryClearSearch"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].isSelected)
        app.segmentedControls["zlibraryFeedPicker"].buttons["For you"].leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["Recommended"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["catalogBook-best-nonfiction1"].waitForExistence(timeout: 10))
        app.segmentedControls["zlibraryFeedPicker"].buttons["Bestsellers"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
    }
    @MainActor func testQuickAddAndCrossSourceOwnershipAvoidDuplicateImports() {
        let app = launch(); open(app)
        let add = app.buttons["bestsellerAdd-indie-nonfiction-1"]; waitEnabled(add); add.leafTapVisible(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["bestsellerOwned-indie-nonfiction-1"].firstMatch.waitForExistence(timeout: 15))
        detail(app)
        XCTAssertTrue(app.buttons["bestsellerViewLibrary"].waitForExistence(timeout: 8)); capture("Bestseller imported through existing catalog service")
        app.buttons["bestsellerViewLibrary"].leafTapVisible(in: app); _ = assertLibraryBook("Simply Ina", app: app)
        open(app); app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].leafTapVisible(in: app)
        let owned = app.descendants(matching: .any)["bestsellerOwned-nyt-nonfiction-6"].firstMatch; reveal(owned, app: app)
        XCTAssertFalse(app.buttons["bestsellerAdd-nyt-nonfiction-6"].exists)
        capture("Same work already owned on another bestseller list")
    }
    @MainActor func testAmbiguousEditionUsesExistingBookDetailsAndImport() {
        let app = launch(); open(app)
        let choose = app.buttons["bestsellerChoose-indie-nonfiction-2"]; waitEnabled(choose); choose.leafTapVisible(in: app)
        let edition = app.buttons["bestsellerEdition-best-nonfiction2-other"]; reveal(edition, app: app)
        XCTAssertFalse(app.buttons["bestsellerDetailAdd"].exists); capture("Choose between two matching editions"); edition.leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["bestsellerRankings"].firstMatch.exists)
        app.buttons["catalogAddBook"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogViewLibrary"].waitForExistence(timeout: 15)); capture("Existing Z-Library edition imported from bestseller")
        app.buttons["catalogViewLibrary"].leafTapVisible(in: app); _ = assertLibraryBook("The American Way of Killing", app: app)
    }
    @MainActor func testUnmatchedBookOffersIndependentManualCatalogSearch() {
        let app = launch(); open(app); detail(app, rank: 5)
        let search = app.buttons["bestsellerSearchCatalog"]; reveal(search, app: app); search.leafTapVisible(in: app)
        let field = app.textFields["bestsellerCatalogQuery"]; XCTAssertTrue(field.waitForExistence(timeout: 8))
        let clear = app.buttons["bestsellerCatalogClear"]; XCTAssertTrue(clear.waitForExistence(timeout: 8)); clear.leafTapVisible(in: app)
        field.leafTapVisible(in: app); field.typeText("The Rush\n")
        let edition = app.buttons["bestsellerSearchEdition-best-nonfiction5"]; XCTAssertTrue(edition.waitForExistence(timeout: 10)); edition.leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["Search Z-Library"].leafTapVisible(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 8)); XCTAssertEqual(field.value as? String, "The Rush")
        XCTAssertTrue(edition.waitForExistence(timeout: 8)); edition.leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogAddBook"].waitForExistence(timeout: 8)); app.buttons["catalogAddBook"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["catalogViewLibrary"].waitForExistence(timeout: 15)); app.buttons["catalogViewLibrary"].leafTapVisible(in: app)
        _ = assertLibraryBook("The Rush", app: app)
    }
    @MainActor func testDisconnectedCatalogConnectsWithoutLosingBestsellerSelection() {
        let app = launch(["DISCONNECTED"]); open(app)
        let connect = app.buttons["bestsellerConnect-indie-nonfiction-1"]; XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.leafTapVisible(in: app)
        let preview = app.buttons["zlibraryPreviewConnect"]; XCTAssertTrue(preview.waitForExistence(timeout: 8)); preview.leafTapVisible(in: app)
        waitEnabled(app.buttons["bestsellerAdd-indie-nonfiction-1"])
        XCTAssertTrue(app.segmentedControls["zlibraryFeedPicker"].buttons["Bestsellers"].isSelected)
        capture("Shared catalog connection preserves bestseller list")
    }
    @MainActor func testNYTWithoutKeyLoadsBothCategoriesAndKeepsIndieAvailable() {
        let app = launch(["MISSING_KEY"]); open(app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["bestsellerFeedError"].exists)
        capture("NYT nonfiction loads without an API key")
        app.segmentedControls["bestsellerGenrePicker"].buttons["Fiction"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-fiction-1"].waitForExistence(timeout: 10))
        capture("NYT fiction loads without an API key")
        let source = app.descendants(matching: .any)["bestsellerPublicSource"].firstMatch; reveal(source, app: app)
        XCTAssertTrue(source.exists)
        capture("Public NYT source attribution")
        let picker = app.segmentedControls["bestsellerSourcePicker"]; reveal(picker, app: app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["Indie"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-fiction-1"].waitForExistence(timeout: 10))
    }
    @MainActor func testFeedRetryAndDownloadFailureRemainRecoverable() {
        let app = launch(["FEED_FAILURE", "DOWNLOAD_FAILURE"]); open(app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["bestsellerFeedError"].waitForExistence(timeout: 10))
        app.buttons["Try again"].firstMatch.leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-nyt-nonfiction-1"].waitForExistence(timeout: 10))
        app.segmentedControls["bestsellerSourcePicker"].buttons["Indie"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10)); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.leafTapVisible(in: app)
        let error = app.staticTexts["bestsellerImportError"]; reveal(error, app: app)
        XCTAssertTrue(error.label.contains("failed")); waitEnabled(add)
        XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists); capture("Failed download keeps retry available")
    }
    @MainActor func testQuotaFailureDoesNotMarkBookOwned() {
        let app = launch(["QUOTA"]); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.leafTapVisible(in: app)
        let error = app.staticTexts["bestsellerImportError"]; reveal(error, app: app)
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("allowance")); XCTAssertTrue(error.label.localizedCaseInsensitiveContains("used up"))
        XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists); waitEnabled(add)
        capture("Account quota prevents import without false ownership")
    }
    @MainActor func testCancellingDownloadLeavesBookAvailable() {
        let app = launch(["SLOW_DOWNLOAD"]); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.leafTapVisible(in: app)
        let cancel = app.buttons["bestsellerCancelDownload"]; XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.leafTapVisible(in: app)
        waitEnabled(add); XCTAssertFalse(app.buttons["bestsellerViewLibrary"].exists); capture("Cancelled bestseller download can be retried")
    }
    @MainActor func testBestsellerAppearanceInDay() { appearance("Day") }
    @MainActor func testBestsellerAppearanceInPaper() { appearance("Paper") }
    @MainActor func testBestsellerAppearanceInNight() { appearance("Night") }
    @MainActor private func appearance(_ theme: String) {
        let app = launch(); app.tabBars.buttons["Settings"].leafTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        app.buttons[theme + " theme"].leafTapVisible(in: app); open(app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10)); capture(theme + " bestseller covers portrait")
        setReaderOrientation(.landscapeLeft, app: app); capture(theme + " bestseller covers landscape geometry")
        detail(app); XCTAssertTrue(app.buttons["bestsellerDetailAdd"].waitForExistence(timeout: 10)); capture(theme + " bestseller details landscape geometry")
        setReaderOrientation(.portrait, app: app); capture(theme + " bestseller details portrait")
    }
    @MainActor func testAskLeafReadsTheBestsellerListAndSelectedWork() {
        let app = launch(agent: true); open(app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10))
        app.buttons["openLibraryChat"].leafTapVisible(in: app)
        ask("Summarize these books", prefix: "Screen reply: Bestsellers · 1. Simply Ina", app: app)
        app.buttons["closeReaderChat"].leafTapVisible(in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeReaderChat"]); waitForExpectations(timeout: 8)
        detail(app)
        app.buttons["openLibraryChat"].leafTapVisible(in: app)
        ask("What is this book about?", prefix: "Screen reply: open book Simply Ina", app: app)
        capture("Ask Leaf reads selected bestseller metadata")
    }
    @MainActor private func ask(_ text: String, prefix: String, app: XCUIApplication) {
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.leafTapVisible(in: app); input.typeText(text); app.buttons["sendReaderChat"].leafTapVisible(in: app)
        let answer = app.textViews.matching(NSPredicate(format: "identifier == 'chatReply' AND label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
    }
    // MARK: 中文 (起点 and 微信读书)

    @MainActor private func openWebNovels(_ app: XCUIApplication) {
        app.tabBars.buttons["Discover"].leafTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Discover"].isSelected)
        let picker = app.segmentedControls["zlibraryFeedPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        for title in ["Popular", "For you", "Bestsellers", "中文"] { XCTAssertTrue(picker.buttons[title].exists, "\(title) segment") }
        picker.buttons["中文"].leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["webNovelsHeading"].waitForExistence(timeout: 8))
        XCTAssertTrue(picker.buttons["中文"].isSelected)
        // 起点 is the site shown until the reader picks the other.
        XCTAssertTrue(app.segmentedControls["webNovelSourcePicker"].buttons["起点"].isSelected)
    }
    @MainActor private func webNovelRow(_ rank: Int, has text: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["webNovelRow-\(rank)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: row); waitForExpectations(timeout: 10)
    }
    /// The floating Ask Leaf button rests over the right edge, where each row's action is.
    /// Scroll the row out from under it, as a reader would, before tapping the action.
    @MainActor private func tapClearOfChatButton(_ element: XCUIElement, app: XCUIApplication) {
        reveal(element, app: app)
        let chat = app.buttons["openLibraryChat"], origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 where chat.exists && element.frame.intersects(chat.frame.insetBy(dx: -36, dy: -36)) {
            let start = origin.withOffset(CGVector(dx: 90, dy: app.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)), withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        XCTAssertFalse(chat.exists && element.frame.intersects(chat.frame), "\(element.identifier) is still under the chat button")
        element.leafTapVisible(in: app)
    }
    @MainActor func testWebNovelChartListsRowsWithSynopsisAndSwitchesChartPeriodAndCategory() {
        let app = launch(webNovels: true); openWebNovels(app)
        webNovelRow(1, has: "星海拾荒者, 青柠茶 · 科幻 · 128.5万字", app: app); webNovelRow(2, has: "长夜书局", app: app)
        XCTAssertEqual(app.staticTexts["webNovelListDate"].label, "2026年11月")
        // One book per row, the full width of the list; the row reads out its count and synopsis.
        let first = app.buttons["webNovelRow-1"].frame, second = app.buttons["webNovelRow-2"].frame, window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(first.maxY, second.minY); XCTAssertEqual(first.minX, second.minX, accuracy: 1)
        XCTAssertGreaterThan(first.width, window.width * 0.7)
        webNovelRow(1, has: "6.0万月票, 废土边缘的拾荒少年", app: app)
        XCTAssertFalse(app.segmentedControls["webNovelPeriodPicker"].exists, "only 推荐票榜 has periods")
        capture("中文 起点 月票榜 rows with synopsis portrait")

        app.segmentedControls["webNovelChartPicker"].buttons["推荐票"].leafTapVisible(in: app)
        webNovelRow(1, has: "机械与花", app: app)
        let period = app.segmentedControls["webNovelPeriodPicker"]; XCTAssertTrue(period.waitForExistence(timeout: 5))
        period.buttons["总榜"].leafTapVisible(in: app)
        webNovelRow(1, has: "都市烟火录", app: app)
        XCTAssertTrue(app.staticTexts["webNovelListDate"].label.hasPrefix("Retrieved"))
        app.buttons["webNovelCategory"].leafTapVisible(in: app)
        let science = app.buttons["科幻"]; XCTAssertTrue(science.waitForExistence(timeout: 5)); science.tap()
        webNovelRow(1, has: "星海拾荒者", app: app); webNovelRow(2, has: "机械与花", app: app)
        XCTAssertFalse(app.buttons["webNovelRow-3"].exists)
        XCTAssertTrue(app.buttons["webNovelCategory"].label.contains("科幻"))
        capture("中文 起点 推荐票榜 总榜 科幻")

        // The chart, period and category are still chosen after leaving for another section.
        app.segmentedControls["zlibraryFeedPicker"].buttons["Bestsellers"].leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["bestsellersHeading"].waitForExistence(timeout: 8))
        app.segmentedControls["zlibraryFeedPicker"].buttons["中文"].leafTapVisible(in: app)
        webNovelRow(1, has: "星海拾荒者", app: app)
        XCTAssertTrue(app.segmentedControls["webNovelChartPicker"].buttons["推荐票"].isSelected)
    }
    @MainActor func testWeReadChartsShowRatingsLoadMoreAndEachSiteKeepsItsChart() {
        let app = launch(webNovels: true); openWebNovels(app)
        let site = app.segmentedControls["webNovelSourcePicker"], chart = app.segmentedControls["webNovelChartPicker"]
        site.buttons["微信读书"].leafTapVisible(in: app)
        for title in ["总榜", "飙升", "新书", "神作"] { XCTAssertTrue(chart.buttons[title].waitForExistence(timeout: 5), "\(title) chart") }
        XCTAssertTrue(chart.buttons["总榜"].isSelected)
        // The site's own notes stay in the title; the rating and today's readers stand where 起点 shows its count.
        webNovelRow(1, has: "星海拾荒者（全三册）, 青柠茶 · 科幻, 96.0% 推荐 · 今日 3000人在读, 废土边缘的拾荒少年", app: app)
        webNovelRow(2, has: "长夜书局, [英]墨白", app: app)
        XCTAssertFalse(app.buttons["webNovelCategory"].exists, "微信读书 charts are for the whole site")
        XCTAssertTrue(app.staticTexts["webNovelListDate"].label.hasPrefix("Retrieved"))
        capture("中文 微信读书 总榜 rows portrait")
        // The fixture serves four books at a time, as the site serves twenty.
        XCTAssertFalse(app.buttons["webNovelRow-5"].exists)
        let more = app.buttons["webNovelLoadMore"]; reveal(more, app: app); more.leafTapVisible(in: app)
        webNovelRow(5, has: "都市烟火录", app: app); webNovelRow(6, has: "机械与花", app: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: more); waitForExpectations(timeout: 8)
        capture("中文 微信读书 总榜 after Load more")
        // Each site keeps the chart last chosen on it.
        reveal(chart, app: app); chart.buttons["飙升"].leafTapVisible(in: app)
        webNovelRow(1, has: "机械与花", app: app)
        reveal(site, app: app); site.buttons["起点"].leafTapVisible(in: app)
        webNovelRow(1, has: "星海拾荒者, 青柠茶 · 科幻 · 128.5万字, 6.0万月票", app: app)
        XCTAssertTrue(chart.buttons["月票"].isSelected); XCTAssertTrue(app.buttons["webNovelCategory"].exists)
        site.buttons["微信读书"].leafTapVisible(in: app)
        webNovelRow(1, has: "机械与花", app: app); XCTAssertTrue(chart.buttons["飙升"].isSelected)
    }
    @MainActor func testWeReadRowsMatchTheCatalogDespiteTheSitesTitleAndAuthorNotes() {
        let app = launch(webNovels: true); openWebNovels(app)
        app.segmentedControls["webNovelSourcePicker"].buttons["微信读书"].leafTapVisible(in: app)
        webNovelRow(1, has: "星海拾荒者（全三册）", app: app)
        // "（全三册）" on the chart and "《…》（精校版）作者：…" in the catalog are still the same book.
        let add = app.buttons["webNovelAdd-1"]; waitEnabled(add); add.leafTapVisible(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["webNovelOwned-1"].firstMatch.waitForExistence(timeout: 15))
        // "[英]墨白" on the chart is 墨白 in the catalog; with a sequel beside it the reader chooses.
        let choose = app.buttons["webNovelChoose-2"]; reveal(choose, app: app); XCTAssertEqual(choose.label, "Choose"); tapClearOfChatButton(choose, app: app)
        XCTAssertTrue(app.staticTexts["webNovelDetailTitle"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["webNovelRanking"].label, "#2 · 总榜 · 95.0% 推荐 · 今日 2600人在读")
        XCTAssertTrue(app.buttons["View on 微信读书"].exists || app.links["View on 微信读书"].exists)
        let edition = app.buttons["bestsellerEdition-novel-900000002"]; reveal(edition, app: app)
        capture("中文 微信读书 book page with editions")
        // Added from 微信读书, the same book is already owned on 起点's chart.
        app.navigationBars.buttons.firstMatch.leafTapVisible(in: app)
        let site = app.segmentedControls["webNovelSourcePicker"]; reveal(site, app: app); site.buttons["起点"].leafTapVisible(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["webNovelOwned-1"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["webNovelAdd-1"].exists)
    }
    @MainActor func testWebNovelRowsAddChooseOrFindByTheirCatalogMatch() {
        let app = launch(webNovels: true); openWebNovels(app)
        // An upload titled 《…》（精校版）作者：… is the same book and can be added at once.
        let add = app.buttons["webNovelAdd-1"]; waitEnabled(add); add.leafTapVisible(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["webNovelOwned-1"].firstMatch.waitForExistence(timeout: 15))
        capture("中文 起点 row added to the library")
        // A sequel beside the book itself has to be chosen by the reader.
        let choose = app.buttons["webNovelChoose-2"]; reveal(choose, app: app); XCTAssertEqual(choose.label, "Choose"); tapClearOfChatButton(choose, app: app)
        XCTAssertTrue(app.staticTexts["webNovelDetailTitle"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["webNovelDetailTitle"].label, "长夜书局")
        XCTAssertEqual(app.staticTexts["webNovelRanking"].label, "#2 · 月票榜 · 全站 · 5.1万月票")
        let sequel = app.buttons["bestsellerEdition-novel-900000002-2"]; reveal(sequel, app: app)
        XCTAssertTrue(app.buttons["bestsellerEdition-novel-900000002"].exists)
        XCTAssertTrue(app.staticTexts["Confirm this is the right book"].exists); XCTAssertFalse(app.buttons["bestsellerDetailAdd"].exists)
        capture("中文 起点 book page with the book and its sequel to choose from")
        app.navigationBars.buttons.firstMatch.leafTapVisible(in: app)
        // Nothing in the catalog: the row offers a search instead.
        let find = app.buttons["webNovelChoose-3"]; reveal(find, app: app); XCTAssertEqual(find.label, "Find"); tapClearOfChatButton(find, app: app)
        XCTAssertTrue(app.staticTexts["webNovelDetailTitle"].waitForExistence(timeout: 8))
        let search = app.buttons["bestsellerSearchCatalog"]; reveal(search, app: app)
        XCTAssertTrue(app.staticTexts["No matching edition found yet."].exists)
        app.navigationBars.buttons.firstMatch.leafTapVisible(in: app)
        // The added book is recognised on its own page and opens from the library.
        let row = app.buttons["webNovelRow-1"]; reveal(row, app: app); row.leafTapVisible(in: app)
        let view = app.buttons["bestsellerViewLibrary"]; XCTAssertTrue(view.waitForExistence(timeout: 8)); view.leafTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-' AND identifier CONTAINS %@", "星海拾荒者")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10))
    }
    @MainActor func testWebNovelChartFailureIsReadableAndTryAgainLoadsIt() {
        let app = launch(webNovels: true, webNovelFeedFailure: true); openWebNovels(app)
        let error = app.staticTexts["webNovelFeedError"]; XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("could not be loaded")); XCTAssertFalse(app.buttons["webNovelRow-1"].exists)
        capture("中文 起点 chart could not be loaded")
        app.buttons["Try again"].leafTapVisible(in: app)
        webNovelRow(1, has: "星海拾荒者", app: app); XCTAssertFalse(error.exists)
    }
    @MainActor func testWebNovelRowsInNightPortraitAndLandscape() {
        let app = launch(webNovels: true); app.tabBars.buttons["Settings"].leafTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        app.buttons["Night theme"].leafTapVisible(in: app); openWebNovels(app)
        webNovelRow(1, has: "星海拾荒者", app: app); capture("Night 中文 rows portrait")
        setReaderOrientation(.landscapeLeft, app: app)
        webNovelRow(1, has: "星海拾荒者", app: app); capture("Night 中文 rows landscape")
        let row = app.buttons["webNovelRow-1"]; reveal(row, app: app); row.leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["webNovelSynopsis"].waitForExistence(timeout: 8)); capture("Night 中文 book page landscape")
        setReaderOrientation(.portrait, app: app); capture("Night 中文 book page portrait")
    }
    @MainActor func testAskLeafReadsTheWebNovelChartAndTheOpenBook() {
        let app = launch(agent: true, webNovels: true); openWebNovels(app)
        webNovelRow(1, has: "星海拾荒者", app: app)
        app.buttons["openLibraryChat"].leafTapVisible(in: app)
        ask("Which of these should I read?", prefix: "Screen reply: 中文榜单 (Chinese charts) · 1. 星海拾荒者; 2. 长夜书局; 3. 山河旧梦", app: app)
        app.buttons["closeReaderChat"].leafTapVisible(in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeReaderChat"]); waitForExpectations(timeout: 8)
        let row = app.buttons["webNovelRow-2"]; reveal(row, app: app); row.leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["webNovelDetailTitle"].waitForExistence(timeout: 8))
        app.buttons["openLibraryChat"].leafTapVisible(in: app)
        ask("What is this one about?", prefix: "Screen reply: open book 长夜书局", app: app)
        capture("Ask Leaf reads the open 中文 book")
    }

    // MARK: Ratings & reviews on the book pages (review sites and the AI are fixtures)

    @MainActor private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    /// Waits for an element's accessibility label to contain each piece, then brings it into view.
    @MainActor private func reviewPart(_ identifier: String, has pieces: [String], app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let part = element(identifier, app)
        XCTAssertTrue(part.waitForExistence(timeout: 10), "\(identifier) is missing", file: file, line: line)
        expectation(for: NSPredicate { _, _ in pieces.allSatisfy { part.label.contains($0) } }, evaluatedWith: part); waitForExpectations(timeout: 10)
        reveal(part, app: app)
    }
    @MainActor private func summarize(has text: String, app: XCUIApplication) {
        let button = app.buttons["summarizeBookReviews"]; reveal(button, app: app); button.leafTapVisible(in: app)
        let summary = app.staticTexts["bookReviewSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: summary); waitForExpectations(timeout: 10)
        reveal(summary, app: app)
    }

    @MainActor func testBestsellerPageShowsOpenLibraryRatingsACriticAndAnAskLeafSummaryThatIsKept() {
        let app = launch(); open(app); detail(app)
        reviewPart("bookRating-openLibrary", has: ["Open Library", "4.3", "1,204 ratings", "3,410 want to read"], app: app)
        XCTAssertFalse(element("bookRating-douban", app).exists, "No 豆瓣 entry for this English book")
        reviewPart("bookCriticReview-0", has: ["The New York Times", "2026-05-04"], app: app)
        capture("Bestseller page ratings and critic")
        summarize(has: "Liked: the steady pace", app: app)
        XCTAssertTrue(app.staticTexts["bookReviewSummary"].label.contains("Sources: Fixture reviews"), "Links read as their text")
        XCTAssertTrue(app.staticTexts["bookReviewSummarySource"].label.hasPrefix("Ask Leaf, from a web search"))
        XCTAssertFalse(app.buttons["summarizeBookReviews"].exists)
        capture("Bestseller page Ask Leaf summary")
        // The summary is kept for the book: back on the page, it is there without asking again.
        app.navigationBars.buttons.firstMatch.leafTapVisible(in: app); detail(app)
        let kept = app.staticTexts["bookReviewSummary"]; reveal(kept, app: app)
        XCTAssertTrue(kept.label.contains("Liked: the steady pace")); XCTAssertTrue(app.buttons["refreshBookReviewSummary"].exists)
    }

    @MainActor func testWeReadPageShowsItsRateDoubanReviewsTriesAgainAndSummarizesInChinese() {
        let app = launch(webNovels: true, reviewsFailure: true); openWebNovels(app)
        app.segmentedControls["webNovelSourcePicker"].buttons["微信读书"].leafTapVisible(in: app)
        webNovelRow(1, has: "星海拾荒者（全三册）", app: app)
        let row = app.buttons["webNovelRow-1"]; reveal(row, app: app); row.leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["webNovelDetailTitle"].waitForExistence(timeout: 8))
        // The chart's own rate shows at once; 豆瓣 does not answer the first time.
        reviewPart("bookRating-weread", has: ["微信读书", "96.0%", "recommended · 52,000 ratings", "神作"], app: app)
        reviewPart("bookReviewsUnavailable", has: ["豆瓣读书"], app: app)
        XCTAssertFalse(element("bookRating-douban", app).exists)
        capture("微信读书 page while 豆瓣 does not answer")
        let retry = app.buttons["retryBookReviews"]; reveal(retry, app: app); retry.leafTapVisible(in: app)
        reviewPart("bookRating-douban", has: ["豆瓣读书", "8.6", "12,345 ratings"], app: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "bookRating-weread").count, 1, "The list's rate is not asked for again")
        reviewPart("bookReaderReview-0", has: ["5 of 5 stars", "1204 found this useful", "开篇就把人拉进去"], app: app)
        XCTAssertTrue(element("bookReaderReview-2", app).exists); XCTAssertFalse(element("bookReaderReview-3", app).exists)
        XCTAssertTrue(app.buttons["allReaderReviews"].exists || app.links["allReaderReviews"].exists)
        XCTAssertFalse(element("bookReviewsUnavailable", app).exists)
        capture("微信读书 page with 豆瓣 score and short reviews")
        summarize(has: "好评：", app: app)
        capture("微信读书 page Ask Leaf summary in Chinese")
    }

    @MainActor func testQidianPageFindsDoubanAndWeReadRatingsInNightPortraitAndLandscape() {
        let app = launch(webNovels: true); app.tabBars.buttons["Settings"].leafTapVisible(in: app)
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        app.buttons["Night theme"].leafTapVisible(in: app); openWebNovels(app)
        webNovelRow(1, has: "星海拾荒者", app: app)
        let row = app.buttons["webNovelRow-1"]; reveal(row, app: app); row.leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["webNovelDetailTitle"].waitForExistence(timeout: 8))
        // 起点 has no scores of its own: 豆瓣 and 微信读书 are found by title and author.
        reviewPart("bookRating-weread", has: ["微信读书", "91.2%", "好评如潮"], app: app)
        reviewPart("bookRating-douban", has: ["豆瓣读书", "8.6"], app: app)
        reviewPart("bookReaderReview-0", has: ["开篇就把人拉进去"], app: app)
        capture("Night 起点 page ratings portrait")
        setReaderOrientation(.landscapeLeft, app: app)
        reviewPart("bookRating-douban", has: ["8.6"], app: app)
        let douban = element("bookRating-douban", app).frame, weread = element("bookRating-weread", app).frame
        XCTAssertEqual(douban.minY, weread.minY, accuracy: 2, "The scores sit side by side")
        capture("Night 起点 page ratings landscape")
        setReaderOrientation(.portrait, app: app)
    }

    @MainActor func testImportedBestsellerOpensAndRestoresInPages() { readImported(flow: "Pages") }
    @MainActor func testImportedBestsellerOpensAndRestoresInScroll() { readImported(flow: "Scroll") }
    @MainActor private func readImported(flow: String) {
        let app = launch(); open(app); detail(app)
        let add = app.buttons["bestsellerDetailAdd"]; waitEnabled(add); add.leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerViewLibrary"].waitForExistence(timeout: 15)); app.buttons["bestsellerViewLibrary"].leafTapVisible(in: app)
        assertLibraryBook("Simply Ina", app: app).leafTapVisible(in: app)
        let web = app.webViews["bookWebView"]
        func waitForText() {
            XCTAssertTrue(web.waitForExistence(timeout: 15))
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Opening your book…"]); waitForExpectations(timeout: 20)
            expectation(for: NSPredicate { _, _ in
                web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This original Leaf test passage")).allElementsBoundByIndex.contains {
                    let visible = $0.frame.intersection(web.frame)
                    return !visible.isNull && visible.width > 20 && visible.height > 20
                }
            }, evaluatedWith: web); waitForExpectations(timeout: 15)
            XCTAssertFalse(app.otherElements["readerError"].exists)
        }
        func controls() {
            if !app.buttons["closeBook"].exists { web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
            XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 8))
        }
        func percent() -> Double {
            let progress = app.sliders["readingProgress"]
            guard progress.exists else { return -1 }
            return Double((progress.value as? String ?? "").filter { "0123456789.".contains($0) }) ?? -1
        }
        waitForText(); controls()
        waitEnabled(app.buttons["Appearance"]); app.buttons["Appearance"].leafTapVisible(in: app)
        app.segmentedControls["appearanceTabs"].buttons["Layout"].leafTapVisible(in: app); app.segmentedControls["readingFlow"].buttons[flow].leafTapVisible(in: app)
        XCTAssertTrue(app.segmentedControls["readingFlow"].buttons[flow].isSelected)
        app.navigationBars["Appearance"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.segmentedControls["appearanceTabs"]); waitForExpectations(timeout: 8)
        waitForText(); controls()
        XCTAssertTrue(app.sliders["readingProgress"].waitForExistence(timeout: 8))
        let initial = percent(); XCTAssertGreaterThanOrEqual(initial, 0)
        app.buttons["nextPage"].leafTapVisible(in: app)
        waitForText(); controls()
        expectation(for: NSPredicate { _, _ in percent() > initial }, evaluatedWith: web); waitForExpectations(timeout: 10)
        let saved = percent(); capture("Imported bestseller rendered in " + flow)
        controls(); app.buttons["closeBook"].leafTapVisible(in: app); assertLibraryBook("Simply Ina", app: app).leafTapVisible(in: app)
        waitForText(); controls(); XCTAssertEqual(percent(), saved, accuracy: 2, "The imported book must restore its saved passage")
        capture("Imported bestseller reopened at saved passage in " + flow)
    }
}

// Keep native input targeted to the actual visible control. On the overloaded
// iOS 27.2 host Button.tap's automatic scrolling reported {-1,-1}, even on
// controls whose actions succeeded; using isHittable to scroll then overshot
// the first row. This records geometry and still requires a real on-screen tap.
@MainActor extension XCUIApplication {
    func leafDragContent(up: Bool, in scroll: XCUIElement? = nil) {
        let surface = scroll ?? scrollViews.firstMatch
        let visible = surface.frame.intersection(leafContentViewport).insetBy(dx: 12, dy: 12)
        guard surface.exists, !visible.isNull, visible.width > 24, visible.height > 48 else {
            return XCTFail("No visible scroll surface: \(surface.frame), viewport \(leafContentViewport)")
        }
        // The outer margin does not receive scroll gestures. Start inside the
        // content, with the fixed footer and bars excluded from the drag area.
        XCTContext.runActivity(named: "Native content scroll") { activity in
            let evidence = XCTAttachment(string: "scroll=\(surface.frame), usable=\(visible), up=\(up)")
            evidence.lifetime = .keepAlways; activity.add(evidence)
        }
        let origin = coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: visible.midX - frame.minX, dy: (up ? visible.maxY : visible.minY) - frame.minY))
        let end = origin.withOffset(CGVector(dx: visible.midX - frame.minX, dy: (up ? visible.minY : visible.maxY) - frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
    }
    var leafContentViewport: CGRect {
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
        for id in ["bestsellerDetailAdd", "bestsellerViewLibrary", "catalogAddBook", "catalogViewLibrary"] {
            let footer = buttons[id]
            if footer.exists {
                let top = footer.frame.minY - 16
                if top > visible.minY && top < visible.maxY { visible.size.height = top - visible.minY }
            }
        }
        return visible
    }
}
@MainActor extension XCUIElement {
    func leafTapVisible(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: 10), "Missing control: \(identifier)", file: file, line: line)
        let bounds = frame
        // Navigation and reader toolbars are valid tap targets too. Only the
        // keyboard occludes ordinary controls; content scrolling uses its own viewport.
        var viewport = app.frame.insetBy(dx: 2, dy: 2)
        if app.keyboards.firstMatch.exists {
            let keyboard = app.keyboards.firstMatch.frame
            if keyboard.minY > viewport.minY && keyboard.minY < viewport.maxY { viewport.size.height = keyboard.minY - viewport.minY }
        }
        let target = bounds.intersection(viewport)
        XCTContext.runActivity(named: "Native visible control: " + (identifier.isEmpty ? label : identifier)) { activity in
            let evidence = XCTAttachment(string: "control=\(bounds), app=\(app.frame), viewport=\(viewport), visible=\(target), hittable=\(isHittable)")
            evidence.lifetime = .keepAlways; activity.add(evidence)
        }
        guard !target.isNull, target.width > 1, target.height > 1,
              target.width + 0.5 >= min(20, bounds.width), target.height + 0.5 >= min(20, bounds.height) else {
            XCTContext.runActivity(named: "Control outside native tap area") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; activity.add(screenshot)
            }
            XCTFail("Control has no visible tap area: \(identifier), frame \(bounds), app \(app.frame)", file: file, line: line); return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.midX - app.frame.minX, dy: target.midY - app.frame.minY)).tap()
    }
}
