import XCTest
@testable import LeafReader

@MainActor
private final class FixtureBookSource: BookTextSource {
    var sections: [BookTextSection]
    var reads = 0
    var failing = false
    init(_ sections: [BookTextSection]) { self.sections = sections }
    func bookSectionCount() async throws -> Int { sections.count }
    func bookSectionText(_ index: Int) async throws -> BookTextSection {
        reads += 1
        if failing { throw ChatError.interrupted }
        return sections[index]
    }
    func bookBoundary(for locator: String) async throws -> BookTextBoundary? { nil }
}

private struct ScriptedTransport: ChatTransport {
    var lines: [String]
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        return (response, AsyncThrowingStream { continuation in lines.forEach { continuation.yield($0) }; continuation.finish() })
    }
}

/// Replays one scripted round per request and records what each request carried.
@MainActor
private final class ScriptedAgentProvider: ToolChatProvider {
    var rounds: [[AgentEvent]]
    var failure: Error?
    var requests: [(items: [AgentItem], allowTools: Bool, system: String)] = []
    var plainRequests: [ChatRequest] = []
    init(_ rounds: [[AgentEvent]], failure: Error? = nil) { self.rounds = rounds; self.failure = failure }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        plainRequests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Evidence answer.")); continuation.yield(.finished(truncated: false)); continuation.finish()
        }
    }
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        requests.append((items, allowTools, system))
        let failure = self.failure
        let events = rounds.isEmpty ? [.text("Done."), .finished(truncated: false)] : rounds.removeFirst()
        return AsyncThrowingStream { continuation in
            if let failure { continuation.finish(throwing: failure); return }
            events.forEach { continuation.yield($0) }; continuation.finish()
        }
    }
}

