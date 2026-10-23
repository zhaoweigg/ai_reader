import XCTest

final class AnnotationUITests: XCTestCase {
    @MainActor private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
    @MainActor private func surface(_ app: XCUIApplication) -> XCUIElement {
        app.webViews["bookWebView"].exists ? app.webViews["bookWebView"] : app.descendants(matching: .any)["bookPDFView"].firstMatch
    }
    @MainActor private func controls(_ app: XCUIApplication) {
        XCTAssertTrue(surface(app).waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Opening your book…"])
        waitForExpectations(timeout: 20)
        if !app.buttons["closeBook"].exists {
            surface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if !app.buttons["closeBook"].waitForExistence(timeout: 2) {
                capture("Reader controls setup after rotation")
                surface(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            }
        }
        XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 5))
    }
    @MainActor private func appearance(_ app: XCUIApplication, theme: String, flow: String? = nil) {
        controls(app); app.buttons["Appearance"].tap()
        if let flow {
            app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
            app.segmentedControls["readingFlow"].buttons[flow].tap()
        }
        app.segmentedControls["appearanceTabs"].buttons["Themes"].tap()
        app.buttons[theme + " theme"].tap()
        app.navigationBars["Appearance"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.segmentedControls["appearanceTabs"])
        waitForExpectations(timeout: 5)
    }
    @MainActor private func select(_ action: String, app: XCUIApplication, pdf: Bool) {
        let paragraph = surface(app).staticTexts.containing(NSPredicate(format: "label CONTAINS %@", pdf ? "Before the town" : "Attention is a way")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 8))
        let point = paragraph.coordinate(withNormalizedOffset: CGVector(dx: pdf ? 0.15 : 0.3, dy: pdf ? 0.25 : 0.1))
        point.press(forDuration: 1.2)
        let menu = app.menuItems[action]
        let button = app.buttons.matching(NSPredicate(format: "label == %@", action)).firstMatch
        // The native selection menu paginates when Listen from here is added.
        // Follow its actual Forward control rather than assuming every action
        // fits on the first page on every device/flow.
        for _ in 0..<3 where !menu.exists && !button.exists {
            let forward = app.buttons["Forward"]
            guard forward.waitForExistence(timeout: 2), forward.isHittable else { break }
            forward.tap()
            _ = menu.waitForExistence(timeout: 2)
        }
        if !menu.waitForExistence(timeout: 2) && !button.exists {
            capture("Missing " + action + " selection action")
            let state = XCTAttachment(string: app.debugDescription); state.name = "Selection hierarchy"; state.lifetime = .keepAlways; add(state)
        }
        let row = app.scrollViews["expandedSelectionMenu"]
        for _ in 0..<3 where row.exists && (!button.isHittable || !row.frame.insetBy(dx: -1, dy: 0).contains(button.frame)) { row.swipeLeft() }
        let target = menu.exists ? menu : button
        XCTAssertTrue(target.waitForExistence(timeout: 3)); target.tap()
    }
    @MainActor private func chatInput(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
    }
    @MainActor private func revealAnnotationControl(_ control: XCUIElement, app: XCUIApplication) {
        let form = app.descendants(matching: .any)["annotationForm"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<4 where !control.isHittable {
            // Scroll the form beside the text editor, whose own scrolling must stay independent.
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.85))
                .press(forDuration: 0.1, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.2)))
        }
        XCTAssertTrue(control.isHittable)
    }
    @MainActor func testHighlightsAndNotesInPages() { verify(flow: "Pages") }
    @MainActor func testHighlightsAndNotesInScroll() { verify(flow: "Scroll") }
    @MainActor func testHighlightsAndNotesInPDF() { verify(flow: "PDF") }

    @MainActor private func verify(flow: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["LEAF_UI_TEST_ID": UUID().uuidString, "LEAF_UI_CHAT_MOCK": "1", "LEAF_UI_ZLIB_MOCK": "1", "LEAF_UI_SCENE_GEOMETRY_FIXTURE": "1"]
        app.launch()
        registerSceneGeometryCleanup(app: app)
        let pdf = flow == "PDF"
        if pdf {
            let field = app.textFields["librarySearch"]; XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap(); field.typeText("Coast"); app.buttons["book-Notes from the Coast"].tap()
            controls(app); app.buttons["nextPage"].tap()
        } else { app.buttons["featuredBook"].tap(); appearance(app, theme: "Day", flow: flow) }
        XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 10))
        app.buttons["openReaderChat"].tap()
        chatInput(app).tap(); chatInput(app).typeText("Keep my reading question")
        app.buttons["Hide keyboard"].tap()
        select("Add Note", app: app, pdf: pdf)
        XCTAssertTrue(app.staticTexts["annotationQuote"].waitForExistence(timeout: 5))
        capture(flow + " selected passage in note editor")
        app.buttons["cancelAnnotation"].tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
        XCTAssertEqual(chatInput(app).value as? String, "Keep my reading question")

        select("Highlight", app: app, pdf: pdf)
        XCTAssertTrue(app.buttons["closeReaderChat"].exists)
        XCTAssertEqual(chatInput(app).value as? String, "Keep my reading question")
        capture(flow + " highlighted text with chat open")
        select("Add Note", app: app, pdf: pdf)
        let note = app.textViews["annotationNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap()
        let marker = "My " + flow + " reading note"
        note.typeText(marker)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(flow + " composing a persistent note")
        app.buttons["Green highlight"].tap(); app.buttons["saveAnnotation"].tap()
        XCTAssertTrue(app.buttons["closeReaderChat"].waitForExistence(timeout: 5))
        XCTAssertEqual(chatInput(app).value as? String, "Keep my reading question")
        app.buttons["closeReaderChat"].tap()

        if !pdf { appearance(app, theme: "Paper") }
        controls(app); app.buttons["Saved"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 5))
        capture(flow + " saved highlight and note")
        app.buttons["Done"].tap()
        if !pdf { appearance(app, theme: "Night") }
        setReaderOrientation(.landscapeLeft, app: app)
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        capture(flow + " highlight after theme and landscape change")
        controls(app); app.buttons["Saved"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editAnnotation-")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        XCTAssertTrue(app.buttons["saveAnnotation"].waitForExistence(timeout: 5))
        app.buttons["Blue highlight"].tap()
        revealAnnotationControl(app.textViews["annotationNote"], app: app)
        XCTAssertEqual(app.textViews["annotationNote"].value as? String, marker)
        capture(flow + " landscape note editor")
        app.buttons["saveAnnotation"].tap()
        controls(app); app.buttons["closeBook"].tap()
        setReaderOrientation(.portrait, app: app); app.terminate(); app.launch()

        app.tabBars.buttons["Bookmarks"].tap()
        app.segmentedControls["librarySavedPassageFilter"].buttons["Highlights & notes"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        capture(flow + " note survives app relaunch")
        saved.tap()
        XCTAssertTrue(surface(app).waitForExistence(timeout: 15))
        controls(app); app.buttons["Saved"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editAnnotation-")).firstMatch.tap()
        let remove = app.buttons["deleteAnnotation"]
        revealAnnotationControl(remove, app: app); remove.tap()
        controls(app); app.buttons["Saved"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.exists)
        capture(flow + " saved note removed")
    }
}
