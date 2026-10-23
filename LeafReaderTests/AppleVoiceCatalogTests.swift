import AVFoundation
import XCTest
@testable import LeafReader

final class AppleVoiceCatalogTests: XCTestCase {
    private let basic = AppleReadingVoice(id: "compact", name: "Compact", language: "zh-CN", quality: .default)
    private let enhanced = AppleReadingVoice(id: "enhanced", name: "Enhanced", language: "zh-CN", quality: .enhanced)
    private let premium = AppleReadingVoice(id: "premium", name: "Premium", language: "zh-TW", quality: .premium)

    func testCompactVoicesCannotAppearInTheCatalogOrAutomaticSelection() {
        XCTAssertTrue(AppleVoiceCatalog.eligible([basic]).isEmpty)
        XCTAssertNil(AppleVoiceCatalog.preferredIdentifier(selected: basic.id, language: "zh-CN", voices: [basic]))
    }
    func testAutomaticPrefersPremiumWithinTheTextsLanguage() {
        XCTAssertEqual(AppleVoiceCatalog.preferredIdentifier(selected: "", language: "zh-CN", voices: [basic, enhanced, premium]), premium.id)
    }
    func testAnExplicitEnhancedChoiceIsPreservedWhenPremiumIsAvailable() {
        XCTAssertEqual(AppleVoiceCatalog.preferredIdentifier(selected: enhanced.id, language: "zh-CN", voices: [basic, enhanced, premium]), enhanced.id)
    }
    func testDeletedOrLegacyCompactChoicesResolveToAnEligibleVoice() {
        for selected in ["deleted", basic.id] {
            XCTAssertEqual(AppleVoiceCatalog.preferredIdentifier(selected: selected, language: "zh-CN", voices: [basic, enhanced]), enhanced.id)
        }
    }
    func testAutomaticDoesNotSubstituteAnUnrelatedLanguage() {
        XCTAssertNil(AppleVoiceCatalog.preferredIdentifier(selected: "", language: "fr-FR", voices: [basic, enhanced, premium]))
        XCTAssertNil(AppleVoiceCatalog.preferredIdentifier(selected: "", language: "yue-HK", voices: [enhanced, premium]))
        XCTAssertNil(AppleVoiceCatalog.preferredIdentifier(selected: "", language: "", voices: [premium]))
    }
    func testMatchingDialectBreaksTiesAndLanguageTagsAreNormalized() {
        let other = AppleReadingVoice(id: "premium-cn", name: "Premium CN", language: "zh-CN", quality: .premium)
        XCTAssertEqual(AppleVoiceCatalog.preferredIdentifier(selected: "", language: "ZH_cn", voices: [premium, other]), other.id)
    }
    func testOnlyEligibleQualitiesAreLabeledAndListed() {
        let catalog = AppleVoiceCatalog.eligible([premium, basic, enhanced])
        XCTAssertEqual(catalog.map(\.id), [enhanced.id, premium.id])
        XCTAssertEqual(catalog.map(\.qualityLabel), ["Enhanced", "Premium"])
        XCTAssertEqual(basic.qualityLabel, "Basic")
    }
    func testCatalogUsesActualInstalledQualitiesWithoutAssumingAPackIsPresent() {
        XCTAssertTrue(AppleVoiceCatalog.installed.allSatisfy(\.isHighQuality))
        let details = AppleVoiceCatalog.installed.map { ["id": $0.id, "language": $0.language, "quality": $0.qualityLabel] }
        let attachment = XCTAttachment(string: String(describing: details))
        attachment.name = "Installed Enhanced and Premium Apple voices"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testNewSessionsPreferNaturalAndLegacyCompactChoicesMigrateWithoutLosingEngineChoice() {
        let name = "AppleQualityMigration.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
        XCTAssertEqual(fresh.engine, .kokoro)
        defaults.set("system", forKey: "audio.engine")
        defaults.set("com.apple.voice.compact.zh-CN.Tingting", forKey: "audio.voice")
        let migrated = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
        XCTAssertEqual(migrated.engine, .system, "An explicit existing engine choice is retained")
        XCTAssertEqual(migrated.voice, "")
        XCTAssertEqual(defaults.string(forKey: "audio.voice"), "", "A compact identifier cannot return on the next launch")
        migrated.engine = .kokoro; migrated.kokoroVoice = "zf_003"
        let reopened = ReadAloudSession(defaults: defaults, speaker: RecordingSpeaker())
        XCTAssertEqual(reopened.engine, .kokoro); XCTAssertEqual(reopened.kokoroVoice, "zf_003")
    }
    @MainActor func testStrictSpeakerFailsBeforeSpeechWhenNoHighQualityVoiceIsInstalled() {
        let speaker = SystemReadAloudSpeaker(requiresHighQuality: true, installedVoices: { [] })
        defer { speaker.stop(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        var progressed = false, finished = false
        speaker.progressed = { _ in progressed = true }; speaker.finished = { finished = true }
        XCTAssertThrowsError(try speaker.speak("Read this paragraph.", language: "en", voice: "", speed: 1)) {
            XCTAssertTrue($0 is AppleReadingVoiceError)
        }
        XCTAssertFalse(progressed); XCTAssertFalse(finished)
    }
}
