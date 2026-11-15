import XCTest
import UIKit
@testable import LeafReader

private final class RetryCredentials: ChatCredentialStore {
    func read(account: String) throws -> String? { nil }
    func write(_ key: String?, account: String) throws {}
}

private final class RetryTransport: ChatTransport {
    var requests: [URLRequest] = []
    var payloads: [(status: Int, headers: [String: String], lines: [String], error: Error?)] = []
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        requests.append(request)
        let payload = payloads.removeFirst()
        if payload.status == 0 { throw payload.error! }
        let response = HTTPURLResponse(url: request.url!, statusCode: payload.status, httpVersion: nil, headerFields: payload.headers)!
        return (response, AsyncThrowingStream { continuation in
            payload.lines.forEach { continuation.yield($0) }; continuation.finish(throwing: payload.error)
        })
    }
}

private struct RetryModelsClient: ChatGPTHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(#"{"models":[{"slug":"fixture-model","display_name":"Fixture","visibility":"list"}]}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}

private final class RetryProvider: ToolChatProvider {
    struct Reply { var events: [AgentEvent] = []; var error: Error? }
    var replies: [Reply] = []
    var requests: [[AgentItem]] = []
    var plainRequests: [ChatRequest] = []
    var held: AsyncThrowingStream<ChatEvent, Error>.Continuation?
    var hold = false
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        plainRequests.append(request)
        if hold { return AsyncThrowingStream { held = $0 } }
        let reply = replies.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in reply.events {
                switch event {
                case .text(let text): continuation.yield(.text(text))
                case .imageStarted: continuation.yield(.imageStarted)
                case .image(let data): continuation.yield(.image(data))
                case .imageToolRefused(let reason): continuation.yield(.imageToolRefused(reason))
                case .finished(let value): continuation.yield(.finished(truncated: value))
                default: break
                }
            }
            continuation.finish(throwing: reply.error)
        }
    }
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        requests.append(items)
        let reply = replies.removeFirst()
        return AsyncThrowingStream { continuation in
            reply.events.forEach { continuation.yield($0) }; continuation.finish(throwing: reply.error)
        }
    }
}

@MainActor
private final class RetryBookSource: BookTextSource {
    func bookSectionCount() async throws -> Int { 1 }
    func bookSectionText(_ index: Int) async throws -> BookTextSection { .init(label: "Chapter 1", text: "The first passage.") }
    func bookBoundary(for locator: String) async throws -> BookTextBoundary? { .init(section: 0, offset: 18) }
}

@MainActor
final class ChatRetryTests: XCTestCase {
    private var immediate: ChatRetryPolicy {
        var policy = ChatRetryPolicy(); policy.jitter = { 1 }; policy.sleep = { _ in try Task.checkCancellation() }; return policy
    }
    private func settings(_ provider: any ChatProvider, traced: Bool = false) throws -> AISettingsStore {
        let name = "LeafRetryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        // Remove this exact suite after use; tests never touch the user's provider settings.
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let value = AISettingsStore(defaults: defaults, credentials: RetryCredentials(), providerOverride: provider)
        var configuration = value.configuration; configuration.recordTraces = traced
        try value.save(configuration, replacementKey: nil)
        return value
    }
    private var context: ReadingChatContext {
        .init(title: "Book", author: "Author", chapter: "Chapter 1", text: "Original passage", source: "selection", locator: "private-locator", progress: 0.2)
    }
    // MARK: Leaving the screen mid-reply

    private let socketAbort = NSError(domain: NSPOSIXErrorDomain, code: 53, userInfo: [NSLocalizedDescriptionKey: "Software caused connection abort"])

    func testSocketAbortFromASuspendedConnectionIsRetried() async throws {
        XCTAssertTrue(ChatRetryBudget.transient(socketAbort))
        XCTAssertTrue(ChatRetryBudget.transient(NSError(domain: NSPOSIXErrorDomain, code: 57)))
        XCTAssertFalse(ChatRetryBudget.transient(NSError(domain: NSPOSIXErrorDomain, code: 2)))
        XCTAssertEqual(ChatRetryBudget.errorCode(socketAbort), "NSPOSIXErrorDomain:53")
        let provider = RetryProvider()
        provider.replies = [.init(error: socketAbort), .init(events: [.text("Recovered"), .finished(truncated: false)])]
        let session = ReaderChatSession(); session.retryPolicy = immediate; session.draft = "Why?"
        session.send(settings: try settings(provider)) { self.context }
        try await eventually(interval: 0.005) { !session.isSending }
        XCTAssertEqual(session.messages.last?.text, "Recovered"); XCTAssertNil(session.error)
    }

