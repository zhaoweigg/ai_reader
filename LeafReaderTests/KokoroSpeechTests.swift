import XCTest
import AVFoundation
import Combine
@testable import LeafReader

// MARK: - Fakes

/// Deterministic stand-in for the model: 1 ms of audio per character, optional per-call failure.
final class FakeKokoroSynthesizer: KokoroSynthesizing, @unchecked Sendable {
    let sampleRate = 24_000
    private let lock = NSLock()
    private(set) var requests: [(text: String, speaker: Int, speed: Double)] = []
    var failing: Set<String> = []
    var delay: TimeInterval = 0
    func synthesize(_ text: String, speaker: Int, speed: Double, shouldContinue: @escaping () -> Bool) -> KokoroAudio? {
        lock.lock(); requests.append((text, speaker, speed)); let fails = failing.contains(text); lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard !fails, shouldContinue() else { return nil }
        return KokoroAudio(samples: [Float](repeating: 0.1, count: max(1, text.utf16.count * 24)), sampleRate: sampleRate)
    }
    var requestedTexts: [String] { lock.lock(); defer { lock.unlock() }; return requests.map(\.text) }
}

/// Records queued sentences and lets a test drive playback completion.
@MainActor final class FakeAudioPlayer: KokoroAudioPlaying {
    var prepared: [Int] = []
    var queued: [(audio: KokoroAudio, onStart: () -> Void, onFinish: () -> Void)] = []
    var paused = false, stopped = 0, played = 0
    func prepare(sampleRate: Int) throws { prepared.append(sampleRate) }
    func enqueue(_ audio: KokoroAudio, onStart: @escaping () -> Void, onFinish: @escaping () -> Void) {
        queued.append((audio, onStart, onFinish))
        if queued.count == 1 { onStart() }
    }
    func pause() { paused = true }
    func resume() throws { paused = false }
    func stop() { stopped += 1; queued.removeAll(); played = 0 }
    /// Completes the oldest unfinished sentence and starts the next one, like gapless playback.
    func finishCurrent() {
        guard played < queued.count else { return }
        let index = played; played += 1
        queued[index].onFinish()
        if played < queued.count { queued[played].onStart() }
    }
}

