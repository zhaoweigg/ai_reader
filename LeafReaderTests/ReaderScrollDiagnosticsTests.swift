import XCTest
@testable import LeafReader

@MainActor
final class ReaderScrollDiagnosticsTests: XCTestCase {
    func testStaysOffUnlessALaunchEnablesItAndExpiresAfterADay() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReaderScrollDiagnosticsTests.\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let diagnostics = ReaderScrollDiagnostics()
        let start = Date()
        diagnostics.configure(defaults: defaults, environment: [:], directory: directory, now: start)
        XCTAssertFalse(diagnostics.isEnabled, "Ordinary launches never record")
        diagnostics.configure(defaults: defaults, environment: ["LEAF_SCROLL_DIAGNOSTICS": "1"], directory: directory, now: start)
        XCTAssertTrue(diagnostics.isEnabled)
        diagnostics.configure(defaults: defaults, environment: [:], directory: directory, now: start.addingTimeInterval(3600))
        XCTAssertTrue(diagnostics.isEnabled, "Relaunching from the Home Screen keeps recording for the enabled day")
        diagnostics.configure(defaults: defaults, environment: [:], directory: directory, now: start.addingTimeInterval(25 * 3600))
        XCTAssertFalse(diagnostics.isEnabled, "Recording ends by itself after a day")
    }

    func testRecordsTouchesAndStopsAsJSON() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReaderScrollDiagnosticsTests.\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let diagnostics = ReaderScrollDiagnostics()
        diagnostics.configure(defaults: defaults, environment: ["LEAF_SCROLL_DIAGNOSTICS": "1"], directory: directory)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        scroll.contentSize = CGSize(width: 300, height: 3000)
        scroll.contentOffset = CGPoint(x: 0, y: 120)
        let touch = UITouch()
        diagnostics.touch(touch, scrolls: [scroll], moving: [scroll]) { _ in 0.01 }
        diagnostics.touch(touch, scrolls: [scroll], moving: [scroll]) { _ in 0.01 }
        diagnostics.afterStop([scroll])
        diagnostics.flush(force: true)
        let data = try Data(contentsOf: XCTUnwrap(diagnostics.file))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.filter { $0["event"] as? String == "touch" }.count, 1, "Both tap recognizers' questions about one touch are recorded once")
        let touchEvent = try XCTUnwrap(events.first { $0["event"] as? String == "touch" })
        XCTAssertEqual(touchEvent["result"] as? String, "stop")
        let state = try XCTUnwrap((touchEvent["scrolls"] as? [[String: Any]])?.first)
        XCTAssertEqual(state["y"] as? Double, 120)
        XCTAssertEqual(state["moving"] as? Bool, true)
        XCTAssertEqual(state["coastAge"] as? Double, 0.01)
        XCTAssertTrue(events.contains { $0["event"] as? String == "stopped" })
    }
}