    func testReplyCutOffInTheBackgroundContinuesOnReturnWithoutAnError() async throws {
        let provider = RetryProvider()
        // The first attempt and both retries fail while Leaf is suspended.
        provider.replies = [.init(events: [.text("Partial")], error: socketAbort), .init(error: URLError(.timedOut)),
                            .init(error: URLError(.networkConnectionLost)), .init(events: [.text("Whole answer"), .finished(truncated: false)])]
        let session = ReaderChatSession(); session.retryPolicy = immediate; session.draft = "Why?"
        var background = false
        session.appInBackground = { background }
        session.send(settings: try settings(provider)) { self.context }
        background = true; session.appDidEnterBackground()
        try await eventually(interval: 0.005) { !session.isSending }
        XCTAssertNil(session.error, "No error for a reply cut off by leaving the screen")
        XCTAssertTrue(session.notice?.contains("continues when you come back") == true)
        XCTAssertEqual(session.messages.last?.state, .failed)
        XCTAssertEqual(provider.plainRequests.count, 3)

        background = false; session.appWillEnterForeground()
        try await eventually(interval: 0.005) { session.messages.last?.text == "Whole answer" && !session.isSending }
        XCTAssertEqual(provider.plainRequests.count, 4)
        XCTAssertEqual(provider.plainRequests.last?.turns.last?.content, provider.plainRequests.first?.turns.last?.content, "The same question is asked again")
        XCTAssertEqual(session.messages.count, 2, "The cut-off reply is replaced, not kept beside the new one")
        XCTAssertEqual(session.notice, ReaderChatSession.resumedNotice); XCTAssertNil(session.error)
    }

    func testFailureNoticedAfterReturningContinuesAtOnce() async throws {
        let provider = RetryProvider()
        provider.replies = [.init(error: socketAbort), .init(error: socketAbort), .init(error: socketAbort),
                            .init(events: [.text("Continued"), .finished(truncated: false)])]
        let session = ReaderChatSession(); session.retryPolicy = immediate; session.draft = "Why?"
        session.appInBackground = { false }
        session.send(settings: try settings(provider)) { self.context }
        session.appDidEnterBackground()
        try await eventually(interval: 0.005) { session.messages.last?.text == "Continued" && !session.isSending }
        XCTAssertNil(session.error); XCTAssertEqual(provider.plainRequests.count, 4)
    }

    func testOtherFailuresStillShowAndClosingCancelsAPendingContinue() async throws {
        // A refusal is not caused by leaving the screen.
        let refused = RetryProvider(); refused.replies = [.init(error: ChatError.http(401))]
        let session = ReaderChatSession(); session.retryPolicy = immediate; session.draft = "Why?"
        var background = false
        session.appInBackground = { background }
        session.send(settings: try settings(refused)) { self.context }
        background = true; session.appDidEnterBackground()
        try await eventually(interval: 0.005) { !session.isSending }
        XCTAssertNotNil(session.error)
        background = false; session.appWillEnterForeground()
        XCTAssertEqual(refused.plainRequests.count, 1)

        // Without leaving the screen, an exhausted network failure is reported as before.
        let offline = RetryProvider(); offline.replies = Array(repeating: .init(error: socketAbort), count: 3)
        let staying = ReaderChatSession(); staying.retryPolicy = immediate; staying.draft = "Why?"
        staying.appInBackground = { false }
        staying.send(settings: try settings(offline)) { self.context }
        try await eventually(interval: 0.005) { !staying.isSending }
        XCTAssertEqual(staying.error, "The connection was lost. Check your internet connection and retry.")

        // Closing the chat while waiting to continue drops the continue.
        let dropped = RetryProvider(); dropped.replies = Array(repeating: .init(error: socketAbort), count: 3)
        let closing = ReaderChatSession(); closing.retryPolicy = immediate; closing.draft = "Why?"
        var away = false
        closing.appInBackground = { away }
        closing.send(settings: try settings(dropped)) { self.context }
        away = true; closing.appDidEnterBackground()
        try await eventually(interval: 0.005) { !closing.isSending }
        closing.close()
        away = false; closing.appWillEnterForeground()
        XCTAssertFalse(closing.isSending); XCTAssertEqual(dropped.plainRequests.count, 3)
    }

