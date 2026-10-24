#if DEBUG
import Foundation

/// Launch context for XCUITest runs. Every value is inert unless the app was
/// launched with `--ui-testing`; Release builds contain none of this.
enum UITesting {
    static let isActive = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    /// Per-launch identifier that isolates defaults, Keychain and files between parallel test jobs.
    static var testID: UUID? { environment("LEAF_UI_TEST_ID").flatMap(UUID.init(uuidString:)) }
    /// A launch environment value, only while UI testing.
    static func environment(_ key: String) -> String? { isActive ? ProcessInfo.processInfo.environment[key] : nil }
    /// True when the launch environment sets `key` to "1".
    static func flag(_ key: String) -> Bool { environment(key) == "1" }
    /// The isolated defaults suite of this test launch, or the standard defaults.
    static var defaults: UserDefaults {
        testID.flatMap { UserDefaults(suiteName: "com.leafreader.uitests.\($0.uuidString)") } ?? .standard
    }
}
#endif
