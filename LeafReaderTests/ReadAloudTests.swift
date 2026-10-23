import XCTest
import AVFoundation
import PDFKit
@testable import LeafReader

@MainActor private final class RecordingSpeaker: ReadAloudSpeaking {
    var finished: (() -> Void)?
    var progressed: ((NSRange) -> Void)?
    var spoken: [String] = []
    var speeds: [Double] = []
    var paused = false
    var hasCurrent = false
    func speak(_ text: String, language: String, voice: String, speed: Double) throws { spoken.append(text); speeds.append(speed); paused = false; hasCurrent = true }
    func pause() { if hasCurrent { paused = true } }
    func resume() -> Bool { let result = paused; paused = false; return result }
    func stop() { paused = false; hasCurrent = false }
}

@MainActor final class ReadAloudTests: XCTestCase {
    private func passage(_ index: Int, text: String? = nil) -> ReadAloudPassage {
        ReadAloudPassage(text: text ?? "Passage \(index)", locator: "position:\(index)", nextLocator: "position:\(index + 1)", language: "en-US", label: "Chapter \(index)")
    }
    private func setup() -> (ReadAloudSession, RecordingSpeaker, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "ReadAloudTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let speaker = RecordingSpeaker()
        let session = ReadAloudSession(bookmarkURL: directory.appendingPathComponent("bookmark.json"), defaults: defaults, speaker: speaker)
        addTeardownBlock { @MainActor in session.stop(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        return (session, speaker, directory, defaults)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    func testRetainsOnlyCurrentAndOnePrefetchedPassageAndFinishesAtBookEnd() async throws {
        let (session, speaker, directory, _) = setup()
        var calls: [String?] = []
        session.source = { [self] locator in
            calls.append(locator)
            let index = Int(locator?.split(separator: ":").last ?? "0") ?? 0
            return index < 3 ? passage(index) : nil
        }
        session.start(); try await wait { calls.count == 2 && session.state == .playing }
        XCTAssertEqual(speaker.spoken, ["Passage 0"]); XCTAssertEqual(calls.count, 2)
        speaker.finished?(); try await wait { session.passage?.locator == "position:1" }
        speaker.finished?(); try await wait { session.passage?.locator == "position:2" }
        speaker.finished?(); try await wait { session.state == .finished }
        XCTAssertEqual(speaker.spoken, ["Passage 0", "Passage 1", "Passage 2"])
        XCTAssertNil(session.bookmark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bookmark.json").path))
    }
    func testPauseDuringSourceLoadDoesNotStartUntilResumed() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { [self] locator in
            try await Task.sleep(for: .milliseconds(100))
            return locator == nil ? passage(0) : nil
        }
        session.start(); session.pause()
        try await wait { session.passage != nil }
        XCTAssertEqual(session.state, .paused); XCTAssertTrue(speaker.spoken.isEmpty)
        session.resume(); XCTAssertEqual(speaker.spoken, ["Passage 0"])
    }
    func testReplacingStartIgnoresCancelledLateSourceCompletion() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { [self] locator in
            if locator == "old" { try? await Task.sleep(for: .milliseconds(150)); return passage(0, text: "Old request") }
            if locator == "new" { return passage(1, text: "New request") }
            return nil
        }
        session.start(at: "old"); try await Task.sleep(for: .milliseconds(20)); session.start(at: "new")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(speaker.spoken, ["New request"])
        XCTAssertEqual(session.passage?.locator, "position:1")
    }
    func testSpeedVoiceChangesResumeAtWordAndSavedCursorSurvivesReopen() async throws {
        let (session, speaker, directory, defaults) = setup()
        let value = passage(2, text: "Alpha 😀 beta gamma")
        session.source = { locator in locator == "position:3" ? nil : value }
        session.start(at: "position:2"); try await wait { session.state == .playing }
        speaker.progressed?(NSRange(location: 9, length: 4))
        session.speed = 1.5
        XCTAssertEqual(speaker.spoken.last, "beta gamma"); XCTAssertEqual(speaker.speeds.last, 1.5)
        session.pause(); session.voice = "test.voice"
        let count = speaker.spoken.count
        session.resume(); XCTAssertEqual(speaker.spoken.count, count + 1)
        session.stop()
        let reopenedSpeaker = RecordingSpeaker()
        let reopened = ReadAloudSession(bookmarkURL: directory.appendingPathComponent("bookmark.json"), defaults: defaults, speaker: reopenedSpeaker)
        reopened.source = { _ in value }
        XCTAssertEqual(reopened.bookmark?.offset, 9); XCTAssertEqual(reopened.speed, 1.5); XCTAssertEqual(reopened.voice, "test.voice")
        reopened.resumeSaved(); try await wait { reopened.state == .playing }
        XCTAssertEqual(reopenedSpeaker.spoken.first, "beta gamma"); reopened.stop()
    }
    func testPreviousAndNextWhilePausedKeepAudioPaused() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { [self] locator in passage(Int(locator?.split(separator: ":").last ?? "0") ?? 0) }
        session.start(); try await wait { session.state == .playing }
        session.next(); try await wait { session.passage?.locator == "position:1" }
        session.pause(); let count = speaker.spoken.count
        session.next(); try await wait { session.passage?.locator == "position:2" }
        XCTAssertEqual(session.state, .paused); XCTAssertEqual(speaker.spoken.count, count)
        session.previous(); try await wait { session.passage?.locator == "position:1" }
        XCTAssertEqual(session.state, .paused); XCTAssertEqual(speaker.spoken.count, count)
    }
    func testStopCancelsPrefetchAndDoesNotPlayLateCompletion() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { [self] locator in
            if locator != nil { try? await Task.sleep(for: .milliseconds(150)); return passage(1) }
            return passage(0)
        }
        session.start(); try await wait { session.state == .playing }
        session.stop(); try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(session.state, .idle); XCTAssertFalse(session.isPresented); XCTAssertEqual(speaker.spoken.count, 1)
    }
    func testAudioInterruptionAndHeadphoneDisconnectPauseWithoutLosingPosition() async throws {
        let (session, _, _, _) = setup()
        session.source = { [self] locator in locator == nil ? passage(0) : nil }
        session.start(); try await wait { session.state == .playing }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await wait { session.state == .paused }; XCTAssertNotNil(session.bookmark)
        session.resume()
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        try await wait { session.state == .paused }; XCTAssertEqual(session.bookmark?.locator, "position:0")
    }
    func testSourceFailureCanBeReplacedWithoutAffectingBookState() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { _ in throw ReadAloudError.noText }
        session.start(); try await wait { session.state == .failed }
        XCTAssertNotNil(session.error); XCTAssertTrue(speaker.spoken.isEmpty)
        session.source = { [self] _ in passage(3) }
        session.start(at: "position:3"); try await wait { session.state == .playing }; XCTAssertNil(session.error)
    }
    func testPDFSourceStartsAtSelectedCharacterAndContinuesThroughEmptyPages() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        let data = renderer.pdfData { context in
            context.beginPage(); ("First beginning. Selected words here. Last line." as NSString).draw(at: CGPoint(x: 25, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            context.beginPage()
            context.beginPage(); ("Next chapter text." as NSString).draw(at: CGPoint(x: 25, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(document.page(at: 0)?.string) as NSString
        let offset = text.range(of: "Selected").location
        let firstValue = try await PDFReadAloudSource.passage(in: document, at: "pdf:0:\(offset)")
        let first = try XCTUnwrap(firstValue)
        XCTAssertTrue(first.text.hasPrefix("Selected words here.")); XCTAssertFalse(first.text.contains("First beginning"))
        let nextValue = try await PDFReadAloudSource.passage(in: document, at: first.nextLocator)
        let next = try XCTUnwrap(nextValue)
        XCTAssertTrue(next.text.contains("Next chapter text")); XCTAssertEqual(next.locator, "pdf:2:0")
        let end = try await PDFReadAloudSource.passage(in: document, at: next.nextLocator); XCTAssertNil(end)
        XCTAssertNil(PDFReadAloudSource.cursor("pdf:-1:0")); XCTAssertNil(PDFReadAloudSource.cursor("pdf:0:-1"))
    }
    func testSystemVoiceProducesRealAudioBuffers() async throws {
        let synthesizer = AVSpeechSynthesizer()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"), "A system English voice must be installed for this integration check")
        let utterance = AVSpeechUtterance(string: "Leaf can read this book aloud."); utterance.voice = voice
        let complete = expectation(description: "Synthesized real PCM audio")
        complete.assertForOverFulfill = false
        synthesizer.write(utterance) { buffer in
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 { complete.fulfill() }
        }
        await fulfillment(of: [complete], timeout: 20)
        synthesizer.stopSpeaking(at: .immediate)
    }
}