    func testInitialTransportDropRecoversWithIdenticalRequest() async throws {
        let transport = RetryTransport()
        transport.payloads = [(0, [:], [], URLError(.networkConnectionLost)),
                              (200, ["Content-Type": "text/event-stream"], ["data: {\"choices\":[{\"delta\":{\"content\":\"Recovered\"}}]}", "", "data: [DONE]", ""], nil)]
        var profile = ChatProviderKind.chatCompletions.defaultProfile; profile.model = "fixture-model"
        let provider = HTTPChatProvider(kind: .chatCompletions, profile: profile, apiKey: "fixture", transport: transport)
        let session = ReaderChatSession(); session.retryPolicy = immediate; session.draft = "Why?"
        let settings = try settings(provider)
        var captures = 0
        session.send(settings: settings) { captures += 1; return self.context }
        try await eventually(interval: 0.005) { !session.isSending }
        XCTAssertEqual(captures, 1)
        guard transport.requests.count == 2 else { return XCTFail("Expected two transport attempts; got \(transport.requests.count), error: \(session.error ?? "none")") }
        XCTAssertEqual(transport.requests[0].httpBody, transport.requests[1].httpBody)
        XCTAssertEqual(session.messages.last?.text, "Recovered"); XCTAssertNil(session.error)
    }

    func testInterruptedStreamReplacesPartialAndPersistsOneFrozenQuestion() async throws {
        let provider = RetryProvider(); provider.replies = [.init(events: [.text("Discard this partial")], error: ChatError.interrupted),
                                                           .init(events: [.text("Replacement answer"), .finished(truncated: false)])]
        let storage = try ChatHistoryStore(directory: temporaryFolder("RetryTests"), conversation: "retry")
        let session = ReaderChatSession(history: storage); session.retryPolicy = immediate
        let settings = try settings(provider)
        session.attachSelection(context); session.draft = "Original question"
        var replyIDs: [UUID] = []
        session.retryPolicy.sleep = { _ in
            replyIDs.append(session.messages.last!.id)
            session.draft = "New unsent draft"; session.attachSelection(self.contextWithNewText())
        }
        session.send(settings: settings) { XCTFail("Must reuse attached selection"); return nil }
        try await eventually(interval: 0.005) { !session.isSending }
        XCTAssertEqual(provider.plainRequests[0].turns, provider.plainRequests[1].turns)
        XCTAssertEqual(session.messages.count, 2); XCTAssertEqual(session.messages.last?.text, "Replacement answer")
        XCTAssertEqual(replyIDs, [session.messages.last!.id]); XCTAssertEqual(session.draft, "New unsent draft")
        XCTAssertEqual(session.selectedContext?.text, "New selection")
        let reopened = ReaderChatSession(history: storage)
        XCTAssertEqual(reopened.messages.count, 2); XCTAssertEqual(reopened.messages[0].context?.text, "Original passage")
        XCTAssertEqual(reopened.messages.last?.state, .complete); XCTAssertEqual(reopened.draft, "New unsent draft")
    }
    private func contextWithNewText() -> ReadingChatContext { .init(title: "Book", author: "Author", chapter: "Chapter 2", text: "New selection", source: "selection", locator: "new") }

    func testExhaustionKeepsManualRetryAndDoesNotDuplicateTheQuestion() async throws {
        let provider = RetryProvider()
        provider.replies = (1...3).map { .init(events: [.text("Partial \($0)")], error: URLError(.networkConnectionLost)) }
            + [.init(events: [.text("Manual recovery"), .finished(truncated: false)])]
        let session = ReaderChatSession(); session.retryPolicy = immediate; session.draft = "Why?"
        let settings = try settings(provider)
        session.send(settings: settings) { self.context }
        try await eventually(interval: 0.005) { !session.isSending }
        XCTAssertEqual(provider.plainRequests.count, 3); XCTAssertEqual(session.messages.last?.text, "Partial 3")
        XCTAssertTrue(session.canRetry); XCTAssertNotNil(session.error)
        session.retry(settings: settings); try await eventually(interval: 0.005) { !session.isSending }
        XCTAssertEqual(session.messages.count, 2); XCTAssertEqual(session.messages.last?.text, "Manual recovery")
        XCTAssertEqual(provider.plainRequests[0].turns, provider.plainRequests[3].turns)
    }

