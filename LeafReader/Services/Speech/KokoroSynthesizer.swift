import Foundation
import sherpa_onnx

struct KokoroAudio: Equatable {
    let samples: [Float]
    let sampleRate: Int
    var duration: TimeInterval { sampleRate > 0 ? TimeInterval(samples.count) / TimeInterval(sampleRate) : 0 }
}

/// A loaded on-device synthesizer. Calls block the calling thread for the whole
/// sentence; callers run them on a dedicated serial queue, never on the main thread.
protocol KokoroSynthesizing: AnyObject {
    var sampleRate: Int { get }
    /// Returns nil when generation fails or `shouldContinue` reports cancellation.
    func synthesize(_ text: String, speaker: Int, speed: Double, shouldContinue: @escaping () -> Bool) -> KokoroAudio?
}

enum KokoroSynthesizerError: LocalizedError {
    case loadFailed
    var errorDescription: String? { "The natural voice could not be loaded. Download the voice pack again." }
}

/// sherpa-onnx (onnxruntime, CPU) running the Kokoro v1.1 Chinese+English model.
final class SherpaKokoroSynthesizer: KokoroSynthesizing {
    private let handle: OpaquePointer
    let sampleRate: Int
    let speakerCount: Int

    /// Two threads match the performance cores of recent iPhones; more threads
    /// only add contention and heat for this model size.
    static let threads = 2

    init(modelDirectory: URL, threads: Int = SherpaKokoroSynthesizer.threads) throws {
        let path = { (name: String) in modelDirectory.appendingPathComponent(name).path }
        // Keep every C string alive until the engine has copied its configuration.
        let lexicons: String = path("lexicon-us-en.txt") + "," + path("lexicon-zh.txt")
        let rules: String = [path("phone-zh.fst"), path("date-zh.fst"), path("number-zh.fst")].joined(separator: ",")
        let values: [String] = [path("model.onnx"), path("voices.bin"), path("tokens.txt"), path("espeak-ng-data"), path("dict"), lexicons, rules, "cpu"]
        let strings: [UnsafeMutablePointer<CChar>] = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = UnsafePointer(strings[0])
        config.model.kokoro.voices = UnsafePointer(strings[1])
        config.model.kokoro.tokens = UnsafePointer(strings[2])
        config.model.kokoro.data_dir = UnsafePointer(strings[3])
        config.model.kokoro.dict_dir = UnsafePointer(strings[4])
        config.model.kokoro.lexicon = UnsafePointer(strings[5])
        config.model.kokoro.length_scale = 1
        config.model.num_threads = Int32(max(1, threads))
        config.model.provider = UnsafePointer(strings[7])
        config.model.debug = 0
        config.rule_fsts = UnsafePointer(strings[6])
        config.max_num_sentences = 1
        config.silence_scale = 0.2
        guard let handle = SherpaOnnxCreateOfflineTts(&config) else { throw KokoroSynthesizerError.loadFailed }
        self.handle = handle
        sampleRate = Int(SherpaOnnxOfflineTtsSampleRate(handle))
        speakerCount = Int(SherpaOnnxOfflineTtsNumSpeakers(handle))
    }
    deinit { SherpaOnnxDestroyOfflineTts(handle) }

    private final class Gate { let shouldContinue: () -> Bool; init(_ shouldContinue: @escaping () -> Bool) { self.shouldContinue = shouldContinue } }

    func synthesize(_ text: String, speaker: Int, speed: Double, shouldContinue: @escaping () -> Bool) -> KokoroAudio? {
        guard shouldContinue() else { return nil }
        var config = SherpaOnnxGenerationConfig()
        config.sid = Int32(min(max(speaker, 0), max(0, speakerCount - 1)))
        config.speed = Float(min(max(speed, 0.5), 2))
        config.silence_scale = 0.2
        let gate = Unmanaged.passRetained(Gate(shouldContinue))
        defer { gate.release() }
        let callback: SherpaOnnxGeneratedAudioProgressCallbackWithArg = { _, _, _, arg in
            guard let arg else { return 1 }
            return Unmanaged<Gate>.fromOpaque(arg).takeUnretainedValue().shouldContinue() ? 1 : 0
        }
        let audio = text.withCString { cText in
            SherpaOnnxOfflineTtsGenerateWithConfig(handle, cText, &config, callback, gate.toOpaque())
        }
        guard let audio else { return nil }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        guard shouldContinue(), audio.pointee.n > 0, let samples = audio.pointee.samples else { return nil }
        return KokoroAudio(samples: Array(UnsafeBufferPointer(start: samples, count: Int(audio.pointee.n))), sampleRate: Int(audio.pointee.sample_rate))
    }
}
