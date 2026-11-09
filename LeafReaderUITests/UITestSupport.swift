import XCTest

extension XCTestCase {
    /// Attaches a full-screen screenshot that survives in the result bundle for review.
    @MainActor func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// The part of `element` a person can see: inside the app window, above the
    /// tab bar and the keyboard and, unless `overBars` is set, below the
    /// navigation bar. On iOS 27.2 a fully visible SwiftUI control next to the
    /// translucent bars, or inside the frosted chat panel, can report
    /// `isHittable == false`, so rendered geometry is the oracle for "on screen".
    /// `overBars` is for panels that float over the navigation bar.
    @MainActor func visibleFrame(of element: XCUIElement, in app: XCUIApplication, overBars: Bool = false) -> CGRect {
        guard element.exists else { return .zero }
        let bounds = app.frame
        var top = bounds.minY, bottom = bounds.maxY
        let navigation = app.navigationBars.firstMatch
        if !overBars, navigation.exists, navigation.frame.height > 0 { top = max(top, navigation.frame.maxY) }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, tabBar.frame.height > 0, tabBar.frame.minY > bounds.midY { bottom = min(bottom, tabBar.frame.minY) }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.height > 0, keyboard.frame.minY > top { bottom = min(bottom, keyboard.frame.minY) }
        let visible = element.frame.intersection(CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top)))
        return visible.isNull ? .zero : visible
    }

    /// Asserts that `element` is fully on screen in the sense of `visibleFrame`:
    /// none of it is clipped by the window, the bars or the keyboard. Attaches the
    /// geometry so a failure shows what covered it.
    @MainActor func assertOnScreen(_ element: XCUIElement, in app: XCUIApplication, overBars: Bool = false, _ message: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let visible = visibleFrame(of: element, in: app, overBars: overBars), frame = element.frame
        let note = XCTAttachment(string: "\(message)\nelement \(element.identifier): \(frame); visible: \(visible); app: \(app.frame); "
            + "keyboard: \(app.keyboards.firstMatch.exists ? "\(app.keyboards.firstMatch.frame)" : "none"); hittable: \(element.isHittable)")
        note.name = "On-screen geometry: " + message; note.lifetime = .keepAlways; add(note)
        XCTAssertTrue(element.exists && frame.width > 0 && frame.height > 0, message + " (missing)", file: file, line: line)
        XCTAssertEqual(visible.width, frame.width, accuracy: 1, message + " (clipped horizontally)", file: file, line: line)
        XCTAssertEqual(visible.height, frame.height, accuracy: 1, message + " (clipped vertically)", file: file, line: line)
    }

    /// Taps the centre of the visible part of `element`. On iOS 27.2 XCUITest's own
    /// tap on some SwiftUI rows (a Form Menu row) lands nowhere and does nothing.
    @MainActor func tapVisibleCentre(of element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let visible = visibleFrame(of: element, in: app)
        XCTAssertGreaterThanOrEqual(visible.width, 20); XCTAssertGreaterThanOrEqual(visible.height, 20)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX - app.frame.minX, dy: visible.midY - app.frame.minY)).tap()
    }

    /// Presses the centre of the visible part of `element`, for long presses on
    /// controls whose own hit point is unreliable (see `visibleFrame`).
    @MainActor func pressVisibleCentre(of element: XCUIElement, in app: XCUIApplication, duration: TimeInterval) {
        let visible = visibleFrame(of: element, in: app)
        XCTAssertGreaterThanOrEqual(visible.width, 20); XCTAssertGreaterThanOrEqual(visible.height, 20)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX - app.frame.minX, dy: visible.midY - app.frame.minY)).press(forDuration: duration)
    }
}

extension XCUIApplication {
    /// Selects a tab by tapping the centre of its own button. On the iOS 27
    /// floating tab bar neighbouring tab frames overlap, and XCUITest's chosen hit
    /// point can land on the neighbour (Settings taps selected Bookmarks). The
    /// first tap always happens, so re-tapping the current tab still pops its
    /// navigation; a further tap is made only if the tab did not become selected.
    @MainActor func selectTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Missing tab: \(name)", file: file, line: line)
        for attempt in 0..<3 {
            if attempt > 0, tab.isSelected { break }
            let target = tab.frame
            coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.midX - frame.minX, dy: target.midY - frame.minY)).tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: tab)
            if XCTWaiter.wait(for: [selected], timeout: 3) == .completed { break }
        }
        XCTAssertTrue(tab.isSelected, "Tab did not become selected: \(name)", file: file, line: line)
    }
}
