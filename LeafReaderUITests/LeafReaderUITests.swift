import XCTest

final class LeafReaderUITests: XCTestCase {
    @MainActor private func launchApp(mockChat: Bool = true, slowChat: Bool = false, chatGPTBrowser: Bool = false, chatGPTConnected: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = mockChat ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_SLOW"] = slowChat ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHATGPT_BROWSER"] = chatGPTBrowser ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHATGPT_CONNECTED"] = chatGPTConnected ? "1" : "0"
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
    @MainActor private func dismissAppearance(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["Done"].exists)
        let titleBar = app.navigationBars["Appearance"]
        titleBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.segmentedControls["appearanceTabs"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["closeBook"].exists)
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
        capture("AI floating button on paper", app: app)
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
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeReaderChat"])
        waitForExpectations(timeout: 5)
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