    func testStopAndCloseCancelBackoffWithoutStartingAnotherRequest() async throws {
        for close in [false, true] {
            let provider = RetryProvider(); provider.replies = [.init(error: URLError(.networkConnectionLost))]
            let session = ReaderChatSession(); session.draft = "Why?"
            var sleeping = false, cancelled = false
            session.retryPolicy.sleep = { _ in
                sleeping = true
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
            }
            let settings = try settings(provider, traced: true), traces = AgentTraceStore(directory: try temporaryFolder("RetryTests"))
            session.send(settings: settings, traces: traces) { self.context }
            try await eventually(interval: 0.005) { sleeping }
            XCTAssertTrue(session.activity?.contains("Retrying (1/2)") == true)
            if close { session.close() } else { session.stop() }
            try await eventually(interval: 0.005) { cancelled }
            XCTAssertFalse(session.isSending); XCTAssertEqual(provider.requests.count, 1); XCTAssertTrue(session.canRetry)
            XCTAssertEqual(traces.traces.first?.outcome, .stopped)
        }
    }

    func testStopDuringStreamingIgnoresLateTextWithoutRetry() async throws {
        let provider = RetryProvider(); provider.hold = true
        let session = ReaderChatSession(); session.draft = "Why?"; session.retryPolicy = immediate
        session.send(settings: try settings(provider)) { self.context }
        try await eventually(interval: 0.005) { provider.held != nil }
        provider.held?.yield(.text("Before stop")); try await eventually(interval: 0.005) { session.messages.last?.text == "Before stop" }
        session.close(); provider.held?.yield(.text("Late")); provider.held?.finish(throwing: URLError(.networkConnectionLost))
        await Task.yield()
        XCTAssertEqual(provider.plainRequests.count, 1); XCTAssertEqual(session.messages.last?.text, "Before stop")
        XCTAssertEqual(session.messages.last?.state, .stopped)
    }

    func testPermanentFailuresAndCancellationNeverRetry() async throws {
        let failures: [Error] = [ChatError.http(400), ChatError.http(401), ChatError.http(403), ChatError.http(404),
                                 ChatError.invalidResponse, ChatError.emptyResponse, ChatError.tooLarge,
                                 ChatGPTError.signInRequired, ChatGPTError.permissionMissing, ChatGPTError.usageLimit,
                                 ChatGPTError.invalidRefresh, URLError(.cancelled), URLError(.serverCertificateUntrusted), CancellationError()]
        for error in failures {
            var attempts = 0
            do {
                let _: Bool = try await ChatRetryBudget(policy: immediate).run(round: 1, onRetry: { XCTFail("Unexpected retry: \(error)") }) { _ in attempts += 1; throw error }
                XCTFail("Expected failure")
            } catch {}
            XCTAssertEqual(attempts, 1)
        }
        let transients: [Error] = [URLError(.networkConnectionLost), URLError(.timedOut), ChatError.interrupted,
                             ChatError.http(408), ChatError.http(409), ChatError.http(429), ChatError.http(503),
                             ChatError.provider("overloaded_error"), ChatGPTError.unavailable]
        for error in transients {
            XCTAssertTrue(ChatRetryBudget.transient(error))
        }
    }

