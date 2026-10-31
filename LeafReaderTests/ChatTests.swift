import XCTest
@testable import LeafReader

private final class MemoryChatCredentials: ChatCredentialStore {
    var values: [String: String] = [:]
    var failWrites = false
    func read(account: String) throws -> String? { values[account] }
    func write(_ key: String?, account: String) throws {
        if failWrites { throw ChatError.configuration("Test Keychain failure") }
        values[account] = key
    }
}

private struct FixtureChatTransport: ChatTransport {
    var status = 200
    var contentType = "text/event-stream"
    var lines: [String]
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
        return (response, AsyncThrowingStream { continuation in
            lines.forEach { continuation.yield($0) }; continuation.finish()
        })
    }
}

private final class ControlledChatProvider: ChatProvider {
    var requests: [ChatRequest] = []
    var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuations.append($0) }
    }
}

private final class ChatStreamURLProtocol: URLProtocol {
    static var payload = Data()
    static var remainOpen = false
    static var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Arbitrary byte boundaries, including splits within UTF-8 characters.
        for byte in Self.payload { client?.urlProtocol(self, didLoad: Data([byte])) }
        if !Self.remainOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.stopped = true }
}

@MainActor
final class ChatTests: XCTestCase {
    private var context: ReadingChatContext {
        ReadingChatContext(title: "The Book", author: "An Author", chapter: "Chapter 2", text: "The door stayed shut.", source: "page", locator: "test:2")
    }
    private var conversation: ChatRequest {
        ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Why?", context: context)])
    }
    private func provider(_ kind: ChatProviderKind = .anthropic, lines: [String] = [], status: Int = 200) -> HTTPChatProvider {
        var profile = kind.defaultProfile
        if kind == .chatCompletions { profile.model = "another-model" }
        return HTTPChatProvider(kind: kind, profile: profile, apiKey: "test-only-secret", transport: FixtureChatTransport(status: status, lines: lines))
    }
    private func collect(_ provider: any ChatProvider) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in provider.stream(conversation) { events.append(event) }
        return events
    }
    private func sse(_ json: String) -> [String] { ["data: \(json)", ""] }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    private func settings(_ override: (any ChatProvider)? = nil) -> (AISettingsStore, MemoryChatCredentials, UserDefaults) {
        let name = "LeafChatTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let credentials = MemoryChatCredentials()
        return (AISettingsStore(defaults: defaults, credentials: credentials, providerOverride: override), credentials, defaults)
    }

    func testAnthropicRequestCarriesModelSystemContextAndCorrectAuthentication() throws {
        let request = try provider().makeRequest(conversation)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-only-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["system"] as? String, ChatRequest.systemPrompt)
        XCTAssertEqual(body["max_tokens"] as? Int, 2048)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["temperature"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0]["content"]?.contains("The door stayed shut.") == true)
    }

    func testCompatibleProviderUsesItsOwnModelEndpointAndWireFormat() throws {
        var profile = ChatProviderKind.chatCompletions.defaultProfile
        profile.endpoint = "https://custom.example/api/chat/completions"; profile.model = "custom-model"
        let client = HTTPChatProvider(kind: .chatCompletions, profile: profile, apiKey: "own-key")
        let request = try client.makeRequest(conversation)
        XCTAssertEqual(request.url?.host, "custom.example")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer own-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "custom-model")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 2048)
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["role"], "system")
        profile.legacyTokenLimit = true
        let legacy = try HTTPChatProvider(kind: .chatCompletions, profile: profile, apiKey: "own-key").makeRequest(conversation)
        let legacyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(legacy.httpBody)) as? [String: Any])
        XCTAssertEqual(legacyBody["max_tokens"] as? Int, 2048)
    }

    func testRealURLSessionTransportDecodesChunkedUnicodeSSE() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatStreamURLProtocol.self]
        let lines = sse(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"中文 🌱"}}"#)
            + sse(#"{"type":"message_stop"}"#)
        ChatStreamURLProtocol.payload = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        defer { ChatStreamURLProtocol.payload = Data() }
        let client = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "test-only-key",
                                      transport: URLSessionChatTransport(configuration: configuration))
        let events = try await collect(client)
        XCTAssertEqual(events, [.text("中文 🌱"), .finished(truncated: false)])
    }

    func testCancellingConsumerStopsTheUnderlyingHTTPRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatStreamURLProtocol.self]
        let lines = sse(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Partial answer"}}"#)
        ChatStreamURLProtocol.payload = Data((lines.joined(separator: "\n") + "\n").utf8)
        ChatStreamURLProtocol.remainOpen = true; ChatStreamURLProtocol.stopped = false
        defer { ChatStreamURLProtocol.payload = Data(); ChatStreamURLProtocol.remainOpen = false }
        let client = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "test-only-key",
                                      transport: URLSessionChatTransport(configuration: configuration))
        var received = false
        let task = Task {
            do {
                for try await event in client.stream(conversation) {
                    if event == .text("Partial answer") { received = true }
                }
            } catch { }
        }
        try await wait { received }
        task.cancel()
        _ = await task.result
        try await wait { ChatStreamURLProtocol.stopped }
    }

    func testRedirectsDoNotForwardCredentials() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://original.example/messages")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let request = URLRequest(url: URL(string: "https://redirected.example/messages")!)
        var called = false
        ChatRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
            called = true; XCTAssertNil(redirected)
        }
        XCTAssertTrue(called)
    }

    func testSSEHandlesCommentsCRLFMultilineAndBounds() throws {
        var decoder = ServerSentEventDecoder()
        XCTAssertNil(try decoder.consume(": heartbeat\r"))
        XCTAssertNil(try decoder.consume("event: ping\r"))
        XCTAssertNil(try decoder.consume("\r"))
        XCTAssertNil(try decoder.consume("data: {\r"))
        XCTAssertNil(try decoder.consume("data: \"value\":\"中文\"}\r"))
        XCTAssertEqual(try decoder.consume("\r"), "{\n\"value\":\"中文\"}")
        XCTAssertThrowsError(try decoder.consume("data: " + String(repeating: "a", count: 262145)))
    }

    func testAnthropicStreamIgnoresThinkingAndHandlesUnicodeAndTokenLimit() async throws {
        let lines = [": keep alive", ""]
            + sse(#"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private"}}"#)
            + sse(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}"#)
            + sse(#"{"type":"future_metadata"}"#)
            + sse(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":" 🌱"}}"#)
            + sse(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)
            + sse(#"{"type":"message_stop"}"#)
        let events = try await collect(provider(lines: lines))
        XCTAssertEqual(events, [.text("你好"), .text(" 🌱"), .finished(truncated: true)])
    }

    func testCompatibleStreamHandlesUsageFinishAndDone() async throws {
        let lines = sse(#"{"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}"#)
            + sse(#"{"choices":[{"delta":{"content":"An answer"},"finish_reason":null}]}"#)
            + sse(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            + sse(#"{"choices":[],"usage":{"total_tokens":12}}"#) + sse("[DONE]")
        let events = try await collect(provider(.chatCompletions, lines: lines))
        XCTAssertEqual(events, [.text("An answer"), .finished(truncated: false)])
    }

    func testHTTPAndStreamErrorsNeverExposeRawServerBody() async throws {
        for status in [401, 402, 403, 404, 429, 500, 529, 302] {
            do { _ = try await collect(provider(lines: ["test-only-secret"], status: status)); XCTFail("Expected HTTP error") }
            catch { XCTAssertFalse(error.localizedDescription.contains("test-only-secret")); XCTAssertTrue(error is ChatError) }
        }
        let lines = sse(#"{"type":"error","error":{"type":"overloaded_error","message":"test-only-secret"}}"#)
        do { _ = try await collect(provider(lines: lines)); XCTFail("Expected stream error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("overloaded_error")); XCTAssertFalse(error.localizedDescription.contains("test-only-secret")) }
    }

    func testMalformedEmptyAndTruncatedConnectionsFail() async throws {
        let cases = [sse("not-json"), sse(#"{"type":"message_stop"}"#), sse(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}"#)]
        for lines in cases {
            do { _ = try await collect(provider(lines: lines)); XCTFail("Expected incomplete/empty/malformed response") }
            catch { XCTAssertTrue(error is ChatError) }
        }
        let client = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "x",
                                      transport: FixtureChatTransport(contentType: "application/json", lines: []))
        do { _ = try await collect(client); XCTFail("Expected MIME rejection") } catch { XCTAssertTrue(error is ChatError) }
    }

    func testEndpointValidationAndCredentialIsolation() throws {
        for endpoint in ["http://example.com/v1/messages", "https://user:pass@example.com/messages", "https://example.com/messages?key=secret", "https://example.com/messages#fragment", "file:///tmp/key"] {
            var profile = ChatProviderKind.anthropic.defaultProfile; profile.endpoint = endpoint
            XCTAssertThrowsError(try profile.validatedURL())
        }
        let (settings, credentials, defaults) = settings()
        var config = settings.configuration
        try settings.save(config, replacementKey: "test-key")
        XCTAssertNotNil(try settings.provider())
        XCTAssertEqual(credentials.values.count, 1)
        let data = try XCTUnwrap(defaults.data(forKey: "ai.configuration"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-key"))
        config.profile.endpoint = "https://another.example/v1/messages"
        try settings.save(config, replacementKey: nil)
        XCTAssertThrowsError(try settings.provider())
        config.profile.endpoint = "https://api.anthropic.com/v1/messages"
        config.profile.model = "claude-haiku-4-5"
        try settings.save(config, replacementKey: nil)
        XCTAssertEqual(try settings.key(for: config), "test-key", "Switching a model keeps the provider key")
        credentials.failWrites = true
        var other = config; other.profile.model = "different"
        XCTAssertThrowsError(try settings.save(other, replacementKey: "replacement"))
        XCTAssertEqual(settings.configuration, config)
        credentials.failWrites = false
        try settings.removeKey(for: config)
        XCTAssertThrowsError(try settings.provider())
    }

    func testKeychainRoundTripUsesIsolatedTestService() throws {
        let credentials = KeychainChatCredentials(service: "LeafChatTests.\(UUID())")
        defer { try? credentials.write(nil, account: "test") }
        XCTAssertNil(try credentials.read(account: "test"))
        try credentials.write("first-test-key", account: "test")
        XCTAssertEqual(try credentials.read(account: "test"), "first-test-key")
        try credentials.write("replacement-test-key", account: "test")
        XCTAssertEqual(try credentials.read(account: "test"), "replacement-test-key")
        try credentials.write(nil, account: "test")
        XCTAssertNil(try credentials.read(account: "test"))
    }

    func testHistoryIsBoundedAndKeepsContextWithItsQuestion() throws {
        var history: [ReaderChatMessage] = []
        for index in 0..<20 {
            history.append(ReaderChatMessage(isUser: true, text: "Question \(index)", context: context))
            history.append(ReaderChatMessage(isUser: false, text: String(repeating: "A", count: 1000)))
        }
        history.append(ReaderChatMessage(isUser: true, text: "Latest question", context: context))
        history.append(ReaderChatMessage(isUser: false, text: "Unfinished answer", state: .failed))
        let request = ChatRequest.conversation(history)
        XCTAssertLessThanOrEqual(request.turns.count, 12)
        XCTAssertLessThanOrEqual(request.turns.map(\.content).joined().count, 48000)
        XCTAssertEqual(request.turns.first?.role, "user")
        XCTAssertTrue(request.turns.last?.content.contains("Latest question") == true)
        XCTAssertFalse(request.turns.contains { $0.content.contains("Unfinished answer") })
        let long = ReadingChatContext(title: "Title", author: "", chapter: "", text: String(repeating: "文", count: 20000), source: "page", locator: "")
        XCTAssertEqual(long.bounded().text.count, 20000, "The reader keeps up to the largest setting")
        XCTAssertEqual(long.bounded(ReadingContextLimits()).text.count, 12000)
    }
    func testConfiguredReadingContextLimitsTrimRequestsAndClampSavedValues() throws {
        func sent(_ context: ReadingChatContext, _ limits: ReadingContextLimits, harness: ReadingChatHarness = .evidence) throws -> [String: Any] {
            let content = try XCTUnwrap(ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Why?", context: context)], harness: harness, limits: limits).turns.last?.content)
            let start = try XCTUnwrap(content.range(of: "\n")).upperBound, end = try XCTUnwrap(content.range(of: "\n\nReader question:")).lowerBound
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content[start..<end].utf8)) as? [String: Any])
        }
        func counts(_ json: [String: Any]) -> [Int] { ["text", "preceding_text", "following_text"].map { (json[$0] as? String)?.count ?? 0 } }
        let context = ReadingChatContext(title: "书", author: "", chapter: "第一章", text: String(repeating: "文", count: 10000), source: "selection", locator: "private",
            precedingText: String(repeating: "前", count: 9000), followingText: String(repeating: "后", count: 9000), progress: 0.3).bounded()
        XCTAssertEqual(counts(try sent(context, ReadingContextLimits())), [10000, 2000, 0], "Default: 12,000 in all, before ahead of after")
        XCTAssertEqual(counts(try sent(context, ReadingContextLimits(characters: 20000, before: 6000, after: 3000))), [10000, 6000, 3000])
        XCTAssertEqual(counts(try sent(context, ReadingContextLimits(characters: 4000, before: 0, after: 0), harness: .agent)), [4000, 0, 0])
        let largest = ReadingContextLimits.capture
        XCTAssertEqual(counts(try sent(context, largest)), [10000, 8000, 4000])
        let escaped = ReadingChatContext(title: "T", author: "", chapter: "", text: String(repeating: "\u{0001}", count: 24000), source: "page", locator: "")
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Latest", context: escaped)], limits: largest)
        XCTAssertEqual(request.turns.count, 1); XCTAssertLessThanOrEqual(request.turns[0].content.count, largest.encodedLimit + 100)

        let saved = try JSONDecoder().decode(ReadingContextLimits.self, from: Data(#"{"characters":999999,"before":-5}"#.utf8))
        XCTAssertEqual(saved, ReadingContextLimits(characters: 24000, before: 0, after: 1200))
        let older = try JSONDecoder().decode(ChatConfiguration.self, from: Data(#"{"provider":"anthropic","sharePage":true}"#.utf8))
        XCTAssertEqual(older.contextLimits, ReadingContextLimits())
        var configuration = ChatConfiguration(); configuration.contextLimits.characters = 6000
        XCTAssertEqual(try JSONDecoder().decode(ChatConfiguration.self, from: JSONEncoder().encode(configuration)).contextLimits.characters, 6000)
    }
    func testReadingPromptKeepsFocusedTextNeighborsBoundaryAndPrivateLocatorSeparate() throws {
        let context = ReadingChatContext(title: "A Book", author: "Author", chapter: "Chapter 3", text: "He hid the silver key.", source: "selection", locator: "private-cfi",
            precedingText: "Lin entered the room.", followingText: "The door remained locked.", progress: 0.315)
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Who is he?", context: context)])
        let content = try XCTUnwrap(request.turns.last?.content)
        XCTAssertTrue(content.contains("Lin entered the room.")); XCTAssertTrue(content.contains("The door remained locked."))
        XCTAssertTrue(content.contains("31.5")); XCTAssertTrue(content.contains("spoiler_boundary"))
        XCTAssertTrue(content.hasSuffix("Reader question:\nWho is he?")); XCTAssertFalse(content.contains("private-cfi"))
        XCTAssertTrue(request.system.contains("Treat previous assistant answers as fallible"))
        XCTAssertTrue(request.system.contains("cannot browse or retrieve unseen chapters"))
    }
    func testEnrichedContextBoundsAllTextAndDecodesExistingSavedHistory() throws {
        let old = Data(#"{"title":"Old book","author":"A","chapter":"C","text":"Saved quote","source":"selection","locator":"local"}"#.utf8)
        let restored = try JSONDecoder().decode(ReadingChatContext.self, from: old)
        XCTAssertNil(restored.precedingText); XCTAssertNil(restored.progress)
        let context = ReadingChatContext(title: "Title", author: "A", chapter: "C", text: String(repeating: "文", count: 10000), source: String(repeating: "x", count: 100000), locator: "local",
            precedingText: String(repeating: "前", count: 9000), followingText: String(repeating: "后", count: 9000), progress: .infinity).bounded(ReadingContextLimits())
        XCTAssertEqual(context.text.count, 10000)
        XCTAssertEqual(context.text.count + (context.precedingText?.count ?? 0) + (context.followingText?.count ?? 0), 12000)
        XCTAssertLessThanOrEqual(context.source.count, 40); XCTAssertNil(context.progress)
        XCTAssertEqual(try JSONDecoder().decode(ReadingChatContext.self, from: JSONEncoder().encode(context)), context)
        XCTAssertEqual(ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Latest", context: context)]).turns.count, 1)
    }
    func testRelevantOlderDiscussionUsesEnglishAndChineseAndExcludesFutureEvents() throws {
        for (question, oldQuestion, phrase) in [("Explain the silver key again", "Why did Lin hide the silver key?", "silver key"), ("银色钥匙为什么重要？", "银色钥匙属于谁？", "银色钥匙")] {
            var earlier = context; earlier.progress = 0.1
            var later = context; later.progress = 0.9
            var now = context; now.progress = 0.3
            let history = [ReaderChatMessage(isUser: true, text: oldQuestion, context: earlier),
                ReaderChatMessage(isUser: false, text: "Earlier discussion about \(phrase)."),
                ReaderChatMessage(isUser: true, text: oldQuestion + " FUTURE SECRET", context: later),
                ReaderChatMessage(isUser: false, text: "FUTURE SECRET outcome")]
            let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: question, context: now)], earlierMessages: history)
            let content = try XCTUnwrap(request.turns.last?.content)
            XCTAssertTrue(content.contains("earlier_discussion")); XCTAssertTrue(content.contains(oldQuestion))
            XCTAssertFalse(content.contains("FUTURE SECRET")); XCTAssertTrue(content.hasSuffix(question))
        }
    }
    func testLargeOlderPassagesDoNotCrowdOutRecentDialogueOrLatestQuestion() {
        var long = context
        long = ReadingChatContext(title: long.title, author: long.author, chapter: long.chapter, text: String(repeating: "\u{0001}", count: 12000), source: "page", locator: "private")
        var history: [ReaderChatMessage] = []
        for n in 0..<5 {
            history.append(ReaderChatMessage(isUser: true, text: "Question \(n)", context: long))
            history.append(ReaderChatMessage(isUser: false, text: "Answer \(n)"))
        }
        history.append(ReaderChatMessage(isUser: true, text: "LATEST QUESTION", context: long))
        let request = ChatRequest.conversation(history)
        XCTAssertTrue(request.turns.last?.content.hasSuffix("LATEST QUESTION") == true)
        XCTAssertLessThanOrEqual(request.turns.map(\.content).joined().count, 48000)
        XCTAssertTrue(request.turns.contains { $0.content == "Answer 4" })
    }
    func testUnrelatedOrUnfinishedEarlierDiscussionIsNotInjected() {
        let old = [ReaderChatMessage(isUser: true, text: "Describe the silver key", state: .failed),
                   ReaderChatMessage(isUser: false, text: "Incorrect key answer", state: .stopped),
                   ReaderChatMessage(isUser: true, text: "Describe mountains"), ReaderChatMessage(isUser: false, text: "Granite cliffs")]
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Describe the silver key")], earlierMessages: old)
        XCTAssertFalse(request.turns.last?.content.contains("earlier_discussion") == true)
    }
    func testCharacterLookupSkipsGenericSelectionsAndQuestionsWithoutAName() {
        for text in ["a", "the", "he", "这个"] {
            let selected = ReadingChatContext(title: "Book", author: "", chapter: "C", text: text, source: "selection", locator: "")
            XCTAssertNil(ReadingBookRecall.lookupTerm(question: "Who is being discussed here?", context: selected))
            XCTAssertEqual(ReadingBookRecall.lookupTerm(question: "Who is Lin?", context: selected), "Lin")
        }
        let page = ReadingChatContext(title: "Book", author: "", chapter: "C", text: "A passage with several characters.", source: "page", locator: "")
        XCTAssertNil(ReadingBookRecall.lookupTerm(question: "Who is he?", context: page))
        XCTAssertEqual(ReadingBookRecall.lookupTerm(question: "我忘了“白虎”的身份", context: page), "白虎")
    }
    func testFollowUpPhrasingIsNotANameAndKeepsThePreviousSubject() {
        let page = ReadingChatContext(title: "十日终焉", author: "", chapter: "第408章", text: "接连死去的两个队友……", source: "page", locator: "")
        for question in ["再说一遍是谁", "所以他到底是谁", "那个人是谁", "她是谁"] {
            XCTAssertNil(ReadingBookRecall.lookupTerm(question: question, context: page), question)
            XCTAssertEqual(ReadingBookRecall.lookupTerm(question: question, context: page, previous: "林檎"), "林檎", question)
        }
        XCTAssertEqual(ReadingBookRecall.lookupTerm(question: "再说一遍白虎是谁", context: page, previous: "林檎"), "白虎")
        XCTAssertEqual(ReadingBookRecall.lookupTerm(question: "林檎是谁", context: page, previous: "白虎"), "林檎")
        let earlier = ReaderChatMessage(isUser: true, text: "这是谁", context: ReadingChatContext(title: "", author: "", chapter: "", text: "林檎", source: "selection", locator: ""))
        XCTAssertEqual(ReaderChatSession.previousSubject([earlier, ReaderChatMessage(isUser: false, text: "心理咨询师")]), "林檎")
    }
    func testEvidenceFollowUpLooksUpThePreviousSubjectNotThePhrase() async throws {
        let provider = ControlledChatProvider(), (settings, _, _) = settings(provider)
        let session = ReaderChatSession()
        session.attachSelection(ReadingChatContext(title: "测试", author: "", chapter: "第三章", text: "林檎", source: "selection", locator: "a", progress: 0.4))
        session.draft = "这是谁"
        var terms: [String] = []
        let recall: @MainActor (String, ReadingChatContext) async throws -> ReadingBookRecall? = { term, _ in
            terms.append(term)
            return ReadingBookRecall(term: term, excerpts: [ReadingBookExcerpt(chapter: "第一章", text: "林檎是心理咨询师。")], scannedSections: 2, totalSections: 2, complete: true)
        }
        session.send(settings: settings, recall: recall) { nil }
        try await wait { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("心理咨询师。")); provider.continuations[0].yield(.finished(truncated: false)); provider.continuations[0].finish()
        try await wait { !session.isSending }
        session.draft = "再说一遍是谁"
        session.send(settings: settings, recall: recall) {
            ReadingChatContext(title: "测试", author: "", chapter: "第三章", text: "接连死去的两个队友。", source: "page", locator: "b", progress: 0.4)
        }
        try await wait { provider.requests.count == 2 }
        XCTAssertEqual(terms, ["林檎", "林檎"])
        XCTAssertTrue(provider.requests[1].turns.last?.content.contains("林檎是心理咨询师。") == true)
        session.stop()
    }
    func testMovingBackInBookOmitsRecentDiscussionBeyondCurrentPosition() {
        var later = context; later.progress = 0.9
        var now = context; now.progress = 0.2
        let request = ChatRequest.conversation([
            ReaderChatMessage(isUser: true, text: "Who is the killer? FUTURE SECRET", context: later),
            ReaderChatMessage(isUser: false, text: "FUTURE SECRET identity"),
            ReaderChatMessage(isUser: true, text: "Explain this earlier scene", context: now)])
        XCTAssertEqual(request.turns.count, 1)
        XCTAssertFalse(request.turns.map(\.content).joined().contains("FUTURE SECRET"))
    }
    func testBaihuReminderUsesEarlierBookEvidenceAndKeepsCoverageAndBudgetHonest() throws {
        let question = "我有点忘了这个角色了，帮我回忆一下"
        var selected = ReadingChatContext(title: "测试故事", author: "测试作者", chapter: "第三章", text: "白虎", source: "selection", locator: "private-cfi", progress: 0.4)
        XCTAssertEqual(ReadingBookRecall.lookupTerm(question: question, context: selected), "白虎")
        XCTAssertNil(ReadingBookRecall.lookupTerm(question: "Translate this sentence", context: selected))
        selected.bookRecall = ReadingBookRecall(term: "白虎", excerpts: [ReadingBookExcerpt(chapter: "第一章", text: "白虎是测试故事中的城门守卫。")], scannedSections: 3, totalSections: 10, complete: false)
        let decoded = try JSONDecoder().decode(ReadingChatContext.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(decoded, selected)
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: question, context: selected)])
        let content = try XCTUnwrap(request.turns.last?.content)
        XCTAssertTrue(content.contains("白虎是测试故事中的城门守卫。")); XCTAssertTrue(content.contains("earlier_book_passages"))
        XCTAssertTrue(content.contains("\"complete\":false")); XCTAssertTrue(content.hasSuffix(question))
        XCTAssertFalse(content.contains("private-cfi")); XCTAssertTrue(request.system.contains("Lead with the character's supported identity"))
        selected.bookRecall = ReadingBookRecall(term: "白虎", excerpts: (0..<20).map { _ in ReadingBookExcerpt(chapter: String(repeating: "章", count: 800), text: String(repeating: "\u{0001}", count: 12000)) }, scannedSections: 512, totalSections: 1000, complete: false)
        let bounded = selected.bounded(ReadingContextLimits())
        XCTAssertLessThanOrEqual(bounded.text.count + (bounded.precedingText?.count ?? 0) + (bounded.followingText?.count ?? 0) + (bounded.bookRecall?.excerpts.reduce(0) { $0 + $1.text.count } ?? 0), 12000)
        XCTAssertEqual(ChatRequest.conversation([ReaderChatMessage(isUser: true, text: question, context: bounded)]).turns.count, 1)
    }
    func testCharacterRecallUsesFrozenSelectionAndRetryKeepsOriginalEvidence() async throws {
        let provider = ControlledChatProvider(), (settings, _, _) = settings(provider)
        let session = ReaderChatSession()
        let selected = ReadingChatContext(title: "测试故事", author: "", chapter: "第三章", text: "白虎", source: "selection", locator: "snapshot-location", progress: 0.4)
        session.attachSelection(selected); session.draft = "我忘了这个角色，帮我回忆一下"
        var lookups = 0
        session.send(settings: settings, recall: { term, context in
            lookups += 1; XCTAssertEqual(term, "白虎"); XCTAssertEqual(context.locator, "snapshot-location")
            return ReadingBookRecall(term: term, excerpts: [ReadingBookExcerpt(chapter: "第一章", text: "白虎守着测试城门。")], scannedSections: 3, totalSections: 3, complete: true)
        }) { XCTFail("Attached selection is already captured"); return nil }
        try await wait { provider.requests.count == 1 }
        XCTAssertTrue(provider.requests[0].turns.last?.content.contains("白虎守着测试城门。") == true)
        provider.continuations[0].finish(throwing: ChatError.interrupted)
        try await wait { !session.isSending }
        session.retry(settings: settings); try await wait { provider.requests.count == 2 }
        XCTAssertEqual(lookups, 1); XCTAssertEqual(provider.requests[0].turns, provider.requests[1].turns)
        session.stop()
    }
    /// Holds the page capture open until the test releases it.
    private final class ContextGate: @unchecked Sendable {
        var continuation: CheckedContinuation<ReadingChatContext?, Never>?
        func wait() async -> ReadingChatContext? { await withCheckedContinuation { continuation = $0 } }
    }
    func testQuestionAndPlaceholderShowBeforeThePassageIsReady() async throws {
        let provider = ControlledChatProvider(), (settings, _, _) = settings(provider)
        let session = ReaderChatSession(), gate = ContextGate()
        session.draft = "Why?"
        session.send(settings: settings) { await gate.wait() }
        try await wait { session.messages.count == 2 }
        XCTAssertEqual(session.messages[0].text, "Why?"); XCTAssertTrue(session.messages[0].isUser); XCTAssertNil(session.messages[0].context)
        XCTAssertEqual(session.messages[1].state, .streaming); XCTAssertEqual(session.messages[1].text, "")
        XCTAssertEqual(session.activity, "Reading the page…"); XCTAssertEqual(session.draft, ""); XCTAssertTrue(session.isSending)
        XCTAssertTrue(provider.requests.isEmpty, "Nothing leaves before the passage is attached")
        gate.continuation?.resume(returning: context)
        try await wait { provider.requests.count == 1 }
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages[0].context?.text, "The door stayed shut."); XCTAssertNil(session.activity)
        XCTAssertTrue(provider.requests[0].turns.last?.content.contains("The door stayed shut.") == true)
        XCTAssertEqual(provider.requests[0].turns.count, 1, "The placeholder is not part of the conversation sent")
        provider.continuations[0].yield(.text("Because.")); provider.continuations[0].yield(.finished(truncated: false)); provider.continuations[0].finish()
        try await wait { !session.isSending }
        XCTAssertEqual(session.messages.map(\.text), ["Why?", "Because."]); XCTAssertEqual(session.messages[1].state, .complete)
    }
    func testStoppingWhileThePassageLoadsWithdrawsTheQuestionAndRestoresTheDraft() async throws {
        let provider = ControlledChatProvider(), (settings, _, _) = settings(provider)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = ReaderChatSession(history: try ChatHistoryStore(directory: directory, conversation: "book")), gate = ContextGate()
        session.draft = "Why?"
        session.send(settings: settings) { await gate.wait() }
        try await wait { session.messages.count == 2 }
        session.stop()
        XCTAssertEqual(session.messages, []); XCTAssertEqual(session.draft, "Why?"); XCTAssertFalse(session.isSending); XCTAssertNil(session.activity)
        gate.continuation?.resume(returning: context)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(session.messages, [], "A late page capture must not bring the withdrawn question back")
        XCTAssertTrue(provider.requests.isEmpty)
        let reopened = ReaderChatSession(history: try ChatHistoryStore(directory: directory, conversation: "book"))
        XCTAssertEqual(reopened.messages, []); XCTAssertEqual(reopened.draft, "Why?")
        // Sending again works and persists the question with its passage.
        session.send(settings: settings) { [self] in context }
        try await wait { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("Because.")); provider.continuations[0].yield(.finished(truncated: false)); provider.continuations[0].finish()
        try await wait { !session.isSending }
        session.flush()
        let again = ReaderChatSession(history: try ChatHistoryStore(directory: directory, conversation: "book"))
        XCTAssertEqual(again.messages.map(\.text), ["Why?", "Because."]); XCTAssertEqual(again.messages[0].context?.text, "The door stayed shut.")
    }
    func testSharingOffDoesNotReadBookForCharacterRecall() async throws {
        let provider = ControlledChatProvider(), (settings, _, _) = settings(provider)
        var config = settings.configuration; config.sharePage = false; try settings.save(config, replacementKey: nil)
        let session = ReaderChatSession()
        session.attachSelection(ReadingChatContext(title: "Book", author: "", chapter: "C", text: "白虎", source: "selection", locator: "private"))
        session.draft = "帮我回忆这个人物"
        session.send(settings: settings, recall: { _, _ in XCTFail("Sharing off must skip local book lookup"); return nil }) { XCTFail("Sharing off must skip passage capture"); return nil }
        try await wait { provider.requests.count == 1 }
        XCTAssertFalse(provider.requests[0].turns.last?.content.contains("reading_context") == true)
        session.stop()
    }

    func testEscapedPassageCannotDisplaceLatestQuestion() {
        let context = ReadingChatContext(title: "Title", author: "", chapter: "", text: String(repeating: "\u{0001}", count: 12000), source: "page", locator: "internal-locator")
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "My question", context: context)])
        XCTAssertEqual(request.turns.count, 1)
        XCTAssertTrue(request.turns[0].content.hasSuffix("My question"))
        XCTAssertFalse(request.turns[0].content.contains("internal-locator"))
    }

    func testSessionMissingKeyRetainsDraftWithoutReadingOrSending() {
        let (settings, _, _) = settings()
        let session = ReaderChatSession(); session.draft = "My question"
        session.send(settings: settings) { XCTFail("Must not read context before setup"); return nil }
        XCTAssertEqual(session.draft, "My question")
        XCTAssertFalse(session.isSending); XCTAssertNotNil(session.error); XCTAssertTrue(session.messages.isEmpty)
    }

    func testStreamingSessionFollowupAndPassageSharingOff() async throws {
        let provider = ControlledChatProvider()
        let (settings, _, _) = settings(provider)
        let session = ReaderChatSession(); session.draft = "Why is it shut?"
        session.send(settings: settings) { self.context }
        try await wait { provider.requests.count == 1 }
        XCTAssertTrue(session.isSending)
        provider.continuations[0].yield(.text("The passage "))
        try await wait { session.messages.last?.text == "The passage " }
        provider.continuations[0].yield(.text("does not say why."))
        provider.continuations[0].yield(.finished(truncated: false)); provider.continuations[0].finish()
        try await wait { !session.isSending }
        XCTAssertEqual(session.messages.last?.state, .complete)
        var config = settings.configuration; config.sharePage = false
        try settings.save(config, replacementKey: nil)
        session.draft = "What does that imply?"
        session.send(settings: settings) { XCTFail("Sharing disabled must skip context capture"); return nil }
        try await wait { provider.requests.count == 2 }
        let followup = provider.requests[1].turns
        XCTAssertEqual(followup.count, 3)
        XCTAssertEqual(followup[1].content, "The passage does not say why.")
        XCTAssertFalse(followup.contains { $0.content.contains("The door stayed shut.") })
        provider.continuations[1].yield(.text("A followup")); provider.continuations[1].yield(.finished(truncated: false)); provider.continuations[1].finish()
        try await wait { !session.isSending }
    }

    func testStopIgnoresLateEventsAndRetryKeepsOriginalPassage() async throws {
        let provider = ControlledChatProvider(); let (settings, _, _) = settings(provider)
        let session = ReaderChatSession(); session.draft = "Explain this"
        session.send(settings: settings) { self.context }
        try await wait { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("Partial"))
        try await wait { session.messages.last?.text == "Partial" }
        session.stop()
        XCTAssertTrue(session.canRetry); XCTAssertEqual(session.messages.last?.state, .stopped)
        provider.continuations[0].yield(.text("Must not appear")); provider.continuations[0].finish()
        session.retry(settings: settings)
        try await wait { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[0].turns, provider.requests[1].turns)
        XCTAssertEqual(session.messages.filter(\.isUser).count, 1)
        provider.continuations[1].yield(.text("Complete")); provider.continuations[1].yield(.finished(truncated: false)); provider.continuations[1].finish()
        try await wait { !session.isSending }
        XCTAssertEqual(session.messages.last?.text, "Complete"); XCTAssertFalse(session.canRetry)
    }

    func testFailureRetainsPartialAndCanRetryWithoutDuplicatingQuestion() async throws {
        let provider = ControlledChatProvider(); let (settings, _, _) = settings(provider)
        let session = ReaderChatSession(); session.draft = "Explain"
        session.send(settings: settings) { self.context }
        try await wait { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("Partial")); provider.continuations[0].finish(throwing: URLError(.networkConnectionLost))
        try await wait { !session.isSending }
        XCTAssertEqual(session.messages.last?.text, "Partial"); XCTAssertEqual(session.messages.last?.state, .failed)
        XCTAssertNotNil(session.error); XCTAssertTrue(session.canRetry)
        session.retry(settings: settings)
        try await wait { provider.requests.count == 2 }
        XCTAssertEqual(session.messages.filter(\.isUser).count, 1)
        session.clear(); XCTAssertTrue(session.messages.isEmpty); XCTAssertNil(session.error)
    }
}
