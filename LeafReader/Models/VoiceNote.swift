import Foundation

/// Immutable audio. A replacement recording gets a new identity, so sync never
/// overwrites a clip another device is playing or still needs to download.
struct VoiceNote: Identifiable, Codable, Equatable {
    static let maximumDuration: TimeInterval = 600
    static let maximumBytes: Int64 = 12 * 1024 * 1024
    let id: UUID
    let duration: TimeInterval
    let byteCount: Int64
    let sha256: String
    var fileName: String { id.uuidString.lowercased() + ".m4a" }
    var valid: Bool {
        duration.isFinite && duration >= 0.1 && duration <= Self.maximumDuration + 0.1
            && byteCount > 0 && byteCount <= Self.maximumBytes
            && sha256.count == 64 && sha256.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    var durationLabel: String { Self.timeLabel(duration) }
    static func timeLabel(_ seconds: TimeInterval) -> String {
        let value = Int(min(maximumDuration, max(0, seconds.isFinite ? seconds : 0)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

enum VoiceNoteError: LocalizedError {
    case microphonePermission, unavailable, invalidRecording, tooShort, missingAudio
    var errorDescription: String? {
        switch self {
        case .microphonePermission: return "Allow microphone access for Leaf in Settings to record a voice note."
        case .unavailable: return "The voice note could not be recorded. Check your microphone and try again."
        case .invalidRecording: return "This audio recording could not be read. Your saved note has been kept."
        case .tooShort: return "The recording was too short. Record a little longer and try again."
        case .missingAudio: return "This voice note’s audio is unavailable. If you use iCloud, sync your library and try again."
        }
    }
}
