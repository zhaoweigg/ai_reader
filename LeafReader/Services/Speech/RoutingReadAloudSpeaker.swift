import Foundation

enum ReadAloudEngine: String, CaseIterable, Identifiable {
    case system, kokoro
    var id: String { rawValue }
    var title: String { self == .system ? "iPhone voice" : "Natural voice (on-device)" }
    static let kokoroPrefix = "kokoro:"
}

/// Chooses the engine per passage from the voice string: `kokoro:<voice id>`
/// selects the on-device model; anything else is an Apple voice identifier.
/// When the model is unavailable or fails to start, the same passage is spoken
/// with the system voice so listening never stops because of the download state.
@MainActor final class RoutingReadAloudSpeaker: ReadAloudSpeaking, ReadAloudBufferingReporter {
    var finished: (() -> Void)? { didSet { system.finished = finished; kokoro.finished = finished } }
    var progressed: ((NSRange) -> Void)? { didSet { system.progressed = progressed; kokoro.progressed = progressed } }
    var buffering: ((Bool) -> Void)? { didSet { kokoro.buffering = buffering } }
    let system: any ReadAloudSpeaking
    let kokoro: KokoroReadAloudSpeaker
    private(set) var active: (any ReadAloudSpeaking)?
    private var request: (text: String, language: String, speed: Double)?
    /// Set when the last passage fell back to the system voice; cleared by the next Kokoro passage that starts.
    private(set) var fallbackReason: String? { didSet { if fallbackReason != oldValue { onFallback?(fallbackReason) } } }
    var onFallback: ((String?) -> Void)?
    var usingKokoro: Bool { active === kokoro }

    init(system: any ReadAloudSpeaking, kokoro: KokoroReadAloudSpeaker) {
        self.system = system; self.kokoro = kokoro
        kokoro.failedToStart = { [weak self] error in self?.fallBack(error) }
    }
    func speak(_ text: String, language: String, voice: String, speed: Double) throws {
        active?.stop(); active = nil
        request = (text, language, speed)
        if voice.hasPrefix(ReadAloudEngine.kokoroPrefix) {
            let id = String(voice.dropFirst(ReadAloudEngine.kokoroPrefix.count))
            do {
                try kokoro.speak(text, language: language, voice: id, speed: speed)
                active = kokoro; fallbackReason = nil
                return
            } catch { fallbackReason = error.localizedDescription }
        }
        active = system
        try system.speak(text, language: language, voice: voice.hasPrefix(ReadAloudEngine.kokoroPrefix) ? "" : voice, speed: speed)
    }
    private func fallBack(_ error: Error) {
        guard active === kokoro, let request else { return }
        fallbackReason = error.localizedDescription
        active = system
        do { try system.speak(request.text, language: request.language, voice: "", speed: request.speed) }
        catch { active = nil; finished?() }
    }
    func prepare(_ text: String, language: String, voice: String, speed: Double) {
        guard voice.hasPrefix(ReadAloudEngine.kokoroPrefix) else { return }
        kokoro.prepare(text, language: language, voice: String(voice.dropFirst(ReadAloudEngine.kokoroPrefix.count)), speed: speed)
    }
    func pause() { active?.pause() }
    func resume() -> Bool { active?.resume() ?? false }
    func stop() { active?.stop(); active = nil; request = nil }
}
