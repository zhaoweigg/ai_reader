import XCTest
import UIKit

/// Run the identical cases serially, then concurrently on separately leased UUIDs.
/// Each runner receives a slot, unique run token and (for paired runs) barrier directory.
final class SimulatorIsolationUITests: XCTestCase {
    private var slot: String { ProcessInfo.processInfo.environment["LEAF_ISOLATION_SLOT"] ?? "unassigned" }
    private var run: String { ProcessInfo.processInfo.environment["LEAF_ISOLATION_RUN"] ?? UUID().uuidString }

    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["LEAF_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEAF_UI_SCENE_GEOMETRY_FIXTURE"] = "1"
        app.launchEnvironment["LEAF_UI_CHAT_MOCK"] = "1"
        app.launchEnvironment["LEAF_UI_ZLIB_MOCK"] = "1"
        app.launch()
        addTeardownBlock { @MainActor in
            if app.state == .runningForeground { self.setReaderOrientation(.portrait, app: app) }
            app.terminate()
        }
        setReaderOrientation(.portrait, app: app)
        return app
    }

    @MainActor private func record(_ stage: String, app: XCUIApplication, extra: [String: String] = [:]) {
        var data = extra
        data["slot"] = slot; data["run"] = run; data["stage"] = stage
        data["time"] = ISO8601DateFormatter().string(from: Date())
        data["appFrame"] = NSCoder.string(for: app.frame)
        data["geometry"] = app.otherElements["uitestSceneGeometry"].value as? String ?? "missing"
        let report = XCTAttachment(string: String(data: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), encoding: .utf8)!)
        report.name = "Isolation \(slot) \(stage)"; report.lifetime = .keepAlways; add(report)
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = "Isolation \(slot) \(stage)"; picture.lifetime = .keepAlways; add(picture)
    }

    /// Host-visible simulator paths only; no service, device or shared app state mutations.
    @MainActor private func rendezvous(_ stage: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LEAF_ISOLATION_BARRIER"] else { return }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(run.utf8).write(to: base.appendingPathComponent("\(stage)-\(slot)"), options: .atomic)
        let peer = base.appendingPathComponent("\(stage)-\(slot == "A" ? "B" : "A")")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: peer, encoding: .utf8)) == self.run
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed, "Both leased runners must reach \(stage)")
    }

    @MainActor private func controls(_ app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                              object: app.staticTexts["Opening your book…"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        for _ in 0..<2 {
            if app.buttons["closeBook"].waitForExistence(timeout: 1) { return }
            let web = app.webViews["bookWebView"]
            let surface = web.exists ? web : app.descendants(matching: .any)["bookPDFView"].firstMatch
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        }
        XCTAssertTrue(app.buttons["closeBook"].waitForExistence(timeout: 5))
    }

    @MainActor private func open(_ flow: String, app: XCUIApplication) {
        XCTAssertTrue(app.buttons["featuredBook"].waitForExistence(timeout: 15))
        if flow == "PDF" {
            let search = app.textFields["librarySearch"]
            search.tap(); search.typeText("Coast")
            app.buttons["book-Notes from the Coast"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["bookPDFView"].firstMatch.waitForExistence(timeout: 15))
        } else {
            app.buttons["featuredBook"].tap()
            XCTAssertTrue(app.webViews["bookWebView"].waitForExistence(timeout: 15))
            let paragraph = app.webViews["bookWebView"].staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "Attention is a way")).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 15), "Wait for the rendered book, not the web-view shell")
            if flow == "Scroll" {
                controls(app); app.buttons["Appearance"].tap()
                app.segmentedControls["appearanceTabs"].buttons["Layout"].tap()
                app.segmentedControls["readingFlow"].buttons[flow].tap()
                XCTAssertTrue(app.segmentedControls["readingFlow"].buttons[flow].isSelected)
                app.navigationBars["Appearance"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
                XCTAssertTrue(app.buttons["openReaderChat"].waitForExistence(timeout: 5))
            }
        }
    }

    @MainActor private func verify(_ flow: String) throws {
        let app = launch(); open(flow, app: app)
        let token = "\(slot)-\(run)-\(flow)"
        try rendezvous(flow + "-clipboard")

        app.buttons["openReaderChat"].tap()
        let input = app.textFields["readerChatInput"].exists ? app.textFields["readerChatInput"] : app.textViews["readerChatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText(token)
        XCTAssertEqual(input.value as? String, token, "Keyboard input must reach only the assigned app")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Per-device software keyboard preference must apply")
        record(flow + " typing", app: app, extra: ["draft": input.value as? String ?? "missing"])
        app.buttons["closeReaderChat"].tap()

        // Deliberately conflicting requests: A landscape/B portrait, then the reverse.
        for step in 0..<2 {
            let landscape = (slot == "A") == (step == 0)
            setReaderOrientation(landscape ? .landscapeLeft : .portrait, app: app)
            try rendezvous(flow + "-orientation-\(step)")
            XCTAssertEqual(app.frame.width > app.frame.height, landscape, "Peer scene request must not rotate this app")
            record(flow + " orientation \(step)", app: app)
        }
        setReaderOrientation(.portrait, app: app)
        app.buttons["openReaderChat"].tap()
        XCTAssertEqual(input.value as? String, token, "Draft must survive peer activity and both scene changes")
        input.tap(); input.typeText("-local")
        let edited = input.value as? String ?? ""
        XCTAssertTrue(edited.contains("-local"))
        XCTAssertEqual(edited.replacingOccurrences(of: "-local", with: ""), token,
                       "Typing at the tapped insertion point must preserve this device's draft")
        record(flow + " restored", app: app)
    }

    @MainActor func testPagesInputSceneAndClipboardIsolation() throws { try verify("Pages") }
    @MainActor func testScrollInputSceneAndClipboardIsolation() throws { try verify("Scroll") }
    @MainActor func testPDFInputSceneAndClipboardIsolation() throws { try verify("PDF") }

    /// Observation rather than a passing claim about automatic simulated rotation.
    @MainActor func testDeviceMotionDeliveryDiagnostic() throws {
        let app = launch()
        try rendezvous("motion-start")
        XCUIDevice.shared.orientation = slot == "A" ? .landscapeLeft : .landscapeRight
        let delay = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in true }, object: nil)
        _ = XCTWaiter.wait(for: [delay], timeout: 1)
        // Wait for asynchronous UIKit delivery without forcing scene geometry.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        record("physical motion observation", app: app, extra: ["deviceOrientation": String(XCUIDevice.shared.orientation.rawValue)])
        try rendezvous("motion-observed")
    }
}