@MainActor
final class ReadingAgentTests: XCTestCase {
    // The index holds its source weakly, as the reader owns both in the app.
    private var sources: [FixtureBookSource] = []
    private func retain(_ source: FixtureBookSource) -> FixtureBookSource { sources.append(source); return source }
    private func book() -> [BookTextSection] {
        [BookTextSection(label: "第一章", text: "城门外站着白虎，他是守门的统领。"),
         BookTextSection(label: "第二章", text: "大家都在说话，白虎没有出现。" + String(repeating: "雨。", count: 200)),
         BookTextSection(label: "第三章", text: "老白，也就是白虎，救下了林檎。"),
         BookTextSection(label: "第四章", text: "白虎走进大厅。[读者在这里]白虎其实是叛徒。"),
         BookTextSection(label: "第五章", text: "白虎死了。")]
    }
    private func boundary(_ sections: [BookTextSection]) -> BookTextBoundary {
        BookTextBoundary(section: 3, offset: ((sections[3].text as NSString).range(of: "[读者在这里]")).location)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LeafAgentTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSearchRanksAliasesKeepsFirstMentionAndNeverPassesTheReader() async throws {
        let sections = book(), source = FixtureBookSource(sections)
        let index = BookTextIndex(source: retain(source), directory: nil), limit = boundary(sections)
        let coverage = try await index.prepare(through: limit, deadline: .distantFuture)
        XCTAssertEqual(coverage, BookTextIndex.Coverage(indexed: 4, eligible: 4))
        let (hits, counts) = index.search(["白虎", "老白"], within: limit, limit: 3)
        XCTAssertEqual(hits.first?.section, 0, "The first mention is always kept")
        XCTAssertTrue(hits.contains { $0.section == 2 && $0.terms == 2 }, "Passages with both names rank high")
        XCTAssertFalse(hits.contains { $0.text.contains("叛徒") || $0.text.contains("死了") })
        XCTAssertEqual(counts["白虎"], 4); XCTAssertEqual(counts["老白"], 1)
        XCTAssertEqual(index.read(section: 3, position: 0, length: 4000, within: limit)?.text, "白虎走进大厅。")
        XCTAssertNil(index.read(section: 4, position: 0, length: 4000, within: limit))
    }

    func testPreparedSectionsAreReusedFromDiskWithoutReadingTheBookAgain() async throws {
        let sections = book(), directory = try folder(), limit = boundary(sections)
        let first = FixtureBookSource(sections)
        _ = try await BookTextIndex(source: retain(first), directory: directory).prepare(through: limit, deadline: .distantFuture)
        XCTAssertEqual(first.reads, 4)
        let second = FixtureBookSource(sections); second.failing = true
        let reopened = BookTextIndex(source: retain(second), directory: directory)
        let coverage = try await reopened.prepare(through: limit, deadline: .distantPast)
        XCTAssertTrue(coverage.complete); XCTAssertEqual(second.reads, 0)
        XCTAssertEqual(reopened.search(["林檎"], within: limit, limit: 6).hits.first?.chapter, "第三章")
    }

    func testDeadlineReportsPartialCoverageAndUnreadableSectionsDoNotFailSearch() async throws {
        let sections = book(), limit = boundary(sections)
        let index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let partial = try await index.prepare(through: limit, deadline: .distantPast)
        XCTAssertEqual(partial, BookTextIndex.Coverage(indexed: 0, eligible: 4))
        let broken = FixtureBookSource(sections); broken.failing = true
        let coverage = try await BookTextIndex(source: retain(broken), directory: nil).prepare(through: limit, deadline: .distantFuture)
        XCTAssertEqual(coverage.indexed, 4)
    }

    func testToolboxValidatesArgumentsAndRefusesTextPastTheReader() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let toolbox = ReadingAgentToolbox(book: ReadingAgentBook(index: index, boundary: boundary(sections))) { _ in "{}" }
        var activity: [String] = []; toolbox.activity = { activity.append($0) }
        let search = try await toolbox.run(AgentToolCall(id: "1", name: "search_book", arguments: #"{"query":"白虎|老白"}"#))
        XCTAssertTrue(search.contains("第三章")); XCTAssertFalse(search.contains("叛徒"))
        XCTAssertTrue(activity.first?.contains("“白虎”, “老白”") == true)
        let future = try await toolbox.run(AgentToolCall(id: "2", name: "read_passage", arguments: #"{"section":4}"#))
        XCTAssertTrue(future.contains("after the reader's position"))
        let current = try await toolbox.run(AgentToolCall(id: "3", name: "read_passage", arguments: #"{"section":3,"length":99999}"#))
        XCTAssertTrue(current.contains("白虎走进大厅")); XCTAssertFalse(current.contains("叛徒"))
        let bad = try await toolbox.run(AgentToolCall(id: "4", name: "search_book", arguments: "not json"))
        XCTAssertTrue(bad.contains("error"))
        let chapters = try await toolbox.run(AgentToolCall(id: "5", name: "list_chapters", arguments: "{}"))
        XCTAssertTrue(chapters.contains("第四章")); XCTAssertFalse(chapters.contains("第五章"))
        XCTAssertEqual(toolbox.steps.count, 3)
    }

    func testRunnerExecutesToolsWithdrawsPreambleAndCapsToolUse() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let toolbox = ReadingAgentToolbox(book: ReadingAgentBook(index: index, boundary: boundary(sections))) { _ in "{}" }
        let call = AgentToolCall(id: "c1", name: "search_book", arguments: #"{"terms":["白虎"]}"#)
        let provider = ScriptedAgentProvider([[.text("Let me check."), .toolCall(call), .finished(truncated: false)],
                                              [.text("白虎是守门的统领（第一章）。"), .finished(truncated: false)]])
        var text = "", withdrawn = 0
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "白虎是谁？")], harness: .agent)
        _ = try await ReadingAgentRunner.run(provider: provider, request: request, toolbox: toolbox,
                                             onText: { text += $0 }, onWithdraw: { withdrawn += 1; text = "" })
        XCTAssertEqual(text, "白虎是守门的统领（第一章）。"); XCTAssertEqual(withdrawn, 1)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests[1].items.count, 3)
        guard case .toolResults(let results) = provider.requests[1].items.last else { return XCTFail("Missing tool results") }
        XCTAssertEqual(results.first?.id, "c1"); XCTAssertTrue(results.first?.output.contains("第一章") == true)
        XCTAssertTrue(provider.requests[0].system.contains("search_book"))

        let looping = ScriptedAgentProvider(Array(repeating: [.toolCall(call), .toolCall(call), .finished(truncated: false)], count: 4))
        _ = try await ReadingAgentRunner.run(provider: looping, request: request, toolbox: toolbox, onText: { _ in }, onWithdraw: {})
        XCTAssertEqual(looping.requests.map(\.allowTools), [true, true, true, true, false])
    }

    func testToolRejectionIsDistinctOnlyBeforeAnyOutput() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let toolbox = ReadingAgentToolbox(book: ReadingAgentBook(index: index, boundary: boundary(sections))) { _ in "{}" }
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Who?")], harness: .agent)
        do {
            _ = try await ReadingAgentRunner.run(provider: ScriptedAgentProvider([], failure: ChatError.http(400)), request: request,
                                                 toolbox: toolbox, onText: { _ in }, onWithdraw: {})
            XCTFail("Expected rejection")
        } catch ReadingAgentError.toolsUnsupported {}
        do {
            _ = try await ReadingAgentRunner.run(provider: ScriptedAgentProvider([], failure: ChatError.http(429)), request: request,
                                                 toolbox: toolbox, onText: { _ in }, onWithdraw: {})
            XCTFail("Expected rate limit")
        } catch ChatError.http(let status) { XCTAssertEqual(status, 429) }
        XCTAssertTrue(ReadingAgentRunner.rejectsTools(ChatGPTError.unsupported))
        XCTAssertFalse(ReadingAgentRunner.rejectsTools(ChatGPTError.usageLimit))
    }

    func testProvidersEncodeToolCallsAndResultsInTheirOwnFormats() throws {
        let items: [AgentItem] = [.turn(ChatTurn(role: "user", content: "Who?")),
                                  .toolCalls(text: "", calls: [AgentToolCall(id: "t1", name: "search_book", arguments: #"{"terms":["A"]}"#)]),
                                  .toolResults([AgentToolResult(id: "t1", name: "search_book", output: "{\"results\":[]}")])]
        let responses = ChatGPTSubscriptionProvider.input(items)
        XCTAssertEqual(responses[1]["type"] as? String, "function_call"); XCTAssertEqual(responses[1]["call_id"] as? String, "t1")
        XCTAssertEqual(responses[2]["type"] as? String, "function_call_output")

        var profile = ChatProviderKind.chatCompletions.defaultProfile; profile.model = "test-model"
        let completions = HTTPChatProvider(kind: .chatCompletions, profile: profile, apiKey: "test-only")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: completions.makeAgentRequest(system: "S", items: items, tools: AgentTool.all, allowTools: false).httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "t1"); XCTAssertEqual(body["tool_choice"] as? String, "none")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 4)

        let anthropic = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "test-only")
        let request = try anthropic.makeAgentRequest(system: "S", items: items, tools: AgentTool.all, allowTools: true)
        let claude = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let turns = try XCTUnwrap(claude["messages"] as? [[String: Any]])
        let use = try XCTUnwrap((turns[1]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(use["type"] as? String, "tool_use"); XCTAssertEqual((use["input"] as? [String: Any])?["terms"] as? [String], ["A"])
        XCTAssertEqual(((turns[2]["content"] as? [[String: Any]])?.first)?["tool_use_id"] as? String, "t1")
        XCTAssertEqual((claude["tool_choice"] as? [String: Any])?["type"] as? String, "auto")
        XCTAssertNotNil((claude["tools"] as? [[String: Any]])?.first?["input_schema"])
    }

    func testStreamsDecodeFragmentedToolCalls() async throws {
        func collect(_ provider: HTTPChatProvider) async throws -> [AgentEvent] {
            var events: [AgentEvent] = []
            for try await event in provider.streamAgent(system: "S", items: [.turn(ChatTurn(role: "user", content: "Q"))], tools: AgentTool.all, allowTools: true) { events.append(event) }
            return events
        }
        var profile = ChatProviderKind.chatCompletions.defaultProfile; profile.model = "test-model"
        let completions = HTTPChatProvider(kind: .chatCompletions, profile: profile, apiKey: "k", transport: ScriptedTransport(lines: [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"search_book","arguments":"{\"ter"}}]}}]}"#, "",
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ms\":[\"白虎\"]}"}}]}}]}"#, "",
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "", "data: [DONE]", ""]))
        let completionEvents = try await collect(completions)
        XCTAssertEqual(completionEvents, [.toolCall(AgentToolCall(id: "call_9", name: "search_book", arguments: #"{"terms":["白虎"]}"#)), .finished(truncated: false)])

        let anthropic = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "k", transport: ScriptedTransport(lines: [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking."}}"#, "",
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_passage","input":{}}}"#, "",
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"section\":"}}"#, "",
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"2}"}}"#, "",
            #"data: {"type":"content_block_stop","index":1}"#, "",
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#, "",
            #"data: {"type":"message_stop"}"#, ""]))
        let anthropicEvents = try await collect(anthropic)
        XCTAssertEqual(anthropicEvents, [.text("Checking."), .toolCall(AgentToolCall(id: "toolu_1", name: "read_passage", arguments: #"{"section":2}"#)), .finished(truncated: false)])

        XCTAssertEqual(try ChatGPTSubscriptionProvider.decodeAgent(#"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"fc_1","name":"list_chapters","arguments":""}}"#),
                       [.toolCall(AgentToolCall(id: "fc_1", name: "list_chapters", arguments: "{}"))])
    }

    func testSavedSettingsWithoutHarnessKeepTheirValuesAndDefaultToEvidence() throws {
        let old = #"{"provider":"chatGPT","profiles":{"chatGPT":{"endpoint":"https://api.openai.com/v1/responses","model":"m","maxOutputTokens":2048,"legacyTokenLimit":false}},"sharePage":false}"#
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.provider, .chatGPT); XCTAssertFalse(decoded.sharePage); XCTAssertEqual(decoded.harness, .evidence)
        var agent = decoded; agent.harness = .agent
        XCTAssertEqual(try JSONDecoder().decode(ChatConfiguration.self, from: JSONEncoder().encode(agent)).harness, .agent)
    }

    private func settings(_ provider: any ChatProvider, harness: ReadingChatHarness) throws -> AISettingsStore {
        let name = "LeafAgentTests.\(UUID())", defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = AISettingsStore(defaults: defaults, credentials: KeychainChatCredentials(service: "com.leafreader.tests.\(UUID())"), providerOverride: provider)
        var configuration = settings.configuration; configuration.harness = harness
        try settings.save(configuration, replacementKey: nil)
        return settings
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testSessionRecordsAgentStepsAndFallsBackWhenToolsAreRejected() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let context = ReadingChatContext(title: "测试", author: "", chapter: "第四章", text: "白虎", source: "selection", locator: "here", progress: 0.6)
        let call = AgentToolCall(id: "c1", name: "search_book", arguments: #"{"terms":["白虎","老白"]}"#)
        let agent = ScriptedAgentProvider([[.toolCall(call), .finished(truncated: false)], [.text("守门统领。"), .finished(truncated: false)]])
        let session = ReaderChatSession()
        session.attachSelection(context); session.draft = "白虎是谁"
        var recalls = 0
        session.send(settings: try settings(agent, harness: .agent), recall: { _, _ in recalls += 1; return nil },
                     agentBook: { _ in ReadingAgentBook(index: index, boundary: self.boundary(sections)) }) { nil }
        try await wait { !session.isSending && session.messages.count == 2 }
        XCTAssertEqual(session.messages.last?.text, "守门统领。")
        XCTAssertEqual(session.messages.last?.trace?.harness, .agent)
        XCTAssertTrue(session.messages.last?.trace?.caption.contains("searched “白虎”, “老白”") == true)
        XCTAssertEqual(recalls, 0, "The agent does not pre-fetch")
        XCTAssertNil(session.activity)

        let rejecting = ScriptedAgentProvider([], failure: ChatError.http(400))
        let fallback = ReaderChatSession()
        fallback.attachSelection(context); fallback.draft = "我忘了这个角色"
        fallback.send(settings: try settings(rejecting, harness: .agent), recall: { term, _ in
            recalls += 1
            return ReadingBookRecall(term: term, excerpts: [ReadingBookExcerpt(chapter: "第一章", text: "白虎是统领。")], scannedSections: 4, totalSections: 4, complete: true)
        }, agentBook: { _ in ReadingAgentBook(index: index, boundary: self.boundary(sections)) }) { nil }
        try await wait { !fallback.isSending && fallback.messages.count == 2 }
        XCTAssertEqual(fallback.messages.last?.text, "Evidence answer.")
        XCTAssertEqual(fallback.messages.last?.trace?.fellBack, true)
        XCTAssertEqual(recalls, 1)
        XCTAssertTrue(rejecting.plainRequests.first?.turns.last?.content.contains("白虎是统领。") == true)

        let evidence = ReaderChatSession()
        evidence.attachSelection(context); evidence.draft = "白虎是谁"
        evidence.send(settings: try settings(rejecting, harness: .evidence), recall: { term, _ in
            ReadingBookRecall(term: term, excerpts: [ReadingBookExcerpt(chapter: "第一章", text: "白虎是统领。")], scannedSections: 4, totalSections: 4, complete: true)
        }) { nil }
        try await wait { !evidence.isSending && evidence.messages.count == 2 }
        XCTAssertEqual(evidence.messages.last?.trace?.caption, "Pre-fetched evidence · looked up “白虎” (1)")
    }

    func testHighlightedNameAndFollowUpsAreSearchedBeforeTheModelAnswers() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let agentBook: @MainActor (ReadingChatContext) async throws -> ReadingAgentBook? = { _ in ReadingAgentBook(index: index, boundary: self.boundary(sections)) }
        // A model that answers at once, without calling tools itself.
        let quiet = ScriptedAgentProvider([[.text("守门统领。"), .finished(truncated: false)], [.text("还是守门统领。"), .finished(truncated: false)]])
        let settings = try settings(quiet, harness: .agent)
        let session = ReaderChatSession()
        session.attachSelection(ReadingChatContext(title: "测试", author: "", chapter: "第四章", text: "白虎", source: "selection", locator: "here", progress: 0.6))
        session.draft = "这是谁"
        session.send(settings: settings, agentBook: agentBook) { nil }
        try await wait { !session.isSending && session.messages.count == 2 }
        guard case .toolResults(let results) = quiet.requests.first?.items.last else { return XCTFail("The name is searched before the first model request") }
        XCTAssertTrue(results.first?.output.contains("第一章") == true)
        XCTAssertTrue(quiet.requests[0].system.contains("text is exactly what the reader highlighted"))
        XCTAssertTrue(session.messages.last?.trace?.caption.contains("searched “白虎”") == true)

        session.draft = "再说一遍是谁"
        session.send(settings: settings, agentBook: agentBook) {
            ReadingChatContext(title: "测试", author: "", chapter: "第四章", text: "大家都在大厅里。", source: "page", locator: "here", progress: 0.6)
        }
        try await wait { !session.isSending && session.messages.count == 4 }
        guard case .toolCalls(_, let calls) = quiet.requests[1].items.dropLast().last else { return XCTFail("The follow-up subject is searched") }
        XCTAssertEqual(calls.first?.arguments, #"{"terms":["白虎"]}"#)
        XCTAssertFalse(quiet.requests[1].items.contains { if case .toolCalls(_, let calls) = $0 { return calls.contains { $0.arguments.contains("再说一遍") } }; return false })
    }
}
