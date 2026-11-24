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
    /// The value of a registered launch key, only while UI testing.
    static func value(_ key: UITestValue) -> String? { environment(key.rawValue) }
    /// True when the launch environment sets the flag to "1".
    static func flag(_ flag: UITestFlag) -> Bool { environment(flag.rawValue) == "1" }
    /// The isolated defaults suite of this test launch, or the standard defaults.
    static var defaults: UserDefaults {
        testID.flatMap { UserDefaults(suiteName: "com.leafreader.uitests.\($0.uuidString)") } ?? .standard
    }
}

/// Every on/off switch the UI tests can set in the launch environment. The raw
/// value is the environment key the test target passes; adding a fixture means
/// adding a case here, so the full list of test seams stays in one place.
enum UITestFlag: String, CaseIterable {
    // Speech
    case appleSpeech = "LEAF_UI_APPLE_SPEECH"
    // Audio
    case backgroundAudio = "LEAF_UI_BACKGROUND_AUDIO"
    // Bestsellers
    case bestsellersDisconnected = "LEAF_UI_BESTSELLERS_DISCONNECTED"
    case bestsellersDownloadFailure = "LEAF_UI_BESTSELLERS_DOWNLOAD_FAILURE"
    case bestsellersFeedFailure = "LEAF_UI_BESTSELLERS_FEED_FAILURE"
    case bestsellersMock = "LEAF_UI_BESTSELLERS_MOCK"
    case bestsellersQuota = "LEAF_UI_BESTSELLERS_QUOTA"
    case bestsellersSlowDownload = "LEAF_UI_BESTSELLERS_SLOW_DOWNLOAD"
    // Book reviews
    case bookReviewsFailure = "LEAF_UI_BOOK_REVIEWS_FAILURE"
    // ChatGPT
    case chatgptBrowser = "LEAF_UI_CHATGPT_BROWSER"
    case chatgptConnected = "LEAF_UI_CHATGPT_CONNECTED"
    // Chat
    case chatAgent = "LEAF_UI_CHAT_AGENT"
    case chatContextProbe = "LEAF_UI_CHAT_CONTEXT_PROBE"
    case chatFollow = "LEAF_UI_CHAT_FOLLOW"
    case chatImage = "LEAF_UI_CHAT_IMAGE"
    case chatMarkdown = "LEAF_UI_CHAT_MARKDOWN"
    case chatMock = "LEAF_UI_CHAT_MOCK"
    case chatRecovery = "LEAF_UI_CHAT_RECOVERY"
    case chatRecoveryAgent = "LEAF_UI_CHAT_RECOVERY_AGENT"
    case chatScrollLegacy = "LEAF_UI_CHAT_SCROLL_LEGACY"
    case chatScrollPerf = "LEAF_UI_CHAT_SCROLL_PERF"
    case chatScrollStream = "LEAF_UI_CHAT_SCROLL_STREAM"
    case chatSlow = "LEAF_UI_CHAT_SLOW"
    case chatSlowStart = "LEAF_UI_CHAT_SLOW_START"
    // Dictation
    case dictationMock = "LEAF_UI_DICTATION_MOCK"
    // Empty
    case emptyLibrary = "LEAF_UI_EMPTY_LIBRARY"
    // Now
    case nowPlaying = "LEAF_UI_NOW_PLAYING"
    // Saved
    case savedFixture = "LEAF_UI_SAVED_FIXTURE"
    // Scene geometry
    case sceneGeometryFixture = "LEAF_UI_SCENE_GEOMETRY_FIXTURE"
    // Scroll
    case scrollTouchTrace = "LEAF_UI_SCROLL_TOUCH_TRACE"
    // Sync
    case syncFixture = "LEAF_UI_SYNC_FIXTURE"
    case syncOtherDevice = "LEAF_UI_SYNC_OTHER_DEVICE"
    // Voice
    case voiceNotes = "LEAF_UI_VOICE_NOTES"
    // Web novels
    case webNovelsFeedFailure = "LEAF_UI_WEB_NOVELS_FEED_FAILURE"
    case webNovelsMock = "LEAF_UI_WEB_NOVELS_MOCK"
    // Zlib
    case zlibAsyncDetails = "LEAF_UI_ZLIB_ASYNC_DETAILS"
    case zlibFeedFailure = "LEAF_UI_ZLIB_FEED_FAILURE"
    case zlibGrid = "LEAF_UI_ZLIB_GRID"
    case zlibMock = "LEAF_UI_ZLIB_MOCK"
    case zlibPopularRedirect = "LEAF_UI_ZLIB_POPULAR_REDIRECT"
    case zlibRecommendationsEmpty = "LEAF_UI_ZLIB_RECOMMENDATIONS_EMPTY"
    case zlibRecommendationsFailure = "LEAF_UI_ZLIB_RECOMMENDATIONS_FAILURE"
    case zlibRepeatGuard = "LEAF_UI_ZLIB_REPEAT_GUARD"
    case zlibShelf = "LEAF_UI_ZLIB_SHELF"
    case zlibShelfEmpty = "LEAF_UI_ZLIB_SHELF_EMPTY"
    case zlibShelfRefresh = "LEAF_UI_ZLIB_SHELF_REFRESH"
    case zlibShelfRetry = "LEAF_UI_ZLIB_SHELF_RETRY"
    case zlibThumbnails = "LEAF_UI_ZLIB_THUMBNAILS"
    case zlibTrace = "LEAF_UI_ZLIB_TRACE"
    case zlibWebsiteFixture = "LEAF_UI_ZLIB_WEBSITE_FIXTURE"
}

/// Launch environment keys whose value is read, not just checked for "1".
enum UITestValue: String, CaseIterable {
    case testID = "LEAF_UI_TEST_ID"
    // Chat
    case chatHistory = "LEAF_UI_CHAT_HISTORY"
    // Contents
    case contentsBook = "LEAF_UI_CONTENTS_BOOK"
    case contentsLocator = "LEAF_UI_CONTENTS_LOCATOR"
    // Dictation
    case dictationNativeAudio = "LEAF_UI_DICTATION_NATIVE_AUDIO"
    // Voice
    case voiceNotePermission = "LEAF_UI_VOICE_NOTE_PERMISSION"
    // Zlib
    case zlibDetails = "LEAF_UI_ZLIB_DETAILS"
    case zlibSummary = "LEAF_UI_ZLIB_SUMMARY"
}
#endif
