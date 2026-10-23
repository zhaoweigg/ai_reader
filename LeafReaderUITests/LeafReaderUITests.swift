import XCTest

final class LeafReaderUITests: XCTestCase {
    private var geometryApp: XCUIApplication?
    @MainActor private func orient(_ direction: UIDeviceOrientation) {
        if let app = geometryApp, app.state == .runningForeground { setReaderOrientation(direction, app: app) }
        else { XCUIDevice.shared.orientation = direction }
    }
    @MainActor private func launchApp(mockChat: Bool = true, slowChat: Bool = false, chatGPTBrowser: Bool = false, chatGPTConnected: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEAF_UI_SCENE_GEOMETRY_FIXTURE"] = "1"
        app.launchEnvironment["LEAF_UI_ZLIB_MOCK"] = "1"
        app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = mockChat ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_SLOW"] = slowChat ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHATGPT_BROWSER"] = chatGPTBrowser ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHATGPT_CONNECTED"] = chatGPTConnected ? "1" : "0"
        app.launch()
        geometryApp = app
        orient(.portrait)
        addTeardownBlock { @MainActor in
            if app.state == .runningForeground { self.setReaderOrientation(.portrait, app: app) }
            app.terminate()
        }
        return app
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
            let surface = readingSurface(app)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            // Native setup taps can be consumed after rotation. Record the state before
            // one bounded retry; direct immersive-tap assertions remain single taps.
            if !app.buttons["closeBook"].waitForExistence(timeout: 2) {
                capture("Reader controls setup tap retry", app: app)
                surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            }
        }
        XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 5))
    }
    @MainActor private func dismissAppearance(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["Done"].exists)
        let titleBar = app.navigationBars["Appearance"]
        titleBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.segmentedControls["appearanceTabs"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["closeBook"].exists)
    }

    @MainActor private func revealAppearanceControl(_ app: XCUIApplication, _ control: XCUIElement) {
        let form = app.descendants(matching: .any)["appearanceForm"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<3 where !control.isHittable { form.swipeUp() }
        XCTAssertTrue(control.isHittable)
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
        dismissAppearance(app)
        capture("EPUB night", app: app)
        showReaderControls(app)
        app.buttons["closeBook"].tap()
        app.tabBars.buttons["Bookmarks"].tap()
        XCTAssertTrue(app.staticTexts["The Art of Noticing"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Day theme"].tap()
    }
    @MainActor func testAppThemesApplyAcrossLibraryMenusReaderAndRelaunch() {
        let app = launchApp()
        for theme in ["Day", "Paper", "Night", "Sepia", "Sage", "Dusk"] {
            app.tabBars.buttons["Settings"].tap()
            let choice = app.buttons[theme + " theme"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            XCTAssertTrue(choice.isSelected)
            XCTAssertEqual(["Day", "Paper", "Night", "Sepia", "Sage", "Dusk"].filter { app.buttons[$0 + " theme"].isSelected }.count, 1)
            capture(theme + " app theme picker", app: app)
            app.tabBars.buttons["Library"].tap()
            XCTAssertTrue(app.buttons["featuredBook"].waitForExistence(timeout: 5))
            capture(theme + " themed library", app: app)
            app.tabBars.buttons["Bookmarks"].tap()
            capture(theme + " themed bookmarks", app: app)
            app.tabBars.buttons["Library"].tap()
            app.buttons["importBooks"].tap()
            XCTAssertTrue(app.buttons["addFromFiles"].waitForExistence(timeout: 5))
            capture(theme + " themed add books", app: app)
            app.buttons["Close"].tap()
        }
        app.terminate(); app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Dusk theme"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Dusk theme"].isSelected)
        app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap()
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        XCTAssertTrue(app.buttons["Dusk theme"].isSelected)
        app.buttons["Sage theme"].tap()
        dismissAppearance(app)
        showReaderControls(app); app.buttons["closeBook"].tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Sage theme"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sage theme"].isSelected)
        capture("Reader theme synchronizes back to Settings", app: app)
    }

    @MainActor func testThemeSelectorFitsLandscapeAndKeepsItsChoiceAfterRotation() {
        let app = launchApp()
        defer { orient(.portrait) }
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Night theme"].tap()
        orient(.landscapeLeft)
        app.buttons["Sage theme"].tap()
        XCTAssertTrue(app.buttons["Sage theme"].isSelected)
        capture("Landscape app theme selector", app: app)
        orient(.portrait)
        XCTAssertTrue(app.buttons["Sage theme"].isSelected)
        app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap()
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        orient(.landscapeLeft)
        revealAppearanceControl(app, app.buttons["Paper theme"])
        app.buttons["Paper theme"].tap()
        XCTAssertTrue(app.buttons["Paper theme"].isSelected)
        capture("Landscape reader theme selector", app: app)
        revealAppearanceControl(app, app.buttons["Dusk theme"])
        app.buttons["Dusk theme"].tap()
        XCTAssertTrue(app.buttons["Dusk theme"].isSelected)
        orient(.portrait)
        XCTAssertTrue(app.buttons["Dusk theme"].isSelected)
        capture("Reader theme selector after rotation", app: app)
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
        revealAppearanceControl(app, compact)
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        compact.tap()
        XCTAssertTrue(compact.isSelected)
        capture("Aa Themes controls", app: app)
        dismissAppearance(app)
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
        revealAppearanceControl(app, app.buttons["compactLayout"])
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
        let surface = readingSurface(app)
        XCTAssertEqual(surface.frame.width, app.frame.width, accuracy: 2, "PDF must use the full viewport without a button rail")
        let launcher = app.buttons["openReaderChat"]
        launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.65,
            thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)))
        XCTAssertEqual(launcher.value as? String, "Move mode")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(launcher.value as? String, "Stationary")
        launcher.tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
        app.buttons["closeReaderChat"].tap()
        showReaderControls(app)
        XCTAssertTrue(app.staticTexts["Page 2 of 4"].exists)
        capture("PDF translucent movable button", app: app)
        app.buttons["closeBook"].tap()
        app.buttons["book-Notes from the Coast"].tap()
        showReaderControls(app)
        XCTAssertTrue(app.staticTexts["Page 2 of 4"].waitForExistence(timeout: 10))
    }

    @MainActor func testPDFSelectionOffersAskLeaf() {
        let app = launchApp()
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Coast")
        app.buttons["book-Notes from the Coast"].tap()
        showReaderControls(app); app.buttons["nextPage"].tap()
        let surface = readingSurface(app)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        capture("PDF before selecting text", app: app)
        let paragraph = surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Before the town")).firstMatch
        if paragraph.exists { paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25)).press(forDuration: 1.2) }
        else { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(forDuration: 1.2) }
        capture("PDF selection menu", app: app)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "PDF selection hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let menu = app.menuItems["Ask Leaf"].exists ? app.menuItems["Ask Leaf"] : app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Ask Leaf", "openReaderChat")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        XCTAssertTrue(app.staticTexts["chatSelectedPassage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["explainChatSelection"].exists)
        XCTAssertTrue(app.buttons["summarizeChatSelection"].exists)
        XCTAssertFalse(app.menuItems["Ask a question"].exists)
        XCTAssertFalse(app.buttons["sendReaderChat"].isEnabled)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "PDF content taps keep chat open")
        XCTAssertTrue(app.staticTexts["chatSelectedPassage"].exists)
        capture("PDF selection attached", app: app)
    }

    @MainActor func testListeningFromBottomMenuInBothFlowsPersistsAndFitsLandscape() {
        let app = launchApp()
        defer { orient(.portrait) }
        app.buttons["featuredBook"].tap()
        for flow in ["Pages", "Scroll"] {
            showReaderControls(app); app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
            dismissAppearance(app); showReaderControls(app)
            let surface = readingSurface(app), width = surface.frame.width
            XCTAssertTrue(app.buttons["Listen"].isHittable); app.buttons["Listen"].tap()
            XCTAssertTrue(app.buttons["listenFromPage"].waitForExistence(timeout: 5))
            capture(flow + " listening settings", app: app)
            app.buttons["listenFromPage"].tap()
            let pause = app.buttons["audioPlayPause"]
            expectation(for: NSPredicate(format: "label == %@", "Pause listening"), evaluatedWith: pause); waitForExpectations(timeout: 15)
            XCTAssertTrue(app.staticTexts["spokenPassage"].exists)
            XCTAssertEqual(surface.frame.width, width, accuracy: 1)
            pause.tap(); XCTAssertEqual(pause.label, "Resume listening")
            app.buttons["audioNext"].tap()
            XCTAssertEqual(pause.label, "Resume listening", "Skipping while paused must remain paused")
            capture(flow + " listening paused with passage", app: app)
            app.buttons["playbackSpeed"].tap(); app.buttons["1.5×"].tap()
            pause.tap(); XCTAssertEqual(pause.label, "Pause listening")
            self.orient(.landscapeLeft)
            expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 6)
            for id in ["listeningSettings", "audioPlayPause", "stopListening"] { XCTAssertTrue(app.buttons[id].isHittable) }
            capture(flow + " listening landscape", app: app)
            self.orient(.portrait)
            expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app); waitForExpectations(timeout: 6)
            let viewportBeforeComposing = surface.frame
            app.buttons["openReaderChat"].tap()
            let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
            let baseDraft = "Keep this question while listening"
            input.tap()
            if flow == "Pages" { input.typeText(baseDraft) }
            else {
                XCTAssertEqual(input.value as? String, baseDraft, "The first flow's draft is intentionally restored")
                input.typeText(" [Scroll]")
            }
            let expectedDraft = input.value as? String ?? ""
            XCTAssertEqual(expectedDraft.replacingOccurrences(of: " [Scroll]", with: ""), baseDraft)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5), "An offscreen hardware-keyboard preview is not a composing state")
            XCTAssertLessThan(app.keyboards.firstMatch.frame.minY, app.frame.maxY - 100)
            XCTAssertEqual(surface.frame.width, viewportBeforeComposing.width, accuracy: 1)
            XCTAssertEqual(surface.frame.height, viewportBeforeComposing.height, accuracy: 1)
            XCTAssertTrue(pause.isHittable, "Playback must remain controllable while composing a question")
            pause.tap(); XCTAssertEqual(pause.label, "Resume listening")
            XCTAssertEqual(input.value as? String, expectedDraft)
            capture(flow + " listening controls while typing to Ask Leaf", app: app)
            pause.tap(); XCUIDevice.shared.press(.home); app.activate()
            XCTAssertTrue(pause.waitForExistence(timeout: 8)); XCTAssertEqual(pause.label, "Resume listening", "Background playback pauses and retains the cursor")
            XCTAssertEqual(input.value as? String, expectedDraft)
            capture(flow + " listening paused after background", app: app)
            app.buttons["closeReaderChat"].tap()
            app.buttons["stopListening"].tap()
            XCTAssertFalse(app.buttons["audioPlayPause"].exists)
            showReaderControls(app); app.buttons["closeBook"].tap(); app.buttons["featuredBook"].tap()
            showReaderControls(app); app.buttons["Listen"].tap()
            XCTAssertTrue(app.buttons["resumeSavedListening"].waitForExistence(timeout: 5))
            capture(flow + " saved listening position", app: app)
            app.buttons["resumeSavedListening"].tap()
            XCTAssertTrue(pause.waitForExistence(timeout: 10)); app.buttons["stopListening"].tap()
        }
    }

    @MainActor private func openSelectionFixture(_ flow: String, app: XCUIApplication) {
        if flow == "PDF" {
            let field = app.textFields["librarySearch"]; XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap(); field.typeText("Coast"); app.buttons["book-Notes from the Coast"].tap()
            showReaderControls(app); app.buttons["nextPage"].tap()
        } else {
            app.buttons["featuredBook"].tap(); showReaderControls(app); app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
            dismissAppearance(app)
        }
    }
    @MainActor private func selectFixturePassage(_ flow: String, app: XCUIApplication) {
        let pdf = flow == "PDF", paragraph = readingSurface(app).staticTexts.containing(NSPredicate(format: "label CONTAINS %@", pdf ? "Before the town" : "Attention is a way")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: pdf ? 0.15 : 0.3, dy: pdf ? 0.25 : 0.1)).press(forDuration: 1.2)
    }
    @MainActor func testExpandedSelectionMenuShowsAllPrimaryActionsAndCopiesInPagesScrollAndPDF() {
        continueAfterFailure = false
        orient(.portrait)
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll", "PDF"] {
            let app = launchApp(); openSelectionFixture(flow, app: app)
            app.buttons["openReaderChat"].tap()
            selectFixturePassage(flow, app: app)
            let menu = app.tables["expandedSelectionMenu"]
            if !menu.waitForExistence(timeout: 6) {
                capture(flow + " missing expanded selection menu", app: app)
                let state = XCTAttachment(string: app.debugDescription); state.name = "Expanded selection menu hierarchy"; state.lifetime = .keepAlways; add(state)
                XCTFail("Expanded selection menu did not appear in " + flow); return
            }
            let selected = menu.value as? String ?? ""
            XCTAssertFalse(selected.isEmpty)
            for id in ["ask", "listen", "highlight", "note", "copy"] { XCTAssertTrue(app.buttons["selection-" + id].isHittable, flow + " " + id) }
            capture(flow + " expanded selection menu all actions", app: app)
            self.orient(.landscapeLeft)
            expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 6)
            for id in ["ask", "listen", "highlight", "note", "copy"] { XCTAssertTrue(app.buttons["selection-" + id].isHittable, flow + " landscape " + id) }
            capture(flow + " expanded selection menu landscape", app: app)
            self.orient(.portrait)
            expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app); waitForExpectations(timeout: 6)
            app.buttons["selection-copy"].tap()
            XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
            let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
            input.tap(); input.press(forDuration: 1.2)
            let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
            XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
            XCTAssertEqual(input.value as? String, selected, "Copy must retain the actual native selection")
            capture(flow + " copied selection pasted into chat", app: app)
            app.terminate()
        }
    }
    @MainActor func testSelectionActionsReceiveTapsKeepComposerFocusAndLeaveNoWindowAfterClosing() {
        continueAfterFailure = false
        let app = launchApp(); app.buttons["featuredBook"].tap(); waitForBook(app)
        app.buttons["openReaderChat"].tap()
        capture("Reading before the selection menu", app: app)
        selectFixturePassage("Pages", app: app)
        let menu = app.tables["expandedSelectionMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 6))
        for id in ["ask", "listen", "highlight", "note", "copy", "system"] { XCTAssertTrue(app.buttons["selection-" + id].isHittable) }
        XCTAssertFalse(app.menuItems["Leaf actions"].exists || app.buttons["Leaf actions"].exists, "The native toolbar must not cover the expanded actions")
        let firstSelection = menu.value as? String ?? ""
        XCTAssertFalse(firstSelection.isEmpty)
        capture("Selection overlay receives all six actions", app: app)
        app.buttons["selection-copy"].tap(); XCTAssertFalse(menu.exists)
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Keep my menu question")
        XCTAssertEqual(input.value as? String, "Keep my menu question")
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5))
        capture("Selection overlay preserves native composer focus", app: app)
        app.buttons["Hide keyboard"].tap(); selectFixturePassage("Pages", app: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertEqual(menu.value as? String, firstSelection, "Requesting the same selected word must reopen its actions")
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); input.typeText(" again")
        XCTAssertFalse(menu.exists); XCTAssertEqual(input.value as? String, "Keep my menu question again")
        app.buttons["Hide keyboard"].tap()
        let paragraph = readingSurface(app).staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Attention is a way")).firstMatch
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.1)).press(forDuration: 1.2)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let changedSelection = menu.value as? String ?? ""
        XCTAssertFalse(changedSelection.isEmpty); XCTAssertNotEqual(changedSelection, firstSelection, "Actions must use the newly selected word")
        capture("Repeated and changed selections use fresh menu snapshots", app: app)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertFalse(menu.exists, "A backgrounded scene must release its selection window")
        // Reader chrome stays hidden while chat is open; close chat through its
        // normal control before exercising book-close with a new active menu.
        app.buttons["closeReaderChat"].tap()
        showReaderControls(app); selectFixturePassage("Pages", app: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        app.buttons["closeBook"].tap()
        XCTAssertTrue(app.buttons["featuredBook"].waitForExistence(timeout: 5)); XCTAssertFalse(menu.exists)
        app.buttons["featuredBook"].tap(); waitForBook(app)
        XCTAssertFalse(menu.exists, "Reopening cannot retain an orphaned menu window")
        app.buttons["openReaderChat"].tap()
        XCTAssertEqual(input.value as? String, "Keep my menu question again")
        XCTAssertEqual(app.staticTexts["chatSelectedPassage"].label, changedSelection)
        capture("Selection window cleared and question restored after reopening", app: app)
    }
    @MainActor func testExpandedSelectionMenuKeepsNativeTextActionsInAllReaderFlows() {
        continueAfterFailure = false
        for flow in ["Pages", "Scroll", "PDF"] {
            let app = launchApp(); openSelectionFixture(flow, app: app)
            selectFixturePassage(flow, app: app)
            XCTAssertTrue(app.buttons["selection-system"].waitForExistence(timeout: 6))
            let selected = app.tables["expandedSelectionMenu"].value as? String ?? ""
            XCTAssertFalse(selected.isEmpty)
            app.buttons["selection-system"].tap()
            let expanded = app.tables["expandedSelectionMenu"]
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: expanded); waitForExpectations(timeout: 5)
            let nativeCopy = app.menuItems["Copy"].exists ? app.menuItems["Copy"] : app.buttons["Copy"]
            XCTAssertTrue(nativeCopy.waitForExistence(timeout: 5), "Native text actions must remain available in " + flow)
            capture(flow + " standard iOS text actions remain available", app: app)
            nativeCopy.tap(); app.buttons["openReaderChat"].tap()
            let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
            input.tap(); input.press(forDuration: 1.2)
            let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
            XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
            XCTAssertEqual(input.value as? String, selected, "Standard Copy must use the current native selection in " + flow)
            capture(flow + " standard iOS Copy retains selected text", app: app)
            app.terminate()
        }
    }
    @MainActor func testSpeechProgressHighlightsVisibleTextInPagesScrollAndPDF() {
        continueAfterFailure = false
        orient(.portrait)
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll", "PDF"] {
            let app = launchApp(); openSelectionFixture(flow, app: app)
            selectFixturePassage(flow, app: app)
            XCTAssertTrue(app.buttons["selection-listen"].waitForExistence(timeout: 6)); app.buttons["selection-listen"].tap()
            let status = app.buttons["listeningSettings"], pause = app.buttons["audioPlayPause"]
            expectation(for: NSPredicate { _, _ in !(status.value as? String ?? "").isEmpty }, evaluatedWith: status); waitForExpectations(timeout: 15)
            pause.tap(); let word = status.value as? String ?? ""
            XCTAssertFalse(word.isEmpty); XCTAssertEqual(pause.label, "Resume listening")
            capture(flow + " actual spoken text highlighted while paused", app: app)
            self.orient(.landscapeLeft)
            expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 6)
            XCTAssertEqual(status.value as? String, word)
            capture(flow + " spoken highlight retained after rotation", app: app)
            self.orient(.portrait)
            expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app); waitForExpectations(timeout: 6)
            app.buttons["openReaderChat"].tap()
            let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
            input.tap(); input.typeText("Keep my listening question")
            XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5))
            XCTAssertTrue(pause.isHittable); XCTAssertEqual(status.value as? String, word)
            capture(flow + " spoken highlight with actual chat keyboard", app: app)
            app.buttons["closeReaderChat"].tap(); app.buttons["stopListening"].tap()
            XCTAssertFalse(status.exists)
            capture(flow + " stopping clears spoken highlight", app: app)
            app.terminate()
        }
    }
    @MainActor func testListeningFromNativeSelectionInBothFlows() {
        let app = launchApp(); app.buttons["featuredBook"].tap()
        for flow in ["Pages", "Scroll"] {
            showReaderControls(app); app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap(); dismissAppearance(app)
            let surface = readingSurface(app)
            let paragraph = surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Attention is a way")).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).press(forDuration: 1.2)
            let menu = app.menuItems["Listen from here"].exists ? app.menuItems["Listen from here"] : app.buttons["Listen from here"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            capture(flow + " native Listen from here menu", app: app); menu.tap()
            let pause = app.buttons["audioPlayPause"]
            expectation(for: NSPredicate(format: "label == %@", "Pause listening"), evaluatedWith: pause); waitForExpectations(timeout: 15)
            pause.tap()
            XCTAssertFalse(app.buttons["closeReaderChat"].exists)
            XCTAssertTrue(app.staticTexts["spokenPassage"].exists)
            capture(flow + " playing selected passage", app: app)
            app.buttons["stopListening"].tap()
            showReaderControls(app); app.buttons["Contents"].tap()
            app.buttons["Begin where you are"].tap()
        }
    }

    @MainActor func testPDFListeningFromSelectionAndBottomMenu() {
        let app = launchApp()
        let search = app.textFields["librarySearch"]; XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Coast")
        app.buttons["book-Notes from the Coast"].tap()
        showReaderControls(app); app.buttons["nextPage"].tap(); showReaderControls(app)
        app.buttons["Listen"].tap(); app.buttons["listenFromPage"].tap()
        let pause = app.buttons["audioPlayPause"]
        expectation(for: NSPredicate(format: "label == %@", "Pause listening"), evaluatedWith: pause); waitForExpectations(timeout: 15)
        pause.tap(); capture("PDF listening from visible page", app: app); app.buttons["stopListening"].tap()
        let surface = readingSurface(app)
        let paragraph = surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Before the town")).firstMatch
        if paragraph.exists { paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25)).press(forDuration: 1.2) }
        else { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(forDuration: 1.2) }
        let menu = app.menuItems["Listen from here"].exists ? app.menuItems["Listen from here"] : app.buttons["Listen from here"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); capture("PDF native listening selection menu", app: app); menu.tap()
        expectation(for: NSPredicate(format: "label == %@", "Pause listening"), evaluatedWith: pause); waitForExpectations(timeout: 15)
        pause.tap(); XCTAssertTrue(app.staticTexts["spokenPassage"].exists)
        capture("PDF listening from selected character", app: app); app.buttons["stopListening"].tap()
    }

    @MainActor func testTextSizePreviewAfterSwitchingScrollAndPages() {
        let app = launchApp()
        app.buttons["featuredBook"].tap()
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        let tabs = app.segmentedControls["appearanceTabs"]
        tabs.buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons["Scroll"].tap()
        tabs.buttons["Font"].tap()
        app.sliders["fontSize"].adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(app.sliders["fontSize"].value as? String, "32 points")
        capture("Scroll 32 pt preview", app: app)
        dismissAppearance(app)
        capture("Scroll 32 pt reading", app: app)
        let surface = readingSurface(app)
        let before = surface.staticTexts.allElementsBoundByIndex.map { ($0.label, $0.frame.minY) }
        surface.swipeUp()
        let after = surface.staticTexts.allElementsBoundByIndex.map { ($0.label, $0.frame.minY) }
        XCTAssertTrue(before.contains { old in after.contains { $0.0 == old.0 && abs($0.1 - old.1) > 20 } },
                      "Vertical swipes must move the scrolling text")
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        app.sliders["fontSize"].adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(app.sliders["fontSize"].value as? String, "12 points")
        capture("Scroll 12 pt preview", app: app)
        dismissAppearance(app)
        capture("Scroll 12 pt reading", app: app)
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons["Pages"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Font"].tap()
        app.sliders["fontSize"].adjust(toNormalizedSliderPosition: 0.5)
        // XCTest's normalized slider drag is approximate; finish with exact steps.
        for _ in 0..<20 {
            let value = app.sliders["fontSize"].value as? String ?? ""
            if value == "22 points" { break }
            guard let size = Int(value.components(separatedBy: " ").first ?? "") else { break }
            app.buttons[size > 22 ? "decreaseTextSize" : "increaseTextSize"].tap()
        }
        XCTAssertEqual(app.sliders["fontSize"].value as? String, "22 points")
        capture("Pages 22 pt after scrolling preview", app: app)
        dismissAppearance(app)
        capture("Pages 22 pt after scrolling reading", app: app)
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
        app.buttons["Appearance"].tap()
        XCTAssertTrue(app.segmentedControls["appearanceTabs"].waitForExistence(timeout: 5))
        // An exposed page edge dismisses the sheet without also turning the page.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.3)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.segmentedControls["appearanceTabs"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["closeBook"].exists)
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeBook"])
        waitForExpectations(timeout: 5)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
            .press(forDuration: 0.01, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.15)
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeBook"])
        waitForExpectations(timeout: 5)
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Add bookmark")
        app.buttons["toggleBookmark"].tap()
        surface.swipeLeft()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeBook"])
        waitForExpectations(timeout: 5)
        capture("Immersive page turn", app: app)
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Add bookmark")
        surface.swipeRight()
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
    }

    @MainActor func testSelectionMenuOpensChatWithAttachedPassageInBothFlows() {
        let app = launchApp()
        defer { orient(.portrait) }
        app.buttons["featuredBook"].tap()
        for flow in ["Pages", "Scroll"] {
            showReaderControls(app)
            app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
            dismissAppearance(app)
            let actions = flow == "Pages" ? [("explainChatSelection", "Explain this passage.")] : [("summarizeChatSelection", "Summarize this passage.")]
            for (action, prompt) in actions {
                let surface = readingSurface(app)
                let paragraph = surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Attention is a way")).firstMatch
                XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
                let point = paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1))
                let selectionAsk = app.buttons["selection-ask"]
                for _ in 0..<2 {
                    point.press(forDuration: 1.2)
                    // An expanded row is a button. Never dismiss a successful
                    // selection or fall back to a hidden library/chat launcher.
                    if selectionAsk.waitForExistence(timeout: 3) { break }
                    if app.menuItems["Copy"].exists || app.buttons["Copy"].exists { break }
                    point.tap()
                }
                capture(flow + " expanded selection menu", app: app)
                let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = flow + " selection menu hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
                XCTAssertTrue(selectionAsk.waitForExistence(timeout: 3)); XCTAssertTrue(selectionAsk.isHittable)
                let selected = app.tables["expandedSelectionMenu"].value as? String ?? ""
                XCTAssertFalse(selected.isEmpty)
                selectionAsk.tap()
                let passage = app.staticTexts["chatSelectedPassage"]
                XCTAssertTrue(passage.waitForExistence(timeout: 5)); XCTAssertFalse(passage.label.isEmpty)
                XCTAssertEqual(passage.label, selected, "Ask Leaf must attach the exact currently selected passage")
                let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
                XCTAssertFalse(app.menuItems["Ask a question"].exists, "Ask Leaf must open chat directly")
                XCTAssertFalse(app.buttons["Ask a question"].exists)
                XCTAssertFalse(app.buttons["sendReaderChat"].isEnabled)
                for shortcut in ["explainChatSelection", "summarizeChatSelection"] {
                    XCTAssertTrue(app.buttons[shortcut].isHittable)
                }
                capture(flow + " direct chat with selection shortcuts", app: app)
                let other = action == "explainChatSelection" ? "summarizeChatSelection" : "explainChatSelection"
                app.buttons[other].tap(); app.buttons[action].tap()
                XCTAssertEqual(input.value as? String, prompt, "Switching shortcuts replaces the prior preset")
                XCTAssertFalse(app.staticTexts["chatQuestion"].exists, "A shortcut prepares an editable draft")
                if flow == "Scroll" {
                    self.orient(.landscapeLeft)
                    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
                    waitForExpectations(timeout: 5)
                    XCTAssertTrue(app.buttons["explainChatSelection"].isHittable)
                    XCTAssertTrue(app.buttons["summarizeChatSelection"].isHittable)
                    capture("Landscape selection shortcuts", app: app)
                    self.orient(.portrait)
                    expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
                    waitForExpectations(timeout: 5)
                }
                input.tap(); input.typeText(" In context")
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                XCTAssertTrue(passage.exists, "Keep the selected passage attached when the keyboard replaces the selection")
                XCTAssertLessThanOrEqual(app.otherElements["readerChatPanel"].frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
                XCTAssertTrue(app.buttons["removeChatSelection"].isHittable)
                capture(flow + " attached passage while typing", app: app)
                if flow == "Scroll" {
                    self.orient(.landscapeLeft)
                    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
                    waitForExpectations(timeout: 5)
                    XCTAssertTrue(passage.waitForExistence(timeout: 5))
                    XCTAssertTrue(app.buttons["removeChatSelection"].isHittable)
                    XCTAssertTrue(input.isHittable)
                    XCTAssertLessThanOrEqual(app.otherElements["readerChatPanel"].frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
                    capture(flow + " selected passage landscape keyboard", app: app)
                    self.orient(.portrait)
                    expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
                    waitForExpectations(timeout: 5)
                }
                app.buttons["removeChatSelection"].tap()
                XCTAssertFalse(passage.exists)
                app.buttons["Hide keyboard"].tap()
                app.buttons["chatOptions"].tap()
                app.buttons["requestClearConversation"].tap()
                app.buttons["confirmClearConversation"].firstMatch.tap()
                app.buttons["closeReaderChat"].tap()
            }
        }
    }


    @MainActor func testSentQuotePersistsWithQuestionInPages() { verifySentQuote(flow: "Pages") }
    @MainActor func testSentQuotePersistsWithQuestionInScroll() { verifySentQuote(flow: "Scroll") }
    @MainActor func testSentQuotePersistsWithQuestionInPDF() { verifySentQuote(flow: "PDF") }

    @MainActor func testChatEdgeResizesInPages() { verifyChatResize(flow: "Pages") }
    @MainActor func testChatEdgeResizesInScroll() { verifyChatResize(flow: "Scroll") }
    @MainActor func testChatEdgeResizesInPDF() { verifyChatResize(flow: "PDF") }

    @MainActor func testChatStaysOpenWhileSelectingTextInBothFlows() {
        let app = launchApp()
        app.buttons["featuredBook"].tap()
        for flow in ["Pages", "Scroll"] {
            showReaderControls(app); app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            dismissAppearance(app)
            app.buttons["openReaderChat"].tap()
            let paragraph = readingSurface(app).staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Attention is a way")).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).press(forDuration: 1.2)
            let ask = app.menuItems["Ask Leaf"].exists ? app.menuItems["Ask Leaf"] : app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Ask Leaf", "openReaderChat")).firstMatch
            XCTAssertTrue(ask.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Native selection must keep chat open")
            ask.tap()
            XCTAssertTrue(app.staticTexts["chatSelectedPassage"].waitForExistence(timeout: 5))
            let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
            input.tap(); input.typeText("Keep this selection")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["chatSelectedPassage"].exists)
            capture(flow + " selection while chat remains open", app: app)
            app.buttons["removeChatSelection"].tap()
            app.buttons["closeReaderChat"].tap()
        }
    }

    @MainActor func testOpenChatAutomaticallyQuotesSelectionInPages() { verifyAutomaticQuote(flow:"Pages") }
    @MainActor func testOpenChatAutomaticallyQuotesSelectionInScroll() { verifyAutomaticQuote(flow:"Scroll") }
    @MainActor func testOpenChatAutomaticallyQuotesSelectionInPDF() { verifyAutomaticQuote(flow:"PDF") }

    @MainActor private func verifyAutomaticQuote(flow:String) {
        orient(.portrait)
        defer { orient(.portrait) }
        let app = launchApp()
        if flow == "PDF" {
            let search = app.textFields["librarySearch"]
            XCTAssertTrue(search.waitForExistence(timeout:10));search.tap();search.typeText("Coast")
            app.buttons["book-Notes from the Coast"].tap()
            showReaderControls(app);app.buttons["nextPage"].tap()
        } else {
            app.buttons["featuredBook"].tap();showReaderControls(app)
            app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
            dismissAppearance(app)
        }
        waitForBook(app)
        let surface = readingSurface(app), originalFrame = surface.frame
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap();input.typeText("Why does the author say this?")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5))
        app.buttons["Hide keyboard"].tap()
        XCTAssertFalse(app.staticTexts["chatSelectedPassage"].exists)
        let paragraph = surface.staticTexts.containing(NSPredicate(format:"label CONTAINS %@",flow == "PDF" ? "Before the town" : "Attention is a way")).firstMatch
        let point = paragraph.exists ? paragraph.coordinate(withNormalizedOffset:CGVector(dx:flow == "PDF" ? 0.15 : 0.3,dy:flow == "PDF" ? 0.25 : 0.1)) : surface.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.25))
        point.press(forDuration:1.2)
        let passage = app.staticTexts["chatSelectedPassage"]
        XCTAssertTrue(passage.waitForExistence(timeout:5),"Selecting book text must attach it without tapping the Ask Leaf menu action")
        XCTAssertFalse(passage.label.isEmpty)
        let quote = passage.label
        XCTAssertEqual(input.value as? String,"Why does the author say this?")
        XCTAssertFalse(app.staticTexts["chatQuestion"].exists,"Quoting must not send the draft")
        XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        capture(flow + " selection automatically quoted with native menu",app:app)
        input.tap();input.typeText(" In this passage.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5))
        let composedDraft = input.value as? String ?? ""
        XCTAssertTrue(composedDraft.contains(" In this passage."))
        XCTAssertEqual(composedDraft.replacingOccurrences(of:" In this passage.",with:""),"Why does the author say this?",
                       "Typing at the tapped caret must preserve the original question")
        XCTAssertEqual(passage.label,quote,"Keyboard focus must keep the attached selection")
        XCTAssertEqual(surface.frame.width,originalFrame.width,accuracy:2)
        XCTAssertEqual(surface.frame.height,originalFrame.height,accuracy:2)
        capture(flow + " automatic quote while composing",app:app)
        orient(.landscapeLeft)
        expectation(for:NSPredicate { _,_ in app.frame.width > app.frame.height },evaluatedWith:app);waitForExpectations(timeout:5)
        XCTAssertEqual(passage.label,quote)
        XCTAssertTrue(input.isHittable)
        capture(flow + " automatic quote landscape keyboard",app:app)
        orient(.portrait)
        expectation(for:NSPredicate { _,_ in app.frame.height > app.frame.width },evaluatedWith:app);waitForExpectations(timeout:5)
        app.buttons["Hide keyboard"].tap()
        app.buttons["closeReaderChat"].tap();showReaderControls(app);app.buttons["closeBook"].tap()
        app.terminate();app.launch()
        if flow == "PDF" {
            let search = app.textFields["librarySearch"]
            XCTAssertTrue(search.waitForExistence(timeout:10));search.tap();search.typeText("Coast")
            app.buttons["book-Notes from the Coast"].tap()
        }
        else { app.buttons["featuredBook"].tap() }
        waitForBook(app);app.buttons["openReaderChat"].tap()
        XCTAssertEqual(passage.label,quote)
        XCTAssertEqual(input.value as? String,composedDraft)
        capture(flow + " automatic quote and draft restored",app:app)
        app.buttons["removeChatSelection"].tap()
        XCTAssertFalse(passage.exists)
        input.tap();input.typeText(" Still my question.")
        XCTAssertFalse(passage.exists,"An old native selection must not reattach after explicit removal")
    }

    @MainActor private func assertCompactChatHeader(_ app: XCUIApplication) {
        let header = app.descendants(matching: .any)["readerChatHeader"].firstMatch
        let handle = app.descendants(matching: .any)["readerChatDragHandle"].firstMatch
        let close = app.buttons["closeReaderChat"]
        // Accessibility's screen-coordinate conversion can round a 44 pt target down.
        let minimumTarget: CGFloat = 44 - 0.01
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.frame.height, 44, accuracy: 1)
        XCTAssertGreaterThanOrEqual(close.frame.width, minimumTarget)
        XCTAssertGreaterThanOrEqual(close.frame.height, minimumTarget)
        XCTAssertGreaterThanOrEqual(header.frame.minY, handle.frame.maxY - 1, "Resize and dismiss gesture regions must stay separate")
        XCTAssertLessThanOrEqual(header.frame.maxY - handle.frame.minY, 57, "The grabber and title row must leave room for the conversation")
        if app.buttons["chatOptions"].exists {
            XCTAssertGreaterThanOrEqual(app.buttons["chatOptions"].frame.width, minimumTarget)
            XCTAssertGreaterThanOrEqual(app.buttons["chatOptions"].frame.height, minimumTarget)
        }
    }

    @MainActor private func verifyChatResize(flow: String) {
        orient(.portrait)
        let app = launchApp()
        defer { orient(.portrait) }
        func openBook() {
            if flow == "PDF" {
                let search = app.textFields["librarySearch"]
                XCTAssertTrue(search.waitForExistence(timeout: 10))
                if (search.value as? String) != "Coast" { search.tap(); search.typeText("Coast") }
                app.buttons["book-Notes from the Coast"].tap()
            } else { app.buttons["featuredBook"].tap() }
            waitForBook(app)
        }
        func hideKeyboardAndWait() {
            app.buttons["Hide keyboard"].tap()
            expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.keyboards.firstMatch)
            waitForExpectations(timeout:5)
        }
        openBook(); showReaderControls(app)
        if flow == "PDF" { app.buttons["nextPage"].tap() }
        else {
            app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            for margin in ["Narrow", "Wide", "Standard"] { app.buttons[margin + " margins"].tap() }
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
            dismissAppearance(app); showReaderControls(app)
        }
        let surface = readingSurface(app), bookFrame = surface.frame
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let paragraph = surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", flow == "PDF" ? "Before the town" : "Attention is a way")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: flow == "PDF" ? 0.15 : 0.3, dy: flow == "PDF" ? 0.25 : 0.1)).press(forDuration: 1.2)
        let ask = app.menuItems["Ask Leaf"].exists ? app.menuItems["Ask Leaf"] : app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Ask Leaf", "openReaderChat")).firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 5)); ask.tap()
        XCTAssertTrue(app.staticTexts["chatSelectedPassage"].waitForExistence(timeout: 5))
        let selected = app.staticTexts["chatSelectedPassage"].label
        sendChatQuestion("Explain this quote", app: app)
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
        let panel = app.otherElements["readerChatPanel"]
        assertCompactChatHeader(app)
        func resize(_ delta: CGFloat) {
            let edge = app.descendants(matching: .any)["readerChatDragHandle"].firstMatch
            let start = edge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)), withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Resizing must never dismiss chat")
        }
        let initial = panel.frame.height
        resize(-180)
        XCTAssertEqual(panel.frame.height, initial + 180, accuracy: 15)
        XCTAssertEqual(surface.frame.height, bookFrame.height, accuracy: 2, "Keep the book viewport unchanged")
        XCTAssertEqual(surface.frame.width, bookFrame.width, accuracy: 2)
        XCTAssertEqual(app.buttons["toggleChatQuote"].value as? String, selected)
        assertCompactChatHeader(app)
        capture(flow + " expanded chat with sent quote", app: app)
        resize(240)
        XCTAssertLessThan(panel.frame.height, initial + 20)
        // Accessibility reports the content bounds, excluding 8 pt of padding at each edge.
        XCTAssertGreaterThanOrEqual(panel.frame.height, 183)
        assertCompactChatHeader(app)
        capture(flow + " minimum resized chat", app: app)
        resize(-160)
        let readingHeight = panel.frame.height
        // Exercise the invisible edge of the target, outside the small X glyph.
        app.buttons["closeReaderChat"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
        app.buttons["openReaderChat"].tap()
        XCTAssertEqual(panel.frame.height, readingHeight, accuracy: 3)
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Keep my resize draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let compactHeight = panel.frame.height
        resize(-160)
        XCTAssertGreaterThan(panel.frame.height, compactHeight + 70)
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        XCTAssertEqual(input.value as? String, "Keep my resize draft")
        XCTAssertTrue(app.scrollViews["chatMessageHistory"].exists, "Expanded typing can show the conversation")
        assertCompactChatHeader(app)
        capture(flow + " expanded chat above keyboard", app: app)
        let typingHeight = panel.frame.height
        hideKeyboardAndWait()
        XCTAssertEqual(panel.frame.height, readingHeight, accuracy: 3)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout:5))
        XCTAssertEqual(panel.frame.height, typingHeight, accuracy: 3)
        hideKeyboardAndWait()
        orient(.landscapeLeft)
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        resize(-120)
        XCTAssertGreaterThanOrEqual(panel.frame.height, 200)
        XCTAssertTrue(app.scrollViews["chatMessageHistory"].exists)
        assertCompactChatHeader(app)
        capture(flow + " landscape expanded chat history", app: app)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        resize(-50)
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        XCTAssertTrue(input.isHittable)
        assertCompactChatHeader(app)
        capture(flow + " landscape resize with keyboard", app: app)
        hideKeyboardAndWait()
        orient(.portrait)
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let savedHeight = panel.frame.height
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        app.terminate(); app.launch(); openBook(); app.buttons["openReaderChat"].tap()
        XCTAssertEqual(panel.frame.height, savedHeight, accuracy: 4)
        XCTAssertEqual(input.value as? String, "Keep my resize draft")
        XCTAssertEqual(app.buttons["toggleChatQuote"].value as? String, selected)
        assertCompactChatHeader(app)
        capture(flow + " resized chat restored after relaunch", app: app)
    }

    @MainActor private func verifySentQuote(flow: String) {
        let app = launchApp()
        defer { orient(.portrait) }
        func openBook() {
            if flow == "PDF" {
                let search = app.textFields["librarySearch"]
                XCTAssertTrue(search.waitForExistence(timeout: 10))
                if (search.value as? String) != "Coast" { search.tap(); search.typeText("Coast") }
                app.buttons["book-Notes from the Coast"].tap()
            } else { app.buttons["featuredBook"].tap() }
            waitForBook(app)
        }
        openBook(); showReaderControls(app)
        if flow == "PDF" { app.buttons["nextPage"].tap() }
        else {
            app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
            dismissAppearance(app); showReaderControls(app)
        }
        let surface = readingSurface(app)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let paragraph = surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", flow == "PDF" ? "Before the town" : "Attention is a way")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        let point = paragraph.coordinate(withNormalizedOffset: CGVector(dx: flow == "PDF" ? 0.15 : 0.3, dy: flow == "PDF" ? 0.25 : 0.1))
        for _ in 0..<2 {
            point.press(forDuration: 1.2)
            if app.menuItems["Copy"].waitForExistence(timeout: 2) || app.menuItems["Ask Leaf"].exists { break }
            point.tap()
        }
        let ask = app.menuItems["Ask Leaf"].exists ? app.menuItems["Ask Leaf"] : app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Ask Leaf", "openReaderChat")).firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 5)); ask.tap()
        let draftQuote = app.staticTexts["chatSelectedPassage"]
        XCTAssertTrue(draftQuote.waitForExistence(timeout: 5))
        let selectedText = draftQuote.label
        XCTAssertFalse(selectedText.isEmpty)
        sendChatQuestion("What does this mean?", app: app)
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(draftQuote.exists, "Sending consumes the draft attachment")
        let quote = app.buttons["toggleChatQuote"]
        func revealQuote() {
            let history = app.scrollViews["chatMessageHistory"].firstMatch
            XCTAssertTrue(history.waitForExistence(timeout: 5))
            for _ in 0..<4 where !quote.isHittable || quote.frame.minY < history.frame.minY { history.swipeDown() }
            XCTAssertTrue(quote.isHittable)
            XCTAssertGreaterThanOrEqual(quote.frame.minY, history.frame.minY - 1)
            XCTAssertEqual(quote.value as? String, selectedText, "The sent message keeps the exact selected text")
        }
        revealQuote()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        XCTAssertEqual(quote.label, "Expand quoted text")
        capture(flow + " sent question keeps quoted text", app: app)
        quote.tap(); XCTAssertEqual(quote.label, "Collapse quoted text")
        quote.tap(); XCTAssertEqual(quote.label, "Expand quoted text")
        orient(.landscapeLeft)
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        capture(flow + " landscape sent quote conversation retained", app: app)
        orient(.portrait)
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        openBook(); app.buttons["openReaderChat"].tap(); revealQuote()
        app.terminate(); app.launch()
        openBook(); app.buttons["openReaderChat"].tap(); revealQuote()
        capture(flow + " quoted text restored after relaunch", app: app)
        app.buttons["chatOptions"].tap(); app.buttons["requestClearConversation"].tap()
        app.buttons["confirmClearConversation"].firstMatch.tap()
        XCTAssertFalse(quote.exists)
    }

    @MainActor func testFloatingButtonTransparencyInPages() { verifyButtonTransparency(flow:"Pages") }
    @MainActor func testFloatingButtonTransparencyInScroll() { verifyButtonTransparency(flow:"Scroll") }

    @MainActor func testFloatingButtonTransparencyPortraitInPages() { verifyButtonTransparencyPortrait(flow: "Pages") }
    @MainActor func testFloatingButtonTransparencyPortraitInScroll() { verifyButtonTransparencyPortrait(flow: "Scroll") }

    @MainActor private func verifyButtonTransparency(flow:String) {
        orient(.portrait)
        defer { orient(.portrait) }
        verifyButtonTransparencyPortrait(flow: flow) { app, launcher, surface in
            self.orient(.landscapeLeft)
            self.expectation(for:NSPredicate { _,_ in app.frame.width > app.frame.height },evaluatedWith:app);self.waitForExpectations(timeout:5)
            XCTAssertLessThanOrEqual(launcher.frame.maxX,surface.frame.maxX)
            XCTAssertLessThanOrEqual(launcher.frame.maxY,surface.frame.maxY)
            self.capture(flow + " faint button landscape",app:app)
            self.orient(.portrait)
            self.expectation(for:NSPredicate { _,_ in app.frame.height > app.frame.width },evaluatedWith:app);self.waitForExpectations(timeout:5)
        }
    }
    // The portrait cases share every endpoint/persistence assertion with the full
    // cases, and never execute any device orientation call during parallel QA.
    @MainActor private func verifyButtonTransparencyPortrait(flow:String,
        checkRotation: ((XCUIApplication, XCUIElement, XCUIElement) -> Void)? = nil) {
        let app = launchApp()
        expectation(for:NSPredicate { _,_ in app.frame.height > app.frame.width },evaluatedWith:app);waitForExpectations(timeout:5)
        func openButtonSettings() {
            app.tabBars.buttons["Settings"].tap()
            let link = app.buttons["openChatButtonSettings"]
            let form = app.collectionViews.firstMatch
            XCTAssertTrue(form.waitForExistence(timeout: 5))
            for _ in 0..<6 where !link.isHittable {
                // The center of Settings contains sliders/choice controls. Drag
                // the Form's trailing padding so the gesture scrolls the list.
                form.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85)).press(forDuration: 0.05,
                    thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2)))
            }
            XCTAssertTrue(link.isHittable);link.tap()
            XCTAssertTrue(app.sliders["chatButtonTransparency"].waitForExistence(timeout:5))
        }
        openButtonSettings()
        let slider = app.sliders["chatButtonTransparency"]
        XCTAssertEqual(slider.value as? String,"88%")
        slider.adjust(toNormalizedSliderPosition:0)
        XCTAssertEqual(slider.value as? String,"20%")
        capture(flow + " more visible button settings preview",app:app)
        app.navigationBars.buttons["Settings"].tap();app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap();showReaderControls(app)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons[flow].tap()
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
        dismissAppearance(app)
        let surface = readingSurface(app), bookFrame = surface.frame
        let launcher = app.buttons["openReaderChat"]
        XCTAssertEqual(launcher.frame.width,52,accuracy:1)
        launcher.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.65,thenDragTo:surface.coordinate(withNormalizedOffset:CGVector(dx:0.75,dy:0.4)))
        XCTAssertEqual(launcher.value as? String,"Move mode")
        capture(flow + " stronger tint in drag mode",app:app)
        app.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.6)).tap()
        XCTAssertEqual(launcher.value as? String,"Stationary")
        let position = launcher.frame
        launcher.tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap();input.typeText("Keep my transparency draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5))
        app.buttons["Hide keyboard"].tap()
        app.buttons["chatOptions"].tap();app.buttons["configureChatButton"].tap()
        XCTAssertTrue(slider.waitForExistence(timeout:5))
        XCTAssertEqual(slider.value as? String,"20%")
        for attempt in 1...4 where slider.value as? String != "95%" {
            // XCTest sometimes lands short of a stepped slider's maximum.
            // Use its native adjustment again, retaining the exact endpoint.
            slider.adjust(toNormalizedSliderPosition:1)
            let trace = XCTAttachment(string: "Attempt \(attempt): \(slider.value as? String ?? "nil"); frame \(slider.frame)")
            trace.name = flow + " transparency endpoint gesture"; trace.lifetime = .keepAlways; add(trace)
        }
        if slider.value as? String != "95%" {
            let value = Double((slider.value as? String ?? "").replacingOccurrences(of: "%", with: ""))
            let frame = slider.frame
            XCTAssertNotNil(value)
            if let value, frame.width > frame.height {
                // Begin on the measured thumb, allow Form's delayed touch to
                // reach the control, and release inside the track's endpoint.
                let inset = frame.height / 2 / frame.width
                let progress = min(1, max(0, (value - 20) / 75))
                let thumb = inset + (1 - 2 * inset) * progress
                slider.coordinate(withNormalizedOffset: CGVector(dx: thumb, dy: 0.5)).press(forDuration: 0.35,
                    thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 1 - 1 / frame.width, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
                let trace = XCTAttachment(string: "Measured thumb \(thumb); result \(slider.value as? String ?? "nil"); frame \(frame)")
                trace.name = flow + " measured endpoint drag"; trace.lifetime = .keepAlways; add(trace)
            }
        }
        XCTAssertEqual(slider.value as? String,"95%")
        capture(flow + " faint button live preview",app:app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout:5))
        XCTAssertEqual(input.value as? String,"Keep my transparency draft")
        XCTAssertEqual(surface.frame.width,bookFrame.width,accuracy:2)
        XCTAssertEqual(surface.frame.height,bookFrame.height,accuracy:2)
        app.buttons["closeReaderChat"].tap()
        XCTAssertEqual(launcher.frame.minX,position.minX,accuracy:1)
        XCTAssertEqual(launcher.frame.minY,position.minY,accuracy:1)
        capture(flow + " 95 percent transparent button over text",app:app)
        checkRotation?(app, launcher, surface)
        showReaderControls(app);app.buttons["closeBook"].tap()
        app.terminate();app.launch();openButtonSettings()
        XCTAssertEqual(slider.value as? String,"95%")
        app.buttons["resetChatButtonTransparency"].tap()
        XCTAssertEqual(slider.value as? String,"88%")
        app.navigationBars.buttons["Settings"].tap();app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap();waitForBook(app)
        XCTAssertEqual(launcher.frame.minX,position.minX,accuracy:2)
        XCTAssertEqual(launcher.frame.minY,position.minY,accuracy:2)
        XCTAssertEqual(launcher.frame.width,52,accuracy:1)
        capture(flow + " default opacity and position restored",app:app)
    }

    @MainActor func testTranslucentChatLauncherInBothFlowsThemesAndRotation() {
        let app = launchApp()
        app.buttons["featuredBook"].tap()
        waitForBook(app)
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll"] {
            for theme in ["Day", "Paper", "Night", "Sepia", "Sage", "Dusk"] {
                showReaderControls(app)
                app.buttons["Appearance"].tap()
                app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
                app.segmentedControls["readingFlow"].buttons[flow].tap()
                for margin in ["Narrow", "Wide", "Standard"] { app.buttons[margin + " margins"].tap() }
                app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
                app.buttons[theme + " theme"].tap()
                dismissAppearance(app)
                let launcher = app.buttons["openReaderChat"]
                XCTAssertTrue(launcher.waitForExistence(timeout: 5))
                XCTAssertEqual(launcher.frame.width, 52, accuracy: 1)
                capture(flow + " translucent button " + theme, app: app)
                launcher.tap()
                let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
                input.tap(); input.typeText("Explain")
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(app.otherElements["readerChatPanel"].frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
                app.buttons["closeReaderChat"].tap()
                self.orient(.landscapeLeft)
                expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
                waitForExpectations(timeout: 5)
                XCTAssertTrue(launcher.waitForExistence(timeout: 5))
                launcher.tap()
                XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
                app.buttons["closeReaderChat"].tap()
                capture(flow + " landscape translucent button " + theme, app: app)
                self.orient(.portrait)
                expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
                waitForExpectations(timeout: 5)
            }
        }
    }

    @MainActor func testLongPressMoveAndTapAwayInPages() { verifyMovableButton(in: "Pages") }
    @MainActor func testLongPressMoveAndTapAwayInScroll() { verifyMovableButton(in: "Scroll") }

    @MainActor private func verifyMovableButton(in flow: String) {
        orient(.portrait)
        defer { orient(.portrait) }
        let app = launchApp()
        app.buttons["featuredBook"].tap()
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons[flow].tap()
        dismissAppearance(app)
        showReaderControls(app)
        let bookmark = app.buttons["toggleBookmark"]
        if bookmark.label == "Add bookmark" { bookmark.tap() }
        let surface = readingSurface(app)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let launcher = app.buttons["openReaderChat"]
        XCTAssertEqual(launcher.value as? String, "Stationary")
        let original = launcher.frame
        // A short drag must not move the button or open chat.
        launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        XCTAssertEqual(launcher.frame.minX, original.minX, accuracy: 1)
        XCTAssertEqual(launcher.frame.minY, original.minY, accuracy: 1)
        XCTAssertFalse(app.buttons["closeReaderChat"].exists)
        launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.65, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)))
        XCTAssertEqual(launcher.value as? String, "Move mode")
        XCTAssertEqual(launcher.frame.midX, surface.frame.minX + surface.frame.width * 0.25, accuracy: 6)
        XCTAssertEqual(launcher.frame.midY, surface.frame.minY + surface.frame.height * 0.4, accuracy: 6)
        XCTAssertFalse(app.buttons["closeReaderChat"].exists)
        capture(flow + " translucent button move mode over text", app: app)
        // Move mode remains active after lifting, with no second long press.
        launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        XCTAssertEqual(launcher.value as? String, "Move mode")
        let moved = launcher.frame
        XCTAssertEqual(moved.midX, surface.frame.minX + surface.frame.width * 0.75, accuracy: 6)
        XCTAssertEqual(moved.midY, surface.frame.minY + surface.frame.height * 0.3, accuracy: 6)
        // An edge tap used to finish must not also turn a page or reveal controls.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(launcher.value as? String, "Stationary")
        XCTAssertFalse(app.buttons["closeBook"].exists)
        showReaderControls(app)
        XCTAssertEqual(bookmark.label, "Remove bookmark", "Finishing move mode must preserve the saved passage")
        XCTAssertEqual(launcher.frame.minX, moved.minX, accuracy: 1)
        XCTAssertEqual(launcher.frame.minY, moved.minY, accuracy: 1)
        capture(flow + " translucent button saved position", app: app)
        launcher.tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["closeReaderChat"].tap()
        XCTAssertEqual(launcher.frame.minY, moved.minY, accuracy: 1)
        showReaderControls(app)
        app.buttons["closeBook"].tap()
        app.terminate(); app.launch()
        app.buttons["featuredBook"].tap()
        waitForBook(app)
        XCTAssertEqual(launcher.frame.minX, moved.minX, accuracy: 1)
        XCTAssertEqual(launcher.frame.minY, moved.minY, accuracy: 1)
        showReaderControls(app)
        XCTAssertEqual(bookmark.label, "Remove bookmark")
        orient(.landscapeLeft)
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThanOrEqual(launcher.frame.minX, readingSurface(app).frame.minX)
        XCTAssertLessThanOrEqual(launcher.frame.maxX, readingSurface(app).frame.maxX)
        XCTAssertGreaterThanOrEqual(launcher.frame.minY, readingSurface(app).frame.minY)
        XCTAssertLessThanOrEqual(launcher.frame.maxY, readingSurface(app).frame.maxY)
        capture(flow + " moved translucent button landscape", app: app)
        orient(.portrait)
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(launcher.frame.minY, moved.minY, accuracy: 1)
        // Clamp a drag past the leading edge and keep the whole tap target reachable.
        launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.65, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.4)))
        XCTAssertGreaterThanOrEqual(launcher.frame.minX, surface.frame.minX + 7)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(launcher.value as? String, "Stationary")
    }

    @MainActor func testBothFlowsFillLandscapeViewportAndKeepLauncherInsideIt() {
        orient(.portrait)
        defer { orient(.portrait) }
        let app = launchApp()
        app.buttons["featuredBook"].tap()
        for flow in ["Pages", "Scroll"] {
            showReaderControls(app)
            app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            dismissAppearance(app)
            self.orient(.landscapeLeft)
            let launcher = app.buttons["openReaderChat"]
            launcher.tap()
            XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
            app.buttons["closeReaderChat"].tap()
            let surface = readingSurface(app)
            XCTAssertGreaterThan(surface.frame.width, surface.frame.height)
            XCTAssertLessThanOrEqual(launcher.frame.maxX, surface.frame.maxX + 1)
            XCTAssertGreaterThanOrEqual(launcher.frame.minY, surface.frame.minY)
            let frames = "app: \(app.frame), surface: \(surface.frame), launcher: \(launcher.frame)"
            let attachment = XCTAttachment(string: frames); attachment.name = flow + " landscape frames"; attachment.lifetime = .keepAlways; add(attachment)
            capture(flow + " full screen landscape", app: app)
            self.orient(.portrait)
        }
    }

    @MainActor func testScrollSwipesReachNextChapterAndPreviousChapter() {
        let app = launchApp()
        app.buttons["featuredBook"].tap()
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons["Scroll"].tap()
        dismissAppearance(app)
        let surface = readingSurface(app)
        let nextChapter = surface.staticTexts["The ordinary world"]
        for _ in 0..<9 {
            if nextChapter.exists && nextChapter.isHittable { break }
            surface.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(nextChapter.exists && nextChapter.isHittable, "A preloaded offscreen chapter does not count as crossing")
        capture("Scroll continues into the next chapter", app: app)
        showReaderControls(app)
        let chapterTitle = app.staticTexts["readerChapterTitle"]
        for _ in 0..<4 where chapterTitle.label != "The ordinary world" {
            surface.swipeUp(velocity: .slow); showReaderControls(app)
        }
        XCTAssertEqual(chapterTitle.label,"The ordinary world")
        for _ in 0..<4 where chapterTitle.label != "Begin where you are" {
            surface.swipeDown(velocity: .slow); showReaderControls(app)
        }
        showReaderControls(app)
        XCTAssertEqual(chapterTitle.label,"Begin where you are")
        capture("Scroll returns to previous chapter", app: app)
    }

    @MainActor func testChatDismissesOnlyWithCloseOrTopBarSwipeInBothFlows() {
        orient(.portrait)
        let app = launchApp()
        defer { orient(.portrait) }
        expectation(for:NSPredicate { _,_ in app.frame.height > app.frame.width },evaluatedWith:app)
        waitForExpectations(timeout:5)
        app.buttons["featuredBook"].tap()
        waitForBook(app)
        for flow in ["Pages", "Scroll"] {
            showReaderControls(app)
            app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            dismissAppearance(app)
            let surface = readingSurface(app)
            app.buttons["openReaderChat"].tap()
            let panel = app.otherElements["readerChatPanel"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            for x in [0.12, 0.5, 0.88] {
                surface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.3)).tap()
                XCTAssertTrue(app.buttons["closeReaderChat"].exists)
                XCTAssertFalse(app.buttons["openReaderChat"].exists)
            }
            let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
            input.tap(); input.typeText("Keep my question")
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16)).tap()
            XCTAssertTrue(app.buttons["closeReaderChat"].exists)
            XCTAssertEqual(input.value as? String, "Keep my question")
            let a = surface.coordinate(withNormalizedOffset: CGVector(dx: flow == "Pages" ? 0.8 : 0.5, dy: 0.28))
            let b = surface.coordinate(withNormalizedOffset: CGVector(dx: flow == "Pages" ? 0.2 : 0.5, dy: flow == "Pages" ? 0.28 : 0.12))
            a.press(forDuration: 0.01, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.1)
            b.press(forDuration: 0.01, thenDragTo: a, withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Browsing the book keeps chat open")
            XCTAssertEqual(input.value as? String, "Keep my question")
            if app.buttons["Hide keyboard"].isHittable { app.buttons["Hide keyboard"].tap() }
            let bodyStart = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: panel.frame.minX + 80, dy: panel.frame.minY + 100))
            bodyStart.press(forDuration: 0.01, thenDragTo: bodyStart.withOffset(CGVector(dx: 0, dy: 50)), withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Scrolling chat content does not dismiss it")
            let bar = app.descendants(matching: .any)["readerChatHeader"].firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 20)), withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists, "A short drag does not dismiss chat")
            capture(flow + " chat stays open after reading taps", app: app)
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 85)), withVelocity: .slow, thenHoldForDuration: 0.1)
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeReaderChat"])
            waitForExpectations(timeout: 5)
            app.buttons["openReaderChat"].tap()
            XCTAssertEqual(input.value as? String, "Keep my question")
            self.orient(.landscapeLeft)
            expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            XCTAssertTrue(app.buttons["closeReaderChat"].exists)
            capture(flow + " landscape chat retained", app: app)
            let landscapeBar = app.descendants(matching: .any)["readerChatHeader"].firstMatch
            XCTAssertTrue(landscapeBar.exists)
            let landscapeStart = landscapeBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            landscapeStart.press(forDuration: 0.01, thenDragTo: landscapeStart.withOffset(CGVector(dx: 0, dy: 70)), withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
            app.buttons["openReaderChat"].tap()
            app.buttons["closeReaderChat"].tap()
            XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
            self.orient(.portrait)
            expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            // The next flow uses the same persisted draft.
            if flow == "Pages" {
                app.buttons["openReaderChat"].tap()
                app.buttons["chatOptions"].tap(); app.buttons["requestClearConversation"].tap()
                app.buttons["confirmClearConversation"].firstMatch.tap()
                app.buttons["closeReaderChat"].tap()
            }
        }
    }

    @MainActor func testStreamingChatKeepsTheBookVisibleAndPreservesItsPlace() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Paper theme"].tap()
        app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap()
        showReaderControls(app)
        app.buttons["toggleBookmark"].tap()
        readingSurface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let surface = readingSurface(app)
        let height = surface.frame.height
        let launcher = app.buttons["openReaderChat"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertEqual(launcher.frame.width, 52, accuracy: 1)
        XCTAssertGreaterThan(surface.frame.maxY - launcher.frame.maxY, 100)
        let raisedFrame = launcher.frame
        showReaderControls(app)
        XCTAssertEqual(launcher.frame.minY, raisedFrame.minY, accuracy: 1, "Keep the icon in place when controls appear")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        capture("Translucent AI icon over full-width paper text", app: app)
        launcher.tap()
        let panel = app.otherElements["readerChatPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertLessThan(panel.frame.height, app.frame.height * 0.4)
        XCTAssertGreaterThan(panel.frame.height, app.frame.height * 0.2)
        XCTAssertEqual(surface.frame.height, height, accuracy: 1)
        XCTAssertFalse(app.buttons["closeBook"].exists)
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertFalse(app.buttons["sendReaderChat"].isEnabled)
        capture("AI compact translucent chat", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Tapping the book keeps chat open")
        app.buttons["closeReaderChat"].tap()
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists
            ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Summarize this page")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Hide keyboard"].exists)
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        XCTAssertGreaterThan(panel.frame.minY - surface.frame.minY, app.frame.height * 0.25,
                             "Keep a readable portion of the book visible while composing")
        XCTAssertLessThan(panel.frame.height, app.frame.height * 0.25)
        XCTAssertEqual(surface.frame.height, height, accuracy: 1)
        let right = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.18))
        let left = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.18))
        let firstText = surface.staticTexts.firstMatch
        let textStart = firstText.frame.minX
        right.press(forDuration: 0.01, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.12)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Keep typing focus while browsing the visible book")
        XCTAssertEqual(input.value as? String, "Summarize this page")
        left.press(forDuration: 0.01, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0.12)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        expectation(for: NSPredicate { _, _ in abs(firstText.frame.minX - textStart) < 1 }, evaluatedWith: firstText)
        waitForExpectations(timeout: 5)
        capture("AI compose while reading the book", app: app)
        app.buttons["closeReaderChat"].tap()
        app.buttons["openReaderChat"].tap()
        XCTAssertEqual(input.value as? String, "Summarize this page", "Keep the unsent question when returning to the book")
        input.tap()
        app.buttons["sendReaderChat"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Test reply:")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertEqual(surface.frame.height, height, accuracy: 1)
        app.buttons["closeReaderChat"].tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
        app.buttons["openReaderChat"].tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertTrue(reply.isHittable, "Reopening chat should show the latest reply")
        capture("AI sample reply retained", app: app)
        app.buttons["closeReaderChat"].tap()
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Add bookmark")
    }

    @MainActor func testConnectedChatGPTOffersAnotherAccountAndCancelsQuietly() {
        let app = launchApp(mockChat: false, chatGPTConnected: true)
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        let connected = app.descendants(matching: .any)["chatGPTConnectionState"].firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 5))
        XCTAssertEqual(connected.label, "ChatGPT connected")
        XCTAssertFalse(app.buttons["continueWithChatGPT"].exists)
        XCTAssertFalse(app.buttons["Sign in again"].exists)
        let identity = app.descendants(matching: .any)["connectedChatGPTAccount"].firstMatch
        XCTAssertEqual(identity.value as? String, "reader@example.test")
        XCTAssertEqual(app.buttons["chatGPTModelPicker"].value as? String, "Sample Reader")
        let add = app.buttons["addChatGPTAccount"]
        XCTAssertEqual(add.label, "Add another ChatGPT account")
        for _ in 0..<3 where !add.isHittable { app.swipeUp() }
        capture("Connected ChatGPT account actions", app: app)
        add.tap()
        let cancel = app.buttons["cancelChatGPTSignIn"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancel)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(connected.label, "ChatGPT connected")
        XCTAssertFalse(app.staticTexts["chatGPTConnectionError"].exists)
        XCTAssertFalse(app.staticTexts["Sign-in cancelled."].exists)
        XCTAssertEqual(app.buttons["chatGPTModelPicker"].value as? String, "Sample Reader")
        capture("Connected after cancelling another account", app: app)
    }

    @MainActor func testChatGPTNativeBrowserReturnsToLeaf() {
        let app = launchApp(mockChat: false, chatGPTBrowser: true)
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        app.buttons["aiProvider"].tap()
        app.buttons["ChatGPT subscription"].tap()
        XCTAssertTrue(app.buttons["continueWithChatGPT"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["aiAPIKey"].exists)
        let check = app.buttons["testChatGPTBrowser"]
        for _ in 0..<3 where !check.isHittable { app.swipeUp() }
        check.tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 3), app.alerts.buttons["Continue"].exists { app.alerts.buttons["Continue"].tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.exists, springboard.alerts.buttons["Continue"].exists { springboard.alerts.buttons["Continue"].tap() }
        let notice = app.staticTexts["chatGPTConnectionNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(notice.label, "Native browser callback verified.")
        capture("ChatGPT native browser callback", app: app)
    }

    @MainActor private func openFeaturedChat(_ app: XCUIApplication) {
        app.buttons["featuredBook"].tap(); waitForBook(app)
        app.buttons["openReaderChat"].tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
    }
    @MainActor private func sendChatQuestion(_ question: String, app: XCUIApplication) {
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText(question); app.buttons["sendReaderChat"].tap()
        let reply = app.staticTexts.matching(identifier: "chatReply").firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Test reply:"), evaluatedWith: reply)
        waitForExpectations(timeout: 10)
    }
    @MainActor func testChatHistoryAndDraftSurviveClosingBookAndRelaunch() {
        let app = launchApp(); openFeaturedChat(app)
        sendChatQuestion("Remember this question", app: app)
        XCTAssertFalse(app.buttons["toggleChatQuote"].exists, "Automatic page context must not appear as a user-selected quote")
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("An unsent followup")
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        openFeaturedChat(app)
        XCTAssertTrue(app.staticTexts["Remember this question"].exists)
        let restoredInput = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        XCTAssertEqual(restoredInput.value as? String, "An unsent followup")
        app.terminate(); app.launch(); openFeaturedChat(app)
        XCTAssertTrue(app.staticTexts["Remember this question"].exists)
        XCTAssertTrue(app.staticTexts.matching(identifier: "chatReply").firstMatch.label.contains("Test reply:"))
        let restartedInput = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        XCTAssertEqual(restartedInput.value as? String, "An unsent followup")
        capture("Conversation and draft restored after restart", app: app)
    }
    @MainActor func testClearedConversationStaysClearedAfterRelaunch() {
        let app = launchApp(); openFeaturedChat(app)
        sendChatQuestion("A question to clear", app: app)
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
        app.buttons["chatOptions"].tap(); app.buttons["requestClearConversation"].tap()
        capture("Clear conversation confirmation", app: app)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertTrue(app.staticTexts["A question to clear"].exists)
        app.buttons["chatOptions"].tap(); app.buttons["requestClearConversation"].tap()
        app.buttons["confirmClearConversation"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["A question to clear"].exists)
        app.terminate(); app.launch(); openFeaturedChat(app)
        XCTAssertFalse(app.staticTexts.matching(identifier: "chatQuestion").firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(identifier: "chatReply").firstMatch.exists)
        capture("Cleared conversation after restart", app: app)
    }
    @MainActor func testPartialChatRestoresStoppedAfterRestart() {
        let app = launchApp(slowChat: true); openFeaturedChat(app)
        sendChatQuestion("Keep my partial reply", app: app)
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        app.terminate(); app.launch(); openFeaturedChat(app)
        XCTAssertTrue(app.staticTexts["Keep my partial reply"].exists)
        XCTAssertTrue(app.staticTexts.matching(identifier: "chatReply").firstMatch.label.contains("Test reply:"))
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertEqual(app.buttons["sendReaderChat"].label, "Send message")
        capture("Interrupted reply retained with Retry after restart", app: app)
    }

    @MainActor func testChatStopAndRetryKeepOneQuestion() {
        let app = launchApp(slowChat: true)
        app.buttons["featuredBook"].tap(); waitForBook(app)
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Explain this page")
        app.buttons["sendReaderChat"].tap()
        let action = app.buttons["sendReaderChat"]
        expectation(for: NSPredicate(format: "label == %@", "Stop response"), evaluatedWith: action)
        waitForExpectations(timeout: 5)
        action.tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        XCTAssertEqual(action.label, "Send message")
        app.buttons["Retry"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Stop response"), evaluatedWith: action)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts.matching(identifier: "chatQuestion").count, 1)
        action.tap()
        capture("AI stopped reply with retry", app: app)
        app.buttons["closeReaderChat"].tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
    }

    @MainActor func testAISettingsPersistAndMissingKeyKeepsQuestion() {
        let app = launchApp(mockChat: false)
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        let model = app.textFields["aiModel"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "claude-haiku-5-5")
        app.buttons["Choose a Haiku model"].tap()
        app.buttons["Haiku 4.5"].tap()
        app.swipeUp()
        let sharing = app.switches["aiSharePage"]
        sharing.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(sharing.value as? String, "0")
        app.buttons["saveAISettings"].tap()
        XCTAssertTrue(app.staticTexts["AI settings saved"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        XCTAssertEqual(model.value as? String, "claude-haiku-4-5")
        XCTAssertEqual(app.switches["aiSharePage"].value as? String, "0")
        capture("AI provider settings", app: app)
        app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap()
        waitForBook(app)
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Explain this passage")
        app.buttons["sendReaderChat"].tap()
        let error = app.staticTexts["readerChatError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("Add your API key"))
        XCTAssertEqual(input.value as? String, "Explain this passage")
        XCTAssertFalse(app.staticTexts["chatQuestion"].exists)
        capture("AI missing key preserves draft", app: app)
        app.buttons["closeReaderChat"].tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
    }

    @MainActor func testNightChatKeepsBookVisibleWhileTyping() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Night theme"].tap()
        app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap()
        waitForBook(app)
        let surface = readingSurface(app)
        let height = surface.frame.height
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists
            ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap()
        input.typeText("Why does the character think this?")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let panel = app.otherElements["readerChatPanel"]
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        XCTAssertGreaterThan(panel.frame.minY - surface.frame.minY, app.frame.height * 0.25)
        XCTAssertEqual(surface.frame.height, height, accuracy: 1)
        XCTAssertTrue(app.buttons["Hide keyboard"].exists)
        capture("AI night compose with book visible", app: app)
        app.buttons["Hide keyboard"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, "Why does the character think this?")
        capture("AI night draft after hiding keyboard", app: app)
    }
}
