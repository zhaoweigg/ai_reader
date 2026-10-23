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

@MainActor final class AudioEnginePlayer: KokoroAudioPlaying {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var generation = 0
    private var queued: [(onStart: () -> Void, onFinish: () -> Void)] = []
    private var started = 0, completed = 0

    init() { engine.attach(node) }

    func prepare(sampleRate: Int) throws {
        if let format, Int(format.sampleRate) == sampleRate, engine.isRunning { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) else {
            throw AVError(.unknown)
        }
        node.stop(); engine.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.format = format
        try engine.start()
        node.play()
    }
    func enqueue(_ audio: KokoroAudio, onStart: @escaping () -> Void, onFinish: @escaping () -> Void) {
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        audio.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: audio.samples.count) }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        let token = generation
        let index = queued.count
        queued.append((onStart, onFinish))
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.didFinish(index, token: token) } }
        }
        if !engine.isRunning { try? engine.start() }
        if !node.isPlaying { node.play() }
        // The first queued sentence, or one queued after the previous finished,
        // begins immediately; otherwise its start is the predecessor's completion.
        if index == started, completed == started { markStarted() }
    }
    private func didFinish(_ index: Int, token: Int) {
        guard token == generation, index < queued.count, index == completed else { return }
        completed += 1
        queued[index].onFinish()
        if completed == started, started < queued.count { markStarted() }
    }
    private func markStarted() {
        guard started < queued.count else { return }
        let item = queued[started]; started += 1
        item.onStart()
    }
    func pause() { node.pause(); engine.pause() }
    func resume() throws {
        if !engine.isRunning { try engine.start() }
        node.play()
    }
    func stop() {
        generation += 1
        queued.removeAll(); started = 0; completed = 0
        node.stop()
        engine.pause()
    }
}
