import XCTest

final class LibraryChatUITests: XCTestCase {
    @MainActor private func launch(empty: Bool = false, mock: Bool = true, environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = mock ? "1" : "0"
        app.launchEnvironment["LEAF_UI_EMPTY_LIBRARY"] = empty ? "1" : "0"
        // Rotation goes through the public scene-geometry fixture: simulated
        // device motion alone does not reliably reach UIKit on every simulator.
        app.launchEnvironment["LEAF_UI_SCENE_GEOMETRY_FIXTURE"] = "1"
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        XCTAssertTrue(app.buttons["openLibraryChat"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        return app
    }
    @MainActor private func input(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func send(_ text: String, app: XCUIApplication) {
        input(app).tap(); input(app).typeText(text); app.buttons["sendReaderChat"].tap()
        let reply = app.textViews.matching(identifier: "chatReply").firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Test reply:"), evaluatedWith: reply)
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
    }
    @MainActor private func hideKeyboard(_ app: XCUIApplication) {
        // Composing intentionally replaces the conversation chooser with the
        // keyboard controls; finish composing before changing conversation.
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        XCTAssertTrue(app.buttons["chooseLibraryConversation"].waitForExistence(timeout: 5))
    }
    @MainActor private func chooseBook(_ app: XCUIApplication) {
        hideKeyboard(app)
        app.buttons["chooseLibraryConversation"].tap()
        app.buttons["chatBook-The Art of Noticing"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "The Art of Noticing")
    }
    @MainActor private func closeBook(_ app: XCUIApplication) {
        if !app.buttons["closeBook"].exists {
            app.webViews["bookWebView"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        }
        XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 5))
        app.buttons["closeBook"].tap()
        XCTAssertTrue(app.buttons["openLibraryChat"].waitForExistence(timeout: 5))
    }
    @MainActor func testLibraryBookConversationRoundTripInPages() { roundTrip(flow: "Pages") }
    @MainActor func testLibraryBookConversationRoundTripInScroll() { roundTrip(flow: "Scroll") }
    @MainActor private func roundTrip(flow: String) {
        let app = launch()
        let launcher = app.buttons["openLibraryChat"]
        XCTAssertGreaterThanOrEqual(launcher.frame.width, 44)
        XCTAssertLessThan(launcher.frame.maxY, app.tabBars.firstMatch.frame.minY)
        let featuredFrame = app.buttons["featuredBook"].frame
        launcher.tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        chooseBook(app)
        XCTAssertFalse(app.webViews["bookWebView"].exists, "Opening chat in Library must not load a book renderer")
        XCTAssertEqual(app.buttons["featuredBook"].frame, featuredFrame)
        capture(flow + " Library book chat")
        send("Remember my Library question", app: app)
        input(app).tap(); input(app).typeText("A saved Library draft")
        capture(flow + " Library composing over visible library")
        app.buttons["closeReaderChat"].tap()
        launcher.tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        chooseBook(app)
        XCTAssertEqual(input(app).value as? String, "A saved Library draft")
        XCTAssertTrue(app.textViews["Remember my Library question"].exists)
        // Opening the book underneath the panel must synchronously save and stop
        // Library's owner before the reader creates a session for the same history.
        app.buttons["featuredBook"].tap()
        let surface = app.webViews["bookWebView"]
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        let loading = app.staticTexts["Opening your book…"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading); waitForExpectations(timeout: 20)
        if !app.buttons["Appearance"].exists {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        }
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 5))
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons[flow].tap()
        app.navigationBars["Appearance"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
        let readerPosition = app.buttons["openReaderChat"].frame
        app.buttons["openReaderChat"].tap()
        XCTAssertTrue(app.textViews["Remember my Library question"].waitForExistence(timeout: 5))
        XCTAssertEqual(input(app).value as? String, "A saved Library draft")
        capture(flow + " same conversation in reader")
        app.buttons["closeReaderChat"].tap()
        closeBook(app)
        app.terminate(); app.launch()
        app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        chooseBook(app)
        XCTAssertEqual(input(app).value as? String, "A saved Library draft")
        XCTAssertTrue(app.textViews["Remember my Library question"].exists)
        capture(flow + " Library conversation after relaunch")
        app.buttons["closeReaderChat"].tap()
        app.buttons["featuredBook"].tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["openReaderChat"].frame.minX, readerPosition.minX, accuracy: 1)
    }
    @MainActor func testLibraryLauncherAlwaysOpensSeparateGeneralChat() {
        let app = launch()
        app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        send("My general conversation", app: app)
        input(app).tap(); input(app).typeText("General draft")
        chooseBook(app)
        XCTAssertEqual(input(app).value as? String, "Ask about this book…")
        XCTAssertFalse(app.textViews["My general conversation"].exists)
        send("My book conversation", app: app)
        input(app).tap(); input(app).typeText("Separate book draft")
        app.buttons["closeReaderChat"].tap()
        app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        XCTAssertEqual(input(app).value as? String, "General draft")
        XCTAssertTrue(app.textViews["My general conversation"].exists)
        XCTAssertFalse(app.textViews["My book conversation"].exists)
        capture("Library launcher returns to separate General chat")
        chooseBook(app)
        XCTAssertEqual(input(app).value as? String, "Separate book draft")
        XCTAssertTrue(app.textViews["My book conversation"].exists)
        app.buttons["closeReaderChat"].tap()
        app.terminate(); app.launch(); app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        XCTAssertEqual(input(app).value as? String, "General draft")
        XCTAssertTrue(app.textViews["My general conversation"].exists)
        chooseBook(app)
        XCTAssertEqual(input(app).value as? String, "Separate book draft")
        XCTAssertTrue(app.textViews["My book conversation"].exists)
        capture("Book history remains separate after General relaunch")
    }
    @MainActor func testGeneralChatWorksWithEmptyLibraryAndPersistsUntilCleared() {
        let app = launch(empty: true)
        app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        XCTAssertFalse(app.webViews["bookWebView"].exists)
        send("Hello without any books", app: app)
        XCTAssertFalse(app.staticTexts["readerChatError"].exists)
        input(app).tap(); input(app).typeText("Unsent general draft")
        XCTAssertEqual(input(app).value as? String, "Unsent general draft")
        // Backgrounding exercises the app's explicit flush; force termination
        // directly after a keystroke can precede the shared 500 ms checkpoint.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.terminate(); app.launch(); app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(input(app).value as? String, "Unsent general draft")
        XCTAssertTrue(app.textViews["Hello without any books"].exists)
        capture("General chat in empty Library after relaunch")
        app.buttons["chatOptions"].tap(); app.buttons["requestClearConversation"].tap()
        XCTAssertTrue(app.staticTexts["Clear your general conversation?"].waitForExistence(timeout: 5))
        app.buttons["confirmClearConversation"].firstMatch.tap()
        XCTAssertFalse(app.textViews["Hello without any books"].exists)
        app.terminate(); app.launch(); app.buttons["openLibraryChat"].tap()
        XCTAssertFalse(app.textViews.matching(identifier: "chatQuestion").firstMatch.exists)
    }
    @MainActor func testRemovingClosedChatBookKeepsChatClosedAndFallsBackToGeneral() {
        continueAfterFailure = false
        let app = launch()
        registerSceneGeometryCleanup(app: app)
        app.buttons["openLibraryChat"].tap()
        chooseBook(app)
        input(app).tap(); input(app).typeText("Keep this book draft separate")
        app.buttons["closeReaderChat"].tap()
        let card = app.buttons["book-The Art of Noticing"]
        func openRemoval() -> XCUIElement {
            for _ in 0..<6 where !card.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(card.isHittable)
            card.press(forDuration: 1)
            app.buttons["Remove book"].tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5), "Removal uses a centered alert, never a root-anchored popover")
            XCTAssertTrue(alert.staticTexts["Remove The Art of Noticing?"].exists)
            XCTAssertTrue(alert.buttons["Cancel"].isHittable)
            XCTAssertTrue(alert.buttons["Remove from library"].isHittable)
            XCTAssertEqual(alert.frame.midX, app.frame.midX, accuracy: 4)
            XCTAssertEqual(alert.frame.midY, app.frame.midY, accuracy: app.frame.height * 0.08)
            return alert
        }
        var alert = openRemoval()
        capture("Centered library removal Day portrait")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(card.exists, "Cancel keeps the selected book")
        setReaderOrientation(.landscapeLeft, app: app)
        alert = openRemoval()
        capture("Centered library removal Day landscape")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(card.exists)
        setReaderOrientation(.portrait, app: app)
        app.tabBars.buttons["Settings"].tap(); app.buttons["Night theme"].tap()
        app.tabBars.buttons["Library"].tap()
        alert = openRemoval()
        capture("Centered library removal Night portrait")
        alert.buttons["Remove from library"].tap()
        XCTAssertFalse(card.exists, "Confirm removes the book named in the alert")
        XCTAssertTrue(app.buttons["book-Notes from the Coast"].exists, "Other books remain in the library")
        XCTAssertTrue(app.buttons["openLibraryChat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["closeReaderChat"].exists, "Removing a previously chatted book must not open chat")
        app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        XCTAssertEqual(input(app).value as? String, "Ask Leaf…")
        capture("Removed book falls back to General only when requested")
    }
    @MainActor func testLibraryConversationPickerKeepsDraftsSeparateAndSettingsReachable() {
        let app = launch()
        app.buttons["openLibraryChat"].tap()
        chooseBook(app)
        input(app).tap(); input(app).typeText("Book draft")
        app.buttons["Hide keyboard"].tap()
        app.buttons["chooseLibraryConversation"].tap()
        app.buttons["chatGeneral"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        XCTAssertEqual(input(app).value as? String, "Ask Leaf…")
        send("A separate general question", app: app)
        app.buttons["chooseLibraryConversation"].tap()
        app.buttons["chatBook-The Art of Noticing"].tap()
        XCTAssertEqual(input(app).value as? String, "Book draft")
        XCTAssertFalse(app.textViews["A separate general question"].exists)
        app.buttons["chatOptions"].tap(); app.buttons["AI settings"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["aiProvider"].exists || app.buttons["aiProvider"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertEqual(input(app).value as? String, "Book draft")
        app.buttons["chatOptions"].tap(); app.buttons["configureChatButton"].tap()
        XCTAssertTrue(app.sliders["chatButtonTransparency"].waitForExistence(timeout: 5))
        app.sliders["chatButtonTransparency"].adjust(toNormalizedSliderPosition: 0.5)
        capture("Library chat shared transparency settings")
        app.buttons["Close"].tap(); app.buttons["closeReaderChat"].tap()
        app.tabBars.buttons["Bookmarks"].tap()
        XCTAssertFalse(app.buttons["openLibraryChat"].exists)
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["openLibraryChat"].exists)
        let search = app.textFields["librarySearch"]
        search.tap(); search.typeText("Coast")
        XCTAssertTrue(app.buttons["book-Notes from the Coast"].exists)
        XCTAssertFalse(app.buttons["book-The Art of Noticing"].exists)
        app.buttons["openLibraryChat"].tap()
        hideKeyboard(app)
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        XCTAssertTrue(app.textViews["A separate general question"].exists)
        chooseBook(app)
        XCTAssertEqual(input(app).value as? String, "Book draft", "Filtering the grid must not change saved book conversations")
        capture("Library search keeps book conversations available")
    }
    @MainActor func testLibraryLauncherMovementThemesRotationAndPanelSizing() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        registerSceneGeometryCleanup(app: app)
        let launcher = app.buttons["openLibraryChat"]
        let center = launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.65, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)))
        XCTAssertEqual(launcher.value as? String, "Move mode")
        launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        let moved = launcher.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap()
        XCTAssertEqual(launcher.value as? String, "Stationary")
        app.terminate(); app.launch()
        XCTAssertTrue(launcher.waitForExistence(timeout: 10))
        XCTAssertEqual(launcher.frame.minX, moved.minX, accuracy: 1)
        XCTAssertEqual(launcher.frame.minY, moved.minY, accuracy: 1)
        for theme in ["Day", "Paper", "Night"] {
            app.tabBars.buttons["Settings"].tap(); app.buttons[theme + " theme"].tap()
            app.tabBars.buttons["Library"].tap()
            capture(theme + " Library floating button")
            launcher.tap()
            capture(theme + " Library chat")
            app.buttons["closeReaderChat"].tap()
        }
        launcher.tap()
        let panel = app.otherElements["readerChatPanel"]
        let handle = app.otherElements["readerChatDragHandle"]
        let initial = panel.frame.height
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertGreaterThan(panel.frame.height, initial + 50)
        let expanded = panel.frame.height
        app.buttons["closeReaderChat"].tap(); launcher.tap()
        XCTAssertEqual(panel.frame.height, expanded, accuracy: 3)
        input(app).tap(); input(app).typeText("Keep my draft through rotation")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture("Library expanded panel with keyboard")
        setReaderOrientation(.landscapeLeft, app: app)
        XCTAssertTrue(input(app).isHittable)
        XCTAssertTrue(app.buttons["closeReaderChat"].isHittable)
        XCTAssertEqual(input(app).value as? String, "Keep my draft through rotation")
        capture("Library landscape composing")
        app.buttons["Hide keyboard"].tap()
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.frame.maxY)
        capture("Library landscape chat")
        setReaderOrientation(.portrait, app: app)
        XCTAssertEqual(panel.frame.height, expanded, accuracy: 3)
        XCTAssertEqual(input(app).value as? String, "Keep my draft through rotation")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Shrinking the grabber must not dismiss chat")
        XCTAssertLessThan(panel.frame.height, initial + 10)
        capture("Library minimum chat size")
    }

    /// The scripted agent reads the screen with get_current_view, then lists its top three.
    @MainActor private func ask(_ text: String, expecting reply: String, app: XCUIApplication) {
        input(app).tap(); input(app).typeText(text); app.buttons["sendReaderChat"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "identifier == 'chatReply' AND label BEGINSWITH %@", reply)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "Expected a reply starting “\(reply)”")
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
    }
    @MainActor func testDiscoverAndBookmarksChatsReadTheirScreensWhenTheyAnswer() {
        let app = launch(environment: ["LEAF_UI_ZLIB_MOCK": "1", "LEAF_UI_ZLIB_GRID": "1", "LEAF_UI_CHAT_AGENT": "1", "LEAF_UI_SAVED_FIXTURE": "1"])
        registerSceneGeometryCleanup(app: app)
        app.tabBars.buttons["Discover"].tap()
        XCTAssertTrue(app.buttons["catalogBook-sample"].waitForExistence(timeout: 10))
        let launcher = app.buttons["openLibraryChat"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertLessThan(launcher.frame.maxY, app.tabBars.firstMatch.frame.minY)
        launcher.tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        ask("Summarize the top 5 books", expecting: "Screen reply: Most popular · 1. The Art of Noticing; 2. Notes from the Coast; 3. 墓碑", app: app)
        hideKeyboard(app)
        capture("Discover chat answers from the on-screen list")

        // The screen behind the open panel still works, and the next reply reads the list as it is now.
        app.segmentedControls["zlibraryFeedPicker"].buttons["Recommended"].tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Changing the feed keeps Ask Leaf open")
        ask("And this list?", expecting: "Screen reply: Recommended", app: app)
        hideKeyboard(app)
        setReaderOrientation(.landscapeLeft, app: app)
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Rotation keeps Ask Leaf open")
        capture("Discover chat in landscape")
        setReaderOrientation(.portrait, app: app)
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        app.buttons["closeReaderChat"].tap()

        app.tabBars.buttons["Bookmarks"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture bookmark")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(launcher.waitForExistence(timeout: 5)); launcher.tap()
        XCTAssertTrue(app.textViews["Summarize the top 5 books"].exists, "Every tab continues the one General chat")
        ask("What did I bookmark?", expecting: "Screen reply: Bookmarks · 1. ", app: app)
        hideKeyboard(app)
        capture("Bookmarks chat answers from the saved places")
    }
}
