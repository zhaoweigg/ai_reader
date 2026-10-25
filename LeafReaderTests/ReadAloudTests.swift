import XCTest
import AVFoundation
import PDFKit
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
    func testVoiceTypesKeepIndependentSpeedsAfterSwitchingAndReopening() {
        let (session, _, _, defaults) = setup()
        session.speed = 1.75
        session.engine = .system
        XCTAssertEqual(session.speed, 1, "Natural speed changes cannot change Apple's initial speed")
        session.speed = 0.75
        for _ in 0..<8 {
            session.engine = .kokoro; XCTAssertEqual(session.speed, 1.75)
            session.engine = .system; XCTAssertEqual(session.speed, 0.75)
        }
        let reopened = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
        XCTAssertEqual(reopened.engine, .system); XCTAssertEqual(reopened.speed, 0.75)
        reopened.engine = .kokoro; XCTAssertEqual(reopened.speed, 1.75)
        reopened.speed = 2
        reopened.engine = .system; XCTAssertEqual(reopened.speed, 0.75)
        let anotherBook = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
        anotherBook.engine = .kokoro; XCTAssertEqual(anotherBook.speed, 2)
    }
    func testLegacySharedSpeedSeedsBothTypesWithoutOverwritingTheirNewPreferences() {
        for legacy in [0.5, 1.25, 2.0] {
            let (_, _, _, defaults) = setup()
            // Simulate an installation from before independent speed preferences.
            defaults.removeObject(forKey: "audio.speed.system")
            defaults.removeObject(forKey: "audio.speed.kokoro")
            defaults.set(legacy, forKey: "audio.speed")
            defaults.set("system", forKey: "audio.engine")
            let migrated = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
            XCTAssertEqual(migrated.speed, legacy)
            migrated.engine = .kokoro; XCTAssertEqual(migrated.speed, legacy)
            migrated.speed = 1.5
            migrated.engine = .system; XCTAssertEqual(migrated.speed, legacy)
            XCTAssertEqual(defaults.double(forKey: "audio.speed"), legacy, "Migration retains the original shared preference")
            let reopened = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
            XCTAssertEqual(reopened.speed, legacy)
            reopened.engine = .kokoro; XCTAssertEqual(reopened.speed, 1.5)
        }
    }
    func testMissingOrInvalidEngineSpeedUsesASafeMigrationWithoutChangingTheOtherType() {
        for invalid in [0.0, 3.0, Double.infinity, Double.nan] {
            let (_, _, _, defaults) = setup()
            defaults.set(0.75, forKey: "audio.speed.system")
            defaults.set(invalid, forKey: "audio.speed.kokoro")
            defaults.set(1.25, forKey: "audio.speed")
            let migrated = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
            XCTAssertEqual(migrated.speed, 1.25)
            migrated.engine = .system; XCTAssertEqual(migrated.speed, 0.75)
            defaults.removeObject(forKey: "audio.speed.kokoro")
            defaults.set(invalid, forKey: "audio.speed")
            migrated.engine = .kokoro; XCTAssertEqual(migrated.speed, 1)
            migrated.engine = .system; XCTAssertEqual(migrated.speed, 0.75)
        }
    }
    func testEngineSpeedSwitchRestartsOnceAtTheCursorAndDoesNotUnpause() async throws {
        for appleSpeed in [0.75, 1.5] { // Different and equal rates both switch engines once.
            let (session, speaker, directory, defaults) = setup()
            session.speed = 1.5; session.engine = .system; session.speed = appleSpeed; session.engine = .kokoro
            let value = passage(2, text: "Alpha 😀 beta gamma")
            session.source = { locator in locator == "position:3" ? nil : value }
            session.start(at: "position:2", offset: 9)
            try await wait { session.state == .playing }
            XCTAssertEqual(speaker.spoken.last, "beta gamma"); XCTAssertEqual(speaker.speeds.last, 1.5)
            let count = speaker.spoken.count
            session.engine = .system
            XCTAssertEqual(speaker.spoken.count, count + 1)
            XCTAssertEqual(speaker.spoken.last, "beta gamma"); XCTAssertEqual(speaker.speeds.last, appleSpeed)
            speaker.progressed?(NSRange(location: 5, length: 1))
            session.pause(); session.engine = .kokoro
            XCTAssertEqual(session.state, .paused); XCTAssertEqual(speaker.spoken.count, count + 1)
            XCTAssertEqual(session.speed, 1.5)
            session.resume()
            XCTAssertEqual(speaker.spoken.last, "gamma"); XCTAssertEqual(speaker.speeds.last, 1.5)
            session.stop()
            let reopened = ReadAloudSession(bookmarkURL: directory.appendingPathComponent("bookmark.json"), defaults: defaults, speaker: RecordingSpeaker())
            XCTAssertEqual(reopened.bookmark?.offset, 14); XCTAssertEqual(reopened.speed, 1.5)
            reopened.engine = .system; XCTAssertEqual(reopened.speed, appleSpeed)
        }
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
        session.pause(); session.kokoroVoice = "zf_003"
        session.followsText = false
        let count = speaker.spoken.count
        session.resume(); XCTAssertEqual(speaker.spoken.count, count + 1)
        session.stop()
        let reopenedSpeaker = RecordingSpeaker()
        let reopened = ReadAloudSession(bookmarkURL: directory.appendingPathComponent("bookmark.json"), defaults: defaults, speaker: reopenedSpeaker)
        reopened.source = { _ in value }
        XCTAssertEqual(reopened.bookmark?.offset, 9); XCTAssertEqual(reopened.speed, 1.5); XCTAssertEqual(reopened.kokoroVoice, "zf_003")
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
    func testDictationPausesPlaybackSynchronouslyAndKeepsBookmark() async throws {
        let (session, speaker, _, _) = setup()
        session.source = { [self] _ in passage(0) }
        session.start(); try await wait { session.state == .playing }
        NotificationCenter.default.post(name: ChatDictationSession.willRecord, object: nil)
        XCTAssertEqual(session.state, .paused, "Pause before dictation takes the shared audio session")
        XCTAssertTrue(speaker.paused); XCTAssertEqual(session.bookmark?.locator, "position:0")
        XCTAssertEqual(speaker.spoken.count, 1)
    }
    func testPlaybackResumeRestoresAudioCategoryAfterDictation() throws {
        let speaker = RecordingSpeaker()
        let router = RoutingReadAloudSpeaker(system: speaker, kokoro: KokoroReadAloudSpeaker(store: .shared))
        defer { router.stop(); ReadAloudAudioSession.deactivate() }
        try router.speak("A saved passage", language: "en-US", voice: "", speed: 1)
        router.pause()
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
        XCTAssertTrue(router.resume())
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .spokenAudio)
        XCTAssertFalse(speaker.paused)
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
        let starts = KokoroSentenceSplitter.split(text).map(\.range.location)
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
        let second = try XCTUnwrap(KokoroSentenceSplitter.split(text).last).range.location
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
