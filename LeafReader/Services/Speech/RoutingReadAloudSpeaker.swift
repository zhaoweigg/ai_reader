import Foundation

enum ReadAloudEngine: String, CaseIterable, Identifiable {
    case system, kokoro
    var id: String { rawValue }
    var title: String { self == .system ? "Apple voices" : "Natural voice" }
    static let kokoroPrefix = "kokoro:"
}

/// Chooses the engine per passage from the voice string: `kokoro:<voice id>`
/// selects the on-device model; anything else is an Apple voice identifier.
/// Production supplies a strict Enhanced/Premium system speaker. If neither
/// engine can start, preserve the passage and report an error instead of skipping it.
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
    var failed: ((Error) -> Void)?
    var usingKokoro: Bool { active === kokoro }

    init(system: any ReadAloudSpeaking, kokoro: KokoroReadAloudSpeaker) {
        self.system = system; self.kokoro = kokoro
        kokoro.failedToStart = { [weak self] error in self?.fallBack(error) }
    }
    func speak(_ text: String, language: String, voice: String, speed: Double) throws {
        active?.stop(); active = nil; fallbackReason = nil
        request = (text, language, speed)
        if voice.hasPrefix(ReadAloudEngine.kokoroPrefix) {
            let id = String(voice.dropFirst(ReadAloudEngine.kokoroPrefix.count))
            do {
                try kokoro.speak(text, language: language, voice: id, speed: speed)
                active = kokoro; fallbackReason = nil
                return
            } catch {
                try system.speak(text, language: language, voice: "", speed: speed)
                active = system; fallbackReason = error.localizedDescription
                return
            }
        }
        try system.speak(text, language: language, voice: voice, speed: speed)
        active = system
    }
    private func fallBack(_ error: Error) {
        guard active === kokoro, let request else { return }
        do {
            try system.speak(request.text, language: request.language, voice: "", speed: request.speed)
            active = system; fallbackReason = error.localizedDescription
        } catch { active = nil; fallbackReason = nil; failed?(error) }
    }
    func prepare(_ text: String, language: String, voice: String, speed: Double) {
        guard voice.hasPrefix(ReadAloudEngine.kokoroPrefix) else { return }
        kokoro.prepare(text, language: language, voice: String(voice.dropFirst(ReadAloudEngine.kokoroPrefix.count)), speed: speed)
    }
    func pause() { active?.pause() }
    func resume() -> Bool { active?.resume() ?? false }
    func stop() { active?.stop(); active = nil; request = nil }
}
