import Foundation
import NaturalLanguage

/// Speaker table of the Kokoro v1.1 Chinese+English export (`kokoro-multi-lang-v1_1`).
/// Speaker ids are positions in `voices.bin`; the names follow the upstream
/// Kokoro voice ids (`af_` American female, `bf_` British female, `zf_`/`zm_`
/// Chinese female/male).
struct KokoroVoice: Identifiable, Hashable {
    enum Language: String { case english = "en", chinese = "zh" }
    enum Gender: String { case female, male }
    let id: String
    let speaker: Int
    let language: Language
    let gender: Gender
    var title: String {
        switch id {
        case "af_maple": return "Maple · American"
        case "af_sol": return "Sol · American"
        case "bf_vale": return "Vale · British"
        default:
            let number = id.split(separator: "_").last.map(String.init) ?? id
            return (gender == .female ? "Chinese female " : "Chinese male ") + number
        }
    }
}

enum KokoroVoiceCatalog {
    static let english: [KokoroVoice] = [
        KokoroVoice(id: "af_maple", speaker: 0, language: .english, gender: .female),
        KokoroVoice(id: "af_sol", speaker: 1, language: .english, gender: .female),
        KokoroVoice(id: "bf_vale", speaker: 2, language: .english, gender: .female),
    ]
    private static let femaleNumbers = [
        "001", "002", "003", "004", "005", "006", "007", "008", "017", "018", "019", "021", "022", "023", "024", "026", "027", "028",
        "032", "036", "038", "039", "040", "042", "043", "044", "046", "047", "048", "049", "051", "059", "060", "067", "070", "071",
        "072", "073", "074", "075", "076", "077", "078", "079", "083", "084", "085", "086", "087", "088", "090", "092", "093", "094", "099",
    ]
    private static let maleNumbers = [
        "009", "010", "011", "012", "013", "014", "015", "016", "020", "025", "029", "030", "031", "033", "034", "035", "037", "041",
        "045", "050", "052", "053", "054", "055", "056", "057", "058", "061", "062", "063", "064", "065", "066", "068", "069", "080",
        "081", "082", "089", "091", "095", "096", "097", "098", "100",
    ]
    static let chineseFemale: [KokoroVoice] = femaleNumbers.enumerated().map {
        KokoroVoice(id: "zf_\($0.element)", speaker: 3 + $0.offset, language: .chinese, gender: .female)
    }
    static let chineseMale: [KokoroVoice] = maleNumbers.enumerated().map {
        KokoroVoice(id: "zm_\($0.element)", speaker: 3 + femaleNumbers.count + $0.offset, language: .chinese, gender: .male)
    }
    static let all = english + chineseFemale + chineseMale
    static let speakerCount = 103
    static let defaultEnglish = english[0]
    static let defaultChinese = chineseFemale[0]
    static func voice(id: String) -> KokoroVoice? { all.first { $0.id == id } }

    /// Chooses a speaker for a passage: an explicit voice id wins; otherwise the
    /// text's script decides, then the passage language, then the device language.
    static func automaticVoice(for text: String, language: String) -> KokoroVoice {
        var han = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3000...0x303F, 0xFF00...0xFFEF: han += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
            if han + latin > 400 { break }
        }
        // Mixed passages follow the majority script; a few foreign words keep the main voice.
        if han > 0 || latin > 0 { return han * 4 >= latin ? defaultChinese : defaultEnglish }
        if language.lowercased().hasPrefix("zh") { return defaultChinese }
        if language.lowercased().hasPrefix("en") { return defaultEnglish }
        let recognizer = NLLanguageRecognizer(); recognizer.processString(String(text.prefix(400)))
        if let dominant = recognizer.dominantLanguage, dominant == .simplifiedChinese || dominant == .traditionalChinese { return defaultChinese }
        return Locale.current.language.languageCode?.identifier == "zh" ? defaultChinese : defaultEnglish
    }
}
