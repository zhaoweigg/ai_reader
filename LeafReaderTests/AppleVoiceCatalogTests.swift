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
}
