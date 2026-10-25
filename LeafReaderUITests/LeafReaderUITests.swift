import XCTest
import Speech

final class LeafReaderUITests: XCTestCase {
    private var geometryApp: XCUIApplication?
    @MainActor private func orient(_ direction: UIDeviceOrientation) {
        if let app = geometryApp, app.state == .runningForeground { setReaderOrientation(direction, app: app) }
        else { XCUIDevice.shared.orientation = direction }
    }
    @MainActor private func launchApp(mockChat: Bool = true, slowChat: Bool = false, chatGPTBrowser: Bool = false, chatGPTConnected: Bool = false, geometryFixture: Bool = true, naturalVoicePack: Bool = false, contextProbe: Bool = false, markdown: Bool = false, dictation: Bool = false, nativeDictation: Bool = false) -> XCUIApplication {

        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEAF_UI_ZLIB_MOCK"] = "1"
        app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = mockChat ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_SLOW"] = slowChat ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_CONTEXT_PROBE"] = contextProbe ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_MARKDOWN"] = markdown ? "1" : "0"
        app.launchEnvironment["LEAF_UI_DICTATION_MOCK"] = dictation ? "1" : "0"
        if nativeDictation {
            let audio = Bundle(for: LeafReaderUITests.self).url(forResource: "Mandarin", withExtension: "m4a")!
            app.launchEnvironment["LEAF_UI_DICTATION_NATIVE_AUDIO"] = try! Data(contentsOf: audio).base64EncodedString()
        }
        app.launchEnvironment["LEAF_UI_CHATGPT_BROWSER"] = chatGPTBrowser ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHATGPT_CONNECTED"] = chatGPTConnected ? "1" : "0"
        app.launchEnvironment["LEAF_UI_SCENE_GEOMETRY_FIXTURE"] = geometryFixture ? "1" : "0"
        if naturalVoicePack {
            let root = ProcessInfo.processInfo.environment["LEAF_UI_KOKORO_ROOT"] ?? ""
            XCTAssertFalse(root.isEmpty, "Audible playback checks require the real prepared natural voice pack")
            app.launchEnvironment["LEAF_UI_KOKORO_ROOT"] = root
        }
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
        let surface = readingSurface(app)
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let loading = app.staticTexts["Opening your book…"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
        waitForExpectations(timeout: 60)
        XCTAssertFalse(app.otherElements["readerError"].exists)
        if surface.elementType == .webView {
            XCTAssertTrue(surface.staticTexts.firstMatch.waitForExistence(timeout: 10), "Wait for actual chapter text, not merely an empty WebView")
        }
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
        let bookmark = app.buttons["toggleBookmark"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            bookmark.exists && bookmark.isEnabled && app.buttons["Appearance"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Reader controls must be enabled and reachable before setup continues")
    }
    @MainActor private func openAppearance(_ app: XCUIApplication) {
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        XCTAssertTrue(app.segmentedControls["appearanceTabs"].waitForExistence(timeout: 10), "The Appearance sheet must actually open before selecting a tab")
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
            XCTAssertTrue(app.buttons["importBooks"].waitForExistence(timeout: 5))
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
        let app = launchApp(naturalVoicePack: true)
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
            // Navigate the real library card; search-field focus is unrelated to selection.
            let card = app.buttons["book-Notes from the Coast"]
            for _ in 0..<5 {
                if card.exists && card.isHittable { break }
                app.scrollViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(card.exists && card.isHittable, "PDF fixture must be reachable in the library")
            card.tap()
            showReaderControls(app); app.buttons["nextPage"].tap()
        } else {
            XCTAssertTrue(app.buttons["featuredBook"].waitForExistence(timeout: 10))
            app.buttons["featuredBook"].tap(); openAppearance(app)
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
            dismissAppearance(app)
        }
    }
    @MainActor private func selectFixturePassage(_ flow: String, app: XCUIApplication, pdfWordOffset: CGFloat = 0.15) {
        let pdf = flow == "PDF", paragraph = readingSurface(app).staticTexts.containing(NSPredicate(format: "label CONTAINS %@", pdf ? "Before the town" : "Attention is a way")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        // Web content's element-relative coordinates can retain the physical
        // portrait transform after a public scene-geometry request. Use the
        // measured scene frame, as the native handle drags below do.
        let frame = paragraph.frame
        let point = CGPoint(x: frame.minX + frame.width * (pdf ? pdfWordOffset : 0.3),
                            y: frame.minY + frame.height * (pdf ? 0.25 : 0.1))
        XCTAssertTrue(readingSurface(app).frame.contains(point), "The real long press must target visible book text")
        let chat = app.otherElements["readerChatPanel"]
        XCTAssertFalse(chat.exists && chat.frame.contains(point), "Selection setup must not press the chat panel")
        let target = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
        let evidence = XCTAttachment(string: "time: \(ProcessInfo.processInfo.systemUptime); paragraph: \(frame); intended scene point: \(point); resolved screen point: \(target.screenPoint); book: \(readingSurface(app).frame); app: \(app.frame)")
        evidence.name = flow + " native selection gesture target"; evidence.lifetime = .keepAlways; add(evidence)
        target.press(forDuration: 1.2)
    }
    @MainActor private func assertFiveActionRibbon(_ app: XCUIApplication) {
        let menu = app.scrollViews["expandedSelectionMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 6))
        let identifiers = ["ask", "listen", "highlight", "note", "copy"]
        XCTAssertEqual(menu.buttons.count, identifiers.count, "Exactly the five approved actions appear, without overflow")
        let row = app.buttons["selection-ask"].frame, bounds = menu.frame
        for id in identifiers {
            let button = app.buttons["selection-" + id]
            XCTAssertTrue(button.isHittable, "Action is immediately available: " + id)
            let frame = button.frame
            XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(frame), "No action needs horizontal paging: " + id)
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertEqual(frame.midY, row.midY, accuracy: 1, "Every action belongs to the same row")
        }
        XCTAssertGreaterThanOrEqual(bounds.height, 44)
        XCTAssertLessThanOrEqual(bounds.height, 84, "Keep the reference design's compact single row")
        for id in ["system", "more", "lookup", "translate", "share", "back"] {
            XCTAssertFalse(app.buttons["selection-" + id].exists, "No overflow or unapproved action: " + id)
        }
        XCTAssertEqual(app.menuItems.count, 0, "The reader never presents the stock selection toolbar")
        for (label, identifier) in [("Copy", "selection-copy"), ("Look Up", "selection-lookup"), ("Translate", "selection-translate"), ("Leaf actions", "selection-none")] {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", label, identifier)).firstMatch.exists, "No stock selection action: " + label)
        }
    }
    @MainActor private func revealSelectionAction(_ id: String, app: XCUIApplication) -> XCUIElement {
        assertFiveActionRibbon(app)
        return app.buttons["selection-" + id]
    }
    @MainActor private func tapBookOutsideSelectionPalette(_ app: XCUIApplication) {
        let menu = app.scrollViews["expandedSelectionMenu"]
        XCTAssertTrue(menu.exists)
        let book = readingSurface(app).frame.insetBy(dx: 12, dy: 12)
        var excluded = [menu.frame.insetBy(dx: -12, dy: -12)]
        let chat = app.otherElements["readerChatPanel"]
        if chat.exists { excluded.append(chat.frame) }
        for id in ["selection-start-geometry", "selection-end-geometry"] {
            let grip = app.descendants(matching: .any)[id].firstMatch
            if grip.exists { excluded.append(grip.frame.insetBy(dx: -18, dy: -18)) }
        }
        let candidates = [0.85, 0.65, 0.4, 0.2].flatMap { y in
            [0.5, 0.25, 0.75].map { x in CGPoint(x: book.minX + book.width * x, y: book.minY + book.height * y) }
        }
        guard let point = candidates.first(where: { point in !excluded.contains { $0.contains(point) } }) else {
            XCTFail("A visible book point outside the palette and native handles is required"); return
        }
        XCTAssertTrue(book.contains(point))
        XCTAssertFalse(excluded.contains { $0.contains(point) })
        let target = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
        let proof = XCTAttachment(string: "Book: \(book); palette including card: \(excluded[0]); exclusions: \(excluded); intended point: \(point); actual screen point: \(target.screenPoint)")
        proof.name = "Measured book tap outside selection palette"; proof.lifetime = .keepAlways; add(proof)
        target.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: menu); waitForExpectations(timeout: 5)
    }
    @MainActor func testSelectionPaletteThemesFontExtremesAndMarginsInBothFlows() {
        continueAfterFailure = false
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll"] {
            let app = launchApp(); openSelectionFixture(flow, app: app)
            for (theme, size, margin) in [("Day", 12, "Narrow"), ("Paper", 32, "Wide"), ("Night", 22, "Standard"), ("Sage", 19, "Standard")] {
                openAppearance(app)
                app.segmentedControls["appearanceTabs"].buttons["Font"].tap()
                app.sliders["fontSize"].adjust(toNormalizedSliderPosition: Double(size - 12) / 20)
                for _ in 0..<20 {
                    let value = app.sliders["fontSize"].value as? String ?? ""
                    if value == "\(size) points" { break }
                    guard let current = Int(value.components(separatedBy: " ").first ?? "") else { break }
                    app.buttons[current > size ? "decreaseTextSize" : "increaseTextSize"].tap()
                }
                XCTAssertEqual(app.sliders["fontSize"].value as? String, "\(size) points")
                app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
                app.buttons["margins-" + margin].tap()
                app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
                app.buttons[theme + " theme"].tap(); dismissAppearance(app)
                selectFixturePassage(flow, app: app)
                let menu = app.scrollViews["expandedSelectionMenu"]
                XCTAssertTrue(menu.waitForExistence(timeout: 6))
                assertFiveActionRibbon(app)
                capture(flow + " " + theme + " palette at \(size) pt with " + margin + " margins", app: app)
                readingSurface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)).tap()
                XCTAssertFalse(menu.exists)
            }
            app.terminate()
        }
    }
    @MainActor func testSelectionPaletteHandlesInPages() { verifyPaletteSelectionHandles(flow: "Pages") }
    @MainActor func testSelectionPaletteHandlesInScroll() { verifyPaletteSelectionHandles(flow: "Scroll") }
    @MainActor func testSelectionPaletteHandlesInPDF() { verifyPaletteSelectionHandles(flow: "PDF") }
    @MainActor func testSelectionPaletteHandlesInScrollWithSceneGeometryFixture() { verifyPaletteSelectionHandles(flow: "Scroll", geometryFixture: true) }
    @MainActor private func verifyPaletteSelectionHandles(flow: String, geometryFixture: Bool = true) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        do {
            let app = launchApp(geometryFixture: geometryFixture); openSelectionFixture(flow, app: app)
            if geometryFixture {
                addTeardownBlock { @MainActor in
                    if app.state == .runningForeground { self.setReaderOrientation(.portrait, app: app) }
                    app.terminate()
                }
            }
            for landscape in [false, true] {
                setReaderOrientation(landscape ? .landscapeLeft : .portrait, app: app)
                expectation(for: NSPredicate { _, _ in landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width }, evaluatedWith: app)
                waitForExpectations(timeout: 6)
                // PDFKit retains native grips after menu dismissal. Select a
                // different word after rotation, not the old grip itself.
                selectFixturePassage(flow, app: app, pdfWordOffset: landscape ? 0.55 : 0.15)
                let menu = app.scrollViews["expandedSelectionMenu"]
                XCTAssertTrue(menu.waitForExistence(timeout: 6))
                assertFiveActionRibbon(app)
                let initial = menu.value as? String ?? ""
                let initialLocator = app.buttons["selection-ask"].value as? String ?? ""
                XCTAssertFalse(initial.isEmpty); XCTAssertFalse(initialLocator.isEmpty)
                XCTAssertEqual(menu.value as? String, initial, "Presenting the palette cannot change the selected text")
                let handle = app.descendants(matching: .any)["selection-end-geometry"].firstMatch
                XCTAssertTrue(handle.waitForExistence(timeout: 3))
                XCTAssertFalse(menu.frame.insetBy(dx: 0, dy: -12).intersects(handle.frame), "Toolbar must leave the native handle clear")
                capture(flow + (landscape ? " landscape" : " portrait") + " action palette before native handle drag", app: app)
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: handle.frame.midX, dy: handle.frame.midY))
                start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 80, dy: landscape ? 0 : 35)), withVelocity: .slow, thenHoldForDuration: 0.2)
                XCTAssertTrue(menu.waitForExistence(timeout: 5), "Native grip changes must restore the ribbon directly")
                assertFiveActionRibbon(app)
                let extended = menu.value as? String ?? ""
                XCTAssertGreaterThan(extended.count, initial.count, "Dragging the real native end handle must extend the passage in " + flow)
                let extendedLocator = app.buttons["selection-ask"].value as? String ?? ""
                XCTAssertFalse(extendedLocator.isEmpty); XCTAssertNotEqual(extendedLocator, initialLocator, "Actions must use the changed native range locator")
                if flow == "PDF" {
                    // PDFKit can include adjacent whitespace while adjusting a
                    // handle. Preserve the actual original characters, not an
                    // assumption about leading whitespace in selection.string.
                    func ranges(_ identity: String) -> [(Int, NSRange)] {
                        identity.split(separator: "|", maxSplits: 1).last?.split(separator: ",").compactMap { value in
                            let parts = value.split(separator: ":").compactMap { Int($0) }
                            return parts.count == 3 ? (parts[0], NSRange(location: parts[1], length: parts[2])) : nil
                        } ?? []
                    }
                    let oldRanges = ranges(initialLocator), newRanges = ranges(extendedLocator)
                    XCTAssertFalse(oldRanges.isEmpty); XCTAssertFalse(newRanges.isEmpty)
                    for (page, range) in oldRanges {
                        XCTAssertTrue(newRanges.contains { $0.0 == page && $0.1.location <= range.location && NSMaxRange($0.1) >= NSMaxRange(range) }, "PDF handle adjustment must retain the exact original characters")
                    }
                    XCTAssertGreaterThan(newRanges.reduce(0) { $0 + $1.1.length }, oldRanges.reduce(0) { $0 + $1.1.length })
                } else { XCTAssertTrue(extended.hasPrefix(initial), "Handle drag must retain the original selected word") }
                capture(flow + (landscape ? " landscape" : " portrait") + " native selection extended with action palette", app: app)
                let startHandle = app.descendants(matching: .any)["selection-start-geometry"].firstMatch
                XCTAssertTrue(startHandle.waitForExistence(timeout: 3))
                XCTAssertFalse(menu.frame.insetBy(dx: 0, dy: -12).intersects(startHandle.frame))
                let trim = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: startHandle.frame.midX, dy: startHandle.frame.midY))
                trim.press(forDuration: 0.7, thenDragTo: trim.withOffset(CGVector(dx: 36, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
                let trimmed = menu.value as? String ?? ""
                XCTAssertFalse(trimmed.isEmpty); XCTAssertNotEqual(trimmed, extended, "Native start handle must also remain draggable")
                XCTAssertNotEqual(app.buttons["selection-ask"].value as? String, extendedLocator)
                capture(flow + (landscape ? " landscape" : " portrait") + " native start handle adjusted", app: app)
                let copiedStart = app.descendants(matching: .any)["selection-start-geometry"].firstMatch.frame
                let copiedLocator = app.buttons["selection-ask"].value as? String
                revealSelectionAction("copy", app: app).tap()
                let lateCopyMenu = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: menu)
                lateCopyMenu.isInverted = true; waitForExpectations(timeout: 0.45)
                // Copy intentionally retains UIKit's selection. Its real grip
                // must still adjust that range and refresh actions afterward.
                let retained = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: copiedStart.midX, dy: copiedStart.midY))
                retained.press(forDuration: 0.7, thenDragTo: retained.withOffset(CGVector(dx: 18, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
                XCTAssertFalse((menu.value as? String ?? "").isEmpty)
                XCTAssertNotEqual(menu.value as? String, trimmed)
                XCTAssertNotEqual(app.buttons["selection-ask"].value as? String, copiedLocator)
                capture(flow + (landscape ? " landscape" : " portrait") + " copied native selection remains adjustable", app: app)
                // A tap explicitly finishes this range before starting another.
                tapBookOutsideSelectionPalette(app)
                if app.buttons["closeBook"].exists { readingSurface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                selectFixturePassage(flow, app: app)
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
                tapBookOutsideSelectionPalette(app)
                if app.buttons["closeBook"].exists { readingSurface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                let lateDismissedMenu = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: menu)
                lateDismissedMenu.isInverted = true; waitForExpectations(timeout: 0.45)
            }
            if flow == "PDF" {
                // Leaving a selection must not permanently disable ordinary
                // reader edge taps after the native gesture-completion grace.
                selectFixturePassage(flow, app: app, pdfWordOffset: 0.55)
                XCTAssertTrue(app.scrollViews["expandedSelectionMenu"].waitForExistence(timeout: 5))
                revealSelectionAction("ask", app: app).tap()
                XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
                app.buttons["closeReaderChat"].tap()
                showReaderControls(app)
                let title = app.staticTexts["readerChapterTitle"], originalPage = title.label
                XCTAssertFalse(originalPage.isEmpty)
                let surface = readingSurface(app)
                func tapBookInScene(_ fraction: CGFloat) {
                    // Like the native-grip checks, use measured scene points:
                    // element-relative taps can retain the pre-rotation transform.
                    let frame = surface.frame
                    let point = CGPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
                    XCTAssertTrue(frame.contains(point))
                    let target = app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
                    let proof = XCTAttachment(string: "Book: \(frame); intended scene point: \(point); actual screen point: \(target.screenPoint)")
                    proof.name = "PDF post-selection scene tap \(fraction)"; proof.lifetime = .keepAlways; add(proof)
                    target.tap()
                }
                tapBookInScene(0.5)
                tapBookInScene(0.95)
                showReaderControls(app)
                XCTAssertNotEqual(title.label, originalPage, "A normal right-edge tap must advance after selection closes")
                tapBookInScene(0.5)
                tapBookInScene(0.05)
                showReaderControls(app)
                XCTAssertEqual(title.label, originalPage, "A normal left-edge tap must return to the original PDF page")
                capture("PDF ordinary edge navigation resumes after native selection", app: app)
            }
            if geometryFixture { setReaderOrientation(.portrait, app: app) }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }
    @MainActor func testSelectionPalettePrimaryActionsInPages() { verifyPrimarySelectionActions("Pages") }
    @MainActor func testSelectionPalettePrimaryActionsInScroll() { verifyPrimarySelectionActions("Scroll") }
    @MainActor func testSelectionPalettePrimaryActionsInPDF() { verifyPrimarySelectionActions("PDF") }

    @MainActor private func finishNativeSelectionAfterRotation(_ flow: String, expectedQuote: String, app: XCUIApplication) {
        let surface = readingSurface(app)
        // UIKit can retain its native selection interaction after EPUB reflow
        // clears the DOM range. End that interaction with one real book tap.
        let target = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let trace = XCTAttachment(string: "time: \(ProcessInfo.processInfo.systemUptime); resolved screen point: \(target.screenPoint); book: \(surface.frame)")
        trace.name = flow + " finish retained native selection gesture"; trace.lifetime = .keepAlways; add(trace)
        target.tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Ending native selection must keep chat open")
        XCTAssertEqual(app.staticTexts["chatSelectedPassage"].label, expectedQuote, "The saved quote survives ending native selection")
        capture(flow + " retained native selection finished after rotation", app: app)
    }

    @MainActor private func verifyPrimarySelectionActions(_ flow: String) {
        continueAfterFailure = false
        orient(.portrait)
        defer { orient(.portrait) }
        let app = launchApp(); openSelectionFixture(flow, app: app)
        app.buttons["openReaderChat"].tap()
        selectFixturePassage(flow, app: app)
        let menu = app.scrollViews["expandedSelectionMenu"]
        if !menu.waitForExistence(timeout: 6) {
            capture(flow + " missing expanded selection menu", app: app)
            let state = XCTAttachment(string: app.debugDescription); state.name = "Expanded selection menu hierarchy"; state.lifetime = .keepAlways; add(state)
            XCTFail("Expanded selection menu did not appear in " + flow); return
        }
        let selected = menu.value as? String ?? ""
        XCTAssertFalse(selected.isEmpty)
        let passage = app.staticTexts["chatSelectedPassage"]
        XCTAssertTrue(passage.waitForExistence(timeout: 5))
        XCTAssertEqual(passage.label, selected)
        let originalLocator = app.buttons["selection-ask"].value as? String ?? ""
        XCTAssertFalse(originalLocator.isEmpty)
        assertFiveActionRibbon(app)
        XCTAssertEqual(menu.value as? String, selected)
        XCTAssertEqual(app.buttons["selection-ask"].value as? String, originalLocator)
        capture(flow + " expanded selection menu all actions", app: app)
        self.orient(.landscapeLeft)

        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app); waitForExpectations(timeout: 6)
        XCTAssertEqual(passage.label, selected, "The saved quote survives native selection invalidation during reflow")
        // Actual EPUB reflow can clear the native range. Exercise a real
        // selection in the new layout rather than assuming a cached menu
        // still represents selected text. PDFKit can retain its old grips,
        // so choose an unselected word away from the earlier endpoint.
        finishNativeSelectionAfterRotation(flow, expectedQuote: selected, app: app)
        selectFixturePassage(flow, app: app, pdfWordOffset: 0.55)
        XCTAssertTrue(menu.waitForExistence(timeout: 6))
        let landscapeSelection = menu.value as? String ?? ""
        let landscapeLocator = app.buttons["selection-ask"].value as? String ?? ""
        XCTAssertFalse(landscapeSelection.isEmpty); XCTAssertFalse(landscapeLocator.isEmpty)
        XCTAssertEqual(passage.label, landscapeSelection)
        assertFiveActionRibbon(app)
        XCTAssertEqual(menu.value as? String, landscapeSelection)
        XCTAssertEqual(app.buttons["selection-ask"].value as? String, landscapeLocator)
        capture(flow + " expanded selection menu landscape", app: app)
        self.orient(.portrait)

        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app); waitForExpectations(timeout: 6)
        XCTAssertEqual(passage.label, landscapeSelection)
        finishNativeSelectionAfterRotation(flow, expectedQuote: landscapeSelection, app: app)
        selectFixturePassage(flow, app: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 6))
        let copiedSelection = menu.value as? String ?? ""
        XCTAssertFalse(copiedSelection.isEmpty)
        XCTAssertFalse((app.buttons["selection-ask"].value as? String ?? "").isEmpty)
        revealSelectionAction("copy", app: app).tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
        XCTAssertEqual(passage.label, copiedSelection)
        capture(flow + " native Copy completed with selected quote intact", app: app)
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        XCTAssertEqual(input.value as? String, copiedSelection, "Copy must retain the actual current native selection")
        capture(flow + " copied selection pasted into chat", app: app)
        app.terminate()
    }
    @MainActor func testSelectionActionsReceiveTapsKeepComposerFocusAndLeaveNoWindowAfterClosing() {
        continueAfterFailure = false
        let app = launchApp(); app.buttons["featuredBook"].tap(); waitForBook(app)
        app.buttons["openReaderChat"].tap()
        capture("Reading before the selection menu", app: app)
        selectFixturePassage("Pages", app: app)
        let menu = app.scrollViews["expandedSelectionMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 6))
        assertFiveActionRibbon(app)
        XCTAssertFalse(app.menuItems["Leaf actions"].exists || app.buttons["Leaf actions"].exists, "The native toolbar must not cover the expanded actions")
        let firstSelection = menu.value as? String ?? ""
        XCTAssertFalse(firstSelection.isEmpty)
        capture("Selection ribbon receives all five actions", app: app)
        revealSelectionAction("copy", app: app).tap(); XCTAssertFalse(menu.exists)
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
    @MainActor func testFiveActionRibbonHasNoOverflowOrStockToolbarInPages() { verifyFiveActionRibbon("Pages") }
    @MainActor func testFiveActionRibbonHasNoOverflowOrStockToolbarInScroll() { verifyFiveActionRibbon("Scroll") }
    @MainActor func testFiveActionRibbonHasNoOverflowOrStockToolbarInPDF() { verifyFiveActionRibbon("PDF") }
    @MainActor private func verifyFiveActionRibbon(_ flow: String) {
        continueAfterFailure = false
        let app = launchApp(); openSelectionFixture(flow, app: app)
        defer { orient(.portrait) }
        for landscape in [false, true] {
            if landscape { orient(.landscapeLeft) }
            for cycle in 0..<2 {
                // PDFKit retains native handles after tap-away. Selecting
                // another word starts a fresh range instead of pressing a grip.
                selectFixturePassage(flow, app: app, pdfWordOffset: cycle == 0 ? 0.15 : 0.55)
                let menu = app.scrollViews["expandedSelectionMenu"]
                assertFiveActionRibbon(app)
                let selected = menu.value as? String ?? ""
                let locator = app.buttons["selection-ask"].value as? String ?? ""
                XCTAssertFalse(selected.isEmpty); XCTAssertFalse(locator.isEmpty)
                XCTAssertEqual(menu.value as? String, selected, "Showing the ribbon must retain the selected passage")
                capture(flow + (landscape ? " landscape" : " portrait") + " five-action ribbon cycle \(cycle + 1)", app: app)
                tapBookOutsideSelectionPalette(app)
                XCTAssertEqual(app.menuItems.count, 0, "Dismissing the ribbon must not reveal a cached stock toolbar")
                if app.buttons["closeBook"].exists { readingSurface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            }
        }
        app.terminate()
    }
    @MainActor func testSpeechProgressHighlightsVisibleTextInPagesScrollAndPDF() {
        continueAfterFailure = false
        orient(.portrait)
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll", "PDF"] {
            let app = launchApp(naturalVoicePack: true); openSelectionFixture(flow, app: app)
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
        let app = launchApp(naturalVoicePack: true); app.buttons["featuredBook"].tap()
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

    @MainActor func testVoiceTypesKeepIndependentSpeedsInPagesScrollAndPDF() {
        continueAfterFailure = false
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll", "PDF"] {
            let app = launchApp(); openSelectionFixture(flow, app: app)
            showReaderControls(app); app.buttons["Listen"].tap()
            let engine = app.segmentedControls["listeningEngine"]
            let slider = app.sliders["listeningSpeedSlider"], value = app.staticTexts["listeningSpeedValue"]
            XCTAssertTrue(engine.waitForExistence(timeout: 5))
            XCTAssertTrue(engine.buttons["Natural voice"].isSelected)
            XCTAssertEqual(value.label, "1×")
            slider.adjust(toNormalizedSliderPosition: 2.0 / 3.0)
            XCTAssertEqual(value.label, "1.5×")
            engine.buttons["Apple voices"].tap(); XCTAssertEqual(value.label, "1×")
            slider.adjust(toNormalizedSliderPosition: 1.0 / 6.0)
            XCTAssertEqual(value.label, "0.75×")
            capture(flow + " Apple speed independent from Natural", app: app)
            orient(.landscapeLeft)
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
            XCTAssertTrue(engine.isHittable); XCTAssertEqual(value.label, "0.75×")
            capture(flow + " independent speed settings landscape", app: app)
            orient(.portrait)
            engine.buttons["Natural voice"].tap(); XCTAssertEqual(value.label, "1.5×")
            capture(flow + " Natural speed restored after switching", app: app)
            app.navigationBars["Listen"].buttons["Done"].tap()
            showReaderControls(app); app.buttons["closeBook"].tap()
            app.terminate(); app.launch()
            openSelectionFixture(flow, app: app)
            showReaderControls(app); app.buttons["Listen"].tap()
            XCTAssertTrue(engine.waitForExistence(timeout: 5))
            XCTAssertTrue(engine.buttons["Natural voice"].isSelected)
            XCTAssertEqual(value.label, "1.5×", flow + " Natural speed survives closing the book and relaunch")
            engine.buttons["Apple voices"].tap()
            XCTAssertEqual(value.label, "0.75×", flow + " Apple speed survives closing the book and relaunch")
            capture(flow + " both voice speeds survive app relaunch", app: app)
            app.terminate()
        }
    }

    @MainActor func testPlayerSpeedChangesOnlyTheSelectedVoiceTypeInAllReaderFlows() {
        continueAfterFailure = false
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll", "PDF"] {
            let app = launchApp(naturalVoicePack: true); openSelectionFixture(flow, app: app)
            showReaderControls(app); app.buttons["Listen"].tap()
            let engine = app.segmentedControls["listeningEngine"]
            let value = app.staticTexts["listeningSpeedValue"]
            XCTAssertTrue(engine.waitForExistence(timeout: 5))
            engine.buttons["Apple voices"].tap()
            app.sliders["listeningSpeedSlider"].adjust(toNormalizedSliderPosition: 1.0 / 6.0)
            XCTAssertEqual(value.label, "0.75×")
            engine.buttons["Natural voice"].tap(); XCTAssertEqual(value.label, "1×")
            XCTAssertTrue(app.buttons["kokoroRemove"].exists)
            app.buttons["listenFromPage"].tap()
            let player = app.otherElements["readerAudioPlayer"], rate = app.buttons["playbackSpeed"], pause = app.buttons["audioPlayPause"]
            func waitForAudio() {
                expectation(for: NSPredicate(format: "value == %@", "Listening"), evaluatedWith: player)
                waitForExpectations(timeout: 90)
            }
            waitForAudio(); XCTAssertEqual(rate.value as? String, "1×")
            rate.tap(); app.buttons["1.5×"].tap()
            waitForAudio(); XCTAssertEqual(rate.value as? String, "1.5×")
            pause.tap(); XCTAssertEqual(pause.label, "Resume listening")
            capture(flow + " player updates only Natural speed", app: app)
            app.buttons["openReaderChat"].tap()
            let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
            input.tap(); input.typeText("Keep my voice speed")
            XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5))
            XCTAssertTrue(rate.isHittable); XCTAssertEqual(rate.value as? String, "1.5×")
            capture(flow + " saved voice speed with chat and keyboard", app: app)
            app.buttons["closeReaderChat"].tap()
            app.buttons["listeningSettings"].tap()
            XCTAssertEqual(value.label, "1.5×")
            engine.buttons["Apple voices"].tap(); XCTAssertEqual(value.label, "0.75×")
            XCTAssertTrue(app.buttons["Resume listening"].isEnabled, "Changing voice type while paused must stay paused")
            engine.buttons["Natural voice"].tap(); XCTAssertEqual(value.label, "1.5×")
            XCTAssertTrue(app.buttons["Resume listening"].isEnabled)
            capture(flow + " paused engine switch restores separate rates", app: app)
            app.buttons["resumeSavedListening"].tap()
            waitForAudio(); XCTAssertEqual(rate.value as? String, "1.5×")
            pause.tap()
            orient(.landscapeLeft)
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
            XCTAssertTrue(app.frame.contains(player.frame)); XCTAssertTrue(rate.isHittable)
            XCTAssertEqual(rate.value as? String, "1.5×")
            capture(flow + " independent player speed landscape", app: app)
            orient(.portrait); app.buttons["stopListening"].tap()
            app.terminate()
        }
    }

    @MainActor func testOnlyEnhancedAndPremiumAppleVoiceSettingsInPagesScrollAndPDF() {
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll", "PDF"] {
            let app = launchApp(); openSelectionFixture(flow, app: app)
            showReaderControls(app); app.buttons["Listen"].tap()
            let engine = app.segmentedControls["listeningEngine"]
            XCTAssertTrue(engine.waitForExistence(timeout: 5))
            XCTAssertTrue(engine.buttons["Natural voice"].exists)
            XCTAssertTrue(engine.buttons["Apple voices"].exists)
            XCTAssertFalse(engine.buttons["iPhone voice"].exists)
            engine.buttons["Apple voices"].tap()
            let guidance = app.descendants(matching: .any)["appleVoiceDownloadGuidance"].firstMatch
            let picker = app.buttons["listeningVoice"].exists ? app.buttons["listeningVoice"] : app.otherElements["listeningVoice"]
            XCTAssertTrue(guidance.waitForExistence(timeout: 3) || picker.waitForExistence(timeout: 3), "Actual installed-quality list or explicit download guidance must be shown")
            capture(flow + " Apple high-quality voice choices portrait", app: app)
            orient(.landscapeLeft)
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
            XCTAssertTrue(engine.isHittable)
            XCTAssertLessThanOrEqual(engine.frame.maxX, app.frame.maxX)
            XCTAssertGreaterThanOrEqual(engine.frame.minX, app.frame.minX)
            capture(flow + " Apple high-quality voice settings landscape", app: app)
            orient(.portrait)
            XCTAssertTrue(engine.buttons["Apple voices"].isSelected)
            engine.buttons["Natural voice"].tap()
            XCTAssertTrue(app.buttons["kokoroDownload"].waitForExistence(timeout: 5), "Natural voices remain available independently of downloaded Apple voices")
            capture(flow + " Natural voice pack option retained", app: app)
            app.terminate()
        }
    }

    /// Rendered landscape via the public scene-geometry fixture (no physical-rotation claim):
    /// the new engine rows and the player capsule must stay inside the frame and reachable.
    @MainActor func testNaturalVoiceDownloadSettingsFitLandscapeViaGeometryFixture() {
        let app = launchApp()
        defer { orient(.portrait) }
        app.buttons["featuredBook"].tap()
        showReaderControls(app); app.buttons["Listen"].tap()
        let engine = app.segmentedControls["listeningEngine"]
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        engine.buttons["Natural voice"].tap()
        XCTAssertTrue(app.buttons["kokoroDownload"].waitForExistence(timeout: 5))
        orient(.landscapeLeft)
        var frame = app.frame
        XCTAssertGreaterThan(frame.width, frame.height, "Landscape geometry must be applied")
        // The sheet is short in landscape, so the form scrolls; every row must be
        // fully inside the frame once scrolled to, and nothing may be clipped sideways.
        let form = app.descendants(matching: .any)["listeningForm"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "Listening form is reachable in landscape")
        func reveal(_ element: XCUIElement, _ label: String, up: Bool = true) {
            // Gesture evidence from the leased runs on this Form in the 874x402
            // sheet: press(0.1 s)-then-drag moved the content 0 pt, from the gutter
            // and from a cell alike; swipes on the whole form scroll it to either
            // end (default and slow velocity; the sheet is short, so an end state
            // can leave a row partly under the bar); a swipe on the 49x24 "Speed"
            // label moved it 0 pt. So: coarse form swipes toward the row while it is
            // absent or outside the frame, then short zero-hold drags on the form
            // for the final fit. Every gesture is checked for effect and a gesture
            // that moved nothing is swapped for the other kind; the sequence is
            // attached to the result. `up` = the row lies further down the form.
            var useDrag = false, trace = ""
            for step in 0..<10 {
                let before = element.exists ? element.frame : .null
                let scrollDown: Bool
                if element.exists {
                    if frame.contains(before) { break }
                    scrollDown = before.minY >= frame.minY
                    if before.intersects(frame) { useDrag = true }
                } else {
                    scrollDown = up; useDrag = false
                }
                if useDrag {
                    let from = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.6 : 0.4))
                    let to = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.4 : 0.6))
                    from.press(forDuration: 0, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
                } else if scrollDown {
                    form.swipeUp(velocity: .slow)
                } else {
                    form.swipeDown(velocity: .slow)
                }
                let after = element.exists ? element.frame : .null
                trace += "\(step): \(useDrag ? "drag" : "swipe") \(scrollDown ? "content up" : "content down") \(before) -> \(after)\n"
                if element.exists, after == before { useDrag.toggle() }
            }
            let gestures = XCTAttachment(string: trace.isEmpty ? "no gesture needed" : trace)
            gestures.name = label + " scroll gestures"; gestures.lifetime = .keepAlways; add(gestures)
            XCTAssertTrue(element.exists, label)
            XCTAssertTrue(frame.contains(element.frame), label + " inside the landscape frame: \(element.frame) in \(frame)")
            XCTAssertTrue(element.isHittable, label + " hittable in landscape")
        }
        XCTAssertTrue(engine.isHittable); XCTAssertTrue(frame.contains(engine.frame), "Engine picker inside the landscape frame")
        XCTAssertLessThanOrEqual(engine.frame.maxX, frame.maxX); XCTAssertGreaterThanOrEqual(engine.frame.minX, frame.minX)
        capture("Natural voice settings landscape", app: app)
        reveal(app.buttons["kokoroDownload"], "Download row")
        XCTAssertLessThanOrEqual(app.buttons["kokoroDownload"].frame.maxX, frame.maxX)
        capture("Natural voice settings landscape download row", app: app)
        reveal(app.switches["followSpokenText"], "Follow toggle")
        XCTAssertTrue(app.sliders["listeningSpeedSlider"].exists)
        capture("Natural voice settings landscape scrolled", app: app)
        reveal(app.buttons["listenFromPage"], "Listen from this page", up: false)
        orient(.portrait)
        XCTAssertGreaterThan(app.frame.height, app.frame.width)
        XCTAssertTrue(app.buttons["kokoroDownload"].exists)
        capture("Natural voice download settings return to portrait", app: app)
    }

    @MainActor func testMissingVoiceDownloadsGiveGuidanceAndPreserveTheListeningPosition() {
        defer { orient(.portrait) }
        for flow in ["Pages", "Scroll", "PDF"] {
            let app = launchApp(); openSelectionFixture(flow, app: app)
            showReaderControls(app); app.buttons["Listen"].tap()
            let engine = app.segmentedControls["listeningEngine"]
            XCTAssertTrue(engine.waitForExistence(timeout: 5))
            XCTAssertTrue(engine.buttons["Natural voice"].isSelected, "New installs default to Natural")
            XCTAssertTrue(app.buttons["kokoroDownload"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["kokoroRemove"].exists)
            capture(flow + " Natural voice download required", app: app)
            engine.buttons["Apple voices"].tap()
            let noAppleVoices = app.descendants(matching: .any)["appleVoiceDownloadGuidance"].firstMatch.waitForExistence(timeout: 3)
            if noAppleVoices {
                capture(flow + " No Enhanced or Premium voice installed", app: app)
                engine.buttons["Natural voice"].tap()
                app.buttons["listenFromPage"].tap()
                let player = app.otherElements["readerAudioPlayer"]
                expectation(for: NSPredicate(format: "value == %@", "Could not start audio"), evaluatedWith: player)
                waitForExpectations(timeout: 15)
                XCTAssertFalse(app.buttons["audioPlayPause"].isEnabled)
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No Enhanced or Premium Apple voice")).firstMatch.exists)
                XCTAssertTrue(app.frame.contains(player.frame), flow + " failed player fits portrait")
                capture(flow + " No basic voice fallback and no passage skipped", app: app)
                orient(.landscapeLeft)
                XCTAssertGreaterThan(app.frame.width, app.frame.height)
                XCTAssertTrue(app.frame.contains(player.frame), flow + " error player fits landscape")
                XCTAssertTrue(app.buttons["listeningSettings"].isHittable)
                XCTAssertTrue(app.buttons["stopListening"].isHittable)
                capture(flow + " Missing voice error player landscape", app: app)
                orient(.portrait)
                app.buttons["listeningSettings"].tap()
                XCTAssertTrue(app.buttons["resumeSavedListening"].waitForExistence(timeout: 5))
                capture(flow + " Failed voice start keeps saved listening position", app: app)
            } else {
                XCTAssertTrue(app.buttons["listeningVoice"].exists || app.otherElements["listeningVoice"].exists)
                capture(flow + " Actual downloaded high-quality voice choices", app: app)
            }
            app.terminate()
        }
    }

    /// Real on-device engine in Pages, Scroll and PDF. Runs only when the test runner
    /// receives LEAF_UI_KOKORO_ROOT (a prepared read-only pack root); skipped otherwise.
    @MainActor func testNaturalVoiceReadsInPagesScrollAndPDFWhenThePackIsInstalled() throws {
        guard let root = ProcessInfo.processInfo.environment["LEAF_UI_KOKORO_ROOT"], !root.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_LEAF_UI_KOKORO_ROOT to a prepared voice-pack root to exercise the real engine")
        }
        let app = launchApp(naturalVoicePack: true)
        defer { orient(.portrait) }
        let player = app.otherElements["readerAudioPlayer"], pause = app.buttons["audioPlayPause"]
        func waitForVoice(_ label: String) {
            // The player's value is "Generating voice…" until the first chunk is audible, then "Listening".
            expectation(for: NSPredicate(format: "value == %@", "Listening"), evaluatedWith: player); waitForExpectations(timeout: 90)
            XCTAssertEqual(pause.label, "Pause listening", label)
            XCTAssertTrue(app.staticTexts["spokenPassage"].exists, label)
        }
        app.buttons["featuredBook"].tap()
        for flow in ["Pages", "Scroll"] {
            showReaderControls(app); app.buttons["Appearance"].tap()
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap(); dismissAppearance(app); showReaderControls(app)
            app.buttons["Listen"].tap()
            let engine = app.segmentedControls["listeningEngine"]; XCTAssertTrue(engine.waitForExistence(timeout: 5))
            engine.buttons["Natural voice"].tap()
            XCTAssertTrue(app.buttons["kokoroRemove"].waitForExistence(timeout: 5), "Prepared pack is recognized as installed")
            XCTAssertFalse(app.buttons["kokoroDownload"].exists)
            if flow == "Pages" { capture("Natural voice installed settings", app: app) }
            app.buttons["listenFromPage"].tap()
            let generating = player.waitForExistence(timeout: 5) && (player.value as? String)?.hasPrefix("Generating voice") == true
            if generating { capture(flow + " natural voice generating", app: app) }
            waitForVoice(flow + " first passage")
            capture(flow + " natural voice listening", app: app)
            pause.tap(); XCTAssertEqual(pause.label, "Resume listening")
            orient(.landscapeLeft)
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
            XCTAssertTrue(app.frame.contains(player.frame), flow + " natural player fits landscape")
            XCTAssertTrue(pause.isHittable); XCTAssertTrue(app.buttons["stopListening"].isHittable)
            capture(flow + " natural voice player landscape", app: app)
            orient(.portrait)
            pause.tap(); XCTAssertEqual(pause.label, "Pause listening")
            app.buttons["audioNext"].tap()
            waitForVoice(flow + " next passage")
            capture(flow + " natural voice next passage", app: app)
            app.buttons["listeningSettings"].tap()
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last passage used an Enhanced or Premium Apple voice")).firstMatch.exists,
                           flow + ": the real engine spoke every passage")
            app.buttons["Stop listening"].tap()
            XCTAssertFalse(app.buttons["audioPlayPause"].waitForExistence(timeout: 3))
            // Stop removes the player, but intentionally leaves Listen settings
            // open. Dismiss that sheet before accessing controls behind it.
            let done = app.navigationBars["Listen"].buttons["Done"]
            XCTAssertTrue(done.isHittable); done.tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.descendants(matching: .any)["listeningForm"].firstMatch)
            waitForExpectations(timeout: 5)
            capture(flow + " stopped listening settings dismissed", app: app)
            // The saved cursor resumes with the natural voice and the engine choice is retained.
            showReaderControls(app); app.buttons["Listen"].tap()
            XCTAssertTrue(app.buttons["resumeSavedListening"].waitForExistence(timeout: 5), flow + ": saved position offered")
            XCTAssertTrue(app.buttons["kokoroRemove"].exists, flow + ": engine choice retained")
            app.buttons["resumeSavedListening"].tap()
            waitForVoice(flow + " resumed saved position")
            capture(flow + " natural voice resumed saved position", app: app)
            app.buttons["stopListening"].tap()
        }
        showReaderControls(app); app.buttons["closeBook"].tap()
        let search = app.textFields["librarySearch"]; XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Coast")
        app.buttons["book-Notes from the Coast"].tap()
        showReaderControls(app); app.buttons["Listen"].tap()
        XCTAssertTrue(app.buttons["kokoroRemove"].waitForExistence(timeout: 5), "Engine choice persists into the PDF reader")
        app.buttons["listenFromPage"].tap()
        waitForVoice("PDF")
        capture("PDF natural voice listening", app: app)
        pause.tap(); XCTAssertEqual(pause.label, "Resume listening")
        orient(.landscapeLeft)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(app.frame.contains(player.frame), "PDF natural player fits landscape")
        XCTAssertTrue(pause.isHittable); XCTAssertTrue(app.buttons["stopListening"].isHittable)
        capture("PDF natural voice player landscape", app: app)
        orient(.portrait)
        app.buttons["stopListening"].tap()
    }

    @MainActor func testPDFListeningFromSelectionAndBottomMenu() {
        let app = launchApp(naturalVoicePack: true)
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
                let selected = app.scrollViews["expandedSelectionMenu"].value as? String ?? ""
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
                XCTAssertFalse(app.textViews["chatQuestion"].exists, "A shortcut prepares an editable draft")
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

    @MainActor func testDictationAddsAnEditableDraftInPages() { verifyDictation(flow: "Pages") }
    @MainActor func testDictationAddsAnEditableDraftInScroll() { verifyDictation(flow: "Scroll") }
    @MainActor func testDictationAddsAnEditableDraftInPDF() { verifyDictation(flow: "PDF") }

    @MainActor func testNativeMandarinSpeechRecognitionFromAudio() async throws {
        #if targetEnvironment(simulator)
        // A simulator without Apple's speech service cannot validate real ASR.
        // Keep this separate from the app's locale/draft UI checks; never replace
        // the native result with a mock or turn an app recognition error into a pass.
        guard SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.isAvailable == true else {
            throw XCTSkip("Apple's zh-CN speech service is unavailable in this simulator runtime. Real Mandarin recognition requires a physical-device check.")
        }
        #endif
        let app = launchApp(nativeDictation: true)
        app.buttons["featuredBook"].tap(); waitForBook(app)
        app.buttons["openReaderChat"].tap()
        app.buttons["dictationLanguageButton"].tap()
        app.buttons["中文 · 普通话"].tap()
        app.buttons["dictateChatQuestion"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if springboard.alerts.buttons["Allow"].firstMatch.exists { springboard.alerts.buttons["Allow"].firstMatch.tap() }
            let text = input.value as? String ?? ""
            if text.contains("文字"), text.contains("解释") {
                let transcript = XCTAttachment(string: text); transcript.name = "Actual Apple Mandarin transcript"; transcript.lifetime = .keepAlways; add(transcript)
                capture("Native Apple recognizer transcribes Mandarin audio", app: app)
                return
            }
            if app.alerts["Dictation unavailable"].exists {
                capture("Native Mandarin recognition error", app: app)
                XCTFail(app.alerts["Dictation unavailable"].debugDescription)
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        capture("Native Mandarin recognition timeout", app: app)
        XCTFail("Apple speech recognition did not return Chinese text from the prerecorded Mandarin fixture")
    }

    @MainActor private func verifyDictation(flow: String) {
        continueAfterFailure = false
        let app = launchApp(dictation: true)
        defer { orient(.portrait) }
        openSelectionFixture(flow, app: app); waitForBook(app); showReaderControls(app)
        app.buttons["toggleBookmark"].tap()
        let surface = readingSurface(app), frame = surface.frame
        app.buttons["openReaderChat"].tap()
        sendChatQuestion("Keep this conversation", app: app)
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
        selectFixturePassage(flow, app: app)
        let quote = app.staticTexts["chatSelectedPassage"], selected = quote.label
        XCTAssertFalse(selected.isEmpty)
        let mic = app.buttons["dictateChatQuestion"]
        XCTAssertTrue(mic.isHittable); XCTAssertGreaterThanOrEqual(mic.frame.width, 44)
        let language = app.buttons["dictationLanguageButton"]
        XCTAssertTrue(language.isHittable)
        language.tap()
        let mandarin = app.buttons["中文 · 普通话"].exists ? app.buttons["中文 · 普通话"] : app.menuItems["中文 · 普通话"]
        XCTAssertTrue(mandarin.waitForExistence(timeout: 5)); mandarin.tap()
        XCTAssertEqual(language.value as? String, "中文 · 普通话")
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Remember: ")
        mic.tap()
        expectation(for: NSPredicate(format: "label == %@", "Stop dictation"), evaluatedWith: mic)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate(format: "value == %@", "Remember: 帮我解释这段文字"), evaluatedWith: input)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["sendReaderChat"].isEnabled, "Dictation adds a draft; it never sends automatically")
        XCTAssertEqual(quote.label, selected)
        XCTAssertEqual(surface.frame.height, frame.height, accuracy: 2)
        XCTAssertTrue(app.scrollViews["chatMessageHistory"].exists)
        capture(flow + " live dictation keeps the book and quote visible", app: app)
        orient(.landscapeLeft)
        XCTAssertEqual(mic.label, "Stop dictation")
        XCTAssertEqual(input.value as? String, "Remember: 帮我解释这段文字")
        XCTAssertTrue(mic.isHittable)
        capture(flow + " landscape dictation draft", app: app)
        orient(.portrait); mic.tap()
        expectation(for: NSPredicate(format: "label == %@", "Dictate question"), evaluatedWith: mic)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, "Remember: 帮我解释这段文字。")
        input.tap(); input.typeText(" Please.")
        XCTAssertTrue((input.value as? String ?? "").contains("Please."))
        XCTAssertTrue((input.value as? String ?? "").contains("帮我解释这段文字"))
        XCTAssertTrue(app.buttons["sendReaderChat"].isEnabled)
        XCTAssertTrue(app.scrollViews["chatMessageHistory"].exists)
        capture(flow + " dictated text editable with native keyboard", app: app)
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        mic.tap()
        expectation(for: NSPredicate(format: "label == %@", "Stop dictation"), evaluatedWith: mic)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate { _, _ in (input.value as? String ?? "").components(separatedBy: "帮我解释这段文字").count == 3 }, evaluatedWith: input)
        waitForExpectations(timeout: 5)
        var unsent = input.value as? String
        app.buttons["closeReaderChat"].tap()
        app.buttons["openReaderChat"].tap()
        XCTAssertEqual(mic.label, "Dictate question"); XCTAssertEqual(input.value as? String, unsent)
        XCTAssertEqual(quote.label, selected)
        app.buttons["closeReaderChat"].tap(); showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
        app.buttons["closeBook"].tap(); app.terminate(); app.launch()
        if flow == "PDF" {
            let card = app.buttons["book-Notes from the Coast"]
            for _ in 0..<5 where !card.isHittable { app.scrollViews.firstMatch.swipeUp() }
            card.tap()
        } else { app.buttons["featuredBook"].tap() }
        waitForBook(app); app.buttons["openReaderChat"].tap()
        XCTAssertEqual(input.value as? String, unsent); XCTAssertEqual(mic.label, "Dictate question")
        XCTAssertEqual(quote.label, selected)
        if flow == "Pages" {
            mic.tap()
            expectation(for: NSPredicate { _, _ in (input.value as? String) != unsent }, evaluatedWith: input)
            waitForExpectations(timeout: 5)
            let dictatingDraft = input.value as? String
            app.buttons["chatOptions"].tap(); app.buttons["AI settings"].tap()
            XCTAssertTrue(app.navigationBars["AI settings"].waitForExistence(timeout: 5))
            app.navigationBars["AI settings"].buttons["Done"].tap()
            XCTAssertEqual(mic.label, "Dictate question", "Opening another panel stops the microphone")
            XCTAssertEqual(input.value as? String, dictatingDraft)
            unsent = dictatingDraft
        }
        capture(flow + " unsent dictated draft restored", app: app)
        app.buttons["sendReaderChat"].tap()
        let sentText = (unsent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(app.textViews.matching(identifier: "chatQuestion").matching(NSPredicate(format: "label == %@", sentText)).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testKeyboardKeepsHistoryVisibleInPages() { verifyKeyboardHistory(flow: "Pages") }
    @MainActor func testKeyboardKeepsHistoryVisibleInScroll() { verifyKeyboardHistory(flow: "Scroll") }
    @MainActor func testKeyboardKeepsHistoryVisibleInPDF() { verifyKeyboardHistory(flow: "PDF") }

    @MainActor private func verifyKeyboardHistory(flow: String) {
        continueAfterFailure = false
        let app = launchApp()
        defer { orient(.portrait) }
        openSelectionFixture(flow, app: app); waitForBook(app); showReaderControls(app)
        app.buttons["toggleBookmark"].tap()
        let surface = readingSurface(app), originalFrame = surface.frame
        app.buttons["openReaderChat"].tap()
        for question in ["First remembered question", "Second remembered question", "Latest remembered question"] {
            sendChatQuestion(question, app: app)
            expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
            waitForExpectations(timeout: 5)
        }
        selectFixturePassage(flow, app: app)
        let quote = app.staticTexts["chatSelectedPassage"]
        XCTAssertTrue(quote.waitForExistence(timeout: 5)); let selected = quote.label
        let panel = app.otherElements["readerChatPanel"], history = app.scrollViews["chatMessageHistory"]
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        let readingHeight = panel.frame.height
        func focusInput(typing text: String? = nil) {
            // Resolve current scene geometry after the keyboard moved the composer.
            let frame = input.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
            // A real key event brings up the software keyboard reliably after
            // native book selection; a cached AX keyboard can exist while hidden.
            if let text { input.typeText(text) }
            else { input.typeText("x"); input.typeText(XCUIKeyboardKey.delete.rawValue) }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            expectation(for: NSPredicate { _, _ in
                app.buttons["Hide keyboard"].exists && panel.frame.maxY <= app.keyboards.firstMatch.frame.minY + 2
            }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
        }
        func assertHistoryAndBook() {
            XCTAssertTrue(history.exists, "Never remove existing messages while composing")
            XCTAssertGreaterThanOrEqual(history.frame.height, 20, "Keep a readable, scrollable message viewport even in landscape")
            XCTAssertLessThanOrEqual(history.frame.maxY, input.frame.minY + 2)
            XCTAssertLessThanOrEqual(panel.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            XCTAssertGreaterThan(panel.frame.minY - surface.frame.minY, app.frame.width > app.frame.height ? 8 : 210)
            XCTAssertTrue(input.isHittable); XCTAssertTrue(app.buttons["Hide keyboard"].isHittable)
            XCTAssertEqual(quote.label, selected)
        }
        func latestReplyIsVisible() {
            let replies = app.textViews.matching(identifier: "chatReply").allElementsBoundByIndex
            XCTAssertFalse(replies.isEmpty)
            XCTAssertTrue(replies.last!.isHittable)
            XCTAssertGreaterThan(replies.last!.frame.intersection(history.frame).height, 10)
        }
        func hideKeyboard() {
            app.buttons["Hide keyboard"].tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
            waitForExpectations(timeout: 5)
        }
        func resize(_ delta: CGFloat) {
            let handle = app.descendants(matching: .any)["readerChatDragHandle"].firstMatch
            let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let endY = min(app.frame.maxY - 24, max(app.frame.minY + 24, handle.frame.midY + delta))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: endY - handle.frame.midY)), withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        }
        focusInput(typing: "Keep this followup draft")
        assertHistoryAndBook(); latestReplyIsVisible()
        XCTAssertEqual(surface.frame.width, originalFrame.width, accuracy: 2)
        XCTAssertEqual(surface.frame.height, originalFrame.height, accuracy: 2)
        capture(flow + " history visible with keyboard and quote", app: app)
        let first = app.textViews.matching(identifier: "chatQuestion").matching(NSPredicate(format: "label == %@", "First remembered question")).firstMatch
        for _ in 0..<5 {
            if first.exists && first.isHittable && first.frame.intersection(history.frame).height > 10 { break }
            history.swipeDown()
        }
        XCTAssertTrue(first.isHittable); XCTAssertGreaterThan(first.frame.intersection(history.frame).height, 10)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Browsing older chat must keep typing available")
        XCTAssertEqual(input.value as? String, "Keep this followup draft")
        capture(flow + " earlier messages scroll above keyboard", app: app)
        hideKeyboard(); XCTAssertEqual(panel.frame.height, readingHeight, accuracy: 3)
        focusInput(); latestReplyIsVisible()
        resize(500); assertHistoryAndBook()
        capture(flow + " minimum keyboard panel retains history", app: app)
        resize(-500); assertHistoryAndBook()
        let typingHeight = panel.frame.height
        capture(flow + " maximum keyboard panel retains book", app: app)
        hideKeyboard(); XCTAssertEqual(panel.frame.height, readingHeight, accuracy: 3)
        focusInput(); XCTAssertEqual(panel.frame.height, typingHeight, accuracy: 3)
        orient(.landscapeLeft); assertHistoryAndBook(); latestReplyIsVisible()
        capture(flow + " landscape keyboard history and quote", app: app)
        orient(.portrait); assertHistoryAndBook()
        XCTAssertEqual(panel.frame.height, typingHeight, accuracy: 3)
        let bookPoint = CGPoint(x: surface.frame.midX, y: (surface.frame.minY + panel.frame.minY) / 2)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bookPoint.x - app.frame.minX, dy: bookPoint.y - app.frame.minY)).tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Book focus must never dismiss the conversation")
        XCTAssertEqual(input.value as? String, "Keep this followup draft")
        XCTAssertEqual(quote.label, selected)
        if app.buttons["Hide keyboard"].exists { hideKeyboard() }
        let header = app.descendants(matching: .any)["readerChatHeader"].firstMatch
        let top = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.01, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 100)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
        showReaderControls(app); XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark")
        app.buttons["closeBook"].tap(); app.terminate(); app.launch()
        if flow == "PDF" {
            let card = app.buttons["book-Notes from the Coast"]
            for _ in 0..<5 where !card.isHittable { app.scrollViews.firstMatch.swipeUp() }
            card.tap()
        } else { app.buttons["featuredBook"].tap() }
        waitForBook(app); showReaderControls(app)
        XCTAssertEqual(app.buttons["toggleBookmark"].label, "Remove bookmark", "Composing must preserve the saved reading passage")
        app.buttons["openReaderChat"].tap()
        XCTAssertEqual(panel.frame.height, readingHeight, accuracy: 3)
        XCTAssertEqual(quote.label, selected); XCTAssertEqual(input.value as? String, "Keep this followup draft")
        focusInput(); assertHistoryAndBook(); latestReplyIsVisible()
        XCTAssertEqual(panel.frame.height, typingHeight, accuracy: 3)
        capture(flow + " keyboard history draft and sizes restored", app: app)
        app.buttons["closeReaderChat"].tap()
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
    }

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
    @MainActor func testEnrichedReadingPromptInPages() { verifyEnrichedReadingPrompt(flow: "Pages") }
    @MainActor func testEnrichedReadingPromptInScroll() { verifyEnrichedReadingPrompt(flow: "Scroll") }
    @MainActor func testEnrichedReadingPromptInPDF() { verifyEnrichedReadingPrompt(flow: "PDF") }
    @MainActor private func verifyEnrichedReadingPrompt(flow: String) {
        continueAfterFailure = false
        let app = launchApp(contextProbe: true)
        func openBook() {
            if flow == "PDF" {
                let search = app.textFields["librarySearch"]
                XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Coast")
                app.buttons["book-Notes from the Coast"].tap()
            } else { app.buttons["featuredBook"].tap() }
            waitForBook(app)
        }
        openBook(); showReaderControls(app)
        if flow == "PDF" { app.buttons["nextPage"].tap() }
        else {
            app.buttons["Appearance"].tap(); app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap(); dismissAppearance(app)
        }
        let surface = readingSurface(app), frame = surface.frame
        app.buttons["openReaderChat"].tap()
        let paragraph = surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", flow == "PDF" ? "Before the town" : "Attention is a way")).firstMatch
        let point = paragraph.exists ? paragraph.coordinate(withNormalizedOffset: CGVector(dx: flow == "PDF" ? 0.15 : 0.3, dy: flow == "PDF" ? 0.25 : 0.1)) : surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25))
        point.press(forDuration: 1.2)
        let passage = app.staticTexts["chatSelectedPassage"]
        XCTAssertTrue(passage.waitForExistence(timeout: 5)); let quote = passage.label
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Who is being discussed here?")
        XCTAssertEqual(passage.label, quote); XCTAssertEqual(surface.frame.size.width, frame.width, accuracy: 2)
        XCTAssertEqual(surface.frame.size.height, frame.height, accuracy: 2)
        capture(flow + " enriched context selected while composing", app: app)
        orient(.landscapeLeft); XCTAssertEqual(passage.label, quote)
        capture(flow + " enriched context landscape", app: app)
        orient(.portrait); app.buttons["Hide keyboard"].tap()
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        app.terminate(); app.launch(); openBook(); app.buttons["openReaderChat"].tap()
        XCTAssertEqual(passage.label, quote); XCTAssertEqual(input.value as? String, "Who is being discussed here?")
        app.buttons["sendReaderChat"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Reading context verified:")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), app.debugDescription)
        capture(flow + " enriched prompt verified after reopening", app: app)
    }

    @MainActor private func chooseChatHarness(_ title: String, app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        for _ in 0..<4 where !option.isHittable { app.swipeUp() }
        option.tap()
        let save = app.buttons["saveAISettings"]
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["AI settings saved"].waitForExistence(timeout: 5))
        // Return to the Settings list so the next visit starts from it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["openAISettings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
    }
    @MainActor func testAgentLimitsApplyAndTraceViewerShowsStepsAndTokens() {
        continueAfterFailure = false
        let app = launchApp()
        chooseChatHarness("Book search agent (Claude)", app: app)
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        let calls = app.descendants(matching: .any)["agentMaxToolCalls"].firstMatch
        for _ in 0..<6 where !(calls.exists && calls.isHittable) { app.swipeUp() }
        app.buttons["agentMaxToolCalls-Increment"].tap()
        let conversationTool = app.switches["agentTool-search_conversation"]
        for _ in 0..<4 where !(conversationTool.exists && conversationTool.isHittable) { app.swipeUp() }
        conversationTool.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(conversationTool.value as? String, "0")
        capture("Agent limits in AI settings", app: app)
        let save = app.buttons["saveAISettings"]
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["AI settings saved"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap(); waitForBook(app)
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("Remind me about attention")
        app.buttons["sendReaderChat"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Agent reply: found")).firstMatch.waitForExistence(timeout: 30))
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        let traces = app.buttons["openAgentTraces"]
        for _ in 0..<8 where !(traces.exists && traces.isHittable) { app.swipeUp() }
        traces.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "agentTrace-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Remind me about attention"), row.label)
        capture("Agent traces list", app: app)
        row.tap()
        let summary = app.descendants(matching: .any)["agentTraceSummary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("input tokens"), summary.label)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "9 calls")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Tool result · search_book"].exists)
        capture("Agent trace detail", app: app)
        // Steps load lazily; collect each round's usage line while scrolling.
        let usage = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "agentTraceStepUsage-"))
        var roundsWithUsage = Set<String>()
        for attempt in 0..<4 {
            usage.allElementsBoundByIndex.forEach { roundsWithUsage.insert($0.identifier) }
            if roundsWithUsage.count >= 2 { break }
            if attempt < 3 { app.swipeUp() }
        }
        XCTAssertGreaterThanOrEqual(roundsWithUsage.count, 2, "\(roundsWithUsage)")
        capture("Agent trace detail steps", app: app)
    }
    @MainActor func testBookSearchAgentInPagesComparedWithPrefetchedEvidence() { verifyBookSearchAgent(flow: "Pages") }
    @MainActor func testBookSearchAgentInScrollNightLandscape() { verifyBookSearchAgent(flow: "Scroll") }
    @MainActor func testBookSearchAgentInPDF() { verifyBookSearchAgent(flow: "PDF") }
    @MainActor private func verifyBookSearchAgent(flow: String) {
        continueAfterFailure = false
        let app = launchApp()
        chooseChatHarness("Book search agent (Claude)", app: app)
        func openBook() {
            if flow == "PDF" {
                let search = app.textFields["librarySearch"]
                XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Coast")
                app.buttons["book-Notes from the Coast"].tap()
            } else { app.buttons["featuredBook"].tap() }
            waitForBook(app)
        }
        openBook(); showReaderControls(app)
        if flow == "PDF" { app.buttons["nextPage"].tap() }
        else {
            app.buttons["Appearance"].tap(); app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap(); dismissAppearance(app)
        }
        let surface = readingSurface(app), frame = surface.frame
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let term = flow == "PDF" ? "town" : "attention"
        input.tap(); input.typeText("Remind me about \(term)")
        if flow == "Scroll" { orient(.landscapeLeft) }
        XCTAssertEqual(surface.frame.size.width, readingSurface(app).frame.size.width, accuracy: 2)
        capture(flow + " agent question composing", app: app)
        app.buttons["sendReaderChat"].tap()
        // A landscape composer is compact; hiding the keyboard shows the conversation.
        if flow == "Scroll" {
            if app.buttons["Hide keyboard"].waitForExistence(timeout: 2) { app.buttons["Hide keyboard"].tap() }
            // The short landscape panel has no room for history; enlarge it as a reader would.
            let edge = app.descendants(matching: .any)["readerChatDragHandle"].firstMatch
            let start = edge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -200)), withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Resizing must never dismiss chat")
        }
        let reply = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Agent reply: found")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(reply.label.contains("found 0 passages"), reply.label)
        XCTAssertFalse(reply.label.contains("Let me look"), "Preamble before tool calls is withdrawn")
        let trace = app.descendants(matching: .any)["chatReplyTrace"].firstMatch
        XCTAssertTrue(trace.waitForExistence(timeout: 5))
        XCTAssertTrue(trace.label.contains("Book search agent · searched “\(term)”"), trace.label)
        capture(flow + " agent reply with search trace", app: app)
        if flow == "Scroll" {
            orient(.portrait)
            XCTAssertEqual(readingSurface(app).frame.size.height, frame.height, accuracy: 2)
            capture("Scroll agent reply portrait", app: app)
        }
        guard flow == "Pages" else { return }
        // Same question with the other harness, for side-by-side comparison in one conversation.
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        chooseChatHarness("Pre-fetched evidence (Sam)", app: app)
        openBook(); app.buttons["openReaderChat"].tap()
        input.tap(); input.typeText("Remind me about \(term)")
        app.buttons["sendReaderChat"].tap()
        let traces = app.descendants(matching: .any).matching(identifier: "chatReplyTrace")
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: traces); waitForExpectations(timeout: 15)
        XCTAssertTrue(traces.element(boundBy: 1).label.hasPrefix("Pre-fetched evidence"), traces.element(boundBy: 1).label)
        XCTAssertTrue(traces.element(boundBy: 0).label.hasPrefix("Book search agent"))
        capture("Pages harness comparison in one conversation", app: app)
    }

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
        XCTAssertFalse(app.textViews["chatQuestion"].exists,"Quoting must not send the draft")
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
        // The composer has moved from above the keyboard to the reading panel.
        // Resolve its current scene geometry and inject a real tap there rather
        // than asking accessibility to reveal the previously focused element.
        let reopenedInputFrame = input.frame
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(reopenedInputFrame))
        let focusPoint = CGPoint(x: reopenedInputFrame.midX, y: reopenedInputFrame.midY)
        let focusTarget = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: focusPoint.x - app.frame.minX, dy: focusPoint.y - app.frame.minY))
        let focusProof = XCTAttachment(string: "App: \(app.frame); panel: \(panel.frame); input: \(reopenedInputFrame); intended point: \(focusPoint); resolved screen point: \(focusTarget.screenPoint); keyboard before: \(app.keyboards.firstMatch.exists)")
        focusProof.name = flow + " restored composer focus geometry"; focusProof.lifetime = .keepAlways; add(focusProof)
        capture(flow + " restored input before keyboard reopen", app: app)
        focusTarget.tap()
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
        continueAfterFailure = false
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
        selectFixturePassage(flow, app: app)
        let menu = app.scrollViews["expandedSelectionMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 6))
        let selectedText = menu.value as? String ?? ""
        XCTAssertFalse(selectedText.isEmpty)
        // Target the visible reader action, never a same-label library launcher.
        let ask = menu.buttons["selection-ask"]
        XCTAssertTrue(ask.isHittable)
        XCTAssertTrue(menu.frame.contains(ask.frame))
        ask.tap()
        let draftQuote = app.staticTexts["chatSelectedPassage"]
        XCTAssertTrue(draftQuote.waitForExistence(timeout: 5))
        XCTAssertEqual(draftQuote.label, selectedText, "Ask Leaf must attach the actual selected passage")
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
        continueAfterFailure = false
        orient(.portrait)
        defer { orient(.portrait) }
        let app = launchApp()
        app.buttons["featuredBook"].tap()
        for flow in ["Pages", "Scroll"] {
            openAppearance(app)
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

    @MainActor func testScrollChapterDividerIsInlineAndKeepsChatOpen() {
        let app = launchApp()
        defer { orient(.portrait) }
        app.buttons["featuredBook"].tap()
        openAppearance(app)
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons["Scroll"].tap()
        dismissAppearance(app)
        let surface = readingSurface(app)
        let divider = surface.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Next Chapter")).firstMatch
        app.buttons["openReaderChat"].tap()
        let panel = app.otherElements["readerChatPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Keep my chapter question")
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5))
        app.buttons["Hide keyboard"].tap()
        var visible = false
        for _ in 0..<20 {
            if divider.exists && divider.frame.minY > surface.frame.minY + 60 && divider.frame.maxY < panel.frame.minY {
                visible = true; break
            }
            let top = max(surface.frame.minY + 110, 140)
            let bottom = min(panel.frame.minY - 25, top + 220)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: surface.frame.midX, dy: bottom)).press(forDuration: 0.01,
                thenDragTo: origin.withOffset(CGVector(dx: surface.frame.midX, dy: top)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(visible, "The actual boundary divider must be visible above chat, not merely preloaded offscreen")
        XCTAssertEqual(input.value as? String, "Keep my chapter question")
        XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        capture("Inline next chapter divider above open chat", app: app)
        input.tap(); input.typeText(" while reading")
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5))
        let composed = input.value as? String ?? ""
        XCTAssertTrue(composed.contains("Keep my chapter question"))
        XCTAssertTrue(composed.contains("while reading"))
        capture("Chapter boundary with composing chat", app: app)
        app.buttons["Hide keyboard"].tap()
        orient(.landscapeLeft)
        XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        XCTAssertEqual(input.value as? String, composed)
        capture("Chapter crossing landscape chat retained", app: app)
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
        XCTAssertLessThan(panel.frame.height, app.frame.height * 0.4, "Typing leaves room for both conversation history and book text")
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
        let reply = app.textViews.containing(NSPredicate(format: "label BEGINSWITH %@", "Test reply:")).firstMatch
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
        // The system asks for consent before opening the sign-in browser. On a
        // loaded simulator that prompt can take well over 3 s; without Continue
        // the loopback never completes and the check stays pending.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = Date().addingTimeInterval(12)
        var consented = false
        while Date() < consent, !consented {
            for continueButton in [app.alerts.buttons["Continue"], springboard.alerts.buttons["Continue"]] where continueButton.exists {
                continueButton.tap(); consented = true; break
            }
            if !consented, app.staticTexts["chatGPTConnectionNotice"].exists { break }
            if !consented { Thread.sleep(forTimeInterval: 0.5) }
        }
        let notice = app.staticTexts["chatGPTConnectionNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(notice.label, "Native browser callback verified.")
        capture("ChatGPT native browser callback", app: app)
    }

    @MainActor func testMarkdownReplyInPages() { verifyMarkdownReply(flow: "Pages") }
    @MainActor func testMarkdownReplyInScroll() { verifyMarkdownReply(flow: "Scroll") }
    @MainActor func testMarkdownReplyInPDF() { verifyMarkdownReply(flow: "PDF") }
    @MainActor func testMarkdownReplyInLibrary() { verifyMarkdownReply(flow: "Library") }

    @MainActor func testChatTextSelectionInPages() { verifyMarkdownReply(flow: "Pages", selectText: true) }
    @MainActor func testChatTextSelectionInScroll() { verifyMarkdownReply(flow: "Scroll", selectText: true) }
    @MainActor func testChatTextSelectionInPDF() { verifyMarkdownReply(flow: "PDF", selectText: true) }
    @MainActor func testChatTextSelectionInLibrary() { verifyMarkdownReply(flow: "Library", selectText: true) }

    @MainActor func testChatSelectionSurvivesStreamingInPages() {
        continueAfterFailure = false
        let app = launchApp(slowChat: true)
        openSelectionFixture("Pages", app: app)
        app.buttons["openReaderChat"].tap()
        sendChatQuestion("Keep this selection while replying", app: app)
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        let reply = app.textViews.matching(identifier: "chatReply").firstMatch
        // Markdown strips a trailing source space from the visible partial reply.
        expectation(for: NSPredicate(format: "label == %@", "Test reply:"), evaluatedWith: reply)
        waitForExpectations(timeout: 5)
        copyChatWord(reply, expected: "Test", flow: "Streaming Pages", app: app) {
            self.expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
            self.waitForExpectations(timeout: 40)
            XCTAssertEqual(reply.label, "Test reply:", "Incoming text must not replace a native selection")
        }
        XCTAssertTrue(reply.label.contains("Consider what the passage states"), "The completed reply must appear when selection ends")
    }

    @MainActor private func verifyMarkdownReply(flow: String, selectText: Bool = false) {
        continueAfterFailure = false
        let app = launchApp(markdown: true)
        if flow == "Library" { app.buttons["openLibraryChat"].tap() }
        else {
            if flow == "PDF" {
                let search = app.textFields["librarySearch"]
                XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Coast")
                app.buttons["book-Notes from the Coast"].tap()
            } else { app.buttons["featuredBook"].tap() }
            waitForBook(app)
            if flow != "PDF" {
                openAppearance(app)
                app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
                app.segmentedControls["readingFlow"].buttons[flow].tap()
                app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
                app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
                dismissAppearance(app)
            }
            app.buttons["openReaderChat"].tap()
        }
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("Literal **question**"); app.buttons["sendReaderChat"].tap()
        let reply = app.textViews.matching(identifier: "chatReply").firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "尾句。"), evaluatedWith: reply)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(reply.label.contains("这是李香玲，云瑶的队友。"))
        XCTAssertTrue(reply.label.contains("• 第一条")); XCTAssertTrue(reply.label.contains("let value = 1"))
        XCTAssertFalse(reply.label.contains("**")); XCTAssertFalse(reply.label.contains("```")); XCTAssertFalse(reply.label.contains("##"))
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        let handle = app.descendants(matching: .any)["readerChatDragHandle"].firstMatch
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)), withVelocity: .slow, thenHoldForDuration: 0.1)
        // The compact history lazily removes an offscreen question after a long
        // reply. Reveal it before checking the deliberately literal user text.
        let question = app.textViews.matching(identifier: "chatQuestion").firstMatch
        if !question.exists { app.scrollViews["chatMessageHistory"].swipeDown() }
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertEqual(question.label, "Literal **question**")
        capture(flow + " formatted Markdown portrait", app: app)
        if selectText {
            let bookFrame = flow == "Library" ? app.buttons["featuredBook"].frame : readingSurface(app).frame
            copyChatWord(question, expected: "Literal", flow: flow, app: app)
            // Select the rendered Chinese heading, rather than copying Markdown
            // source or using an application test hook to change the clipboard.
            copyChatWord(reply, expected: "人物", flow: flow, app: app)
            XCTAssertEqual(flow == "Library" ? app.buttons["featuredBook"].frame : readingSurface(app).frame, bookFrame)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        }
        input.tap(); input.typeText("Draft after formatted reply")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(flow + " Markdown while composing", app: app)
        app.buttons["Hide keyboard"].tap()
        orient(.landscapeLeft)
        capture(flow + " formatted Markdown landscape", app: app)
        orient(.portrait)
        app.buttons["closeReaderChat"].tap()
        app.buttons[flow == "Library" ? "openLibraryChat" : "openReaderChat"].tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertTrue(reply.label.contains("这是李香玲"))
        XCTAssertEqual(input.value as? String, "Draft after formatted reply")
    }

    @MainActor private func copyChatWord(_ text: XCUIElement, expected: String, flow: String, app: XCUIApplication, beforeCopy: (() -> Void)? = nil) {
        let history = app.scrollViews["chatMessageHistory"]
        // A long reply can leave its opening line just above the lazy history.
        history.swipeDown()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let point = text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 14, dy: 9))
        point.press(forDuration: 1.2)
        let copy = app.menuItems["Copy"].exists ? app.menuItems["Copy"] : app.buttons["Copy"]
        if !copy.waitForExistence(timeout: 5) {
            capture(flow + " missing native chat Copy menu", app: app)
            let state = XCTAttachment(string: app.debugDescription); state.lifetime = .keepAlways; add(state)
            XCTFail("Long-pressing a chat word must show the native Copy menu"); return
        }
        capture(flow + " native chat selection " + expected, app: app)
        beforeCopy?()
        copy.tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        XCTAssertEqual(input.value as? String, expected, "Copy must contain only the selected word, not the entire chat message")
        capture(flow + " partial chat selection pasted " + expected, app: app)
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: expected.count))
        app.buttons["Hide keyboard"].tap()
    }

    @MainActor private func openFeaturedChat(_ app: XCUIApplication) {
        app.buttons["featuredBook"].tap(); waitForBook(app)
        app.buttons["openReaderChat"].tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
    }
    @MainActor private func sendChatQuestion(_ question: String, app: XCUIApplication) {
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText(question); app.buttons["sendReaderChat"].tap()
        let reply = app.textViews.matching(identifier: "chatReply").firstMatch
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
        XCTAssertTrue(app.textViews["Remember this question"].exists)
        let restoredInput = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        XCTAssertEqual(restoredInput.value as? String, "An unsent followup")
        app.terminate(); app.launch(); openFeaturedChat(app)
        XCTAssertTrue(app.textViews["Remember this question"].exists)
        XCTAssertTrue(app.textViews.matching(identifier: "chatReply").firstMatch.label.contains("Test reply:"))
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
        XCTAssertTrue(app.textViews["A question to clear"].exists)
        app.buttons["chatOptions"].tap(); app.buttons["requestClearConversation"].tap()
        app.buttons["confirmClearConversation"].firstMatch.tap()
        XCTAssertFalse(app.textViews["A question to clear"].exists)
        app.terminate(); app.launch(); openFeaturedChat(app)
        XCTAssertFalse(app.textViews.matching(identifier: "chatQuestion").firstMatch.exists)
        XCTAssertFalse(app.textViews.matching(identifier: "chatReply").firstMatch.exists)
        capture("Cleared conversation after restart", app: app)
    }
    @MainActor func testPartialChatRestoresStoppedAfterRestart() {
        let app = launchApp(slowChat: true); openFeaturedChat(app)
        sendChatQuestion("Keep my partial reply", app: app)
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        app.terminate(); app.launch(); openFeaturedChat(app)
        XCTAssertTrue(app.textViews["Keep my partial reply"].exists)
        XCTAssertTrue(app.textViews.matching(identifier: "chatReply").firstMatch.label.contains("Test reply:"))
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
        XCTAssertEqual(app.textViews.matching(identifier: "chatQuestion").count, 1)
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
        let sharing = app.switches["aiSharePage"]
        // The Book context section sits above Reading context.
        for _ in 0..<4 where !sharing.isHittable { app.swipeUp() }
        sharing.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(sharing.value as? String, "0")
        // Agent troubleshooting sits between Reading context and Save.
        let save = app.buttons["saveAISettings"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["AI settings saved"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        XCTAssertEqual(model.value as? String, "claude-haiku-4-5")
        for _ in 0..<4 where !app.switches["aiSharePage"].isHittable { app.swipeUp() }
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
        XCTAssertFalse(app.textViews["chatQuestion"].exists)
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