final class FakeArchiveDownloader: KokoroArchiveDownloading, @unchecked Sendable {
    let source: URL?
    var cancelled = false
    var error: Error?
    init(source: URL?) { self.source = source }
    func download(_ url: URL, to destination: URL, resumeDataURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if let error { throw error }
        progress(0.5)
        guard let source else { throw URLError(.notConnectedToInternet) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        progress(1)
    }
    func cancel() { cancelled = true }
}

@MainActor final class StubSystemSpeaker: ReadAloudSpeaking {
    var finished: (() -> Void)?
    var progressed: ((NSRange) -> Void)?
    var spoken: [(text: String, voice: String)] = []
    var stops = 0
    func speak(_ text: String, language: String, voice: String, speed: Double) throws { spoken.append((text, voice)) }
    func pause() {}
    func resume() -> Bool { true }
    func stop() { stops += 1 }
}

// MARK: - Tests

@MainActor final class KokoroSpeechTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "tar.bz2"))
        return url
    }
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KokoroTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func readyStore(root: URL) throws -> KokoroModelStore {
        let manifest = try testManifest(archive: fixture("KokoroPack"))
        let store = KokoroModelStore(manifest: manifest, root: root, downloader: FakeArchiveDownloader(source: nil), freeSpace: { _ in Int64.max })
        return store
    }
    private func testManifest(archive: URL, sha256: String? = nil) throws -> KokoroModelManifest {
        let size = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value)
        return KokoroModelManifest(directoryName: "kokoro-multi-lang-v1_1", archiveURL: archive, archiveSize: size,
                                   archiveSHA256: try sha256 ?? KokoroModelStore.sha256(of: archive),
                                   requiredFiles: KokoroModelManifest.current.requiredFiles)
    }

    // Sentence splitting

    func testSplitterKeepsChineseSentencesShortAndOffsetsExact() {
        let text = "那是一个寒冷的冬夜，雪花悄无声息地落在青石板路上。林远站在巷口，手里攥着那封信，犹豫了很久。他知道，一旦推开那扇门，很多事情就再也回不去了。"
        let sentences = KokoroSentenceSplitter.split(text)
        XCTAssertEqual(sentences.map(\.text), ["那是一个寒冷的冬夜，雪花悄无声息地落在青石板路上。", "林远站在巷口，手里攥着那封信，犹豫了很久。", "他知道，一旦推开那扇门，很多事情就再也回不去了。"])
        for sentence in sentences {
            XCTAssertEqual((text as NSString).substring(with: sentence.range), sentence.text)
            XCTAssertLessThanOrEqual(sentence.range.length, KokoroSentenceSplitter.chineseLimit)
        }
        let long = String(repeating: "很长的一段话没有任何标点符号一直写下去", count: 12)
        XCTAssertGreaterThan(KokoroSentenceSplitter.split(long).count, 2)
        XCTAssertTrue(KokoroSentenceSplitter.split(long).allSatisfy { $0.range.length <= KokoroSentenceSplitter.chineseLimit })
    }
    func testSplitterHandlesEnglishAbbreviationsQuotesAndLineBreaks() {
        let text = "Dr. Smith paid $3.50 at 9 a.m.! \"Really?\" she asked.\nThe next line has no terminator"
        let sentences = KokoroSentenceSplitter.split(text)
        XCTAssertEqual(sentences.map(\.text), ["Dr. Smith paid $3.50 at 9 a.m.!", "\"Really?\"", "she asked.", "The next line has no terminator"])
        XCTAssertEqual(sentences.last?.range, NSRange(location: 53, length: 31))
        XCTAssertEqual(KokoroSentenceSplitter.split("J. K. Rowling wrote it. Then more.").map(\.text), ["J. K. Rowling wrote it.", "Then more."])
        let emoji = "Alpha 😀 beta. Gamma 𝄞 delta."
        for sentence in KokoroSentenceSplitter.split(emoji) {
            XCTAssertEqual((emoji as NSString).substring(with: sentence.range), sentence.text)
        }
        XCTAssertEqual(KokoroSentenceSplitter.split("   \n ... \n").count, 0, "Punctuation-only text has nothing to say")
        let run = String(repeating: "word ", count: 120)
        XCTAssertTrue(KokoroSentenceSplitter.split(run).allSatisfy { $0.range.length <= KokoroSentenceSplitter.englishLimit })
        XCTAssertGreaterThan(KokoroSentenceSplitter.split(run).count, 1)
    }

    // Voice catalog

    func testCatalogHasEveryKokoroSpeakerAndPicksVoicesByScript() {
        XCTAssertEqual(KokoroVoiceCatalog.all.count, KokoroVoiceCatalog.speakerCount)
        XCTAssertEqual(KokoroVoiceCatalog.all.map(\.speaker), Array(0..<KokoroVoiceCatalog.speakerCount))
        XCTAssertEqual(Set(KokoroVoiceCatalog.all.map(\.id)).count, KokoroVoiceCatalog.speakerCount)
        XCTAssertEqual(KokoroVoiceCatalog.voice(id: "zm_009")?.speaker, 58)
        XCTAssertEqual(KokoroVoiceCatalog.voice(id: "zf_099")?.speaker, 57)
        XCTAssertEqual(KokoroVoiceCatalog.automaticVoice(for: "我们讨论了 attention 机制", language: "en").language, .chinese)
        XCTAssertEqual(KokoroVoiceCatalog.automaticVoice(for: "The author 鲁迅 wrote it in 1918.", language: "zh").language, .english)
        XCTAssertEqual(KokoroVoiceCatalog.automaticVoice(for: "1999 12 31", language: "zh-CN").language, .chinese)
        XCTAssertEqual(KokoroVoiceCatalog.automaticVoice(for: "1999 12 31", language: "en-GB").language, .english)
    }

    // Archive extraction

    func testExtractorUnpacksGnuAndPaxArchivesAndIgnoresLinks() throws {
        let root = temporary()
        try TarBzip2Extractor.extract(archive: fixture("KokoroPack"), into: root)
        let pack = root.appendingPathComponent("kokoro-multi-lang-v1_1")
        XCTAssertEqual(try Data(contentsOf: pack.appendingPathComponent("model.onnx")).count, 4000)
        XCTAssertEqual(try String(contentsOf: pack.appendingPathComponent("lexicon-zh.txt"), encoding: .utf8), "你好 n i h a o\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pack.appendingPathComponent("dict/jieba.dict.utf8").path))
        let long = pack.appendingPathComponent("espeak-ng-data/" + String(repeating: "very-long-directory-name-segment/", count: 4) + "data.txt")
        XCTAssertEqual(try String(contentsOf: long, encoding: .utf8), "long")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.appendingPathComponent("link").path), "Symbolic links are never materialized")
        let pax = temporary()
        try TarBzip2Extractor.extract(archive: fixture("PaxNames"), into: pax)
        XCTAssertEqual(try String(contentsOf: pax.appendingPathComponent("kokoro-multi-lang-v1_1/" + String(repeating: "p", count: 120) + ".txt"), encoding: .utf8), "pax")
    }
    func testExtractorRejectsPathTraversalAndTruncatedArchives() throws {
        let root = temporary()
        XCTAssertThrowsError(try TarBzip2Extractor.extract(archive: fixture("Traversal"), into: root)) { error in
            guard case TarBzip2Extractor.Failure.unsafePath = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
        let truncated = temporary().appendingPathComponent("short.tar.bz2")
        try FileManager.default.createDirectory(at: truncated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(try Data(contentsOf: fixture("KokoroPack")).prefix(300)).write(to: truncated)
        XCTAssertThrowsError(try TarBzip2Extractor.extract(archive: truncated, into: temporary()))
    }

    // Model store

    func testStoreDownloadsVerifiesUnpacksAndRemembersInstallation() async throws {
        let root = temporary(), archive = try fixture("KokoroPack")
        let manifest = try testManifest(archive: archive)
        let downloader = FakeArchiveDownloader(source: archive)
        let store = KokoroModelStore(manifest: manifest, root: root, downloader: downloader, freeSpace: { _ in Int64.max })
        XCTAssertEqual(store.state, .notInstalled)
        var states: [KokoroModelStore.State] = []
        let token = store.$state.sink { states.append($0) }
        store.install()
        try await wait { store.state == .ready }
        token.cancel()
        XCTAssertTrue(states.contains(.verifying)); XCTAssertTrue(states.contains(.unpacking))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.modelDirectory.appendingPathComponent("voices.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("kokoro-multi-lang-v1_1.tar.bz2.download").path), "The archive is deleted after unpacking")
        let again = KokoroModelStore(manifest: manifest, root: root, downloader: FakeArchiveDownloader(source: nil), freeSpace: { _ in 0 })
        XCTAssertEqual(again.state, .ready, "A complete install is recognized without any download")
        try FileManager.default.removeItem(at: store.modelDirectory.appendingPathComponent("tokens.txt"))
        let damaged = KokoroModelStore(manifest: manifest, root: root, downloader: FakeArchiveDownloader(source: nil), freeSpace: { _ in 0 })
        XCTAssertEqual(damaged.state, .notInstalled, "A missing required file invalidates the pack")
        store.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelDirectory.path)); XCTAssertEqual(store.state, .notInstalled)
    }
    func testStoreDiscardsArchivesWithWrongChecksumAndReportsSpaceAndNetworkFailures() async throws {
        let root = temporary(), archive = try fixture("KokoroPack")
        let wrong = try testManifest(archive: archive, sha256: String(repeating: "0", count: 64))
        let store = KokoroModelStore(manifest: wrong, root: root, downloader: FakeArchiveDownloader(source: archive), freeSpace: { _ in Int64.max })
        store.install()
        try await wait { if case .failed = store.state { return true } else { return false } }
        XCTAssertEqual(store.state, .failed(KokoroModelError.checksum.localizedDescription))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("kokoro-multi-lang-v1_1.tar.bz2.download").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelDirectory.path))
        let cramped = KokoroModelStore(manifest: try testManifest(archive: archive), root: temporary(), downloader: FakeArchiveDownloader(source: archive), freeSpace: { _ in 1 })
        cramped.install()
        try await wait { if case .failed = cramped.state { return true } else { return false } }
        if case .failed(let reason) = cramped.state { XCTAssertTrue(reason.contains("Free up")) }
        let offline = KokoroModelStore(manifest: try testManifest(archive: archive), root: temporary(), downloader: FakeArchiveDownloader(source: nil), freeSpace: { _ in Int64.max })
        offline.install()
        try await wait { if case .failed = offline.state { return true } else { return false } }
        let cancelled = FakeArchiveDownloader(source: archive); cancelled.error = CancellationError()
        let abandoned = KokoroModelStore(manifest: try testManifest(archive: archive), root: temporary(), downloader: cancelled, freeSpace: { _ in Int64.max })
        abandoned.install()
        try await wait { abandoned.state == .notInstalled }
    }

    // Speaker

    func testSpeakerStreamsSentencesInOrderReportsRangesAndFinishesAfterPlayback() async throws {
        let root = temporary()
        let store = try readyStore(root: root)
        try TarBzip2Extractor.extract(archive: fixture("KokoroPack"), into: root)
        try store.manifest.archiveSHA256.write(to: root.appendingPathComponent("kokoro-multi-lang-v1_1.installed"), atomically: true, encoding: .utf8)
        store.refresh(); XCTAssertEqual(store.state, .ready)
        let synthesizer = FakeKokoroSynthesizer(), player = FakeAudioPlayer()
        let speaker = KokoroReadAloudSpeaker(store: store, player: player, makeSynthesizer: { _ in synthesizer })
        var ranges: [NSRange] = [], finished = 0, buffering: [Bool] = []
        speaker.progressed = { ranges.append($0) }; speaker.finished = { finished += 1 }; speaker.buffering = { buffering.append($0) }
        let text = "第一句话。Second sentence here. 第三句。"
        try speaker.speak(text, language: "zh", voice: "", speed: 1.25)
        try await wait { player.queued.count == 3 }
        XCTAssertEqual(synthesizer.requestedTexts, ["第一句话。", "Second sentence here.", "第三句。"])
        XCTAssertEqual(synthesizer.requests.first?.speaker, KokoroVoiceCatalog.defaultChinese.speaker)
        XCTAssertEqual(synthesizer.requests.first?.speed, 1.25)
        XCTAssertEqual(player.prepared, [24_000, 24_000, 24_000])
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 5)]); XCTAssertEqual(buffering, [true, false])
        XCTAssertEqual(finished, 0)
        player.finishCurrent(); XCTAssertEqual(ranges.count, 2); XCTAssertEqual(ranges[1], NSRange(location: 5, length: 21))
        player.finishCurrent(); XCTAssertEqual(ranges[2], NSRange(location: 27, length: 4))
        XCTAssertEqual(finished, 0)
        player.finishCurrent(); XCTAssertEqual(finished, 1, "Finished only after the last sentence played")
        // Speaking again reuses cached audio and an explicit voice.
        try speaker.speak("Second sentence here.", language: "en", voice: "zf_001", speed: 1.25)
        try await wait { player.queued.count == 1 }
        XCTAssertEqual(synthesizer.requestedTexts.count, 3, "Cached sentence was not synthesized twice")
        XCTAssertTrue(speaker.resume())
        speaker.stop(); XCTAssertFalse(speaker.resume()); XCTAssertEqual(player.stopped, 3)
    }
    func testSpeakerSkipsFailedSentencesCancelsOnStopAndReportsLoadFailures() async throws {
        let root = temporary()
        let store = try readyStore(root: root)
        try TarBzip2Extractor.extract(archive: fixture("KokoroPack"), into: root)
        try store.manifest.archiveSHA256.write(to: root.appendingPathComponent("kokoro-multi-lang-v1_1.installed"), atomically: true, encoding: .utf8)
        store.refresh()
        let synthesizer = FakeKokoroSynthesizer(), player = FakeAudioPlayer()
        synthesizer.failing = ["Broken."]
        let speaker = KokoroReadAloudSpeaker(store: store, player: player, makeSynthesizer: { _ in synthesizer })
        var finished = 0; speaker.finished = { finished += 1 }
        try speaker.speak("Good one. Broken. Last one.", language: "en", voice: "af_maple", speed: 1)
        try await wait { player.queued.count == 2 }
        XCTAssertEqual(player.queued.map { $0.audio.samples.count }, ["Good one.".utf16.count * 24, "Last one.".utf16.count * 24])
        player.finishCurrent(); player.finishCurrent()
        try await wait { finished == 1 }
        synthesizer.delay = 0.05
        try speaker.speak("One. Two. Three. Four. Five. Six.", language: "en", voice: "af_maple", speed: 1)
        try await wait { !player.queued.isEmpty }
        speaker.stop()
        let count = synthesizer.requestedTexts.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(synthesizer.requestedTexts.count, count + 1, "Stop cancels the remaining sentences")
        XCTAssertEqual(finished, 1)
        let failing = KokoroReadAloudSpeaker(store: store, player: FakeAudioPlayer(), makeSynthesizer: { _ in throw KokoroSynthesizerError.loadFailed })
        var failures: [String] = []; failing.failedToStart = { failures.append($0.localizedDescription) }
        try failing.speak("Hello there.", language: "en", voice: "", speed: 1)
        try await wait { !failures.isEmpty }
        XCTAssertEqual(failures, [KokoroSynthesizerError.loadFailed.localizedDescription])
        XCTAssertEqual(store.state, .ready, "A load failure never deletes the downloaded pack")
        store.remove()
        XCTAssertThrowsError(try speaker.speak("Hello.", language: "en", voice: "", speed: 1))
    }

    // Routing and session integration

    func testRoutingUsesKokoroOnlyForKokoroVoicesAndFallsBackToTheSystemVoice() async throws {
        let root = temporary()
        let store = try readyStore(root: root)
        let synthesizer = FakeKokoroSynthesizer(), player = FakeAudioPlayer(), system = StubSystemSpeaker()
        let kokoro = KokoroReadAloudSpeaker(store: store, player: player, makeSynthesizer: { _ in synthesizer })
        let router = RoutingReadAloudSpeaker(system: system, kokoro: kokoro)
        var fallbacks: [String?] = []; router.onFallback = { fallbacks.append($0) }
        try router.speak("Plain voice.", language: "en", voice: "com.apple.voice.compact.en-US.Samantha", speed: 1)
        XCTAssertEqual(system.spoken.map(\.voice), ["com.apple.voice.compact.en-US.Samantha"]); XCTAssertFalse(router.usingKokoro)
        try router.speak("Not installed yet.", language: "en", voice: "kokoro:", speed: 1)
        XCTAssertEqual(system.spoken.count, 2); XCTAssertEqual(system.spoken.last?.voice, "", "Automatic system voice stands in for the missing pack")
        XCTAssertEqual(fallbacks, [KokoroModelError.notInstalled.localizedDescription])
        try TarBzip2Extractor.extract(archive: fixture("KokoroPack"), into: root)
        try store.manifest.archiveSHA256.write(to: root.appendingPathComponent("kokoro-multi-lang-v1_1.installed"), atomically: true, encoding: .utf8)
        store.refresh()
        try router.speak("Now on device.", language: "en", voice: "kokoro:af_sol", speed: 1)
        XCTAssertTrue(router.usingKokoro); XCTAssertEqual(fallbacks.count, 2); XCTAssertNil(fallbacks[1])
        try await wait { player.queued.count == 1 }
        XCTAssertEqual(synthesizer.requests.last?.speaker, 1)
        router.prepare("Upcoming passage.", language: "en", voice: "kokoro:af_sol", speed: 1)
        try await wait { synthesizer.requestedTexts.contains("Upcoming passage.") }
        router.prepare("System passage.", language: "en", voice: "", speed: 1)
        XCTAssertFalse(synthesizer.requestedTexts.contains("System passage."))
        router.stop(); XCTAssertNil(router.active)
    }
    func testSessionPersistsEngineAndKokoroVoiceAndRestartsPlayback() async throws {
        let name = "KokoroSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let speaker = StubSystemSpeaker()
        let session = ReadAloudSession(bookmarkURL: nil, defaults: defaults, speaker: speaker)
        session.source = { locator in locator == nil ? ReadAloudPassage(text: "Passage text.", locator: "a", nextLocator: "b", language: "en", label: "A") : nil }
        session.start(); try await wait { session.state == .playing }
        XCTAssertEqual(speaker.spoken.map(\.voice), [""])
        session.engine = .kokoro; session.kokoroVoice = "zf_001"
        try await wait { speaker.spoken.count == 3 }
        XCTAssertEqual(speaker.spoken.map(\.voice), ["", "kokoro:", "kokoro:zf_001"])
        XCTAssertEqual(session.effectiveVoice, "kokoro:zf_001")
        let restored = ReadAloudSession(bookmarkURL: nil, defaults: defaults, speaker: StubSystemSpeaker())
        XCTAssertEqual(restored.engine, .kokoro); XCTAssertEqual(restored.kokoroVoice, "zf_001")
        session.stop()
    }
}
