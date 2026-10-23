import AVFoundation
import Foundation
import UIKit

/// Reports when audio is being generated but nothing is audible yet.
@MainActor protocol ReadAloudBufferingReporter: AnyObject {
    var buffering: ((Bool) -> Void)? { get set }
}

/// Cancellation flag shared between the main actor and the synthesis queue.
final class KokoroJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Runs the model on one serial background queue. The loaded synthesizer and
/// the sentence cache are only touched on that queue.
final class KokoroSynthesisWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.weizhao.leafreader.kokoro", qos: .userInitiated)
    private let make: (URL) throws -> any KokoroSynthesizing
    private var synthesizer: (any KokoroSynthesizing)?
    private let cache = KokoroAudioCache(limit: 48)
    init(make: @escaping (URL) throws -> any KokoroSynthesizing) { self.make = make }

    /// Delivers each sentence in order on an arbitrary thread; `completion`
    /// receives the load error, or nil once every sentence was delivered.
    func synthesize(_ sentences: [KokoroSentence], directory: URL, speaker: Int, speed: Double, job: KokoroJob,
                    deliver: @escaping @Sendable (KokoroSentence, KokoroAudio?) -> Void,
                    completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            let synthesizer: any KokoroSynthesizing
            do { synthesizer = try load(directory) } catch { completion(error); return }
            for sentence in sentences {
                if job.isCancelled { return }
                let audio = render(sentence.text, speaker: speaker, speed: speed, with: synthesizer, job: job)
                if job.isCancelled { return }
                deliver(sentence, audio)
            }
            completion(nil)
        }
    }
    func prepare(_ sentences: [KokoroSentence], directory: URL, speaker: Int, speed: Double) {
        queue.async { [self] in
            guard let synthesizer = try? load(directory) else { return }
            for sentence in sentences where cache.audio(for: key(sentence.text, speaker, speed)) == nil {
                _ = render(sentence.text, speaker: speaker, speed: speed, with: synthesizer, job: nil)
            }
        }
    }
    /// Releases the loaded model (hundreds of megabytes); it reloads on the next passage.
    func unload() { queue.async { [self] in synthesizer = nil } }

    private func load(_ directory: URL) throws -> any KokoroSynthesizing {
        if let synthesizer { return synthesizer }
        let created = try make(directory)
        synthesizer = created
        return created
    }
    private func key(_ text: String, _ speaker: Int, _ speed: Double) -> String { "\(speaker)|\(speed)|\(text)" }
    private func render(_ text: String, speaker: Int, speed: Double, with synthesizer: any KokoroSynthesizing, job: KokoroJob?) -> KokoroAudio? {
        let key = key(text, speaker, speed)
        if let cached = cache.audio(for: key) { return cached }
        let audio = synthesizer.synthesize(text, speaker: speaker, speed: speed) { !(job?.isCancelled ?? false) }
        if let audio { cache.store(audio, for: key) }
        return audio
    }
}

/// Speaks a passage with the on-device Kokoro model: the passage is split into
/// sentences, each sentence is synthesized in the background and queued for
/// gapless playback while the next one is being generated. Progress and
/// completion mirror `SystemReadAloudSpeaker`, so the session's cursor,
/// bookmark and highlight logic are unchanged.
@MainActor final class KokoroReadAloudSpeaker: ReadAloudSpeaking, ReadAloudBufferingReporter {
    var finished: (() -> Void)?
    var progressed: ((NSRange) -> Void)?
    var buffering: ((Bool) -> Void)?
    /// The passage could not start (model missing or failed to load); nothing was spoken.
    var failedToStart: ((Error) -> Void)?
    let store: KokoroModelStore
    private let player: any KokoroAudioPlaying
    private let worker: KokoroSynthesisWorker
    private var job: KokoroJob?
    private var remaining = 0
    private var synthesisDone = false
    private var isBuffering = false { didSet { if isBuffering != oldValue { buffering?(isBuffering) } } }
    private var memoryToken: NSObjectProtocol?

    /// Sentences of the next passage synthesized ahead so a chapter boundary has no gap.
    static let prepareDepth = 2

