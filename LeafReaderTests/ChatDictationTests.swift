import XCTest
@testable import LeafReader

@MainActor private final class DictationRecognizerProbe: ChatDictationRecognizing {
    var authorizationError: Error?
    var startError: Error?
    var authorization: CheckedContinuation<Void, Error>?
    var delaysAuthorization = false
    var starts = 0, finishes = 0, cancellations = 0
    var locale: String?
    var update: ((String, Bool) -> Void)?
    var failure: ((Error) -> Void)?
    func authorize() async throws {
        if let authorizationError { throw authorizationError }
        if delaysAuthorization { try await withCheckedThrowingContinuation { authorization = $0 } }
    }
    func start(locale: String, update: @escaping (String, Bool) -> Void, failure: @escaping (Error) -> Void) throws {
        if let startError { throw startError }
        starts += 1; self.locale = locale; self.update = update; self.failure = failure
    }
    func finish() { finishes += 1 }
    func cancel() { cancellations += 1 }
}

@MainActor final class ChatDictationTests: XCTestCase {
    func testPartialRevisionsReplaceOnlyTheDictatedSegment() async throws {
        let backend = DictationRecognizerProbe()
        let session = ChatDictationSession(recognizer: backend)
        var draft = "Explain"
        session.start(draft: draft, language: .english) { draft = $0 }
        try await eventually(timeout: 1, interval: 0.002) { session.state == .recording }
        backend.update?("this", false); XCTAssertEqual(draft, "Explain this")
        backend.update?("this character", false); XCTAssertEqual(draft, "Explain this character")
        backend.update?("this character.", true)
        XCTAssertEqual(draft, "Explain this character."); XCTAssertFalse(session.isActive)
        XCTAssertEqual(backend.locale, "en-US"); XCTAssertEqual(backend.cancellations, 1)
    }
    func testChineseAndWhitespaceKeepNaturalDraftBoundaries() {
        XCTAssertEqual(ChatDictationSession.appending("是谁？", to: "白虎"), "白虎是谁？")
        XCTAssertEqual(ChatDictationSession.appending("中文问题", to: ""), "中文问题")
        XCTAssertEqual(ChatDictationSession.appending("question", to: "First\n"), "First\nquestion")
        XCTAssertEqual(ChatDictationSession.appending("", to: "Keep me"), "Keep me")
        XCTAssertEqual(DictationLanguage.mandarin.locale, "zh-CN")
        XCTAssertEqual(DictationLanguage.traditionalChinese.locale, "zh-TW")
        XCTAssertEqual(DictationLanguage.cantonese.locale, "zh-HK")
    }
    func testAutomaticUsesChineseBookOrQuoteOnAnEnglishPhone() {
        XCTAssertEqual(DictationLanguage.system.resolvedLocale(bookTitle: "十日终焉", deviceLanguage: "en-US"), "zh-CN")
        XCTAssertEqual(DictationLanguage.system.resolvedLocale(bookTitle: "紅樓夢", deviceLanguage: "en-US"), "zh-TW")
        XCTAssertEqual(DictationLanguage.system.resolvedLocale(bookTitle: "A Book", selectedText: "请解释这段文字，我想了解这个人物。", deviceLanguage: "en-US"), "zh-CN")
        XCTAssertEqual(DictationLanguage.system.resolvedLocale(bookTitle: "A Book", deviceLanguage: "en-GB"), "en-GB")
    }
    func testExplicitLanguageOverridesBookAndDevice() {
        XCTAssertEqual(DictationLanguage.english.resolvedLocale(bookTitle: "十日终焉", deviceLanguage: "zh-CN"), "en-US")
        XCTAssertEqual(DictationLanguage.mandarin.resolvedLocale(bookTitle: "A Book", deviceLanguage: "en-US"), "zh-CN")
        XCTAssertEqual(DictationLanguage.cantonese.resolvedLocale(bookTitle: "A Book", deviceLanguage: "en-US"), "zh-HK")
    }
    func testAutomaticPassesMandarinToRecognizerForChineseBook() async throws {
        let backend = DictationRecognizerProbe()
        let voice = ChatDictationSession(recognizer: backend)
        var draft = ""
        voice.start(draft: draft, language: .system, bookTitle: "十日终焉") { draft = $0 }
        try await eventually(timeout: 1, interval: 0.002) { voice.state == .recording }
        XCTAssertEqual(backend.locale, "zh-CN")
        XCTAssertEqual(voice.localeIdentifier, "zh-CN")
        backend.update?("这个人物是谁？", true)
        XCTAssertEqual(draft, "这个人物是谁？")
    }
    func testStopAcceptsFinalRevisionButNeverLateResults() async throws {
        let backend = DictationRecognizerProbe(), session: ChatDictationSession
        session = ChatDictationSession(recognizer: backend)
        var draft = ""
        session.start(draft: draft, language: .mandarin) { draft = $0 }
        try await eventually(timeout: 1, interval: 0.002) { session.state == .recording }
        backend.update?("解释", false); session.finish()
        XCTAssertEqual(session.state, .finishing); XCTAssertEqual(backend.finishes, 1)
        backend.update?("解释这段文字。", true)
        XCTAssertEqual(draft, "解释这段文字。"); XCTAssertFalse(session.isActive)
        backend.update?("Late overwrite", false)
        XCTAssertEqual(draft, "解释这段文字。")
    }
    func testDeniedPermissionsPreserveDraftAndOfferSettings() async throws {
        for permission in [ChatDictationError.microphonePermission, .speechPermission] {
            let backend = DictationRecognizerProbe(); backend.authorizationError = permission
            let session = ChatDictationSession(recognizer: backend)
            var draft = "Keep my question"
            session.start(draft: draft, language: .system) { draft = $0 }
            try await eventually(timeout: 1, interval: 0.002) { session.error != nil }
            XCTAssertFalse(session.isActive); XCTAssertEqual(backend.starts, 0)
            XCTAssertTrue(session.needsSettings); XCTAssertEqual(draft, "Keep my question")
        }
    }
    func testCancelledPermissionRequestCannotStartRecordingLater() async throws {
        let backend = DictationRecognizerProbe(); backend.delaysAuthorization = true
        let session = ChatDictationSession(recognizer: backend)
        session.start(draft: "Keep me", language: .english) { _ in XCTFail("Cancelled permission must not change the draft") }
        try await eventually(timeout: 1, interval: 0.002) { backend.authorization != nil }
        session.suspend(background: false)
        XCTAssertEqual(session.state, .authorizing, "A first-use permission dialog may make the app inactive")
        session.suspend(background: true); backend.authorization?.resume(); backend.authorization = nil
        await Task.yield()
        XCTAssertFalse(session.isActive); XCTAssertEqual(backend.starts, 0)
    }
    func testCloseOrInterruptionKeepsPartialTextAndRejectsOldSessionEvents() async throws {
        let backend = DictationRecognizerProbe(), session: ChatDictationSession
        session = ChatDictationSession(recognizer: backend)
        var draft = "Remember"
        session.start(draft: draft, language: .english) { draft = $0 }
        try await eventually(timeout: 1, interval: 0.002) { session.state == .recording }
        backend.update?("this name", false); let old = backend.update
        session.suspend(background: false); XCTAssertEqual(draft, "Remember this name")
        session.start(draft: draft, language: .english) { draft = $0 }
        try await eventually(timeout: 1, interval: 0.002) { session.state == .recording }
        old?("discard me", true); XCTAssertEqual(session.state, .recording)
        backend.update?("please", true)
        XCTAssertEqual(draft, "Remember this name please")
    }
    func testUnavailableRecognizerPreservesDraftAndReleasesResources() async throws {
        let backend = DictationRecognizerProbe(); backend.startError = ChatDictationError.unavailable
        let session = ChatDictationSession(recognizer: backend)
        var draft = "Unsent question"
        session.start(draft: draft, language: .mandarin) { draft = $0 }
        try await eventually(timeout: 1, interval: 0.002) { session.error != nil }
        XCTAssertFalse(session.needsSettings); XCTAssertFalse(session.isActive)
        XCTAssertEqual(backend.cancellations, 1); XCTAssertEqual(draft, "Unsent question")
    }
    func testRecordingAndFinishingHaveBoundedLifetimesWithoutFinalResult() async throws {
        let backend = DictationRecognizerProbe()
        let session = ChatDictationSession(recognizer: backend, recordingLimit: .milliseconds(40), finishLimit: .milliseconds(10))
        var draft = ""
        session.start(draft: draft, language: .english) { draft = $0 }
        try await eventually(timeout: 1, interval: 0.002) { session.state == .recording }
        backend.update?("Keep the partial text", false)
        try await eventually(timeout: 1, interval: 0.002) { !session.isActive }
        XCTAssertEqual(backend.finishes, 1); XCTAssertEqual(backend.cancellations, 1)
        XCTAssertEqual(draft, "Keep the partial text"); XCTAssertNil(session.error)
    }
    func testDictatedDraftPersistsWithoutSendingAChatMessage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let history = try ChatHistoryStore(directory: url, conversation: "dictation")
        let chat = ReaderChatSession(history: history), backend = DictationRecognizerProbe()
        let session = ChatDictationSession(recognizer: backend)
        session.start(draft: chat.draft, language: .mandarin) { chat.draft = $0 }
        try await eventually(timeout: 1, interval: 0.002) { session.state == .recording }
        backend.update?("帮我回忆这个人物", false); session.cancel(); chat.close()
        let restored = ReaderChatSession(history: try ChatHistoryStore(directory: url, conversation: "dictation"))
        XCTAssertEqual(restored.draft, "帮我回忆这个人物")
        XCTAssertTrue(chat.messages.isEmpty); XCTAssertTrue(restored.messages.isEmpty)
    }
}
