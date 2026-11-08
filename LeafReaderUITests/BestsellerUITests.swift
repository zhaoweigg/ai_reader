import XCTest

final class BestsellerUITests: XCTestCase {
    @MainActor private func launch(_ flags: [String] = [], agent: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["LEAF_UI_TEST_ID": UUID().uuidString, "LEAF_UI_ZLIB_MOCK": "1", "LEAF_UI_CHAT_MOCK": "1",
                                 "LEAF_UI_BESTSELLERS_MOCK": "1", "LEAF_UI_ZLIB_SHELF": "1", "LEAF_UI_EMPTY_LIBRARY": "1", "LEAF_UI_SCENE_GEOMETRY_FIXTURE": "1"]
        for flag in flags { app.launchEnvironment["LEAF_UI_BESTSELLERS_" + flag] = "1" }
        if agent { app.launchEnvironment["LEAF_UI_CHAT_AGENT"] = "1" }
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
                if frame.width > 1 && frame.height > 1 && !visible.isNull,
                   visible.width + 0.5 >= min(24, frame.width), visible.height + 0.5 >= min(24, frame.height) { return }
                let scroll = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
                app.leafDragContent(up: frame.maxY > viewport.minY, in: scroll)
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
        app.segmentedControls["zlibraryFeedPicker"].buttons["Recommended"].leafTapVisible(in: app)
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
    @MainActor func testMissingNYTKeyShowsPrivateConnectionAndIndieStillWorks() {
        let app = launch(["MISSING_KEY"]); open(app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["New York Times"].leafTapVisible(in: app)
        XCTAssertTrue(app.staticTexts["bestsellerFeedError"].waitForExistence(timeout: 10))
        app.buttons["NYT Books connection"].leafTapVisible(in: app)
        XCTAssertTrue(app.secureTextFields["nytAPIKey"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["saveNYTConnection"].isEnabled)
        capture("NYT Books private connection setup"); app.buttons["Done"].leafTapVisible(in: app)
        app.segmentedControls["bestsellerSourcePicker"].buttons["Indie"].leafTapVisible(in: app)
        XCTAssertTrue(app.buttons["bestsellerBook-indie-nonfiction-1"].waitForExistence(timeout: 10))
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