    init(store: KokoroModelStore, player: (any KokoroAudioPlaying)? = nil,
         makeSynthesizer: ((URL) throws -> any KokoroSynthesizing)? = nil) {
        self.store = store
        self.player = player ?? AudioEnginePlayer()
        worker = KokoroSynthesisWorker(make: makeSynthesizer ?? { try SherpaKokoroSynthesizer(modelDirectory: $0) })
        let worker = self.worker
        store.onRemoved = { worker.unload() }
        memoryToken = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.job == nil { self?.worker.unload() } }
        }
    }
    deinit { if let memoryToken { NotificationCenter.default.removeObserver(memoryToken) } }

    func speak(_ text: String, language: String, voice: String, speed: Double) throws {
        stop()
        guard store.state == .ready else { throw KokoroModelError.notInstalled }
        let sentences = KokoroSentenceSplitter.split(text)
        guard !sentences.isEmpty else { throw ReadAloudError.noText }
        let speaker = (KokoroVoiceCatalog.voice(id: voice) ?? KokoroVoiceCatalog.automaticVoice(for: text, language: language)).speaker
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let job = KokoroJob(); self.job = job
        remaining = sentences.count; synthesisDone = false; isBuffering = true
        worker.synthesize(sentences, directory: store.modelDirectory, speaker: speaker, speed: speed, job: job, deliver: { sentence, audio in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver(job, sentence: sentence, audio: audio) } }
        }, completion: { error in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard self.job === job else { return }
                if let error { self.fail(job, error) } else { self.synthesisDone = true; self.checkFinished() }
            } }
        })
    }
    func prepare(_ text: String, language: String, voice: String, speed: Double) {
        guard store.state == .ready else { return }
        let sentences = Array(KokoroSentenceSplitter.split(text).prefix(Self.prepareDepth))
        guard !sentences.isEmpty else { return }
        let speaker = (KokoroVoiceCatalog.voice(id: voice) ?? KokoroVoiceCatalog.automaticVoice(for: text, language: language)).speaker
        worker.prepare(sentences, directory: store.modelDirectory, speaker: speaker, speed: speed)
    }
    func pause() { player.pause() }
    func resume() -> Bool {
        guard job != nil else { return false }
        do { try player.resume() } catch { return false }
        return true
    }
    func stop() {
        job?.cancel(); job = nil
        player.stop()
        remaining = 0; synthesisDone = false; isBuffering = false
    }
    func unload() { worker.unload() }

    private func deliver(_ job: KokoroJob, sentence: KokoroSentence, audio: KokoroAudio?) {
        guard self.job === job else { return }
        guard let audio else { remaining -= 1; checkFinished(); return }
        do { try player.prepare(sampleRate: audio.sampleRate) } catch { fail(job, error); return }
        player.enqueue(audio, onStart: { [weak self] in
            guard let self, self.job === job else { return }
            self.isBuffering = false
            self.progressed?(sentence.range)
        }, onFinish: { [weak self] in
            guard let self, self.job === job else { return }
            self.remaining -= 1
            self.checkFinished()
        })
    }
    private func checkFinished() {
        guard job != nil, synthesisDone, remaining <= 0 else { return }
        job = nil; isBuffering = false
        finished?()
    }
    private func fail(_ job: KokoroJob, _ error: Error) {
        guard self.job === job else { return }
        stop()
        failedToStart?(error)
    }
}

/// Small in-memory cache of synthesized sentences so skipping back, restarting
/// after a speed change and chapter boundaries do not re-run the model.
final class KokoroAudioCache: @unchecked Sendable {
    private let limit: Int
    private var entries: [String: KokoroAudio] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    init(limit: Int) { self.limit = limit }
    func audio(for key: String) -> KokoroAudio? { lock.lock(); defer { lock.unlock() }; return entries[key] }
    func store(_ audio: KokoroAudio, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if entries[key] == nil { order.append(key) }
        entries[key] = audio
        while order.count > limit { entries[order.removeFirst()] = nil }
    }
}
