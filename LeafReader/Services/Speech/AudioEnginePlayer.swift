import AVFoundation

/// Gapless PCM playback for synthesized sentences. `onStart` fires when a
/// sentence begins playing and `onFinish` after its last sample was rendered.
@MainActor protocol KokoroAudioPlaying: AnyObject {
    func prepare(sampleRate: Int) throws
    func enqueue(_ audio: KokoroAudio, onStart: @escaping () -> Void, onFinish: @escaping () -> Void)
    func pause()
    func resume() throws
    func stop()
}

/// A paused player stays silent: chunks that arrive while paused are scheduled
/// but the engine is not restarted until `resume()`. If the system stops the
/// engine (an audio configuration change) the node reports its pending chunks
/// as consumed; those are not finished, and `resume()` schedules them again.
@MainActor final class AudioEnginePlayer: KokoroAudioPlaying {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var generation = 0
    private struct Item { let buffer: AVAudioPCMBuffer; let onStart: () -> Void; let onFinish: () -> Void }
    private var queued: [Item] = []
    private var started = 0, completed = 0
    /// Index of the first chunk scheduled on the node's current timeline (reset by `node.stop()`).
    private var timelineStart = 0
    private var paused = false
    /// Frames the node had rendered when playback was paused.
    private var pausedFrames: AVAudioFramePosition = 0
    /// The engine stopped on its own; chunks from `completed` on must be scheduled again.
    private var interrupted = false
    private var configurationToken: NSObjectProtocol?

    init() {
        engine.attach(node)
        configurationToken = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt() }
        }
    }
    deinit { if let configurationToken { NotificationCenter.default.removeObserver(configurationToken) } }

    func prepare(sampleRate: Int) throws {
        if let format, Int(format.sampleRate) == sampleRate { try run(); return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) else {
            throw AVError(.unknown)
        }
        node.stop(); engine.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.format = format
        try run()
    }
    func enqueue(_ audio: KokoroAudio, onStart: @escaping () -> Void, onFinish: @escaping () -> Void) {
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        audio.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: audio.samples.count) }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        queued.append(Item(buffer: buffer, onStart: onStart, onFinish: onFinish))
        if !interrupted { schedule(queued.count - 1) }
        try? run()
        // The first queued sentence, or one queued after the previous finished,
        // begins immediately; otherwise its start is the predecessor's completion.
        if !paused, completed == started { markStarted() }
    }
    func pause() {
        pausedFrames = renderedFrames
        paused = true
        node.pause(); engine.pause()
    }
    func resume() throws {
        paused = false
        try run()
        if completed == started { markStarted() }
    }
    func stop() {
        generation += 1
        queued.removeAll(); started = 0; completed = 0; timelineStart = 0
        paused = false; interrupted = false
        node.stop()
        engine.pause()
    }

    /// Starts the engine and node unless playback is paused; `resume()` starts a paused player.
    private func run() throws {
        guard !paused else { return }
        if interrupted { reschedule() }
        if !engine.isRunning { try engine.start() }
        if !node.isPlaying { node.play() }
    }
    private func schedule(_ index: Int) {
        let token = generation
        node.scheduleBuffer(queued[index].buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.didFinish(index, token: token) } }
        }
    }
    private func reschedule() {
        interrupted = false; generation += 1
        node.stop()
        timelineStart = completed; started = completed
        for index in completed..<queued.count { schedule(index) }
    }
    private func interrupt() {
        guard !interrupted, completed < queued.count else { return }
        interrupted = true; generation += 1
    }
    private var renderedFrames: AVAudioFramePosition {
        guard let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        return playerTime.sampleTime
    }
    /// The frame at which `index` ends on the node's current timeline.
    private func end(of index: Int) -> AVAudioFramePosition {
        (timelineStart...index).reduce(0) { $0 + AVAudioFramePosition(queued[$1].buffer.frameLength) }
    }
    private func didFinish(_ index: Int, token: Int) {
        guard token == generation, index < queued.count, index == completed else { return }
        if !engine.isRunning {
            // A stopped node reports every pending chunk as consumed. Only a chunk
            // that had fully rendered before the pause is actually finished.
            guard paused, end(of: index) <= pausedFrames else { interrupt(); return }
        }
        completed += 1
        queued[index].onFinish()
        if !paused, completed == started { markStarted() }
    }
    private func markStarted() {
        guard started < queued.count else { return }
        let item = queued[started]; started += 1
        item.onStart()
    }

    #if DEBUG
    var isEngineRunning: Bool { engine.isRunning }
    /// Stops the engine the way the system does on an audio configuration change,
    /// including the notification it posts afterwards.
    func stopEngineForTesting() {
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }
    #endif
}
