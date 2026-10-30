import AVFoundation
import Foundation

/// A small, testable description of voices actually installed on this device.
/// Compact/default voices are never a user choice or an automatic substitute.
struct AppleReadingVoice: Equatable, Identifiable {
    let id: String
    let name: String
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality

    var qualityLabel: String {
        switch quality { case .premium: return "Premium"; case .enhanced: return "Enhanced"; default: return "Basic" }
    }
    var isHighQuality: Bool { quality == .enhanced || quality == .premium }
}

enum AppleVoiceCatalog {
    static var installed: [AppleReadingVoice] {
        eligible(AVSpeechSynthesisVoice.speechVoices().map {
            AppleReadingVoice(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality)
        })
    }

    static func eligible(_ voices: [AppleReadingVoice]) -> [AppleReadingVoice] {
        voices.filter(\.isHighQuality).sorted {
            if $0.language != $1.language { return $0.language < $1.language }
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
    }

    static func preferredIdentifier(selected: String, language: String, voices: [AppleReadingVoice]) -> String? {
        let available = eligible(voices)
        if let explicit = available.first(where: { $0.id == selected }) { return explicit.id }
        let language = normalized(language)
        guard !language.isEmpty else { return nil }
        let base = language.split(separator: "-").first
        return available.filter { normalized($0.language).split(separator: "-").first == base }.sorted {
            // Premium is preferred across dialects; a dialect match breaks ties.
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            let exactA = normalized($0.language) == language, exactB = normalized($1.language) == language
            if exactA != exactB { return exactA }
            return $0.id < $1.id
        }.first?.id
    }

    private static func normalized(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

enum AppleReadingVoiceError: LocalizedError {
    case downloadRequired
    var errorDescription: String? {
        "No Enhanced or Premium Apple voice is installed for this language. Download one in iPhone Accessibility settings, then return to Leaf."
    }
}
