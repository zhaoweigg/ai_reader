import XCTest
import AVFoundation
import PDFKit
import UIKit
@testable import LeafReader

@MainActor final class RecordingSpeaker: ReadAloudSpeaking {
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

/// Stands in for the Lock Screen / Control Center player.
@MainActor final class RecordingNowPlaying: ReadAloudNowPlayingPresenting {
    var handler: ((ReadAloudRemoteCommand) -> Void)?
    var shown: [ReadAloudNowPlayingInfo] = []
    var artworks: [UIImage?] = []
    var cleared = 0
    func show(_ info: ReadAloudNowPlayingInfo, artwork: UIImage?) { shown.append(info); artworks.append(artwork) }
    func clear() { cleared += 1 }
}

@MainActor final class ReadAloudTests: XCTestCase {
    private func passage(_ index: Int, text: String? = nil) -> ReadAloudPassage {
        ReadAloudPassage(text: text ?? "Passage \(index)", locator: "position:\(index)", nextLocator: "position:\(index + 1)", language: "en-US", label: "Chapter \(index)")
    }
    private func setup(nowPlaying: RecordingNowPlaying? = nil) -> (ReadAloudSession, RecordingSpeaker, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "ReadAloudTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let speaker = RecordingSpeaker()
        let session = ReadAloudSession(bookmarkURL: directory.appendingPathComponent("bookmark.json"), defaults: defaults, speaker: speaker, nowPlaying: nowPlaying)
        addTeardownBlock { @MainActor in session.stop(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        return (session, speaker, directory, defaults)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    func testLockScreenPlayerShowsTheBookAndFollowsPlaybackAndPassages() async throws {
        let player = RecordingNowPlaying()
        let (session, speaker, directory, _) = setup(nowPlaying: player)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cover = directory.appendingPathComponent("cover.png")
        try UIGraphicsImageRenderer(size: CGSize(width: 12, height: 18)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 12, height: 18)) }.write(to: cover)
        session.book = ReadAloudBookInfo(title: "The Art of Noticing", author: "Leaf Editions", coverURL: cover)
        XCTAssertEqual(player.shown, [], "Nothing plays yet, so the Lock Screen stays empty")
        XCTAssertGreaterThan(player.cleared, 0)
        session.source = { [self] locator in
            let index = Int(locator?.split(separator: ":").last ?? "0") ?? 0
            return index < 3 ? passage(index) : nil
        }
        session.start(); try await wait { session.state == .playing }
        var info = try XCTUnwrap(player.shown.last)
        XCTAssertEqual(info, ReadAloudNowPlayingInfo(title: "The Art of Noticing", author: "Leaf Editions", chapter: "Chapter 0", isPlaying: true, canGoNext: true, canGoBack: false))
        // The renderer writes at the screen scale, so compare proportions, not points.
        let artwork = try XCTUnwrap(player.artworks.last ?? nil, "The cover must reach the Lock Screen")
        XCTAssertEqual(artwork.size.width / artwork.size.height, 12.0 / 18.0, accuracy: 0.01)
        session.pause()
        info = try XCTUnwrap(player.shown.last)
        XCTAssertFalse(info.isPlaying); XCTAssertEqual(info.chapter, "Chapter 0")
        session.resume(); XCTAssertEqual(player.shown.last?.isPlaying, true)
        speaker.finished?(); try await wait { session.passage?.locator == "position:1" && session.state == .playing }
        info = try XCTUnwrap(player.shown.last)
        XCTAssertEqual(info.chapter, "Chapter 1"); XCTAssertTrue(info.canGoBack); XCTAssertTrue(info.isPlaying)
        let shownBeforeStop = player.shown.count, clearedBeforeStop = player.cleared
        session.stop()
        XCTAssertGreaterThan(player.cleared, clearedBeforeStop, "Stopping takes the player off the Lock Screen")
        XCTAssertEqual(player.shown.count, shownBeforeStop)
        // Reaching the end of the book clears it as well.
        session.start(at: "position:2"); try await wait { session.state == .playing }
        let clearedBeforeEnd = player.cleared
        speaker.finished?(); try await wait { session.state == .finished }
        XCTAssertGreaterThan(player.cleared, clearedBeforeEnd)
    }
    func testRemoteCommandsDrivePlaybackLikeThePlayerButtons() async throws {
        let player = RecordingNowPlaying()
        let (session, speaker, _, _) = setup(nowPlaying: player)
        session.source = { [self] locator in
            let index = Int(locator?.split(separator: ":").last ?? "0") ?? 0
            return index < 4 ? passage(index) : nil
        }
        let send = try XCTUnwrap(player.handler)
        send(.play); XCTAssertEqual(session.state, .idle, "Play before a narration starts does nothing")
        session.start(); try await wait { session.state == .playing }
        send(.pause); XCTAssertEqual(session.state, .paused); XCTAssertTrue(speaker.paused)
        send(.play); XCTAssertEqual(session.state, .playing); XCTAssertFalse(speaker.paused)
        send(.toggle); XCTAssertEqual(session.state, .paused)
        send(.next); try await wait { session.passage?.locator == "position:1" }
        XCTAssertEqual(session.state, .paused, "Next from the Lock Screen keeps a paused narration paused")
        send(.toggle); XCTAssertEqual(session.state, .playing)
        send(.next); try await wait { session.passage?.locator == "position:2" && session.state == .playing }
        send(.previous); try await wait { session.passage?.locator == "position:1" && session.state == .playing }
        XCTAssertEqual(player.shown.last?.chapter, "Chapter 1")
        XCTAssertEqual(player.shown.last?.canGoBack, true)
    }
    func testAppleSpeedPersistsAcrossBooksAndReopening() {
        let (session, _, _, defaults) = setup()
        session.speed = 0.75
        let reopened = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
        XCTAssertEqual(reopened.speed, 0.75)
        reopened.speed = 1.75
        XCTAssertEqual(ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker()).speed, 1.75)
    }
    func testRetiredEngineChoiceKeepsAppleSpeedAndRemovesOldPreferences() {
        for engine in ["kokoro", "system", "unknown"] {
            let (_, _, _, defaults) = setup()
            defaults.set(engine, forKey: "audio.engine")
            defaults.set("zf_003", forKey: "audio.kokoroVoice")
            defaults.set(1.75, forKey: "audio.speed.kokoro")
            defaults.set(0.75, forKey: "audio.speed.system")
            let migrated = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
            XCTAssertEqual(migrated.speed, 0.75)
            for key in ["audio.engine", "audio.kokoroVoice", "audio.speed.kokoro"] { XCTAssertNil(defaults.object(forKey: key)) }
        }
    }
    func testLegacySharedSpeedMigratesOnlyWhenAppleSpeedIsMissingOrInvalid() {
        for legacy in [0.5, 1.25, 2.0] {
            let (_, _, _, defaults) = setup()
            defaults.removeObject(forKey: "audio.speed.system"); defaults.set(legacy, forKey: "audio.speed")
            let migrated = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
            XCTAssertEqual(migrated.speed, legacy)
            migrated.speed = 1.5
            XCTAssertEqual(ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker()).speed, 1.5)
        }
        for invalid in [0.0, 3.0, Double.infinity, Double.nan] {
            let (_, _, _, defaults) = setup()
            defaults.set(invalid, forKey: "audio.speed.system"); defaults.set(invalid, forKey: "audio.speed")
            XCTAssertEqual(ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker()).speed, 1)
        }
    }
    func testSpeedChangeRestartsOnceAtTheCursorAndDoesNotUnpause() async throws {
        let (session, speaker, directory, defaults) = setup()
        let value = passage(2, text: "Alpha 😀 beta gamma")
        session.source = { locator in locator == "position:3" ? nil : value }
        session.start(at: "position:2", offset: 9)
        try await wait { session.state == .playing }
        let count = speaker.spoken.count
        session.speed = 0.75
        XCTAssertEqual(speaker.spoken.count, count + 1)
        XCTAssertEqual(speaker.spoken.last, "beta gamma"); XCTAssertEqual(speaker.speeds.last, 0.75)
        speaker.progressed?(NSRange(location: 5, length: 1))
        session.pause(); session.speed = 1.5
        XCTAssertEqual(session.state, .paused); XCTAssertEqual(speaker.spoken.count, count + 1)
        session.resume()
        XCTAssertEqual(speaker.spoken.last, "gamma"); XCTAssertEqual(speaker.speeds.last, 1.5)
        session.stop()
        let reopened = ReadAloudSession(bookmarkURL: directory.appendingPathComponent("bookmark.json"), defaults: defaults, speaker: RecordingSpeaker())
        XCTAssertEqual(reopened.bookmark?.offset, 14); XCTAssertEqual(reopened.speed, 1.5)
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
    func testSpokenRangesTrackResumeOffsetsStayPausedAndClearWithoutChangingSavedCursor() async throws {
        let (session, speaker, _, _) = setup()
        let value = passage(0, text: "Alpha 😀 beta gamma")
        session.source = { locator in locator == "position:1" ? nil : value }
        var highlighted: NSRange?, latestPassage: ReadAloudPassage?, following = false
        session.highlight = { passage, range, follow in latestPassage = passage; highlighted = passage == nil ? nil : range; following = follow }
        session.start(); try await wait { session.state == .playing }
        speaker.progressed?(NSRange(location: 9, length: 4))
        XCTAssertEqual(highlighted, NSRange(location: 9, length: 4)); XCTAssertEqual(session.spokenText, "beta")
        XCTAssertEqual(latestPassage, value); XCTAssertTrue(following)
        session.pause(); speaker.progressed?(NSRange(location: 14, length: 5))
        XCTAssertEqual(session.spokenText, "beta"); XCTAssertEqual(highlighted?.location, 9)
        session.followsText = false; XCTAssertFalse(following)
        session.speed = 1.5; session.resume()
        speaker.progressed?(NSRange(location: 5, length: 5))
        XCTAssertEqual(highlighted, NSRange(location: 14, length: 5)); XCTAssertEqual(session.spokenText, "gamma")
        session.stop(); XCTAssertNil(highlighted); XCTAssertNil(latestPassage); XCTAssertEqual(session.spokenText, "")
        XCTAssertEqual(session.bookmark?.offset, 14)
        speaker.progressed?(NSRange(location: 0, length: 5)); XCTAssertNil(highlighted)
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
        session.pause(); session.voice = ""
        session.followsText = false
        let count = speaker.spoken.count
        session.resume(); XCTAssertEqual(speaker.spoken.count, count + 1)
        session.stop()
        let reopenedSpeaker = RecordingSpeaker()
        let reopened = ReadAloudSession(bookmarkURL: directory.appendingPathComponent("bookmark.json"), defaults: defaults, speaker: reopenedSpeaker)
        reopened.source = { _ in value }
        XCTAssertEqual(reopened.bookmark?.offset, 9); XCTAssertEqual(reopened.speed, 1.5); XCTAssertEqual(reopened.voice, "")
        XCTAssertFalse(reopened.followsText)
        reopened.resumeSaved(); try await wait { reopened.state == .playing }
        XCTAssertEqual(reopenedSpeaker.spoken.first, "beta gamma"); reopened.stop()
    }
    func testInitialHighlightUsesSavedOffsetWithoutACompetingParagraphReveal() async throws {
        let (session, speaker, _, _) = setup()
        let value = passage(0, text: "Alpha 😀 beta gamma")
        session.source = { locator in locator == "position:1" ? nil : value }
        var ranges: [NSRange] = [], reveals: [String] = []
        session.highlight = { passage, range, _ in if passage != nil { ranges.append(range) } }
        session.reveal = { reveals.append($0) }
        session.start(at: value.locator, offset: 10)
        try await wait { session.state == .playing }
        XCTAssertEqual(ranges.last, NSRange(location: 10, length: 1))
        XCTAssertEqual(speaker.spoken.last, "eta gamma")
        XCTAssertTrue(reveals.isEmpty, "The line-following bridge owns navigation; a delayed paragraph reveal must not move it back")
        session.start(at: value.locator, offset: 7) // Low surrogate of the emoji.
        try await wait { session.state == .playing }
        XCTAssertEqual(ranges.last, NSRange(location: 6, length: 2))
        XCTAssertEqual(speaker.spoken.last, "😀 beta gamma")
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
    func testBackgroundKeepsNarratingAcrossPassagesAndRestoresLatestHighlight() async throws {
        let (session, speaker, directory, _) = setup()
        var rendered: [(String?, NSRange)] = [], sourceCalls = 0
        session.highlight = { passage, range, _ in rendered.append((passage?.locator, range)) }
        session.source = { [self] locator in
            sourceCalls += 1
            let index = Int(locator?.split(separator: ":").last ?? "0") ?? 0
            return index < 4 ? passage(index, text: "Alpha beta gamma") : nil
        }
        session.start(); try await wait { session.state == .playing && sourceCalls == 2 }
        session.setForeground(false)
        let renderCount = rendered.count
        speaker.progressed?(NSRange(location: 6, length: 4))
        XCTAssertEqual(session.state, .playing); XCTAssertFalse(speaker.paused)
        for index in 1...2 {
            speaker.finished?()
            try await wait { session.passage?.locator == "position:\(index)" && session.state == .playing }
        }
        speaker.progressed?(NSRange(location: 11, length: 5))
        session.followsText = false; session.followsText = true
        XCTAssertEqual(rendered.count, renderCount, "No hidden WebKit/PDF highlight or page navigation")
        XCTAssertEqual(speaker.spoken.count, 3)
        session.pause()
        XCTAssertEqual(session.bookmark, ReadAloudBookmark(locator: "position:2", offset: 11))
        let url = directory.appendingPathComponent("bookmark.json")
        XCTAssertEqual(try JSONDecoder().decode(ReadAloudBookmark.self, from: Data(contentsOf: url)), session.bookmark)
        // Simulator persists the cursor but supplies no iPhone protection metadata.
        // Assert the actual data-protection attribute on physical-device test runs.
        #if !targetEnvironment(simulator)
        let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
        XCTAssertEqual((protection as? FileProtectionType)?.rawValue ?? protection as? String,
                       FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
                       "The listening cursor remains writable after locking")
        #endif
        session.setForeground(true)
        XCTAssertEqual(session.state, .paused, "Unlocking must not undo a user pause")
        XCTAssertEqual(rendered.count, renderCount + 1)
        XCTAssertEqual(rendered.last?.0, "position:2"); XCTAssertEqual(rendered.last?.1, NSRange(location: 11, length: 5))
        session.setForeground(true); XCTAssertEqual(rendered.count, renderCount + 1)
    }
    func testBackgroundLoadingRespectsPauseAndBookEndClearsHighlightOnReturn() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { [self] locator in
            try await Task.sleep(for: .milliseconds(80))
            return locator == nil ? passage(0) : nil
        }
        var cleared = 0
        session.highlight = { passage, _, _ in if passage == nil { cleared += 1 } }
        session.start(); session.setForeground(false); session.pause()
        try await wait { session.passage != nil }
        XCTAssertEqual(session.state, .paused); XCTAssertTrue(speaker.spoken.isEmpty)
        session.resume(); XCTAssertEqual(session.state, .playing)
        let before = cleared
        speaker.finished?(); try await wait { session.state == .finished }
        XCTAssertEqual(cleared, before, "An offscreen completion defers presentation")
        session.setForeground(true)
        XCTAssertEqual(cleared, before + 1); XCTAssertNil(session.bookmark)
        XCTAssertEqual(session.state, .finished)
    }
    func testDictationPausesPlaybackSynchronouslyAndKeepsBookmark() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { [self] _ in passage(0) }
        session.start(); try await wait { session.state == .playing }
        NotificationCenter.default.post(name: ChatDictationSession.willRecord, object: nil)
        XCTAssertEqual(session.state, .paused, "Pause before dictation takes the shared audio session")
        XCTAssertTrue(speaker.paused); XCTAssertEqual(session.bookmark?.locator, "position:0")
        XCTAssertEqual(speaker.spoken.count, 1)
    }
    func testPlaybackResumeRestoresAudioCategoryAfterDictation() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { [self] _ in passage(0) }
        session.start(); try await wait { session.state == .playing }
        session.pause()
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
        session.resume()
        XCTAssertEqual(session.state, .playing); XCTAssertFalse(speaker.paused)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .spokenAudio)
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
        XCTAssertNil(PDFLocator.cursor("pdf:-1:0")); XCTAssertNil(PDFLocator.cursor("pdf:0:-1"))
        XCTAssertEqual(PDFLocator.pageIndex("pdf:4"), 4); XCTAssertEqual(PDFLocator.pageIndex("pdf:4:120"), 4)
        XCTAssertNil(PDFLocator.pageIndex("epubcfi(/6/4)")); XCTAssertEqual(PDFLocator.cursor(PDFLocator.position(page: 2, offset: 9))?.offset, 9)
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
    func testChineseSystemVoiceProducesRealAudioBuffers() async throws {
        let synthesizer = AVSpeechSynthesizer()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "zh-CN"), "Chinese integration requires an installed system voice")
        let utterance = AVSpeechUtterance(string: "从选中的位置开始，继续朗读下一章。"); utterance.voice = voice
        let complete = expectation(description: "Synthesized Chinese PCM audio"); complete.assertForOverFulfill = false
        synthesizer.write(utterance) { buffer in
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 { complete.fulfill() }
        }
        await fulfillment(of: [complete], timeout: 20); synthesizer.stopSpeaking(at: .immediate)
    }
    func testSystemSpeakerReadsNumberOnlyPassageWithoutLanguageMetadata() async throws {
        let speaker = SystemReadAloudSpeaker()
        defer { speaker.stop(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        let finished = expectation(description: "Default device voice reads a page number")
        speaker.finished = { finished.fulfill() }
        do { try speaker.speak("419", language: "", voice: "", speed: 1) }
        catch { XCTFail("A number-only page must use the device voice instead of blocking the rest of the book: \(error)"); return }
        await fulfillment(of: [finished], timeout: 15)
    }
    private func systemSpeaker() -> SystemReadAloudSpeaker {
        let speaker = SystemReadAloudSpeaker()
        addTeardownBlock { @MainActor in speaker.stop(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        return speaker
    }
    /// A voice that reports no word ranges must still move the highlight at every
    /// sentence: each queued utterance's start is reported at its chunk offset.
    func testSystemSpeakerReportsEverySentenceStartWithoutWordRanges() async throws {
        let speaker = systemSpeaker(); speaker.reportsWordRanges = false
        let text = "Leaf reads the first sentence. Then it reads a second one, with a clause inside. A third sentence ends the passage."
        let starts = ReadAloudSentenceSplitter.split(text).map(\.range.location)
        XCTAssertEqual(starts.count, 3)
        var reported: [NSRange] = []
        let finished = expectation(description: "finished once after the last chunk")
        speaker.finished = { finished.fulfill() }
        speaker.progressed = { reported.append($0) }
        try speaker.speak(text, language: "en-US", voice: "", speed: 2)
        await fulfillment(of: [finished], timeout: 40)
        XCTAssertEqual(reported.map(\.location), starts, "One progress report per chunk, at the chunk's offset in the passage")
        XCTAssertEqual(reported.map(\.length), [4, 4, 1], "Each report covers the chunk's first word")
    }
    func testChineseSystemSpeakerReportsSentenceStartsWithoutWordRanges() async throws {
        let speaker = systemSpeaker(); speaker.reportsWordRanges = false
        let sentences = ["第一句话很短。", "第二句话也不长，但是有一个逗号。", "第三句结束这一段。"]
        let text = sentences.joined()
        // Expected starts come from the sentences' own UTF-16 lengths, not from the splitter.
        let starts = [0, (sentences[0] as NSString).length, (sentences[0] as NSString).length + (sentences[1] as NSString).length]
        XCTAssertEqual(starts, [0, 7, 23])
        var reported: [Int] = []
        let finished = expectation(description: "finished once")
        speaker.finished = { finished.fulfill() }
        speaker.progressed = { reported.append($0.location) }
        try speaker.speak(text, language: "zh-CN", voice: "", speed: 2)
        await fulfillment(of: [finished], timeout: 40)
        XCTAssertEqual(reported, starts, "One didStart report per Chinese sentence, at its UTF-16 offset")
    }
    /// With a voice that reports words, ranges keep their per-word cadence and are
    /// offset into the passage, so they never restart at 0 for the second chunk.
    func testSystemSpeakerOffsetsWordRangesIntoThePassageAcrossChunks() async throws {
        let speaker = systemSpeaker()
        let text = "Leaf reads the first sentence aloud. Then the second sentence follows it."
        let second = try XCTUnwrap(ReadAloudSentenceSplitter.split(text).last).range.location
        var reported: [Int] = []
        let finished = expectation(description: "finished once")
        speaker.finished = { finished.fulfill() }
        speaker.progressed = { reported.append($0.location) }
        try speaker.speak(text, language: "en-US", voice: "", speed: 2)
        await fulfillment(of: [finished], timeout: 40)
        XCTAssertEqual(reported, reported.sorted(), "Offsets never go backwards across chunks: \(reported)")
        XCTAssertTrue(reported.contains(second), "The second chunk's start is reported: \(reported)")
        XCTAssertGreaterThan(Set(reported).count, 4, "Word ranges are still reported where the voice provides them: \(reported)")
    }
    func testStoppingMidQueueDoesNotReportFinishAndTheNextPassageStartsFromItsFirstChunk() async throws {
        let speaker = systemSpeaker(); speaker.reportsWordRanges = false
        var finishes = 0
        speaker.finished = { finishes += 1 }
        let firstStart = expectation(description: "first chunk started"); firstStart.assertForOverFulfill = false
        speaker.progressed = { _ in firstStart.fulfill() }
        try speaker.speak("One sentence here. Another sentence there. And a third sentence to finish the passage.", language: "en-US", voice: "", speed: 1)
        await fulfillment(of: [firstStart], timeout: 20)
        speaker.stop()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(finishes, 0, "Stopping a queued passage is not a finish")
        var reported: [Int] = []
        let finished = expectation(description: "second passage finished")
        speaker.finished = { finishes += 1; finished.fulfill() }
        speaker.progressed = { reported.append($0.location) }
        try speaker.speak("Short one. Short two.", language: "en-US", voice: "", speed: 2)
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertEqual(reported, [0, 11]); XCTAssertEqual(finishes, 1)
    }
    func testPausingBetweenChunksResumesTheQueueAndFinishesOnce() async throws {
        let speaker = systemSpeaker(); speaker.reportsWordRanges = false
        var reported: [Int] = []
        let firstStart = expectation(description: "first chunk started"); firstStart.assertForOverFulfill = false
        let finished = expectation(description: "finished once")
        speaker.finished = { finished.fulfill() }
        speaker.progressed = { reported.append($0.location); firstStart.fulfill() }
        try speaker.speak("Pause after this. Resume for this one.", language: "en-US", voice: "", speed: 2)
        await fulfillment(of: [firstStart], timeout: 20)
        speaker.pause()
        try await Task.sleep(for: .milliseconds(400))
        let before = reported.count
        XCTAssertTrue(speaker.resume())
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertEqual(reported, [0, 18]); XCTAssertGreaterThanOrEqual(reported.count, before)
    }
}