    func testRetryAfterIsRespectedOrDeferredInsteadOfShortened() async throws {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ChatRequestFailure.delay("Thu, 01 Jan 1970 00:00:04 GMT", now: now), 4)
        XCTAssertNil(ChatRequestFailure.delay("nan", now: now)); XCTAssertNil(ChatRequestFailure.delay("-1", now: now))
        for value in ["2", "6", "120"] {
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": value])!
            let failure = ChatRequestFailure(ChatError.http(503), response: response)
            var attempts = 0, waits: [Double] = [], policy = immediate
            policy.sleep = { waits.append($0) }
            do {
                let _: Bool = try await ChatRetryBudget(policy: policy).run(round: 1, onRetry: {}) { _ in attempts += 1; throw failure }
                XCTFail("Expected exhaustion")
            } catch {}
            XCTAssertEqual(attempts, value == "2" ? 3 : (value == "6" ? 2 : 1))
            XCTAssertEqual(waits, value == "2" ? [2, 2] : (value == "6" ? [6] : []))
        }
    }

    func testSubscriptionAgentRetriesActualResponsesStreamWithCompletedToolInput() async throws {
        let name = "LeafSubscriptionRetry.\(UUID())", transport = RetryTransport()
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let accounts = ChatGPTAccountStore(defaults: defaults, credentials: RetryCredentials(), client: ChatGPTOAuthClient(http: RetryModelsClient()))
        let account = ChatGPTAccount(clientID: "fixture", subject: "reader", email: "fixture@example.test", tokens: ChatGPTTokens(
            accessToken: "fixture-access", refreshToken: "fixture-refresh", idToken: "fixture-id", scopes: ["chatgpt.tokens.use.direct"], expiresAt: Date().addingTimeInterval(3600)))
        try accounts.accept(account)
        func events(_ values: [String]) -> [String] { values.flatMap { ["data: " + $0, ""] } }
        let complete = #"{"type":"response.completed"}"#
        transport.payloads = [
            (200, [:], events([#"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"chapters","name":"list_chapters","arguments":"{}"}}"#, complete]), nil),
            (200, [:], events([#"{"type":"response.output_text.delta","delta":"Abandoned subscription text"}"#]), URLError(.networkConnectionLost)),
            (200, [:], events([#"{"type":"response.output_text.delta","delta":"Subscription recovered"}"#, complete]), nil)
        ]
        let provider = ChatGPTSubscriptionProvider(accounts: accounts, accountID: account.id, model: "fixture-model", transport: transport)
        let source = RetryBookSource(), toolbox = ReadingAgentToolbox(book: .init(index: BookTextIndex(source: source, directory: nil), boundary: .init(section: 0, offset: 18))) { _ in "{}" }
        var text = ""
        _ = try await ReadingAgentRunner.run(provider: provider, request: .conversation([.init(isUser: true, text: "Remind me", context: context)], bookTools: true),
                                             toolbox: toolbox, recovery: ChatRetryBudget(policy: immediate), onText: { text += $0 }, onWithdraw: { text = "" })
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[1].httpBody, transport.requests[2].httpBody)
        XCTAssertTrue(String(decoding: transport.requests[2].httpBody!, as: UTF8.self).contains("function_call_output"))
        XCTAssertEqual(toolbox.steps, ["listed chapters"]); XCTAssertEqual(text, "Subscription recovered")
    }

    func testAgentRecoversInitialAndInterruptedRoundsWithoutReplayingTools() async throws {
        let source = RetryBookSource(), toolbox = ReadingAgentToolbox(book: .init(index: BookTextIndex(source: source, directory: nil), boundary: .init(section: 0, offset: 18))) { _ in "{\"matches\":[]}" }
        let completed = AgentToolCall(id: "completed", name: "search_conversation", arguments: "{\"terms\":[\"name\"]}")
        let abandoned = AgentToolCall(id: "abandoned", name: "search_conversation", arguments: "{\"terms\":[\"other\"]}")
        let provider = RetryProvider()
        provider.replies = [.init(error: URLError(.networkConnectionLost)), .init(events: [.toolCall(completed), .finished(truncated: false)]),
                            .init(events: [.text("Abandoned answer"), .toolCall(abandoned)], error: ChatError.interrupted),
                            .init(events: [.text("Recovered answer"), .finished(truncated: false)])]
        let recorder = AgentTraceRecorder(trace: .init(provider: "fixture", model: "fixture", bookTitle: "Book", chapter: "Chapter 1", question: "Who?"))
        let request = ChatRequest.conversation([.init(isUser: true, text: "Who?", context: context)], bookTools: true)
        let budget = ChatRetryBudget(policy: immediate); var text = ""
        _ = try await ReadingAgentRunner.run(provider: provider, request: request, toolbox: toolbox, recorder: recorder, recovery: budget,
                                             onText: { text += $0 }, onWithdraw: { text = "" })
        XCTAssertEqual(provider.requests.count, 4); XCTAssertEqual(budget.retries, 2)
        XCTAssertEqual(provider.requests[0], provider.requests[1]); XCTAssertEqual(provider.requests[2], provider.requests[3])
        XCTAssertEqual(toolbox.steps, ["searched earlier chat"]); XCTAssertEqual(text, "Recovered answer")
        XCTAssertEqual(recorder.trace.toolCalls, 1); XCTAssertEqual(recorder.trace.rounds, 2)
        XCTAssertTrue(recorder.trace.json.contains("NSURLErrorDomain:-1005")); XCTAssertTrue(recorder.trace.json.contains("retry_scheduled"))
        XCTAssertFalse(recorder.trace.json.contains("Abandoned answer"))
    }

    func testRetryBudgetIsSharedAcrossAgentRounds() async throws {
        let source = RetryBookSource(), toolbox = ReadingAgentToolbox(book: .init(index: BookTextIndex(source: source, directory: nil), boundary: .init(section: 0, offset: 18))) { _ in "{}" }
        let call = AgentToolCall(id: "one", name: "search_conversation", arguments: "{\"terms\":[\"name\"]}")
        let provider = RetryProvider(); provider.replies = [.init(error: ChatError.http(503)), .init(events: [.toolCall(call), .finished(truncated: false)]),
                                                           .init(error: ChatError.interrupted), .init(error: ChatError.interrupted)]
        do {
            _ = try await ReadingAgentRunner.run(provider: provider, request: .conversation([.init(isUser: true, text: "Who?")]), toolbox: toolbox,
                                                 recovery: ChatRetryBudget(policy: immediate), onText: { _ in }, onWithdraw: {})
            XCTFail("Expected exhaustion")
        } catch { XCTAssertTrue(error is ChatError) }
        XCTAssertEqual(provider.requests.count, 4); XCTAssertEqual(toolbox.steps.count, 1)
    }

    // MARK: Generated pictures

    private func picture(_ shade: CGFloat = 0.4) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 40)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor(white: shade, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        }
    }
    func testGeneratedPictureIsSavedWithTheReplyRestoredAndClearedWithTheConversation() async throws {
        for traced in [false, true] {
            let drawn = picture()
            let provider = RetryProvider()
            provider.replies = [.init(events: [.imageStarted, .image(drawn), .text("Here is the harbor."), .finished(truncated: false)])]
            let directory = try temporaryFolder("RetryTests"), pictures = directory.appendingPathComponent("Images")
            let session = ReaderChatSession(history: try ChatHistoryStore(directory: directory, conversation: "pictures"), imageDirectory: pictures)
            session.retryPolicy = immediate
            session.draft = "Draw the harbor"
            session.send(settings: try settings(provider, traced: traced)) { self.context }
            try await eventually(interval: 0.005) { !session.isSending }
            let reply = try XCTUnwrap(session.messages.last)
            XCTAssertNil(session.error, "traced=\(traced)"); XCTAssertEqual(reply.state, .complete)
            XCTAssertEqual(reply.text, "Here is the harbor."); XCTAssertEqual(reply.images?.count, 1)
            XCTAssertNil(session.activity, "The drawing notice gives way once the picture arrives")
            let file = try XCTUnwrap(session.imageURL(try XCTUnwrap(reply.images?.first)))
            XCTAssertEqual(try Data(contentsOf: file), drawn)
            XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, pictures.standardizedFileURL)
            // Reopening the book restores the picture with its reply.
            let reopened = ReaderChatSession(history: try ChatHistoryStore(directory: directory, conversation: "pictures"), imageDirectory: pictures)
            XCTAssertEqual(reopened.messages.last?.images, reply.images)
            // The next question tells the model a picture was made, without sending it.
            let next = ChatRequest.conversation(reopened.messages + [ReaderChatMessage(isUser: true, text: "Make it darker")])
            let answer = try XCTUnwrap(next.turns.last(where: { $0.role == "assistant" }))
            XCTAssertEqual(answer.content, "Here is the harbor.\n\n[Generated an image for the reader.]")
            XCTAssertFalse(next.turns.contains { $0.content.contains(file.lastPathComponent) })
            // Clearing the conversation removes the picture files too.
            reopened.clear()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
    func testAPictureAloneIsACompleteReplyAndAnInterruptedOneIsRedrawn() async throws {
        let first = picture(0.2), second = picture(0.8)
        let provider = RetryProvider()
        provider.replies = [.init(events: [.imageStarted, .image(first)], error: ChatError.interrupted),
                            .init(events: [.imageStarted, .image(second), .finished(truncated: false)])]
        let directory = try temporaryFolder("RetryTests"), pictures = directory.appendingPathComponent("Images")
        let session = ReaderChatSession(history: try ChatHistoryStore(directory: directory, conversation: "alone"), imageDirectory: pictures)
        session.retryPolicy = immediate
        session.draft = "Just the picture"
        session.send(settings: try settings(provider)) { self.context }
        try await eventually(interval: 0.005) { !session.isSending }
        let reply = try XCTUnwrap(session.messages.last)
        XCTAssertNil(session.error); XCTAssertEqual(reply.state, .complete); XCTAssertEqual(reply.text, "")
        XCTAssertEqual(reply.images?.count, 1, "The interrupted attempt's picture is replaced, not kept beside the new one")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(session.imageURL(reply.images![0]))), second)
        let files = try FileManager.default.contentsOfDirectory(atPath: pictures.path)
        XCTAssertEqual(files, [reply.images![0]], "The abandoned attempt's file is deleted")
        XCTAssertEqual(ChatRequest.conversation(session.messages).turns.last?.content, "[Generated an image for the reader.]")
    }
    func testRefusedImageToolIsTracedAndExplainedOnlyWhenAPictureWasAskedFor() async throws {
        let reason = "HTTP 400 · unsupported_tool"
        for (question, traced, explained) in [("根据本章内容生成一张图片", true, true), ("画一只在海边的猫", false, true), ("Draw the harbor", false, true), ("这是谁", true, false)] {
            let provider = RetryProvider()
            provider.replies = [.init(events: [.imageToolRefused(reason), .text("我现在无法直接生成图片。"), .finished(truncated: false)])]
            let traces = AgentTraceStore(directory: try temporaryFolder("RetryTests"))
            let session = ReaderChatSession(); session.retryPolicy = immediate
            session.draft = question
            session.send(settings: try settings(provider, traced: traced), traces: traces) { self.context }
            try await eventually(interval: 0.005) { !session.isSending }
            XCTAssertEqual(session.messages.last?.state, .complete, question); XCTAssertNil(session.error, question)
            if explained {
                XCTAssertEqual(session.notice, "This model or ChatGPT plan didn’t accept drawing (\(reason)), so Leaf answered in words.", question)
            } else { XCTAssertNil(session.notice, "Only a picture request gets the note: \(question)") }
            if traced {
                let step = try XCTUnwrap(traces.traces.first?.steps.first { $0.title == "Image tool refused" }, question)
                XCTAssertEqual(step.detail, reason + " · asked again without it")
            }
        }
        XCTAssertFalse(ReaderChatSession.asksForPicture("What happens next?"))
        XCTAssertTrue(ReaderChatSession.asksForPicture("Could you sketch the scene?"))
    }
    func testPictureStoreAcceptsOnlyItsOwnNamesAndRealImages() throws {
        let directory = try temporaryFolder("RetryTests")
        XCTAssertThrowsError(try ChatImageStore.save(Data("not a picture".utf8), in: directory))
        XCTAssertThrowsError(try ChatImageStore.save(Data([0xFF, 0xD8, 0xFF, 0x00]), in: directory), "A JPEG header alone is not a picture")
        let name = try ChatImageStore.save(picture(), in: directory)
        XCTAssertTrue(name.hasSuffix(".jpg")); XCTAssertNotNil(ChatImageStore.url(name, in: directory))
        // Names also arrive from synced history; nothing else may resolve to a file.
        for hostile in ["../conversations.sqlite", "\(UUID().uuidString).jpg/../x", "\(UUID().uuidString.lowercased()).jpg", "\(UUID().uuidString).sqlite", "picture.jpg", ""] {
            XCTAssertNil(ChatImageStore.url(hostile, in: directory), hostile)
        }
        ChatImageStore.remove(["../conversations.sqlite", name], in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String ?? "").isEmpty,
                       "Saving a picture from the share sheet needs the photo-library add permission text")
    }
}
