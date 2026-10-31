import XCTest
import Speech

final class LeafReaderUITests: XCTestCase {
    private var geometryApp: XCUIApplication?
    @MainActor private func orient(_ direction: UIDeviceOrientation) {
        if let app = geometryApp, app.state == .runningForeground { setReaderOrientation(direction, app: app) }
        else { XCUIDevice.shared.orientation = direction }
    }
    @MainActor private func launchApp(mockChat: Bool = true, slowChat: Bool = false, chatGPTBrowser: Bool = false, chatGPTConnected: Bool = false, geometryFixture: Bool = true, appleSpeech: Bool = false, backgroundAudio: Bool = false, nowPlayingProbe: Bool = false, contextProbe: Bool = false, markdown: Bool = false, dictation: Bool = false, nativeDictation: Bool = false, scrollStream: Bool = false, legacyScroll: Bool = false, scrollPerformance: Bool = false, chatFollow: Bool = false, scrollTouchTrace: Bool = false, syncFixture: Bool = false, contentsFixture: Bool = false, contentsBook: String = "ContentsLocation") -> XCUIApplication {

        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        if contentsFixture {
            let fixture = Bundle(for: LeafReaderUITests.self).url(forResource: contentsBook, withExtension: "epub")!
            app.launchEnvironment["LEAF_UI_CONTENTS_BOOK"] = try! Data(contentsOf: fixture).base64EncodedString()
        }
        app.launchEnvironment["LEAF_UI_ZLIB_MOCK"] = "1"
        app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = mockChat ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_SLOW"] = slowChat ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_CONTEXT_PROBE"] = contextProbe ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_MARKDOWN"] = markdown ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_SCROLL_STREAM"] = scrollStream ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_SCROLL_LEGACY"] = legacyScroll ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_SCROLL_PERF"] = scrollPerformance ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHAT_FOLLOW"] = chatFollow ? "1" : "0"
        app.launchEnvironment["LEAF_UI_SCROLL_TOUCH_TRACE"] = scrollTouchTrace ? "1" : "0"
        if syncFixture { app.launchEnvironment["LEAF_UI_SYNC_FIXTURE"] = "1"; app.launchEnvironment["LEAF_UI_EMPTY_LIBRARY"] = "1" }
        app.launchEnvironment["LEAF_UI_DICTATION_MOCK"] = dictation ? "1" : "0"
        if nativeDictation {
            let audio = Bundle(for: LeafReaderUITests.self).url(forResource: "Mandarin", withExtension: "m4a")!
            app.launchEnvironment["LEAF_UI_DICTATION_NATIVE_AUDIO"] = try! Data(contentsOf: audio).base64EncodedString()
        }
        app.launchEnvironment["LEAF_UI_CHATGPT_BROWSER"] = chatGPTBrowser ? "1" : "0"
        app.launchEnvironment["LEAF_UI_CHATGPT_CONNECTED"] = chatGPTConnected ? "1" : "0"
        app.launchEnvironment["LEAF_UI_SCENE_GEOMETRY_FIXTURE"] = geometryFixture ? "1" : "0"
        if appleSpeech { app.launchEnvironment["LEAF_UI_APPLE_SPEECH"] = "1" }
        if backgroundAudio { app.launchEnvironment["LEAF_UI_BACKGROUND_AUDIO"] = "1" }
        if nowPlayingProbe { app.launchEnvironment["LEAF_UI_NOW_PLAYING"] = "1" }
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

    /// Bring a settings row on screen with short drags. Whole-form swipes jump
    /// past rows; a held press can scroll a Form 0 pt, so swap gesture kinds
    /// when one does not move the row.
    @MainActor private func revealSettingsRow(_ row: XCUIElement, app: XCUIApplication) {
        var held = false, last: CGRect?
        // Fixed margins clear the navigation bar and the floating tab bar.
        let top = app.frame.minY + app.frame.height * 0.12, bottom = app.frame.maxY - app.frame.height * 0.12
        for _ in 0..<14 {
            if row.exists, row.isHittable, row.frame.minY >= top, row.frame.maxY <= bottom { return }
            let up = !row.exists || row.frame.maxY > bottom
            if row.exists, row.frame == last { held.toggle() }
            last = row.exists ? row.frame : nil
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: up ? 0.62 : 0.4))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: up ? 0.4 : 0.62))
            if held { start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2) }
            else { start.press(forDuration: 0, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0) }
        }
        XCTAssertTrue(row.exists && row.isHittable, "Could not reveal \(row.identifier): \(row.exists ? "\(row.frame)" : "absent") within \(top)...\(bottom)")
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
        for theme in ["Day", "Paper", "Night", "Sepia", "Sage", "Dusk", "Black"] {
            app.tabBars.buttons["Settings"].tap()
            let choice = app.buttons[theme + " theme"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            XCTAssertTrue(choice.isSelected)
            XCTAssertEqual(["Day", "Paper", "Night", "Sepia", "Sage", "Dusk", "Black"].filter { app.buttons[$0 + " theme"].isSelected }.count, 1)
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
        // Black is the last theme chosen above, so it is what the relaunch must restore.
        XCTAssertTrue(app.buttons["Black theme"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Black theme"].isSelected)
        app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap()
        showReaderControls(app)
        app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        XCTAssertTrue(app.buttons["Black theme"].isSelected)
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

    @MainActor func testAppearanceSystemLabelsTrackDuskInPagesWithoutSceneFixture() {
        checkAppearanceSystemLabelContrast(scrolling: false)
    }

    @MainActor func testAppearanceSystemLabelsTrackDuskInScrollWithoutSceneFixture() {
        checkAppearanceSystemLabelContrast(scrolling: true)
    }

    @MainActor func testAppearanceSystemLabelsTrackDuskInPDFWithoutSceneFixture() {
        checkAppearanceSystemLabelContrast(scrolling: false, pdf: true)
    }

    /// A live theme change must also update native controls in the already-open
    /// sheet. No scene geometry fixture or rotation participates in this check.
    @MainActor private func checkAppearanceSystemLabelContrast(scrolling: Bool, pdf: Bool = false) {
        let app = launchApp(geometryFixture: false)
        if pdf {
            let card = app.buttons["book-Notes from the Coast"]
            for _ in 0..<5 where !card.isHittable { app.scrollViews.firstMatch.swipeUp() }
            card.tap()
        } else { app.buttons["featuredBook"].tap() }
        openAppearance(app)
        if scrolling {
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons["Scroll"].tap()
        }
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        let flow = pdf ? "PDF" : scrolling ? "Scroll" : "Pages"
        for theme in ["Dusk", "Paper", "Black", "Night", "Day"] {
            let choice = app.buttons[theme + " theme"]
            revealAppearanceControl(app, choice)
            choice.tap()
            XCTAssertTrue(choice.isSelected)
            capture(flow + " live " + theme + " Appearance labels without scene fixture", app: app)
            let dark = theme == "Dusk" || theme == "Night" || theme == "Black"
            assertAppearanceLabelInk(app.navigationBars["Appearance"].staticTexts["Appearance"],
                                     lightInk: dark, app: app)
            for tab in ["Font", "Layout"] {
                assertAppearanceLabelInk(app.segmentedControls["appearanceTabs"].buttons[tab],
                                         lightInk: dark, app: app)
            }
        }
    }

    /// Check rendered ink, not just accessibility existence/selection: the
    /// original QA100-005 case passed while its title was black on dark gray.
    @MainActor private func assertAppearanceLabelInk(_ label: XCUIElement, lightInk: Bool, app: XCUIApplication,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(label.exists, file: file, line: line)
        guard let source = app.screenshot().image.cgImage else { return XCTFail("Missing Appearance screenshot", file: file, line: line) }
        let frame = label.frame.intersection(app.frame)
        guard frame.width > 10, frame.height > 8 else { return XCTFail("Appearance label is not visible", file: file, line: line) }
        let scaleX = CGFloat(source.width) / app.frame.width, scaleY = CGFloat(source.height) / app.frame.height
        let rect = CGRect(x: (frame.minX - app.frame.minX) * scaleX, y: (frame.minY - app.frame.minY) * scaleY,
                          width: frame.width * scaleX, height: frame.height * scaleY)
        guard let crop = source.cropping(to: rect) else { return XCTFail("Missing Appearance label crop", file: file, line: line) }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ink = pixels.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, i in
                let visible = lightInk
                    ? bytes[i] > 160 && bytes[i + 1] > 160 && bytes[i + 2] > 160
                    : bytes[i] < 128 && bytes[i + 1] < 128 && bytes[i + 2] < 128
                return count + (visible ? 1 : 0)
            }
        }
        XCTAssertGreaterThan(ink, width * height / 200,
                             "\(label.label) needs visible \(lightInk ? "light" : "dark") ink after the theme changes", file: file, line: line)
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

    @MainActor func testChineseTypefaceChoiceAppliesAndPersistsAcrossRelaunch() {
        let app = launchApp()
        app.swipeUp()
        app.buttons["book-The Art of Noticing"].tap()
        openAppearance(app)
        // The inline Picker exposes each row as a button carrying the picker's
        // identifier and the row's combined label ("霞鹜文楷, 楷体 · WenKai").
        func typefaceRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
            app.buttons.matching(identifier: "typeface").matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }
        let wenKai = typefaceRow(app, "霞鹜文楷")
        revealAppearanceControl(app, wenKai)
        XCTAssertTrue(typefaceRow(app, "Georgia").isSelected)
        wenKai.tap()
        XCTAssertTrue(wenKai.isSelected)
        XCTAssertFalse(typefaceRow(app, "Georgia").isSelected)
        capture("Aa Typeface rows", app: app)
        dismissAppearance(app)
        capture("WenKai reading page", app: app)
        app.terminate()
        app.launch()
        app.buttons["featuredBook"].tap()
        openAppearance(app)
        let restored = typefaceRow(app, "霞鹜文楷")
        revealAppearanceControl(app, restored)
        XCTAssertTrue(restored.isSelected)
        XCTAssertFalse(typefaceRow(app, "Georgia").isSelected)
    }
    /// The system player (Lock Screen, Control Center, headphones) is fed by
    /// MPNowPlayingInfoCenter and MPRemoteCommandCenter; the simulator's Control
    /// Center has no media module, so the in-app DEBUG probe reads those centers
    /// directly while real Apple narration plays. Control Center itself is opened
    /// best-effort and recorded as evidence either way.
    @MainActor func testSystemPlayerInfoAndCommandsFollowTheNarration() {
        continueAfterFailure = false
        let app = launchApp(appleSpeech: true, nowPlayingProbe: true)
        app.buttons["featuredBook"].tap(); waitForBook(app); showReaderControls(app)
        app.buttons["Listen"].tap(); app.buttons["listenFromPage"].tap()
        let player = app.otherElements["readerAudioPlayer"], pause = app.buttons["audioPlayPause"], probe = app.staticTexts["nowPlayingProbe"]
        expectation(for: NSPredicate(format: "value == %@", "Listening"), evaluatedWith: player)
        waitForExpectations(timeout: 15)
        func system() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "{}").utf8))) as? [String: Any] ?? [:]
        }
        func waitForSystem(_ what: String, _ condition: @escaping ([String: Any]) -> Bool) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(system()) }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "\(what): \(probe.value as? String ?? "nil")")
        }
        // The sample book has no cover file (the Lock Screen shows the app icon), and
        // its short opening passage can finish before this check, enabling Previous.
        waitForSystem("Now Playing shows the book while narrating") {
            $0["title"] as? String == "The Art of Noticing" && $0["artist"] as? String == "Leaf Editions" && $0["rate"] as? Double == 1
                && $0["next"] as? Bool == true && $0["pause"] as? Bool == true && $0["play"] as? Bool == true
        }
        let listening = XCTAttachment(string: probe.value as? String ?? "nil"); listening.name = "System player while listening"; listening.lifetime = .keepAlways; add(listening)
        pause.tap()
        waitForSystem("Pausing drops the playback rate to 0") { $0["rate"] as? Double == 0 && $0["title"] as? String == "The Art of Noticing" }
        app.buttons["audioNext"].tap()
        waitForSystem("Next passage enables Previous") { $0["previous"] as? Bool == true && $0["rate"] as? Double == 0 }
        pause.tap()
        waitForSystem("Resuming restores the playback rate") { $0["rate"] as? Double == 1 }
        // Best effort: Control Center. The iOS simulator's Control Center opens but
        // carries no media module, so a missing title is recorded, not failed.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.01))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.7)))
        let opened = springboard.otherElements["cc-root-folder-view"].waitForExistence(timeout: 5)
        let title = springboard.staticTexts["The Art of Noticing"]
        let shown = title.waitForExistence(timeout: 3)
        capture("Control Center while listening", app: springboard)
        let note = XCTAttachment(string: "controlCenterOpened=\(opened); nowPlayingModuleShowsTitle=\(shown)")
        note.name = "Control Center evidence (simulator)"; note.lifetime = .keepAlways; add(note)
        if shown, springboard.buttons["Pause"].exists {
            springboard.buttons["Pause"].tap()
            capture("Control Center after pausing", app: springboard)
        }
        if opened {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            XCTAssertFalse(springboard.otherElements["cc-root-folder-view"].waitForExistence(timeout: 3), "Control Center must be closed again")
        }
        app.activate()
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        if shown { XCTAssertEqual(pause.label, "Resume listening", "Pausing from Control Center must pause the narration") }
        app.buttons["stopListening"].tap()
        // The player (and its probe row) leaves the screen with the narration; the
        // unit test covers the system player being cleared at the same moment.
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: player)
        waitForExpectations(timeout: 5)
    }
    @MainActor func testContentsRevealsCurrentChapterInPages() { verifyContentsLocation(flow: "Pages") }
    @MainActor func testContentsRevealsCurrentChapterInScroll() { verifyContentsLocation(flow: "Scroll") }
    @MainActor func testContentsRevealsCurrentPageInPDF() { verifyContentsLocation(flow: "PDF") }

    @MainActor func testFastBookSwipesAfterDistantChapterJumpInScroll() { verifyFastBookSwipes(flow: "Scroll") }
    @MainActor func testFastBookSwipesAfterDistantChapterJumpInPages() { verifyFastBookSwipes(flow: "Pages") }

    @MainActor private func verifyFastBookSwipes(flow: String) {
        continueAfterFailure = false
        let app = launchApp(contentsFixture: true, contentsBook: "ScrollFling")
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Contents Location")
        app.buttons["book-Contents Location"].tap()
        openAppearance(app)
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons[flow].tap()
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        app.buttons[(flow == "Scroll" ? "Night" : "Paper") + " theme"].tap()
        dismissAppearance(app)
        showReaderControls(app); app.buttons["Contents"].tap()
        let destination = app.buttons["第30章 归途"]
        for _ in 0..<4 where !destination.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(destination.isHittable); destination.tap(); waitForBook(app)
        let surface = readingSurface(app)
        func visibleText() {
            var area = surface.frame.insetBy(dx: 10, dy: 20)
            let panel = app.otherElements["readerChatPanel"]
            if panel.exists { area.size.height = max(1, panel.frame.minY - area.minY - 12) }
            let texts = surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这是第")).allElementsBoundByIndex
            let content = texts + surface.images.allElementsBoundByIndex
            XCTAssertTrue(content.contains { element in
                let rect = element.frame
                return rect.minX.isFinite && rect.minY.isFinite && rect.width > 0 && rect.height > 0 && rect.intersects(area)
            }, "Actual book text or artwork must remain visible after fast gestures")
        }
        func swipe(_ forward: Bool, withChat: Bool) {
            if !withChat {
                if flow == "Scroll" { if forward { surface.swipeUp(velocity: .fast) } else { surface.swipeDown(velocity: .fast) } }
                else { if forward { surface.swipeLeft(velocity: .fast) } else { surface.swipeRight(velocity: .fast) } }
            } else {
                let panel = app.otherElements["readerChatPanel"].frame
                let top = surface.frame.minY + 30, bottom = panel.minY - 16
                XCTAssertGreaterThan(bottom - top, 40)
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = flow == "Scroll" ? CGPoint(x: surface.frame.midX, y: forward ? bottom : top)
                    : CGPoint(x: surface.frame.width * (forward ? 0.8 : 0.2), y: (top + bottom) / 2)
                let end = flow == "Scroll" ? CGPoint(x: surface.frame.midX, y: forward ? top : bottom)
                    : CGPoint(x: surface.frame.width * (forward ? 0.2 : 0.8), y: (top + bottom) / 2)
                origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(forDuration: 0.01,
                    thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)), withVelocity: .fast, thenHoldForDuration: 0)
                XCTAssertTrue(app.buttons["closeReaderChat"].exists)
            }
            visibleText(); XCTAssertFalse(app.otherElements["readerError"].exists)
        }
        for forward in [true,true,true,false,false,false] { swipe(forward, withChat: false) }
        capture(flow + " fast forward and backward after cold chapter jump", app: app)
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Keep my fast scrolling question"); app.buttons["Hide keyboard"].tap()
        swipe(true, withChat: true); swipe(false, withChat: true)
        orient(.landscapeLeft); visibleText()
        swipe(true, withChat: true); swipe(false, withChat: true)
        XCTAssertEqual(input.value as? String, "Keep my fast scrolling question")
        capture(flow + " landscape fast swipes keep chat and visible book", app: app)
        app.buttons["closeReaderChat"].tap(); orient(.portrait)
        showReaderControls(app)
        let chapter = app.staticTexts["readerChapterTitle"].label
        app.buttons["closeBook"].tap(); app.buttons["book-Contents Location"].tap()
        showReaderControls(app); XCTAssertEqual(app.staticTexts["readerChapterTitle"].label, chapter)
        visibleText(); capture(flow + " saved passage after fast swipes and reopening", app: app)
    }

    /// A held pull toward the previous chapter right after a Contents jump must
    /// stay at that chapter boundary while earlier chapters load above it.
    /// A slow drag released over the book keeps sliding; a tap during that
    /// slow tail must stop it where it is, without opening the controls.
    @MainActor func testTapStopsSlowScrollSlideInScroll() {
        continueAfterFailure = false
        let app = launchApp(scrollTouchTrace: true)
        app.buttons["featuredBook"].tap(); waitForBook(app)
        openAppearance(app)
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons["Scroll"].tap()
        dismissAppearance(app)
        let surface = readingSurface(app), probe = app.descendants(matching: .any)["uitestScrollTouch"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        func trace() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "").utf8))) as? [String: Any] ?? [:]
        }
        func book(_ trace: [String: Any]) -> [String: Any]? {
            // The tallest scrollable native viewport is the book's Scroll container.
            ((trace["views"] as? [[String: Any]]) ?? []).filter { ($0["contentHeight"] as? Double ?? 0) - ($0["height"] as? Double ?? 0) > 100 }
                .max { ($0["height"] as? Double ?? 0) < ($1["height"] as? Double ?? 0) }
        }
        if app.buttons["closeBook"].exists { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        // Every gesture first waits for Leaf to go idle, which outlasts the whole
        // coast (SS3/SS5 tapped 0.52 s and 0.15 s after the slide ended), so skip
        // that wait for the drag and the tap. SpringBoard coordinates on this
        // simulator avoid re-querying the book between them.
        XCTAssertTrue(UITestQuiescence.install(), "XCUITest's idle wait could not be bypassed")
        let frame = surface.frame, screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            screen.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + frame.width * x, dy: frame.minY + frame.height * y))
        }
        // XCUITest velocities are pixels per second. A release this fast keeps
        // the page coasting into a slow tail by the time the tap lands.
        for (name, speed) in [("slow", 1600.0), ("very slow", 1000.0)] {
            UITestQuiescence.skipped = true
            point(0.5, 0.7).press(forDuration: 0.01, thenDragTo: point(0.5, 0.55),
                withVelocity: XCUIGestureVelocity(rawValue: speed), thenHoldForDuration: 0)
            point(0.3, 0.5).tap()
            UITestQuiescence.skipped = false
            let atTap = trace()
            Thread.sleep(forTimeInterval: 0.8)
            let later = trace()
            let attachment = XCTAttachment(string: "at tap: \(atTap)\nlater: \(later)")
            attachment.name = name + " slide tap trace"; attachment.lifetime = .keepAlways; add(attachment)
            capture(name + " slide after tap", app: app)
            let view = book(later)
            XCTAssertNotNil(view, "The book's native scroll viewport must be traced: \(later)")
            // Only a tap that actually caught the page moving exercises the stop.
            let coastAge = view?["coastAge"] as? Double ?? .infinity
            XCTAssertLessThan(coastAge, 0.15, "The \(name) slide must still be moving when the tap lands: \(atTap)")
            let stopped = view?["offset"] as? Double ?? .nan, now = view?["now"] as? Double ?? .nan
            XCTAssertEqual(now, stopped, accuracy: 2, "The \(name) slide must stop at the tap: \(later)")
            XCTAssertFalse(app.buttons["closeBook"].exists, "A tap that stops a slide must not open the reader controls: \(atTap)")
            if app.buttons["closeBook"].exists { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        }
    }

    /// One drift case: how fast the page moved just before the tap, how far it
    /// kept going after it, and whether the tap opened the reader controls.
    private struct DriftCase { let name: String; let speedAtTap: Double; let driftAfter: Double; let controls: Bool }

    /// Pulls the Scroll page slowly over a short distance, taps after `delays`,
    /// and reads every recorded frame. XCUITest's idle wait is skipped so the
    /// tap can land while the page is still drifting.
    @MainActor private func runDriftSweep(chat: Bool = false, speeds: [Double], delays: [Double]) -> [DriftCase] {
        let app = launchApp(scrollTouchTrace: true)
        app.buttons["featuredBook"].tap(); waitForBook(app)
        openAppearance(app)
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons["Scroll"].tap()
        dismissAppearance(app)
        let surface = readingSurface(app), probe = app.descendants(matching: .any)["uitestScrollTouch"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        if app.buttons["closeBook"].exists { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        // With Ask Leaf open, pull and tap in the book area above the panel.
        var top = 0.54, tapY = 0.5
        if chat {
            app.buttons["openReaderChat"].tap()
            XCTAssertTrue(app.otherElements["readerChatPanel"].waitForExistence(timeout: 5))
            if app.keyboards.firstMatch.exists { app.keyboards.buttons["Hide keyboard"].firstMatch.tap() }
            let panelTop = (app.otherElements["readerChatPanel"].frame.minY - surface.frame.minY) / surface.frame.height
            top = max(0.12, panelTop - 0.2); tapY = max(0.08, top - 0.12)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Ask Leaf must stay open for the drift sweep")
        }
        XCTAssertTrue(UITestQuiescence.install(), "XCUITest's idle wait could not be bypassed")
        let frame = surface.frame, screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            screen.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + frame.width * x, dy: frame.minY + frame.height * y))
        }
        var cases: [DriftCase] = []
        // XCUITest velocities are pixels per second (3 px per point here).
        for speed in speeds {
            for delay in delays {
                UITestQuiescence.skipped = true
                point(0.5, top + 0.08).press(forDuration: 0.01, thenDragTo: point(0.5, top),
                    withVelocity: XCUIGestureVelocity(rawValue: speed), thenHoldForDuration: 0)
                Thread.sleep(forTimeInterval: delay)
                point(0.3, tapY).tap()
                UITestQuiescence.skipped = false
                Thread.sleep(forTimeInterval: 1.5)
                let json = probe.value as? String ?? ""
                let trace = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
                let frames = (trace["frames"] as? [[Any]] ?? []).compactMap { f -> (Double, Double)? in
                    guard f.count == 4, let t = f[0] as? Double, let y = f[1] as? Double else { return nil }
                    return (t, y)
                }
                let tapAt = (trace["touches"] as? [[Any]])?.last?.first as? Double ?? 0
                let before = frames.filter { $0.0 > tapAt - 0.1 && $0.0 <= tapAt }
                let speedAtTap = before.count > 1 ? abs(before.last!.1 - before.first!.1) / max(0.001, before.last!.0 - before.first!.0) : 0
                // Visible motion after the tap. Refilling the space reserved for
                // earlier chapters shifts the coordinate by a whole reserve in one
                // frame without moving the text, so such jumps are not drift.
                let after = frames.filter { $0.0 > tapAt + 0.05 }.map(\.1)
                let driftAfter = zip(after, after.dropFirst()).map { abs($1 - $0) }.filter { $0 < 500 }.reduce(0, +)
                let item = DriftCase(name: "\(chat ? "chat " : "")speed \(Int(speed)) delay \(delay)", speedAtTap: speedAtTap,
                                     driftAfter: driftAfter, controls: app.buttons["closeBook"].exists)
                cases.append(item)
                let attachment = XCTAttachment(string: "\(item)\n\(json)")
                attachment.name = item.name + " drift trace"; attachment.lifetime = .keepAlways; add(attachment)
                if app.buttons["closeBook"].exists { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: tapY)).tap() }
            }
        }
        app.terminate()
        return cases
    }

    /// A slow, short pull leaves the page drifting after the finger lifts. A tap
    /// during that drift must stop it where it is, without opening the controls.
    @MainActor func testTapStopsSlowShortDriftInScroll() {
        continueAfterFailure = true
        let cases = runDriftSweep(speeds: [450, 600, 900], delays: [0.15, 0.5, 0.8, 1.1, 1.4])
        let drifting = cases.filter { $0.speedAtTap > 5 }
        XCTAssertFalse(drifting.isEmpty, "At least one slow short pull must still be drifting when the tap lands: \(cases)")
        for item in drifting {
            XCTAssertLessThanOrEqual(item.driftAfter, 1, "\(item.name): a tap during the drift must stop it (\(item.speedAtTap) pt/s at the tap)")
            XCTAssertFalse(item.controls, "\(item.name): the stopping tap must not open the controls")
        }
    }

    /// The reported case: the same slow short drift while Ask Leaf is open.
    /// Recorded on an iPhone (build 109): short slow pulls of 21-39 pt ended in
    /// a tap that opened the controls, which the settled scroll then hid. With
    /// and without Ask Leaf, such a pull must leave the controls alone, while a
    /// still tap afterwards must open them as before.
    @MainActor func testShortSlowPullDoesNotOpenTheControlsInScroll() {
        continueAfterFailure = true
        let app = launchApp()
        app.buttons["featuredBook"].tap(); waitForBook(app)
        openAppearance(app)
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons["Scroll"].tap()
        dismissAppearance(app)
        let surface = readingSurface(app)
        if app.buttons["closeBook"].exists { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        for chat in [false, true] {
            if chat {
                app.buttons["openReaderChat"].tap()
                XCTAssertTrue(app.otherElements["readerChatPanel"].waitForExistence(timeout: 5))
                if app.keyboards.firstMatch.exists { app.keyboards.buttons["Hide keyboard"].firstMatch.tap() }
            }
            let top = chat ? 0.3 : 0.55
            // 25-35 pt pulls at finger speed, like the recorded ones (3 px per point here).
            for pull in [25.0, 35.0] {
                let from = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: top + pull / surface.frame.height))
                from.press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: top)),
                           withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0)
                XCTAssertFalse(app.buttons["closeBook"].waitForExistence(timeout: 1.5),
                               "A \(Int(pull)) pt pull\(chat ? " with Ask Leaf open" : "") must not open the controls")
                capture("After a \(Int(pull)) pt pull\(chat ? " with chat" : "")", app: app)
            }
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: top)).tap()
            XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 3), "A still tap\(chat ? " with Ask Leaf open" : "") still opens the controls")
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: top)).tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["closeBook"])
            waitForExpectations(timeout: 3)
            if chat { app.buttons["closeReaderChat"].tap() }
        }
    }

    @MainActor func testTapStopsSlowShortDriftWithChatInScroll() {
        continueAfterFailure = true
        let cases = runDriftSweep(chat: true, speeds: [450, 600, 900], delays: [0.15, 0.5, 0.8, 1.1, 1.4])
        let drifting = cases.filter { $0.speedAtTap > 5 }
        XCTAssertFalse(drifting.isEmpty, "At least one slow short pull must still be drifting when the tap lands: \(cases)")
        for item in drifting {
            XCTAssertLessThanOrEqual(item.driftAfter, 1, "\(item.name): a tap during the drift must stop it (\(item.speedAtTap) pt/s at the tap)")
            XCTAssertFalse(item.controls, "\(item.name): the stopping tap must not open the controls")
        }
    }

    /// A device joining an iCloud Drive folder that another device filled lists
    /// the synced book with its position before the file is here, downloads it
    /// when opened, and shows the folder in Settings › iCloud.
    /// Settings › Diagnostics records reader touches without a special launch,
    /// shows how much was recorded, offers the file for sharing, and clears it.
    @MainActor func testDiagnosticsRecordingCanBeTurnedOnSharedAndCleared() {
        continueAfterFailure = false
        let app = launchApp()
        func openDiagnostics() {
            app.tabBars.buttons["Settings"].tap()
            for _ in 0..<6 where !app.switches["diagnosticsRecording"].isHittable { app.swipeUp() }
            XCTAssertTrue(app.switches["diagnosticsRecording"].waitForExistence(timeout: 5))
        }
        openDiagnostics()
        XCTAssertEqual(app.switches["diagnosticsRecording"].value as? String, "0", "Recording is off by default")
        XCTAssertFalse(app.buttons["diagnosticsShare"].exists, "Nothing to share before recording")
        app.switches["diagnosticsRecording"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["diagnosticsRecording"].value as? String, "1")
        capture("Diagnostics on", app: app)

        app.tabBars.buttons["Library"].tap()
        app.buttons["featuredBook"].tap(); waitForBook(app)
        let surface = readingSurface(app)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 5))
        app.buttons["closeBook"].tap()

        openDiagnostics()
        let count = app.staticTexts["diagnosticsCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertNotEqual(count.value as? String, "0", "The reader tap was recorded: \(count.label)")
        XCTAssertTrue(app.buttons["diagnosticsShare"].waitForExistence(timeout: 5), "The recording can be shared")
        // The Clear row sits at the bottom of Settings, under the floating tab bar until scrolled up.
        for _ in 0..<4 where !app.buttons["diagnosticsClear"].isHittable { app.swipeUp() }
        app.buttons["diagnosticsClear"].tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        app.switches["diagnosticsRecording"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["diagnosticsRecording"].value as? String, "0")
        capture("Diagnostics cleared and off", app: app)
    }

    @MainActor func testANewDeviceListsASyncedBookAndDownloadsItWhenOpened() {
        continueAfterFailure = false
        let app = launchApp(syncFixture: true)
        let title = "A Field Guide to Slow Days"
        let book = app.buttons["book-\(title)"], badge = app.descendants(matching: .any)["cloudBadge-\(title)"]
        XCTAssertTrue(book.waitForExistence(timeout: 15), "The synced book is listed on the new device")
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "A book still in iCloud Drive shows a cloud badge")
        XCTAssertTrue(app.descendants(matching: .any)["libraryCloudBanner"].exists)
        XCTAssertTrue(app.staticTexts["40% read"].exists, "The reading position arrives with the book")
        capture("Synced library before download", app: app)

        app.tabBars.buttons["Settings"].tap()
        // The reading appearance controls come first; the Sync row is below them.
        for _ in 0..<5 where !app.buttons["openICloudSync"].isHittable { app.swipeUp() }
        app.buttons["openICloudSync"].tap()
        let status = app.staticTexts["syncStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Up to date")
        XCTAssertTrue(app.switches["syncKeepBooks"].exists)
        capture("iCloud settings", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Library"].tap()

        book.tap()
        waitForBook(app)
        let surface = readingSurface(app)
        if !app.buttons["closeBook"].exists { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 5))
        app.buttons["closeBook"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: badge)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.descendants(matching: .any)["libraryCloudBanner"].exists, "Once downloaded, nothing is waiting in iCloud Drive")
        capture("Synced library after download", app: app)
    }

    @MainActor func testHeldScrollBackAfterContentsJumpStaysAtPreviousChapter() {
        continueAfterFailure = false
        let app = launchApp(contentsFixture: true, contentsBook: "ScrollFling")
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Contents Location")
        app.buttons["book-Contents Location"].tap()
        openAppearance(app)
        app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
        app.segmentedControls["readingFlow"].buttons["Scroll"].tap()
        dismissAppearance(app)
        showReaderControls(app); app.buttons["Contents"].tap()
        let destination = app.buttons["第30章 归途"]
        for _ in 0..<4 where !destination.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(destination.isHittable); destination.tap(); waitForBook(app)
        let surface = readingSurface(app)
        func visibleChapters() -> Set<Int> {
            let area = surface.frame.insetBy(dx: 10, dy: 20)
            let regex = try! NSRegularExpression(pattern: "这是第(\\d+)章")
            return Set(surface.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这是第")).allElementsBoundByIndex.compactMap { text in
                guard text.frame.intersects(area), let match = regex.firstMatch(in: text.label, range: NSRange(text.label.startIndex..., in: text.label)),
                      let range = Range(match.range(at: 1), in: text.label) else { return nil }
                return Int(text.label[range])
            })
        }
        XCTAssertTrue(visibleChapters().contains(30), "\(visibleChapters())")
        // Keep the finger down after the pull, so chapter loads finish during the touch.
        func heldPull(allowed: Set<Int>, _ name: String) {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.01,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), withVelocity: .slow, thenHoldForDuration: 2.5)
            let seen = visibleChapters()
            capture(name, app: app)
            XCTAssertFalse(seen.isEmpty, "Book text must stay visible after the pull")
            XCTAssertTrue(seen.isSubset(of: allowed), "Expected chapters \(allowed.sorted()) after the pull, saw \(seen.sorted())")
        }
        heldPull(allowed: [29, 30], "Held pull back after Contents jump")
        heldPull(allowed: [28, 29, 30], "Second held pull back after Contents jump")
        showReaderControls(app)
        let title = app.staticTexts["readerChapterTitle"].label
        XCTAssertTrue(title.contains("第29章") || title.contains("第28章") || title.contains("第30章"), title)
    }

    @MainActor private func verifyContentsLocation(flow: String) {
        continueAfterFailure = false
        let pdf = flow == "PDF"
        let app = launchApp(contentsFixture: !pdf)
        if pdf { openSelectionFixture(flow, app: app) }
        else {
            let search = app.textFields["librarySearch"]
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Contents Location")
            app.buttons["book-Contents Location"].tap()
            openAppearance(app)
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
            app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
            app.buttons[(flow == "Pages" ? "Paper" : "Night") + " theme"].tap()
            dismissAppearance(app)
        }
        let current = app.buttons["currentContentsChapter"]
        func openContents(_ expected: String) {
            // A reopened web book briefly shows a disabled toolbar while restoring.
            showReaderControls(app)
            app.buttons["Contents"].tap()
            XCTAssertTrue(current.waitForExistence(timeout: 5))
            expectation(for: NSPredicate { _, _ in current.isHittable && current.label == expected }, evaluatedWith: current)
            waitForExpectations(timeout: 6)
            XCTAssertEqual(current.value as? String, "Reading here")
            XCTAssertTrue(current.isSelected)
            XCTAssertEqual(app.buttons.matching(identifier: "currentContentsChapter").count, 1)
        }
        openContents(pdf ? "Page 2" : "第24章 归途")
        capture(flow + " Contents opens at the current location", app: app)
        // Opening/dismissing Contents alone must not jump to the chapter start.
        app.buttons["Done"].tap()
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Keep my Contents question")
        app.buttons["Hide keyboard"].tap()
        readingSurface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].exists, "Book taps must keep the chat and draft")
        XCTAssertEqual(input.value as? String, "Keep my Contents question")
        // Contents lives in the bottom reader toolbar, under the chat overlay.
        // Intentionally close chat before using that toolbar, then restore its draft.
        app.buttons["closeReaderChat"].tap()
        openContents(pdf ? "Page 2" : "第24章 归途")
        let previous = pdf ? "Page 1" : "第23章 归途"
        app.buttons[previous].tap()
        openContents(previous)
        app.buttons[pdf ? "Page 2" : "第24章 归途"].tap()
        openContents(pdf ? "Page 2" : "第24章 归途")
        app.buttons["Done"].tap()
        orient(.landscapeLeft)
        openContents(pdf ? "Page 2" : "第24章 归途")
        capture(flow + " Contents current location landscape", app: app)
        app.buttons["Done"].tap()
        app.buttons["openReaderChat"].tap()
        XCTAssertEqual(input.value as? String, "Keep my Contents question")
        app.buttons["closeReaderChat"].tap()
        orient(.portrait)
        showReaderControls(app); app.buttons["closeBook"].tap()
        app.buttons[pdf ? "book-Notes from the Coast" : "book-Contents Location"].tap()
        openContents(pdf ? "Page 2" : "第24章 归途")
        app.buttons["Done"].tap()
        for (position, expected) in [(1.0, pdf ? "Page 4" : "第36章 归途"), (0.0, pdf ? "Page 1" : "第1章 归途")] {
            showReaderControls(app)
            app.sliders["readingProgress"].adjust(toNormalizedSliderPosition: position)
            openContents(expected)
            capture(flow + " Contents " + (position == 1 ? "book end" : "book beginning"), app: app)
            app.buttons["Done"].tap()
        }
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
        let app = launchApp(appleSpeech: true)
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
            XCTAssertTrue(pause.waitForExistence(timeout: 8)); XCTAssertEqual(pause.label, "Pause listening", "Narration keeps playing in the background")
            XCTAssertEqual(input.value as? String, expectedDraft)
            capture(flow + " listening continues after background", app: app)
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

    @MainActor func testNarrationContinuesInBackgroundInPages() { verifyBackgroundNarration("Pages") }
    @MainActor func testNarrationContinuesInBackgroundInScroll() { verifyBackgroundNarration("Scroll") }
    @MainActor func testNarrationContinuesInBackgroundInPDF() { verifyBackgroundNarration("PDF") }
    @MainActor private func verifyBackgroundNarration(_ flow: String) {
        continueAfterFailure = false
        let app = launchApp(appleSpeech: true, backgroundAudio: true)
        openSelectionFixture(flow, app: app); showReaderControls(app)
        if flow == "PDF" {
            // Begin at the cover so setup cannot consume the only two remaining
            // short pages before Home. Keep the two-background-passage requirement.
            app.buttons["Previous page"].tap(); showReaderControls(app)
        }
        app.buttons["Listen"].tap(); app.buttons["listenFromPage"].tap()
        let player = app.otherElements["readerAudioPlayer"], pause = app.buttons["audioPlayPause"]
        expectation(for: NSPredicate(format: "value == %@", "Listening"), evaluatedWith: player)
        waitForExpectations(timeout: 15)
        app.buttons["playbackSpeed"].tap(); app.buttons["2×"].tap()
        capture(flow + " narration before background", app: app)
        let backgroundedAt = ProcessInfo.processInfo.systemUptime
        XCUIDevice.shared.press(.home)
        // No app queries/activation during this interval: recorded speech events
        // must predate activation, so a resumed WebView cannot fake continuation.
        Thread.sleep(forTimeInterval: 40)
        let activationBeganAt = ProcessInfo.processInfo.systemUptime
        app.activate()
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        // The four short PDF pages can finish at2× during the40second interval.
        // Record terminal state before assertions; a real pause still fails.
        let finishedPDF = flow == "PDF" && player.value as? String == "End of book"
        if flow == "PDF" {
            let state = XCTAttachment(string: "status=\(player.value as? String ?? "nil"); enabled=\(pause.isEnabled); proof=\(app.staticTexts["spokenPassage"].value as? String ?? "nil")")
            state.name = "PDF actual playback state on return"; state.lifetime = .keepAlways; add(state)
            capture("PDF playback state immediately after background", app: app)
        }
        if finishedPDF { XCTAssertFalse(pause.isEnabled, "A naturally completed book cannot resume past its end") }
        else { XCTAssertEqual(pause.label, "Pause listening", "Going to the background must not pause narration") }
        let value = app.staticTexts["spokenPassage"].value as? String ?? "{}"
        let proof = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? [:]
        let starts = proof["starts"] as? [Double] ?? []
        let beforeActivation = starts.filter { $0 > backgroundedAt && $0 < activationBeganAt - 1 }
        XCTAssertGreaterThanOrEqual(beforeActivation.count, 2, "Continue past the single prefetched passage while still in the background: \(value)")
        let progress = proof["firstProgress"] as? Double ?? -1
        XCTAssertGreaterThan(progress, backgroundedAt)
        XCTAssertLessThan(progress, activationBeganAt - 1, "Real AVSpeech progress must occur before reactivation")
        let evidence = XCTAttachment(string: "flow=\(flow); homeAt=\(backgroundedAt); activatingAt=\(activationBeganAt); \(value)")
        evidence.name = flow + " background speech and lazy passage evidence"; evidence.lifetime = .keepAlways; add(evidence)
        if !finishedPDF {
            pause.tap(); XCTAssertEqual(pause.label, "Resume listening")
            XCUIDevice.shared.press(.home); app.activate()
            XCTAssertEqual(pause.label, "Resume listening", "A user pause stays paused across background/foreground")
        }
        capture(flow + (finishedPDF ? " completed narration in background" : " narration returns and user pause retained"), app: app)
        app.buttons["stopListening"].tap()
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
        for flow in ["Pages", "Scroll", "PDF"] { verifySpeechProgress(flow: flow) }
    }
    @MainActor func testListeningHighlightInPages() { verifySpeechProgress(flow: "Pages") }
    @MainActor func testListeningHighlightInScroll() { verifySpeechProgress(flow: "Scroll") }
    @MainActor func testListeningHighlightInPDF() { verifySpeechProgress(flow: "PDF") }

    @MainActor private func verifySpeechProgress(flow: String) {
        continueAfterFailure = false
        orient(.portrait)
        defer { orient(.portrait) }
        let app = launchApp(appleSpeech: true); openSelectionFixture(flow, app: app)
        selectFixturePassage(flow, app: app)
        XCTAssertTrue(app.buttons["selection-listen"].waitForExistence(timeout: 6)); app.buttons["selection-listen"].tap()
        let status = app.buttons["listeningSettings"], pause = app.buttons["audioPlayPause"]
        expectation(for: NSPredicate { _, _ in !(status.value as? String ?? "").isEmpty }, evaluatedWith: status); waitForExpectations(timeout: 60)
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
    @MainActor func testListeningFromNativeSelectionInBothFlows() {
        let app = launchApp(appleSpeech: true); app.buttons["featuredBook"].tap()
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


    @MainActor func testAppleOnlyListeningInPages() { verifyAppleOnlyListening("Pages") }
    @MainActor func testAppleOnlyListeningInScroll() { verifyAppleOnlyListening("Scroll") }
    @MainActor func testAppleOnlyListeningInPDF() { verifyAppleOnlyListening("PDF") }
    @MainActor private func verifyAppleOnlyListening(_ flow: String) {
        continueAfterFailure = false
        let app = launchApp(appleSpeech: true); openSelectionFixture(flow, app: app)
        defer { orient(.portrait); app.terminate() }
        showReaderControls(app); app.buttons["Appearance"].tap()
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        app.buttons[(flow == "Pages" ? "Paper" : flow == "Scroll" ? "Night" : "Day") + " theme"].tap()
        dismissAppearance(app); showReaderControls(app); app.buttons["Listen"].tap()
        XCTAssertTrue(app.sliders["listeningSpeedSlider"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["listeningEngine"].exists)
        XCTAssertFalse(app.buttons["kokoroDownload"].exists); XCTAssertFalse(app.buttons["kokoroRemove"].exists)
        XCTAssertFalse(app.staticTexts["Natural voice"].exists)
        app.sliders["listeningSpeedSlider"].adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertEqual(app.staticTexts["listeningSpeedValue"].label, "1.25×")
        capture(flow + " Apple-only voice settings portrait", app: app)
        orient(.landscapeLeft)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(app.descendants(matching: .any)["listeningForm"].firstMatch.exists)
        capture(flow + " Apple-only voice settings landscape", app: app)
        orient(.portrait)
        app.buttons["listenFromPage"].tap()
        let pause = app.buttons["audioPlayPause"]
        expectation(for: NSPredicate(format: "label == %@", "Pause listening"), evaluatedWith: pause); waitForExpectations(timeout: 15)
        pause.tap(); XCTAssertEqual(pause.label, "Resume listening")
        app.buttons["playbackSpeed"].tap(); app.buttons["1.5×"].tap()
        XCTAssertEqual(pause.label, "Resume listening", "Changing speed must keep paused audio paused")
        capture(flow + " Apple playback paused speed retained", app: app)
        let passage = app.staticTexts["spokenPassage"]
        let originalPassage = passage.label
        let originalLocation = passage.value as? String ?? ""
        XCTAssertFalse(originalLocation.isEmpty)
        app.buttons["audioNext"].tap()
        XCTAssertEqual(pause.label, "Resume listening")
        // The sample EPUB repeats paragraphs. Identity is its actual source
        // locator, not whether the visible text happens to be different.
        expectation(for: NSPredicate { _, _ in
            guard let location = passage.value as? String else { return false }
            return !location.isEmpty && location != originalLocation
        }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        let nextLocation = passage.value as? String ?? ""
        XCTAssertFalse(passage.label.isEmpty)
        let previous = app.buttons["audioPrevious"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: previous); waitForExpectations(timeout: 8)
        previous.tap(); XCTAssertEqual(pause.label, "Resume listening")
        expectation(for: NSPredicate(format: "value == %@", originalLocation), evaluatedWith: passage)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(passage.label, originalPassage)
        let locations = XCTAttachment(string: "Original: \(originalLocation)\nNext: \(nextLocation)\nRestored: \(passage.value as? String ?? "")")
        locations.name = flow + " actual listening passage locations"; locations.lifetime = .keepAlways; add(locations)
        app.buttons["stopListening"].tap()
        showReaderControls(app); app.buttons["closeBook"].tap()
        app.buttons["featuredBook"].tap(); showReaderControls(app); app.buttons["Listen"].tap()
        XCTAssertTrue(app.buttons["resumeSavedListening"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["listeningSpeedValue"].label, "1.5×")
        XCTAssertFalse(app.segmentedControls["listeningEngine"].exists)
        capture(flow + " Apple saved listening cursor and speed after reopening", app: app)
        app.buttons["resumeSavedListening"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Pause listening"), evaluatedWith: pause); waitForExpectations(timeout: 15)
        pause.tap(); app.buttons["stopListening"].tap()
    }
    @MainActor func testMissingAppleVoiceKeepsCursorInPages() { verifyMissingAppleVoice("Pages") }
    @MainActor func testMissingAppleVoiceKeepsCursorInScroll() { verifyMissingAppleVoice("Scroll") }
    @MainActor func testMissingAppleVoiceKeepsCursorInPDF() { verifyMissingAppleVoice("PDF") }
    @MainActor private func verifyMissingAppleVoice(_ flow: String) {
        continueAfterFailure = false
        let app = launchApp(); openSelectionFixture(flow, app: app)
        defer { orient(.portrait); app.terminate() }
        showReaderControls(app); app.buttons["Listen"].tap()
        XCTAssertFalse(app.segmentedControls["listeningEngine"].exists)
        XCTAssertFalse(app.buttons["kokoroDownload"].exists)
        let guidance = app.descendants(matching: .any)["appleVoiceDownloadGuidance"].firstMatch
        if guidance.waitForExistence(timeout: 3) {
            capture(flow + " Download Enhanced or Premium Apple voice guidance", app: app)
            app.buttons["listenFromPage"].tap()
            let player = app.otherElements["readerAudioPlayer"]
            expectation(for: NSPredicate(format: "value == %@", "Could not start audio"), evaluatedWith: player); waitForExpectations(timeout: 15)
            XCTAssertFalse(app.buttons["audioPlayPause"].isEnabled)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No Enhanced or Premium Apple voice")).firstMatch.exists)
            capture(flow + " Missing Apple voice keeps passage without fallback", app: app)
            app.buttons["listeningSettings"].tap()
            XCTAssertTrue(app.buttons["resumeSavedListening"].waitForExistence(timeout: 5))
            capture(flow + " Missing Apple voice preserves saved cursor", app: app)
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["listeningVoice"].firstMatch.exists)
            capture(flow + " Actual installed high-quality Apple voice choices", app: app)
        }
    }
    @MainActor func testPDFListeningFromSelectionAndBottomMenu() {
        let app = launchApp(appleSpeech: true)
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

    @MainActor func testReaderControlsStayAccessibleWithChatInPages() { verifyReaderControlsWithChat(flow: "Pages") }
    @MainActor func testReaderControlsStayAccessibleWithChatInScroll() { verifyReaderControlsWithChat(flow: "Scroll") }
    @MainActor func testReaderControlsStayAccessibleWithChatInPDF() { verifyReaderControlsWithChat(flow: "PDF") }

    @MainActor private func verifyReaderControlsWithChat(flow: String) {
        continueAfterFailure = false
        let app=launchApp();defer {orient(.portrait)}
        openSelectionFixture(flow,app:app);waitForBook(app)
        let surface=readingSurface(app), original=surface.frame
        app.buttons["openReaderChat"].tap()
        let panel=app.otherElements["readerChatPanel"],close=app.buttons["closeBook"]
        XCTAssertTrue(panel.waitForExistence(timeout:5));XCTAssertFalse(close.exists)
        func tapBook(_ x:CGFloat=0.5) {
            let top=surface.frame.minY+90,bottom=panel.frame.minY-16
            XCTAssertGreaterThan(bottom,top)
            app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:surface.frame.minX+surface.frame.width*x-app.frame.minX,dy:(top+bottom)/2-app.frame.minY)).tap()
        }
        var progress:String?,chapter:String?
        for x:CGFloat in [0.5,0.12,0.88] {
            tapBook(x)
            XCTAssertTrue(close.waitForExistence(timeout:5));XCTAssertTrue(close.isHittable)
            XCTAssertTrue(app.buttons["closeReaderChat"].exists)
            let current=app.sliders["readingProgress"].value as? String,title=app.staticTexts["readerChapterTitle"].label
            if let progress {XCTAssertEqual(current,progress)} else {progress=current}
            if let chapter {XCTAssertEqual(title,chapter)} else {chapter=title}
            if x==0.5 {capture(flow+" reader Exit visible with chat",app:app)}
            tapBook(x)
            expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:close);waitForExpectations(timeout:5)
        }
        selectFixturePassage(flow,app:app)
        let quote=app.staticTexts["chatSelectedPassage"]
        XCTAssertTrue(quote.waitForExistence(timeout:5));let quoted=quote.label
        XCTAssertFalse(close.exists,"Selecting text must not be treated as a reader-controls tap")
        let input=app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap();XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout:5))
        input.typeText("Keep my exit question")
        XCTAssertEqual(input.value as? String,"Keep my exit question")
        tapBook()
        XCTAssertTrue(close.waitForExistence(timeout:5));XCTAssertTrue(close.isHittable)
        XCTAssertEqual(quote.label,quoted);XCTAssertEqual(input.value as? String,"Keep my exit question")
        XCTAssertEqual(surface.frame.width,original.width,accuracy:2);XCTAssertEqual(surface.frame.height,original.height,accuracy:2)
        capture(flow+" Exit reachable while composing with quote",app:app)
        if app.buttons["Hide keyboard"].isHittable {app.buttons["Hide keyboard"].tap()}
        orient(.landscapeLeft)
        if close.exists {tapBook()}
        tapBook();XCTAssertTrue(close.waitForExistence(timeout:5));XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.buttons["closeReaderChat"].exists);XCTAssertEqual(input.value as? String,"Keep my exit question")
        capture(flow+" landscape Exit with chat",app:app)
        close.tap()
        XCTAssertTrue(app.buttons["featuredBook"].waitForExistence(timeout:8),"Exit must return to the library without first closing chat")
        orient(.portrait)
        if flow=="PDF" {let card=app.buttons["book-Notes from the Coast"];for _ in 0..<5 where !card.isHittable {app.scrollViews.firstMatch.swipeUp()};card.tap()}
        else {app.buttons["featuredBook"].tap()}
        waitForBook(app);app.buttons["openReaderChat"].tap()
        XCTAssertEqual(input.value as? String,"Keep my exit question");XCTAssertEqual(quote.label,quoted)
        capture(flow+" draft and quote survive direct book Exit",app:app)
    }

    @MainActor func testBookEndingAboveChatInPages() { verifyBookEndingAboveChat(flow: "Pages") }
    @MainActor func testBookEndingAboveChatInScroll() { verifyBookEndingAboveChat(flow: "Scroll") }
    @MainActor func testBookEndingAboveChatInPDF() { verifyBookEndingAboveChat(flow: "PDF") }

    @MainActor private func verifyBookEndingAboveChat(flow: String) {
        continueAfterFailure = false
        let app=launchApp(); defer { orient(.portrait) }
        openSelectionFixture(flow,app:app);showReaderControls(app)
        if flow == "PDF" {
            app.buttons["Contents"].tap()
            XCTAssertTrue(app.buttons["Page 4"].waitForExistence(timeout: 5));app.buttons["Page 4"].tap()
            showReaderControls(app)
        } else { app.sliders["readingProgress"].adjust(toNormalizedSliderPosition: 1) }
        capture(flow+" ending before chat",app:app)
        let title=app.staticTexts["readerChapterTitle"]
        expectation(for: NSPredicate(format: "label CONTAINS %@",flow == "PDF" ? "Page 4" : "Carry it with you"),evaluatedWith:title)
        waitForExpectations(timeout:10)
        let surface=readingSurface(app), original=surface.frame
        surface.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4)).tap()
        app.buttons["openReaderChat"].tap()
        let panel=app.otherElements["readerChatPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout:5))
        func liftEnding(_ label:String) {
            for _ in 0..<6 {
                let top=max(surface.frame.minY+12,app.frame.minY+12), bottom=panel.frame.minY-18
                XCTAssertGreaterThan(bottom-top,32)
                let start=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:app.frame.width*0.5,dy:bottom-app.frame.minY))
                let end=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:app.frame.width*0.5,dy:top-app.frame.minY))
                start.press(forDuration:0.01,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.1)
            }
            let endings=flow == "PDF" ? surface.staticTexts.allElementsBoundByIndex : surface.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","world will keep offering itself")).allElementsBoundByIndex
            capture(flow+" final lines "+label,app:app)
            XCTAssertFalse(endings.isEmpty)
            let last=endings.last!
            XCTAssertLessThanOrEqual(last.frame.maxY,panel.frame.minY+2,"Final text must clear the chat: \(last.frame) vs \(panel.frame)")
            XCTAssertGreaterThan(last.frame.maxY,surface.frame.minY,"The ending must remain visible")
            XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        }
        liftEnding("above reading chat")
        XCTAssertEqual(surface.frame.width,original.width,accuracy:2);XCTAssertEqual(surface.frame.height,original.height,accuracy:2)
        let handle=app.descendants(matching:.any)["readerChatDragHandle"].firstMatch
        let start=handle.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        start.press(forDuration:0.01,thenDragTo:start.withOffset(CGVector(dx:0,dy:-180)),withVelocity:.slow,thenHoldForDuration:0.1)
        liftEnding("above expanded chat")
        let input=app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap()
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout:5))
        input.typeText("Question about the ending")
        XCTAssertEqual(input.value as? String,"Question about the ending")
        liftEnding("with keyboard")
        XCTAssertEqual(surface.frame.height,original.height,accuracy:2)
        app.buttons["Hide keyboard"].tap()
        orient(.landscapeLeft);liftEnding("landscape")
        XCTAssertEqual(input.value as? String,"Question about the ending")
        orient(.portrait)
        app.buttons["closeReaderChat"].tap();showReaderControls(app)
        XCTAssertTrue(title.label.contains(flow == "PDF" ? "Page 4" : "Carry it with you"))
        app.buttons["closeBook"].tap()
        if flow == "PDF" { let card=app.buttons["book-Notes from the Coast"];for _ in 0..<5 where !card.isHittable {app.scrollViews.firstMatch.swipeUp()};card.tap() }
        else {app.buttons["featuredBook"].tap()}
        showReaderControls(app)
        XCTAssertTrue(title.label.contains(flow == "PDF" ? "Page 4" : "Carry it with you"))
        app.buttons["openReaderChat"].tap()
        XCTAssertEqual(input.value as? String,"Question about the ending")
        capture(flow+" saved passage after reopening",app:app)
        // Rotation preserves the passage, which can reflow onto the preceding
        // physical page. Navigate back to the actual ending before testing it.
        if flow == "Pages" {
            for _ in 0..<3 {
                let y=surface.frame.minY+40
                let origin=app.coordinate(withNormalizedOffset:.zero)
                origin.withOffset(CGVector(dx:app.frame.width*0.85,dy:y-app.frame.minY))
                    .press(forDuration:0.01,thenDragTo:origin.withOffset(CGVector(dx:app.frame.width*0.15,dy:y-app.frame.minY)),withVelocity:.slow,thenHoldForDuration:0.1)
            }
        }
        liftEnding("restored after reopening")
    }

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
        let initialReadingHeight = panel.frame.height
        var readingHeight = initialReadingHeight
        XCTAssertGreaterThan(initialReadingHeight, app.frame.height * 0.28)
        XCTAssertLessThan(initialReadingHeight, app.frame.height * 0.40, "The dock leaves most of the screen for the book")
        XCTAssertGreaterThanOrEqual(panel.frame.maxY, app.frame.maxY - 24, "No unused bottom safe-area gap below the reader chat")
        capture(flow + " lower reading dock at approved height", app: app)
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
        resize(500)
        XCTAssertLessThan(panel.frame.height, initialReadingHeight)
        XCTAssertTrue(input.isHittable)
        capture(flow + " minimum reading dock", app: app)
        resize(-700)
        XCTAssertGreaterThan(panel.frame.height, initialReadingHeight + 100)
        XCTAssertLessThan(panel.frame.height, app.frame.height * 0.9)
        XCTAssertTrue(input.isHittable)
        capture(flow + " maximum reading dock", app: app)
        resize(panel.frame.height - initialReadingHeight)
        XCTAssertEqual(panel.frame.height, initialReadingHeight, accuracy: 15)
        readingHeight = panel.frame.height
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
        let decrement = app.buttons["contextCharacters-Decrement"]
        revealSettingsRow(decrement, app: app)
        decrement.tap()
        XCTAssertTrue(app.staticTexts["11,000 chars"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "up to 11,000 characters")).firstMatch.exists)
        capture("Reading context limits in AI settings", app: app)
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
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "label BEGINSWITH %@", "Agent reply: found")).firstMatch.waitForExistence(timeout: 30))
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !app.buttons["openAISettings"].isHittable { app.swipeUp() }
        app.buttons["openAISettings"].tap()
        revealSettingsRow(decrement, app: app)
        XCTAssertTrue(app.staticTexts["11,000 chars"].exists, "The reading context limit is saved")
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
        let reply = app.textViews.containing(NSPredicate(format: "label BEGINSWITH %@", "Agent reply: found")).firstMatch
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

    @MainActor func testQuickChatHistorySwipeInPages() { verifyQuickChatHistorySwipe(flow: "Pages") }
    @MainActor func testQuickChatHistorySwipeInScroll() { verifyQuickChatHistorySwipe(flow: "Scroll") }
    @MainActor func testQuickChatHistorySwipeInPDF() { verifyQuickChatHistorySwipe(flow: "PDF") }

    @MainActor private func verifyQuickChatHistorySwipe(flow: String) {
        continueAfterFailure = false
        let app = launchApp(scrollPerformance: true)
        openSelectionFixture(flow, app: app); waitForBook(app)
        let bookFrame = readingSurface(app).frame
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"]
        input.tap(); input.typeText("回顾人物和线索"); app.buttons["sendReaderChat"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 10)
        let history = app.scrollViews["chatMessageHistory"]
        let probe = app.descendants(matching: .any)["uitestChatSwipeWork"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        func metrics() -> [String: Any] {
            let data = (probe.value as? String ?? "").data(using: .utf8) ?? Data()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        history.swipeDown(velocity: .fast) // Warm visible text and lazy layout.
        history.swipeUp(velocity: .fast)
        let before = metrics()
        let options = XCTMeasureOptions(); options.iterationCount = 1
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            history.swipeDown(velocity: .fast)
            history.swipeDown(velocity: .fast)
            history.swipeUp(velocity: .fast)
        }
        let after = metrics()
        let work = XCTAttachment(string: "Before: \(before)\nAfter: \(after)")
        work.name = flow + " quick swipe rendering work"; work.lifetime = .keepAlways; add(work)
        XCTAssertLessThanOrEqual((after["formats"] as? Int ?? .max) - (before["formats"] as? Int ?? 0), 2,
                                 "Warm history must not repeatedly parse Markdown during swipes")
        XCTAssertLessThanOrEqual((after["measurements"] as? Int ?? .max) - (before["measurements"] as? Int ?? 0), 4,
                                 "Warm history must reuse its measured text layout during swipes")
        XCTAssertNotEqual(before["offset"] as? Double, after["offset"] as? Double, "A quick swipe must actually move history")
        XCTAssertEqual(readingSurface(app).frame, bookFrame)
        XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        capture(flow + " quick chat swipe portrait", app: app)
        // The very long selectable reply makes AX snapshots slow. Close it
        // while requesting scene geometry, then verify restored history at the
        // new width. Streaming/selection cases separately rotate an open panel.
        app.buttons["closeReaderChat"].tap()
        orient(.landscapeLeft)
        app.buttons["openReaderChat"].tap()
        history.swipeDown(velocity: .fast)
        XCTAssertGreaterThan(history.frame.width, 500)
        capture(flow + " quick chat swipe landscape", app: app)
        app.buttons["closeReaderChat"].tap()
        orient(.portrait)
    }

    @MainActor func testStreamingScrollAtOwnPaceInPages() { verifyStreamingScroll(flow: "Pages") }
    @MainActor func testStreamingScrollAtOwnPaceInScroll() { verifyStreamingScroll(flow: "Scroll") }
    @MainActor func testStreamingScrollAtOwnPaceInPDF() { verifyStreamingScroll(flow: "PDF") }
    @MainActor func testStreamingScrollAtOwnPaceInLibrary() { verifyStreamingScroll(flow: "Library") }
    @MainActor func testStreamingScrollAtOwnPaceUsingLegacyTracking() { verifyStreamingScroll(flow: "Library", legacy: true) }

    @MainActor private func verifyStreamingScroll(flow: String, legacy: Bool = false) {
        continueAfterFailure = false
        let app = launchApp(scrollStream: true, legacyScroll: legacy)
        if flow == "Library" { app.buttons["openLibraryChat"].tap() }
        else { openSelectionFixture(flow, app: app); waitForBook(app); app.buttons["openReaderChat"].tap() }
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        input.tap(); input.typeText("Explain at length"); app.buttons["sendReaderChat"].tap()
        let history = app.scrollViews["chatMessageHistory"]
        let reply = app.descendants(matching: .any).matching(identifier: "chatReply").firstMatch
        let geometry = app.descendants(matching: .any)["uitestChatHistoryGeometry"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        func measuredOffset() -> Double {
            let data = (geometry.value as? String ?? "").data(using: .utf8) ?? Data()
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["offset"] as? Double ?? .nan
        }
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Update 1:"), evaluatedWith: reply)
        waitForExpectations(timeout: 10)

        func assertPausedWhileGrowing(_ name: String) {
            // A gesture can extend outside the small history viewport, just as
            // a finger does when reading above the keyboard.
            let start = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            let distance = min(220, max(100, history.frame.height * 0.65))
            start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
            expectation(for: NSPredicate(format: "value == %@", "Reading earlier"), evaluatedWith: history)
            waitForExpectations(timeout: 5)
            let origin = measuredOffset(), count = reply.label.count
            expectation(for: NSPredicate { _, _ in reply.label.count > count + 20 }, evaluatedWith: reply)
            waitForExpectations(timeout: 8)
            let current = measuredOffset()
            XCTAssertEqual(current, origin, accuracy: 3, "New tokens must not move the passage being read")
            let trace = XCTAttachment(string: "Actual history offset: \(origin) → \(current); reply characters: \(count) → \(reply.label.count)")
            trace.name = flow + " " + name + " measured position"; trace.lifetime = .keepAlways; add(trace)
            XCTAssertEqual(history.value as? String, "Reading earlier")
            capture(flow + " " + name, app: app)
        }
        assertPausedWhileGrowing("manual reading during streaming")
        for _ in 0..<8 {
            if history.value as? String == "Following latest" { break }
            history.swipeUp(velocity: .fast)
        }
        expectation(for: NSPredicate(format: "value == %@", "Following latest"), evaluatedWith: history)
        waitForExpectations(timeout: 5)
        let origin = measuredOffset(), count = reply.label.count
        var samples: [String] = []
        let resumes = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            samples.append("characters=\(reply.label.count) \(geometry.value as? String ?? "missing")")
            return reply.label.count > count + 80 && measuredOffset() > origin + 10
        }, object: reply)
        let outcome = XCTWaiter.wait(for: [resumes], timeout: 12)
        let trace = XCTAttachment(string: "Following offset: \(origin) → \(measuredOffset()); reply characters: \(count) → \(reply.label.count)\n" + samples.joined(separator: "\n"))
        trace.name = flow + " measured following position"; trace.lifetime = .keepAlways; add(trace)
        XCTAssertEqual(outcome, .completed, "Returning to the bottom must resume actual scrolling as the reply grows")
        capture(flow + " following resumes at bottom", app: app)

        input.tap(); input.typeText("Keep my draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertPausedWhileGrowing("manual reading above keyboard")
        XCTAssertEqual(input.value as? String, "Keep my draft")
        app.buttons["Hide keyboard"].tap()
        app.buttons["sendReaderChat"].tap() // Stop the deterministic long stream.
        expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: app.buttons["sendReaderChat"])
        waitForExpectations(timeout: 5)
        app.buttons["closeReaderChat"].tap()
        app.buttons[flow == "Library" ? "openLibraryChat" : "openReaderChat"].tap()
        XCTAssertEqual(input.value as? String, "Keep my draft")
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        orient(.landscapeLeft)
        capture(flow + " long reply after reopening in landscape", app: app)
    }

    @MainActor func testStreamingReplyFollowsSmoothlyInPages() { verifyStreamingFollow(flow: "Pages") }
    @MainActor func testStreamingReplyFollowsSmoothlyInScroll() { verifyStreamingFollow(flow: "Scroll") }

    /// While following, the history must not jump back when the placeholder
    /// becomes the reply, nor trail the newest line and catch up in leaps.
    @MainActor private func verifyStreamingFollow(flow: String) {
        continueAfterFailure = false
        let app = launchApp(chatFollow: true)
        openSelectionFixture(flow, app: app); waitForBook(app)
        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        let send = app.buttons["sendReaderChat"], history = app.scrollViews["chatMessageHistory"]
        let geometry = app.descendants(matching: .any)["uitestChatHistoryGeometry"].firstMatch
        func ask(_ question: String) {
            // Close the keyboard first, so the panel does not resize while measured.
            input.tap(); input.typeText(question)
            if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
            waitForExpectations(timeout: 5)
            send.tap()
            expectation(for: NSPredicate(format: "label == %@", "Stop response"), evaluatedWith: send)
            waitForExpectations(timeout: 5)
            expectation(for: NSPredicate(format: "label == %@", "Send message"), evaluatedWith: send)
            waitForExpectations(timeout: 30)
        }
        func trace() -> [String: Any] {
            let data = (geometry.value as? String ?? "").data(using: .utf8) ?? Data()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        ask("有没有出现和熊有关的游戏")
        ask("详细些")
        let result = trace()
        let attachment = XCTAttachment(string: geometry.value as? String ?? "missing")
        attachment.name = flow + " streaming follow trace"; attachment.lifetime = .keepAlways; add(attachment)
        capture(flow + " streamed reply followed to the end", app: app)
        XCTAssertEqual(history.value as? String, "Following latest")
        XCTAssertGreaterThan(result["samples"] as? Int ?? 0, 20, "The second reply must stream while measured: \(result)")
        XCTAssertLessThanOrEqual(result["maxBack"] as? Double ?? 99, 1, "Following must never move the history backward: \(result)")
        XCTAssertLessThanOrEqual(result["maxGap"] as? Double ?? 99, 4, "The newest line must stay at the bottom as it streams: \(result)")
        XCTAssertLessThanOrEqual(result["gap"] as? Double ?? 99, 4, "The last line must end visible: \(result)")
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
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5), "Wait for the composing panel before native typing")
        input.typeText("Literal **question**")
        expectation(for: NSPredicate(format: "value == %@", "Literal **question**"), evaluatedWith: input)
        waitForExpectations(timeout: 5)
        app.buttons["sendReaderChat"].tap()
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
        defer { orient(.portrait) }
        let app = launchApp(slowChat: true); openFeaturedChat(app)
        sendChatQuestion("Keep my partial reply", app: app)
        app.buttons["closeReaderChat"].tap(); showReaderControls(app); app.buttons["closeBook"].tap()
        app.terminate(); app.launch(); openFeaturedChat(app)
        XCTAssertTrue(app.textViews["Keep my partial reply"].exists)
        XCTAssertTrue(app.textViews.matching(identifier: "chatReply").firstMatch.label.contains("Test reply:"))
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertEqual(app.buttons["sendReaderChat"].label, "Send message")
        capture("Interrupted reply retained with Retry after restart", app: app)
        orient(.landscapeLeft)
        let history = app.scrollViews["chatMessageHistory"]
        let reply = app.textViews.matching(identifier: "chatReply").firstMatch
        XCTAssertGreaterThanOrEqual(history.frame.height, 20, "A stopped-reply notice must leave readable history in the compact dock")
        XCTAssertGreaterThan(reply.frame.intersection(history.frame).height, 15)
        XCTAssertTrue(app.buttons["Retry"].isHittable)
        XCTAssertTrue(app.buttons["sendReaderChat"].exists)
        capture("Compact landscape stopped reply keeps history above Retry notice", app: app)
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
        // The question shows at once; stop once the reply itself is under way
        // (stopping while the page is still being read withdraws the question).
        // The slow mock streams its first words quickly, so wait for them, not the placeholder.
        XCTAssertTrue(app.textViews.matching(identifier: "chatQuestion").matching(NSPredicate(format: "label == %@", "Explain this page")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews.matching(identifier: "chatReply").matching(NSPredicate(format: "label BEGINSWITH %@", "Test reply")).firstMatch.waitForExistence(timeout: 10))
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

/// XCUITest waits for the app to go idle before and after every gesture, which
/// makes touching a still-coasting page impossible. While `skipped` is set,
/// XCUITest's own pre/post-event skip checks answer yes for every app process.
enum UITestQuiescence {
    nonisolated(unsafe) static var skipped = false
    nonisolated(unsafe) private static var installed = false
    static func install() -> Bool {
        if installed { return true }
        guard let process = NSClassFromString("XCUIApplicationProcess") else { return false }
        typealias Check = @convention(c) (AnyObject, Selector) -> Bool
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(process, selector) else { return false }
            let original = unsafeBitCast(method_getImplementation(method), to: Check.self)
            let replacement: @convention(block) (AnyObject) -> Bool = { process in
                skipped || original(process, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        installed = true
        return true
    }
}
