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
private final class ScriptedAgentProvider: @MainActor ToolChatProvider {
    var rounds: [[AgentEvent]]
    var failure: Error?
    var requests: [(items: [AgentItem], allowTools: Bool, system: String)] = []
    var offered: [[String]] = []
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
        offered.append(tools.map(\.name))
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
        let sections = book(), directory = try temporaryFolder(create: false), limit = boundary(sections)
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
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "白虎是谁？")], bookTools: true)
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
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Who?")], bookTools: true)
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

    func testClaudeGetsItsOwnWebSearchToolAndOtherServersDoNot() throws {
        let items = [AgentItem.turn(ChatTurn(role: "user", content: "Q"))]
        let tools = AgentTool.all + [AgentTool.webSearch]
        func body(_ provider: HTTPChatProvider, allowTools: Bool = true, webSearch: Bool = true, tools: [AgentTool]) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: provider.makeAgentRequest(system: "S", items: items, tools: tools, allowTools: allowTools, webSearch: webSearch).httpBody!) as? [String: Any])
        }
        var profile = ChatProviderKind.anthropic.defaultProfile; profile.model = "claude-haiku-5-5"
        let haiku = HTTPChatProvider(kind: .anthropic, profile: profile, apiKey: "k")
        let open = try body(haiku, tools: tools)
        let definitions = try XCTUnwrap(open["tools"] as? [[String: Any]])
        XCTAssertEqual(definitions.count, AgentTool.all.count + 1)
        XCTAssertEqual(definitions.last?["type"] as? String, "web_search_20250305"); XCTAssertEqual(definitions.last?["name"] as? String, "web_search")
        XCTAssertEqual(definitions.last?["max_uses"] as? Int, 5); XCTAssertNil(definitions.last?["input_schema"])
        XCTAssertEqual(open["system"] as? String, "S\n\n" + AgentTool.webSearchInstruction)
        // The closing round keeps the definition (earlier searches stay in the messages) and the same instructions.
        let closing = try body(haiku, allowTools: false, tools: tools)
        XCTAssertEqual((closing["tools"] as? [[String: Any]])?.last?["name"] as? String, "web_search")
        XCTAssertEqual((closing["tool_choice"] as? [String: Any])?["type"] as? String, "none"); XCTAssertEqual(closing["system"] as? String, open["system"] as? String)
        let refused = try body(haiku, webSearch: false, tools: tools)
        XCTAssertEqual((refused["tools"] as? [[String: Any]])?.count, AgentTool.all.count); XCTAssertEqual(refused["system"] as? String, "S")
        XCTAssertEqual(HTTPChatProvider.anthropicWebSearchType("claude-opus-5-5"), "web_search_20260209")
        XCTAssertEqual(HTTPChatProvider.anthropicWebSearchType("claude-sonnet-4-6"), "web_search_20260209")
        XCTAssertEqual(HTTPChatProvider.anthropicWebSearchType("claude-sonnet-4-5"), "web_search_20250305")
        var other = ChatProviderKind.chatCompletions.defaultProfile; other.model = "test-model"
        let completions = try body(HTTPChatProvider(kind: .chatCompletions, profile: other, apiKey: "k"), tools: tools)
        let functions = (completions["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(functions, AgentTool.all.map(\.name), "Servers without hosted search never see a web_search function")
        XCTAssertNil(try body(HTTPChatProvider(kind: .chatCompletions, profile: other, apiKey: "k"), tools: [AgentTool.webSearch])["tools"])
    }

    func testClaudeWebSearchStreamIsShownCitedAndSentBackUnchanged() async throws {
        func line(_ json: String) -> [String] { ["data: " + json, ""] }
        let anthropic = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "k", transport: ScriptedTransport(lines: [
            #"{"type":"message_start","message":{"usage":{"input_tokens":900,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me look. "}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"青山 会说"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"话的肘子\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","url":"https://book.qidian.com/info/1","title":"青山","encrypted_content":"enc"}]}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://book.qidian.com/info/1","title":"青山","cited_text":"少年","encrypted_index":"ei"}}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"少年骑马走向江湖。"}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"content_block_start","index":4,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_book","input":{}}}"#,
            #"{"type":"content_block_delta","index":4,"delta":{"type":"input_json_delta","partial_json":"{\"terms\":[\"青山\"]}"}}"#,
            #"{"type":"content_block_stop","index":4}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}"#,
            #"{"type":"message_stop"}"#].flatMap(line)))
        var events: [AgentEvent] = []
        for try await event in anthropic.streamAgent(system: "S", items: [.turn(ChatTurn(role: "user", content: "Q"))],
                                                     tools: AgentTool.all + [AgentTool.webSearch], allowTools: true) { events.append(event) }
        let call = AgentToolCall(id: "toolu_1", name: "search_book", arguments: #"{"terms":["青山"]}"#)
        XCTAssertEqual(Array(events.prefix(6)), [.text("Let me look. "), .webSearch(nil), .webSearch("青山 会说话的肘子"), .text("少年骑马走向江湖。"), .toolCall(call),
                                                 .text("\n\n来源：\n- [青山](https://book.qidian.com/info/1)")])
        XCTAssertEqual(events.suffix(2), [.usage(TokenUsage(input: 900, output: 40)), .finished(truncated: false)])
        guard case .providerContent(let data, let paused) = events[6] else { return XCTFail("Claude's content must come back: \(events)") }
        XCTAssertFalse(paused)
        let blocks = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(blocks.compactMap { $0["type"] as? String }, ["text", "server_tool_use", "web_search_tool_result", "text", "tool_use"])
        XCTAssertEqual((blocks[1]["input"] as? [String: Any])?["query"] as? String, "青山 会说话的肘子")
        XCTAssertEqual(((blocks[2]["content"] as? [[String: Any]])?.first)?["encrypted_content"] as? String, "enc")
        XCTAssertEqual(blocks[3]["text"] as? String, "少年骑马走向江湖。")
        XCTAssertEqual(((blocks[3]["citations"] as? [[String: Any]])?.first)?["encrypted_index"] as? String, "ei")
        XCTAssertEqual((blocks[4]["input"] as? [String: Any])?["terms"] as? [String], ["青山"])
        // The next request repeats that content as the assistant turn, before the tool results.
        let next = HTTPChatProvider.anthropicMessages([.providerContent(data, text: "少年骑马走向江湖。", calls: [call]),
                                                       .toolResults([AgentToolResult(id: "toolu_1", name: "search_book", output: "{}")])])
        XCTAssertEqual(next[0]["role"] as? String, "assistant")
        XCTAssertEqual((next[0]["content"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual(((next[1]["content"] as? [[String: Any]])?.first)?["tool_use_id"] as? String, "toolu_1")
        // Without content (or unreadable content) a reply is rebuilt from its text and calls, as before.
        XCTAssertEqual(((HTTPChatProvider.anthropicMessages([.providerContent(Data("x".utf8), text: "", calls: [call])])[0]["content"] as? [[String: Any]])?.first)?["type"] as? String, "tool_use")
        // A reply that never searched sends nothing extra back.
        let plain = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "k", transport: ScriptedTransport(lines: [
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#, #"{"type":"message_stop"}"#].flatMap(line)))
        var plainEvents: [AgentEvent] = []
        for try await event in plain.streamAgent(system: "S", items: [.turn(ChatTurn(role: "user", content: "Q"))], tools: AgentTool.all + [AgentTool.webSearch], allowTools: true) { plainEvents.append(event) }
        XCTAssertEqual(plainEvents, [.text("Hi"), .finished(truncated: false)])
    }

    func testClaudeRefusingWebSearchIsAskedAgainWithoutItAndAPausedSearchGoesOn() async throws {
        final class SearchSequence: ChatTransport, @unchecked Sendable {
            var replies: [(Int, [String])]; var bodies: [[String: Any]] = []
            init(_ replies: [(Int, [String])]) { self.replies = replies }
            func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
                bodies.append((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:])
                let (status, lines) = replies.removeFirst()
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!,
                        AsyncThrowingStream { continuation in lines.forEach { continuation.yield($0) }; continuation.finish() })
            }
        }
        var profile = ChatProviderKind.anthropic.defaultProfile; profile.model = "claude-test-\(UUID().uuidString)"
        let refused = (400, [#"{"type":"error","error":{"type":"invalid_request_error","message":"web search is disabled for <org>"}}"#])
        let answered = (200, [#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"From the book."}}"#, "", #"data: {"type":"message_stop"}"#, ""])
        let transport = SearchSequence([refused, answered, answered])
        let provider = HTTPChatProvider(kind: .anthropic, profile: profile, apiKey: "k", transport: transport)
        func run() async throws -> [AgentEvent] {
            var events: [AgentEvent] = []
            for try await event in provider.streamAgent(system: "S", items: [.turn(ChatTurn(role: "user", content: "Q"))], tools: AgentTool.all + [AgentTool.webSearch], allowTools: true) { events.append(event) }
            return events
        }
        let reason = "HTTP 400 · invalid_request_error"
        XCTAssertEqual(try await run(), [.webSearchRefused(reason), .text("From the book."), .finished(truncated: false)])
        XCTAssertEqual((transport.bodies[0]["tools"] as? [[String: Any]])?.last?["name"] as? String, "web_search")
        XCTAssertEqual((transport.bodies[1]["tools"] as? [[String: Any]])?.count, AgentTool.all.count, "Book tools stay; only web search goes")
        XCTAssertEqual(try await run().first, .webSearchRefused(reason), "Later requests skip it and still say why")
        XCTAssertEqual(transport.bodies.count, 3); XCTAssertEqual((transport.bodies[2]["tools"] as? [[String: Any]])?.count, AgentTool.all.count)

        // Claude paused part way through its own searching: the reply goes back as it is,
        // the runner asks again, and the searches are listed with the answer.
        let content = Data(#"[{"type":"server_tool_use","id":"s1","name":"web_search","input":{"query":"q"}}]"#.utf8)
        let scripted = ScriptedAgentProvider([[.webSearch(nil), .webSearch("Leaf reader"), .providerContent(content, paused: true), .finished(truncated: false)],
                                              [.text("Answer."), .finished(truncated: false)]])
        let toolbox = ReadingAgentToolbox(book: nil) { _ in "{}" }
        toolbox.webSearch = true
        XCTAssertEqual(toolbox.tools.map(\.name), ["search_conversation", "web_search"])
        var activities: [String] = []
        toolbox.activity = { activities.append($0) }
        let recorder = AgentTraceRecorder(trace: AgentTrace(provider: "Test", model: "m", bookTitle: "", chapter: "", question: "Q", selection: nil, limits: AgentLimits()))
        var text = ""
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "Search the web for Leaf reader")])
        _ = try await ReadingAgentRunner.run(provider: scripted, request: request, toolbox: toolbox, recorder: recorder, onText: { text += $0 }, onWithdraw: {})
        XCTAssertEqual(text, "Answer.")
        XCTAssertEqual(scripted.requests.count, 2)
        XCTAssertEqual(scripted.requests[1].items.last, .providerContent(content, text: "", calls: []))
        XCTAssertEqual(toolbox.steps, ["searched the web for “Leaf reader”"])
        XCTAssertEqual(activities, ["Searching the web…", "Searched the web for “Leaf reader”…"])
        XCTAssertTrue(recorder.trace.steps.contains { $0.title == "Web search" && $0.detail == "Leaf reader" })
        // AI settings can turn it off like any other tool.
        toolbox.limits.disabledTools = [AgentTool.webSearchName]
        XCTAssertEqual(toolbox.tools.map(\.name), ["search_conversation"])
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

    func testSettingsAndRepliesSavedWithPrefetchedEvidenceStillLoad() throws {
        let old = #"{"provider":"chatGPT","profiles":{"chatGPT":{"endpoint":"https://api.openai.com/v1/responses","model":"m","maxOutputTokens":2048,"legacyTokenLimit":false}},"sharePage":false,"harness":"evidence"}"#
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.provider, .chatGPT); XCTAssertFalse(decoded.sharePage)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("harness"))
        let reply = try JSONDecoder().decode(ChatTrace.self, from: Data(#"{"steps":["looked up “白虎” (1)"],"fellBack":false,"harness":"evidence"}"#.utf8))
        XCTAssertEqual(reply.caption, "Pre-fetched evidence · looked up “白虎” (1)"); XCTAssertFalse(reply.usedTools)
        let agent = try JSONDecoder().decode(ChatTrace.self, from: Data(#"{"steps":["searched “白虎” (2)"],"fellBack":false,"harness":"agent"}"#.utf8))
        XCTAssertEqual(agent.caption, "Leaf agent · searched “白虎” (2)"); XCTAssertTrue(agent.usedTools)
        XCTAssertEqual(try JSONDecoder().decode(ChatTrace.self, from: JSONEncoder().encode(ChatTrace(steps: ["x"]))), ChatTrace(steps: ["x"]))
        let trace = try JSONDecoder().decode(AgentTrace.self, from: Data(#"{"id":"6F1C5C1E-1111-4444-8888-000000000001","date":0,"harness":"evidence","provider":"p","model":"m","bookTitle":"b","chapter":"c","question":"q","steps":[],"outcome":"complete","totalSeconds":1,"charactersSent":2}"#.utf8))
        XCTAssertEqual(trace.harness, "evidence")
    }

    private func settings(_ provider: any ChatProvider) throws -> AISettingsStore {
        let name = "LeafAgentTests.\(UUID())", defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = AISettingsStore(defaults: defaults, credentials: KeychainChatCredentials(service: "com.leafreader.tests.\(UUID())"), providerOverride: provider)
        return settings
    }
    func testSessionRecordsAgentStepsAndFallsBackWhenToolsAreRejected() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let context = ReadingChatContext(title: "测试", author: "", chapter: "第四章", text: "白虎", source: "selection", locator: "here", progress: 0.6)
        let call = AgentToolCall(id: "c1", name: "search_book", arguments: #"{"terms":["白虎","老白"]}"#)
        let agent = ScriptedAgentProvider([[.toolCall(call), .finished(truncated: false)], [.text("守门统领。"), .finished(truncated: false)]])
        let session = ReaderChatSession()
        session.attachSelection(context); session.draft = "白虎是谁"
        session.send(settings: try settings(agent), agentBook: { _ in ReadingAgentBook(index: index, boundary: self.boundary(sections)) }) { nil }
        try await eventually { !session.isSending && session.messages.count == 2 }
        XCTAssertEqual(session.messages.last?.text, "守门统领。")
        XCTAssertEqual(session.messages.last?.trace?.usedTools, true)
        XCTAssertTrue(session.messages.last?.trace?.caption.contains("searched “白虎”, “老白”") == true)
        XCTAssertNil(session.activity)

        // A model that refuses tools is asked once more without them; nothing is pre-fetched.
        let rejecting = ScriptedAgentProvider([], failure: ChatError.http(400))
        let fallback = ReaderChatSession()
        fallback.attachSelection(context); fallback.draft = "我忘了这个角色"
        fallback.send(settings: try settings(rejecting), agentBook: { _ in ReadingAgentBook(index: index, boundary: self.boundary(sections)) }) { nil }
        try await eventually { !fallback.isSending && fallback.messages.count == 2 }
        XCTAssertEqual(fallback.messages.last?.text, "Evidence answer.")
        XCTAssertEqual(fallback.messages.last?.trace?.fellBack, true)
        XCTAssertEqual(fallback.messages.last?.trace?.caption, "Answered without tools (the provider has none)")
        let plain = try XCTUnwrap(rejecting.plainRequests.first?.turns.last?.content)
        XCTAssertTrue(plain.contains("reading_context") && plain.contains("白虎") && !plain.contains("earlier_book_passages"))
    }

    func testHighlightedNameAndFollowUpsAreSearchedBeforeTheModelAnswers() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let agentBook: @MainActor (ReadingChatContext) async throws -> ReadingAgentBook? = { _ in ReadingAgentBook(index: index, boundary: self.boundary(sections)) }
        // A model that answers at once, without calling tools itself.
        let quiet = ScriptedAgentProvider([[.text("守门统领。"), .finished(truncated: false)], [.text("还是守门统领。"), .finished(truncated: false)]])
        let settings = try settings(quiet)
        let session = ReaderChatSession()
        session.attachSelection(ReadingChatContext(title: "测试", author: "", chapter: "第四章", text: "白虎", source: "selection", locator: "here", progress: 0.6))
        session.draft = "这是谁"
        session.send(settings: settings, agentBook: agentBook) { nil }
        try await eventually { !session.isSending && session.messages.count == 2 }
        guard case .toolResults(let results) = quiet.requests.first?.items.last else { return XCTFail("The name is searched before the first model request") }
        XCTAssertTrue(results.first?.output.contains("第一章") == true)
        XCTAssertTrue(quiet.requests[0].system.contains("text is exactly what the reader highlighted"))
        XCTAssertTrue(session.messages.last?.trace?.caption.contains("searched “白虎”") == true)

        session.draft = "再说一遍是谁"
        session.send(settings: settings, agentBook: agentBook) {
            ReadingChatContext(title: "测试", author: "", chapter: "第四章", text: "大家都在大厅里。", source: "page", locator: "here", progress: 0.6)
        }
        try await eventually { !session.isSending && session.messages.count == 4 }
        guard case .toolCalls(_, let calls) = quiet.requests[1].items.dropLast().last else { return XCTFail("The follow-up subject is searched") }
        XCTAssertEqual(calls.first?.arguments, #"{"terms":["白虎"]}"#)
        XCTAssertFalse(quiet.requests[1].items.contains { if case .toolCalls(_, let calls) = $0 { return calls.contains { $0.arguments.contains("再说一遍") } }; return false })
    }

    func testConfiguredLimitsCapCallsRoundsResultsAndTools() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        var limits = AgentLimits(); limits.maxToolCalls = 2; limits.maxRounds = 3; limits.resultsPerSearch = 1
        limits.disabledTools = ["list_chapters", "search_conversation"]
        let toolbox = ReadingAgentToolbox(book: ReadingAgentBook(index: index, boundary: boundary(sections))) { _ in "{}" }
        toolbox.limits = limits
        let search = AgentToolCall(id: "a", name: "search_book", arguments: #"{"terms":["白虎"]}"#)
        let provider = ScriptedAgentProvider([[.toolCall(search), .toolCall(search), .finished(truncated: false)], [.text("答。"), .finished(truncated: false)]])
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "白虎是谁？")], bookTools: true)
        _ = try await ReadingAgentRunner.run(provider: provider, request: request, toolbox: toolbox, limits: limits, onText: { _ in }, onWithdraw: {})
        XCTAssertEqual(provider.requests.map(\.allowTools), [true, false])
        XCTAssertEqual(provider.offered.first, ["search_book", "read_passage"])
        guard case .toolResults(let results) = provider.requests[1].items.last else { return XCTFail("Missing results") }
        let hits = (try JSONSerialization.jsonObject(with: Data(results[0].output.utf8)) as? [String: Any])?["results"] as? [Any]
        XCTAssertEqual(hits?.count, 1)
        let off = try await toolbox.run(AgentToolCall(id: "b", name: "list_chapters", arguments: "{}"))
        XCTAssertTrue(off.contains("turned off"))
        limits.seedSearch = false; toolbox.limits = limits
        let seed = try await toolbox.seed("白虎", followUp: nil)
        XCTAssertTrue(seed.isEmpty)
    }

    func testSavedLimitsClampAndDefaultTracesOn() throws {
        let saved = #"{"provider":"anthropic","agentLimits":{"maxToolCalls":99,"maxRounds":1,"passageLength":2500,"disabledTools":["read_passage"]}}"#
        let configuration = try JSONDecoder().decode(ChatConfiguration.self, from: Data(saved.utf8))
        XCTAssertEqual(configuration.agentLimits.maxToolCalls, 16); XCTAssertEqual(configuration.agentLimits.maxRounds, 2)
        XCTAssertEqual(configuration.agentLimits.passageLength, 2500); XCTAssertEqual(configuration.agentLimits.resultsPerSearch, 6)
        XCTAssertEqual(configuration.agentLimits.tools.map(\.name), ["search_book", "list_chapters", "search_conversation"])
        XCTAssertTrue(configuration.recordTraces)
        XCTAssertEqual(try JSONDecoder().decode(ChatConfiguration.self, from: Data("{}".utf8)).agentLimits, AgentLimits())
    }

    func testTokenUsageIsDecodedForAllThreeProviders() async throws {
        func collect(_ provider: HTTPChatProvider) async throws -> [AgentEvent] {
            var events: [AgentEvent] = []
            for try await event in provider.streamAgent(system: "S", items: [.turn(ChatTurn(role: "user", content: "Q"))], tools: AgentTool.all, allowTools: true) { events.append(event) }
            return events
        }
        var profile = ChatProviderKind.chatCompletions.defaultProfile; profile.model = "test-model"
        let completions = HTTPChatProvider(kind: .chatCompletions, profile: profile, apiKey: "k", transport: ScriptedTransport(lines: [
            #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#, "",
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, "",
            #"data: {"choices":[],"usage":{"prompt_tokens":1500,"completion_tokens":12,"prompt_tokens_details":{"cached_tokens":1024},"completion_tokens_details":{"reasoning_tokens":4}}}"#, "",
            "data: [DONE]", ""]))
        let completionEvents = try await collect(completions)
        XCTAssertTrue(completionEvents.contains(.usage(TokenUsage(input: 1500, output: 12, cachedInput: 1024, reasoning: 4))))
        let request = try completions.makeAgentRequest(system: "S", items: [.turn(ChatTurn(role: "user", content: "Q"))], tools: AgentTool.all, allowTools: true)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])?["stream_options"])

        let anthropic = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "k", transport: ScriptedTransport(lines: [
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":2100,"cache_read_input_tokens":2000,"output_tokens":1}}}"#, "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#, "",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":33}}"#, "",
            #"data: {"type":"message_stop"}"#, ""]))
        let anthropicEvents = try await collect(anthropic)
        XCTAssertEqual(anthropicEvents, [.text("Hi"), .usage(TokenUsage(input: 2100, output: 33, cachedInput: 2000)), .finished(truncated: false)])

        XCTAssertEqual(try ChatGPTSubscriptionProvider.decodeAgent(#"{"type":"response.completed","response":{"usage":{"input_tokens":900,"output_tokens":40,"input_tokens_details":{"cached_tokens":512},"output_tokens_details":{"reasoning_tokens":16}}}}"#),
                       [.usage(TokenUsage(input: 900, output: 40, cachedInput: 512, reasoning: 16)), .finished(truncated: false)])
        let plain = HTTPChatProvider(kind: .anthropic, profile: ChatProviderKind.anthropic.defaultProfile, apiKey: "k")
        let toolless = try JSONSerialization.jsonObject(with: plain.makeAgentRequest(system: "S", items: [.turn(ChatTurn(role: "user", content: "Q"))], tools: [], allowTools: false).httpBody!) as? [String: Any]
        XCTAssertNil(toolless?["tools"]); XCTAssertNil(toolless?["tool_choice"])
    }

    func testAgentAnswerIsTracedWithStepsTimingAndTokensAndKeptOnDevice() async throws {
        let sections = book(), index = BookTextIndex(source: retain(FixtureBookSource(sections)), directory: nil)
        let directory = try temporaryFolder(create: false), store = AgentTraceStore(directory: directory)
        let call = AgentToolCall(id: "c1", name: "read_passage", arguments: #"{"section":0}"#)
        let provider = ScriptedAgentProvider([[.text("Let me check."), .toolCall(call), .usage(TokenUsage(input: 1000, output: 20)), .finished(truncated: false)],
                                              [.text("守门统领。"), .usage(TokenUsage(input: 1500, output: 8, cachedInput: 900)), .finished(truncated: false)]])
        let session = ReaderChatSession()
        session.attachSelection(ReadingChatContext(title: "测试", author: "", chapter: "第四章", text: "白虎", source: "selection", locator: "here", progress: 0.6))
        session.draft = "这是谁"
        session.send(settings: try settings(provider), agentBook: { _ in ReadingAgentBook(index: index, boundary: self.boundary(sections)) },
                     traces: store) { nil }
        try await eventually { !session.isSending && store.traces.count == 1 }
        let trace = try XCTUnwrap(store.traces.first)
        // Each request attempt is recorded too (start and outcome) since automatic retry.
        let steps = trace.steps.filter { $0.kind != .request }
        XCTAssertEqual(steps.map(\.kind), [.context, .seed, .round, .tool, .answer])
        XCTAssertEqual(trace.steps.filter { $0.kind == .request }.count, 4, "Two request records for each of the two rounds")
        XCTAssertEqual(steps[2].withdrawn, "Let me check.")
        XCTAssertEqual(trace.usage, TokenUsage(input: 2500, output: 28, cachedInput: 900))
        XCTAssertEqual(trace.selection, "白虎"); XCTAssertEqual(trace.bookTitle, "测试"); XCTAssertEqual(trace.limits, AgentLimits())
        XCTAssertTrue(trace.steps[0].payload.contains("SYSTEM\n"))
        XCTAssertTrue(trace.steps[0].detail.contains("boundary §4"))
        XCTAssertEqual(AgentTraceStore(directory: directory).traces.first?.id, trace.id)
        for _ in 0..<60 { store.add(trace) }
        XCTAssertEqual(store.traces.count, AgentTraceStore.limit)
        store.clear(); XCTAssertTrue(AgentTraceStore(directory: directory).traces.isEmpty)
    }

    // MARK: Screen tools

    private func catalogBooks() -> [ZLibraryBook] {
        (1...7).map { index in
            ZLibraryBook(remoteID: "\(index)", hash: "h\(index)", title: "Book \(index)", author: index == 2 ? "" : "Author \(index)",
                         fileExtension: "epub", size: "1 MB", language: "english", year: "200\(index)", coverURL: nil,
                         rating: index == 1 ? 4.5 : nil, ratingCount: index == 1 ? 12 : nil)
        }
    }
    private func screen(_ books: [ZLibraryBook], details: [String: Any]? = nil) -> ChatScreen {
        ChatScreen(name: "Discover", view: { limit, _ in
            ChatScreen.catalogView(books, query: "", feed: .recommended, order: .popular, status: [], canLoadMore: true,
                                   owned: [books[2].sourceID], limit: limit)
        }, details: { rank, _ in books.indices.contains(rank - 1) ? details ?? ChatScreen.catalogItem(books[rank - 1], rank: rank, owned: false) : nil })
    }

    func testCatalogScreenListsBooksInOnScreenOrderWithRanks() throws {
        let books = catalogBooks()
        let feed = ChatScreen.catalogView(books, query: "", feed: .recommended, order: .popular, status: ["preview catalog"], canLoadMore: true,
                                          owned: [books[2].sourceID], limit: 5)
        XCTAssertEqual(feed["list"] as? String, "Recommended")
        let items = try XCTUnwrap(feed["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["rank"] as? Int }, [1, 2, 3, 4, 5])
        XCTAssertEqual(items.map { $0["title"] as? String }, ["Book 1", "Book 2", "Book 3", "Book 4", "Book 5"])
        XCTAssertEqual(items[0]["rating"] as? Double, 4.5); XCTAssertEqual(items[0]["rating_count"] as? Int, 12)
        XCTAssertEqual(items[1]["author"] as? String, "Unknown author")
        XCTAssertEqual(items[2]["in_library"] as? Bool, true); XCTAssertNil(items[3]["in_library"])
        XCTAssertEqual(feed["total_items"] as? Int, 7)
        XCTAssertTrue((feed["note"] as? String)?.contains("top 5 of 7") == true)
        XCTAssertEqual(feed["status"] as? [String], ["preview catalog"])
        XCTAssertNil(feed["search"])

        let search = ChatScreen.catalogView(books, query: "dune", feed: .recommended, order: .year, status: [], canLoadMore: false, owned: [], limit: 30)
        XCTAssertEqual(search["list"] as? String, "Search results")
        XCTAssertEqual(search["search"] as? String, "dune"); XCTAssertEqual(search["sorted_by"] as? String, ZLibrarySearchOrder.year.title)
        XCTAssertEqual((search["items"] as? [Any])?.count, 7); XCTAssertNil(search["note"])
    }

    func testOpenBookDetailsAreWhatThisBookMeans() throws {
        var books = catalogBooks()
        books[1].summary = "A described second book."
        let listed = ChatScreen.catalogView(books, query: "", feed: .popular, order: .popular, status: [], canLoadMore: false,
                                            owned: [books[1].sourceID], limit: 5, open: books[1])
        let open = try XCTUnwrap(listed["open_book"] as? [String: Any])
        XCTAssertEqual(open["title"] as? String, "Book 2"); XCTAssertEqual(open["rank"] as? Int, 2)
        XCTAssertEqual(open["description"] as? String, "A described second book.")
        XCTAssertEqual(open["in_library"] as? Bool, true)
        XCTAssertTrue((listed["open_book_note"] as? String)?.contains("this book") == true)
        XCTAssertEqual((listed["items"] as? [Any])?.count, 5, "The list behind the page is still readable")

        var elsewhere = ZLibraryBook(remoteID: "99", hash: "h99", title: "Unlisted", author: "A", fileExtension: "epub", size: "", language: "", year: "", coverURL: nil)
        var view = ChatScreen.catalogView(books, query: "", feed: .popular, order: .popular, status: [], canLoadMore: false, owned: [], limit: 5, open: elsewhere)
        var unlisted = try XCTUnwrap(view["open_book"] as? [String: Any])
        XCTAssertNil(unlisted["rank"]); XCTAssertTrue((unlisted["description_note"] as? String)?.contains("loading") == true)
        elsewhere.summary = ""
        view = ChatScreen.catalogView(books, query: "", feed: .popular, order: .popular, status: [], canLoadMore: false, owned: [], limit: 5, open: elsewhere)
        unlisted = try XCTUnwrap(view["open_book"] as? [String: Any])
        XCTAssertEqual(unlisted["description_note"] as? String, "The catalog has no description for this book.")
        XCTAssertNil(ChatScreen.catalogView(books, query: "", feed: .popular, order: .popular, status: [], canLoadMore: false, owned: [], limit: 5)["open_book"])
        XCTAssertTrue(ChatRequest.screenPrompt("Discover", tools: true).contains("open_book"))
    }

    func testSavedScreenFollowsTheListOrderAndHidesPassagesWhenSharingIsOff() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000), new = old.addingTimeInterval(86_400)
        var first = Book(id: UUID(), title: "First", author: "A", fileName: "a.epub", format: .epub, fingerprint: "a")
        first.bookmarks = [BookBookmark(label: "Older place", locator: "l1", fraction: 0.2, createdAt: old),
                           BookBookmark(label: "Newer place", locator: "l2", fraction: 0.456, createdAt: new)]
        first.annotations = [BookAnnotation(text: "A highlighted line", locator: "l3", chapter: "Chapter 2", fraction: 0.3, note: "My thought", createdAt: old)]
        var second = Book(id: UUID(), title: "Second", author: "B", fileName: "b.epub", format: .epub, fingerprint: "b")
        second.bookmarks = [BookBookmark(label: "Only place", locator: "l4", fraction: 0.9, createdAt: old)]

        let bookmarks = ChatScreen.savedView(ChatScreen.savedEntries([first, second], highlights: false), highlights: false, sharePassages: true, limit: 30)
        let rows = try XCTUnwrap(bookmarks["items"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["label"] as? String }, ["Newer place", "Older place", "Only place"])
        XCTAssertEqual(rows.map { $0["rank"] as? Int }, [1, 2, 3])
        XCTAssertEqual(rows[0]["book"] as? String, "First"); XCTAssertEqual(rows[0]["percent_through_book"] as? Int, 45)
        XCTAssertEqual(rows[2]["book"] as? String, "Second")
        XCTAssertEqual(bookmarks["list"] as? String, "Bookmarks")

        let entries = ChatScreen.savedEntries([first, second], highlights: true)
        XCTAssertEqual(entries.count, 1, "A book without highlights is not on the Highlights list")
        let shared = try XCTUnwrap((ChatScreen.savedView(entries, highlights: true, sharePassages: true, limit: 30)["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(shared["kind"] as? String, "note"); XCTAssertEqual(shared["text"] as? String, "A highlighted line")
        XCTAssertEqual(shared["note"] as? String, "My thought"); XCTAssertEqual(shared["chapter"] as? String, "Chapter 2")
        let hidden = ChatScreen.savedView(entries, highlights: true, sharePassages: false, limit: 30)
        let row = try XCTUnwrap((hidden["items"] as? [[String: Any]])?.first)
        XCTAssertNil(row["text"]); XCTAssertNil(row["note"]); XCTAssertNotNil(hidden["note_on_passages"])
        XCTAssertEqual(row["chapter"] as? String, "Chapter 2")
    }

    func testScreenToolboxOffersViewToolsAndRefusesBookTools() async throws {
        let toolbox = ReadingAgentToolbox(book: nil, screen: screen(catalogBooks())) { _ in "{\"matches\":[]}" }
        XCTAssertEqual(toolbox.tools.map(\.name), ["search_conversation", "get_current_view", "get_item_details"])
        let view = try await toolbox.run(AgentToolCall(id: "1", name: "get_current_view", arguments: #"{"max_items":5}"#))
        XCTAssertTrue(view.contains("\"rank\":5") && !view.contains("\"rank\":6"))
        let item = try await toolbox.run(AgentToolCall(id: "2", name: "get_item_details", arguments: #"{"rank":3}"#))
        XCTAssertTrue(item.contains("Book 3"))
        let missing = try await toolbox.run(AgentToolCall(id: "3", name: "get_item_details", arguments: #"{"rank":30}"#))
        XCTAssertTrue(missing.contains("Nothing is at rank 30"))
        let noRank = try await toolbox.run(AgentToolCall(id: "4", name: "get_item_details", arguments: "{}"))
        XCTAssertTrue(noRank.contains("Provide rank"))
        let search = try await toolbox.run(AgentToolCall(id: "5", name: "search_book", arguments: #"{"terms":["x"]}"#))
        XCTAssertTrue(search.contains("No book is open"))
        XCTAssertEqual(toolbox.steps, ["read the Discover screen (5)", "details for #3"])
        let seed = try await toolbox.seed("Book 3", followUp: nil)
        XCTAssertEqual(seed, [], "No book to search before answering")

        toolbox.limits.disabledTools = ["get_item_details"]
        XCTAssertEqual(toolbox.tools.map(\.name), ["search_conversation", "get_current_view"])
        let failing = ChatScreen(name: "Discover", view: { _, _ in [:] }, details: { _, _ in throw ZLibraryError.response })
        let unreachable = try await ReadingAgentToolbox(book: nil, screen: failing) { _ in "" }
            .run(AgentToolCall(id: "6", name: "get_item_details", arguments: #"{"rank":1}"#))
        XCTAssertTrue(unreachable.contains("Details could not be loaded"), "A failed lookup is reported to the model, not a failed reply")
    }

    func testTopFiveQuestionReadsTheScreenThroughToolsOrAsTextWithoutThem() async throws {
        let books = catalogBooks()
        let view = AgentToolCall(id: "v1", name: "get_current_view", arguments: #"{"max_items":5}"#)
        let details = AgentToolCall(id: "d1", name: "get_item_details", arguments: #"{"rank":1}"#)
        let agent = ScriptedAgentProvider([[.toolCall(view), .finished(truncated: false)],
                                           [.toolCall(details), .finished(truncated: false)],
                                           [.text("1. Book 1 — a summary."), .finished(truncated: false)]])
        let session = ReaderChatSession()
        session.draft = "Summarize the top 5 recommendations"
        session.send(settings: try settings(agent), missingContextNotice: nil,
                     screen: screen(books, details: ["rank": 1, "title": "Book 1", "description": "A described book."])) { nil }
        try await eventually { !session.isSending && session.messages.count == 2 }
        XCTAssertEqual(session.messages.last?.text, "1. Book 1 — a summary.")
        XCTAssertEqual(agent.offered.first, ["search_conversation", "get_current_view", "get_item_details"])
        XCTAssertTrue(agent.requests[0].system.contains("from the Discover screen") && agent.requests[0].system.contains("call get_current_view first"))
        guard case .toolResults(let listed) = agent.requests[1].items.last, case .toolResults(let described) = agent.requests[2].items.last else {
            return XCTFail("Missing tool results")
        }
        XCTAssertTrue(listed[0].output.contains("Book 5") && !listed[0].output.contains("Book 6"))
        XCTAssertTrue(described[0].output.contains("A described book."))
        XCTAssertEqual(session.messages.last?.trace?.steps, ["read the Discover screen (5)", "details for #1"])

        // A model without tools gets the list with the question.
        let plain = ScriptedAgentProvider([], failure: ChatError.http(400))
        let evidence = ReaderChatSession()
        evidence.draft = "Summarize the top 5 recommendations"
        evidence.send(settings: try settings(plain), missingContextNotice: nil, screen: screen(books)) { nil }
        try await eventually { !evidence.isSending && evidence.messages.count == 2 }
        let request = try XCTUnwrap(plain.plainRequests.first)
        XCTAssertTrue(request.system.contains("comes with current_screen"))
        XCTAssertTrue(request.turns.last?.content.hasPrefix("current_screen (source material") == true)
        XCTAssertTrue(request.turns.last?.content.contains("\"title\":\"Book 7\"") == true)
        XCTAssertTrue(request.turns.last?.content.hasSuffix("Summarize the top 5 recommendations") == true)
        XCTAssertEqual(evidence.messages.last?.trace?.steps, ["sent the Discover screen as text (7)"])
    }

    func testCatalogDescriptionsArePlainText() throws {
        XCTAssertEqual(ZLibraryClient.plainText("<p>A <b>bold</b> story &amp; more.</p><p>Second&nbsp;part.</p>"), "A bold story & more.\n\nSecond part.")
        XCTAssertNil(ZLibraryClient.plainText("  <br/> "))
        XCTAssertNil(ZLibraryClient.plainText(42))
        XCTAssertEqual(ZLibraryClient.plainText(String(repeating: "a", count: 5000))?.count, 3000)
        let row: [String: Any] = ["id": "1", "hash": "abc", "title": "T", "description": "<i>Hello</i>"]
        XCTAssertEqual(ZLibraryClient.book(row, origin: try ZLibraryOrigin("https://catalog.example.org"))?.summary, "Hello")
    }
}
