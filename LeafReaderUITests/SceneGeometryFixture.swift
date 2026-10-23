import XCTest
import CoreFoundation

// Explicit public scene-layout fixture; this does not validate simulated device motion.
extension XCTestCase {
    @MainActor func setReaderOrientation(_ direction: UIDeviceOrientation, app: XCUIApplication) {
        XCUIDevice.shared.orientation = direction
        guard app.launchEnvironment["LEAF_UI_SCENE_GEOMETRY_FIXTURE"] == "1", let id = app.launchEnvironment["LEAF_UI_TEST_ID"] else { return }
        // UIKit interface and physical device landscape names are inverted.
        let name = direction == .landscapeLeft ? "landscapeRight" : direction == .landscapeRight ? "landscapeLeft" : "portrait"
        let notification = CFNotificationName("com.leafreader.uitest.geometry.\(id).\(name)" as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notification, nil, nil, true)
        let probe = app.otherElements["uitestSceneGeometry"]
        let expected = direction == .landscapeLeft ? UIInterfaceOrientation.landscapeRight.rawValue : direction == .landscapeRight ? UIInterfaceOrientation.landscapeLeft.rawValue : UIInterfaceOrientation.portrait.rawValue
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = probe.value as? String, let data = value.data(using: .utf8),
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return report["result"] as? String == "applied" && report["effectiveOrientation"] as? Int == expected
        }, object: probe)
        let result = XCTWaiter.wait(for: [applied], timeout: 8)
        let web = app.webViews["bookWebView"]
        let surface = web.exists ? web : app.descendants(matching: .any)["bookPDFView"].firstMatch
        let bookFrame = surface.exists ? surface.frame : CGRect.zero
        let evidence = XCTAttachment(string: "Explicit public scene-geometry fixture: \(probe.value as? String ?? "missing")\napp: \(app.frame), book: \(bookFrame)")
        evidence.name = "Public geometry fixture " + name; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertEqual(result, .completed, "Public scene geometry must apply before physical selection checks")
        if direction.isLandscape {
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
            if surface.exists { XCTAssertGreaterThan(bookFrame.width, bookFrame.height, "Book must really render in landscape") }
        } else { XCTAssertGreaterThan(app.frame.height, app.frame.width) }
    }
    @MainActor func registerSceneGeometryCleanup(app: XCUIApplication) {
        guard app.launchEnvironment["LEAF_UI_SCENE_GEOMETRY_FIXTURE"] == "1" else { return }
        addTeardownBlock { @MainActor in
            if app.state == .runningForeground { self.setReaderOrientation(.portrait, app: app) }
        }
    }
}
