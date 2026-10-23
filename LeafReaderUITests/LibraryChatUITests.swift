import XCTest

final class LibraryChatUITests: XCTestCase {
    @MainActor private func launch(empty: Bool = false, mock: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = mock ? "1" : "0"
        app.launchEnvironment["LEAF_UI_EMPTY_LIBRARY"] = empty ? "1" : "0"
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
        let reply = app.staticTexts.matching(identifier: "chatReply").firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Test reply:"), evaluatedWith: reply)
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
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
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "The Art of Noticing")
        XCTAssertFalse(app.webViews["bookWebView"].exists, "Opening chat in Library must not load a book renderer")
        XCTAssertEqual(app.buttons["featuredBook"].frame, featuredFrame)
        capture(flow + " Library book chat")
        send("Remember my Library question", app: app)
        input(app).tap(); input(app).typeText("A saved Library draft")
        capture(flow + " Library composing over visible library")
        app.buttons["closeReaderChat"].tap()
        launcher.tap()
        XCTAssertEqual(input(app).value as? String, "A saved Library draft")
        XCTAssertTrue(app.staticTexts["Remember my Library question"].exists)
        // Opening the book underneath the panel must synchronously save and stop
        // Library's owner before the reader creates a session for the same history.
        app.buttons["closeReaderChat"].tap()
        app.buttons["featuredBook"].tap()
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 15))
        let loading = app.staticTexts["Opening your book…"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading); waitForExpectations(timeout: 20)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons[flow].tap()
        app.navigationBars["Appearance"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
        let readerPosition = app.buttons["openReaderChat"].frame
        app.buttons["openReaderChat"].tap()
        XCTAssertTrue(app.staticTexts["Remember my Library question"].waitForExistence(timeout: 5))
        XCTAssertEqual(input(app).value as? String, "A saved Library draft")
        capture(flow + " same conversation in reader")
        app.buttons["closeReaderChat"].tap()
        closeBook(app)
        app.terminate(); app.launch()
        app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(input(app).value as? String, "A saved Library draft")
        XCTAssertTrue(app.staticTexts["Remember my Library question"].exists)
        capture(flow + " Library conversation after relaunch")
        app.buttons["closeReaderChat"].tap()
        app.buttons["featuredBook"].tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["openReaderChat"].frame.minX, readerPosition.minX, accuracy: 1)
    }
    @MainActor func testGeneralChatWorksWithEmptyLibraryAndPersistsUntilCleared() {
        let app = launch(empty: true)
        app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(app.buttons["chooseLibraryConversation"].value as? String, "General chat")
        XCTAssertFalse(app.webViews["bookWebView"].exists)
        send("Hello without any books", app: app)
        XCTAssertFalse(app.staticTexts["readerChatError"].exists)
        input(app).tap(); input(app).typeText("Unsent general draft")
        app.terminate(); app.launch(); app.buttons["openLibraryChat"].tap()
        XCTAssertEqual(input(app).value as? String, "Unsent general draft")
        XCTAssertTrue(app.staticTexts["Hello without any books"].exists)
        capture("General chat in empty Library after relaunch")
        app.buttons["chatOptions"].tap(); app.buttons["requestClearConversation"].tap()
        XCTAssertTrue(app.staticTexts["Clear your general conversation?"].waitForExistence(timeout: 5))
        app.buttons["confirmClearConversation"].tap()
        XCTAssertFalse(app.staticTexts["Hello without any books"].exists)
        app.terminate(); app.launch(); app.buttons["openLibraryChat"].tap()
        XCTAssertFalse(app.staticTexts.matching(identifier: "chatQuestion").firstMatch.exists)
    }
    @MainActor func testLibraryConversationPickerKeepsDraftsSeparateAndSettingsReachable() {
        let app = launch()
        app.buttons["openLibraryChat"].tap()
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
        XCTAssertFalse(app.staticTexts["A separate general question"].exists)
        app.buttons["chatOptions"].tap(); app.buttons["AI settings"].tap()
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
        XCTAssertEqual(input(app).value as? String, "Book draft", "Filtering the grid must not change the selected chat")
        capture("Library search retains chosen book chat")
    }
    @MainActor func testLibraryLauncherMovementThemesRotationAndPanelSizing() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
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
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 5)
        XCTAssertTrue(input(app).isHittable)
        XCTAssertTrue(app.buttons["closeReaderChat"].isHittable)
        XCTAssertEqual(input(app).value as? String, "Keep my draft through rotation")
        capture("Library landscape composing")
        app.buttons["Hide keyboard"].tap()
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.frame.maxY)
        capture("Library landscape chat")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app); waitForExpectations(timeout: 5)
        XCTAssertEqual(panel.frame.height, expanded, accuracy: 3)
        XCTAssertEqual(input(app).value as? String, "Keep my draft through rotation")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Shrinking the grabber must not dismiss chat")
        XCTAssertLessThan(panel.frame.height, initial + 10)
        capture("Library minimum chat size")
    }
}
