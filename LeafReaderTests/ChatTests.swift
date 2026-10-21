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
        XCTAssertEqual(long.bounded().text.count, 12000)
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
