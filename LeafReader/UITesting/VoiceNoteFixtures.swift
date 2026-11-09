import Foundation
import AVFoundation

#if DEBUG
/// Deterministic, real AAC files for UI/storage/player checks, not microphone QA.
@MainActor final class FixtureVoiceNoteRecorder: VoiceNoteRecording {
    private var url: URL?
    private var started = Date()
    var currentTime: TimeInterval { Date().timeIntervalSince(started) }
    func authorize() async -> Bool { UITesting.value(.voiceNotePermission) != "denied" }
    func start(at url: URL, limit: TimeInterval, finished: @escaping (Bool) -> Void) throws { self.url = url; started = Date() }
    func stop() {
        guard let url else { return }; self.url = nil
        try? VoiceNoteFixture.write(to: url, duration: 5)
    }
    func cancel() { url = nil }
}
enum VoiceNoteFixture {
    static func write(to url: URL, duration: TimeInterval = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let count = AVAudioFrameCount(24_000 * min(10, max(0.1, duration)))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / 24_000) * 0.03) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        try file.write(from: buffer)
    }
}
#endif
