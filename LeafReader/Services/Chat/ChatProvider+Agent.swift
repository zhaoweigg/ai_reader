import Foundation

// Tool calling for the book search agent in Anthropic Messages and Chat
// Completions formats. Plain chat requests are unchanged.
extension HTTPChatProvider: ToolChatProvider {
    func makeAgentRequest(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool, webSearch: Bool = true) throws -> URLRequest {
        try makeRequest(system: system, messages: kind == .anthropic ? Self.anthropicMessages(items) : Self.completionMessages(items),
                        tools: tools, allowTools: allowTools, webSearch: webSearch)
    }
    /// Endpoint and model pairs that refused web search during this launch, with the reason.
    static let webSearchRefusals = HostedToolRefusals()
    private var refusalKey: String { (profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n" + profile.model }
    static func completionMessages(_ items: [AgentItem]) -> [[String: Any]] {
        items.flatMap { item -> [[String: Any]] in
            switch item {
            case .turn(let turn): return [["role": turn.role, "content": turn.content]]
            case .toolCalls(let text, let calls), .providerContent(_, let text, let calls):
                return [["role": "assistant", "content": text.isEmpty ? NSNull() : text as Any,
                         "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }]]
            case .toolResults(let results): return results.map { ["role": "tool", "tool_call_id": $0.id, "content": $0.output] }
            }
        }
    }
    static func anthropicMessages(_ items: [AgentItem]) -> [[String: Any]] {
        items.map { item -> [String: Any] in
            switch item {
            case .turn(let turn): return ["role": turn.role, "content": turn.content]
            case .toolCalls(let text, let calls):
                let uses: [[String: Any]] = calls.map {
                    ["type": "tool_use", "id": $0.id, "name": $0.name,
                     "input": (try? JSONSerialization.jsonObject(with: Data($0.arguments.utf8))) as? [String: Any] ?? [:]]
                }
                return ["role": "assistant", "content": (text.isEmpty ? [] : [["type": "text", "text": text]]) + uses]
            case .toolResults(let results):
                return ["role": "user", "content": results.map { ["type": "tool_result", "tool_use_id": $0.id, "content": $0.output] }]
            case .providerContent(let data, let text, let calls):
                // Claude's reply exactly as it came, searches and their results included.
                if let blocks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !blocks.isEmpty {
                    return ["role": "assistant", "content": blocks]
                }
                return anthropicMessages([.toolCalls(text: text, calls: calls)])[0]
            }
        }
    }

    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Claude's web search can be turned off for an organization or a model. Ask
                    // once more without it; only if that is accepted is it set aside until relaunch.
                    let offersSearch = kind == .anthropic && tools.contains { $0.hosted }
                    var webSearch = offersSearch
                    if offersSearch, let reason = Self.webSearchRefusals[refusalKey] {
                        webSearch = false
                        continuation.yield(.webSearchRefused(reason))
                    }
                    var (response, lines) = try await transport.open(
                        try makeAgentRequest(system: system, items: items, tools: tools, allowTools: allowTools, webSearch: webSearch))
                    if webSearch, [400, 422].contains(response.statusCode) {
                        var body = Data()
                        for try await line in lines {
                            body.append(Data(line.utf8))
                            if body.count > 16384 { break }
                        }
                        let reason = ChatGPTSubscriptionProvider.refusalReason(body, status: response.statusCode)
                        webSearch = false
                        (response, lines) = try await transport.open(
                            try makeAgentRequest(system: system, items: items, tools: tools, allowTools: allowTools, webSearch: false))
                        if (200..<300).contains(response.statusCode) {
                            Self.webSearchRefusals[refusalKey] = reason
                            continuation.yield(.webSearchRefused(reason))
                        }
                    }
                    if offersSearch {
                        let sent = webSearch ? "\(Self.anthropicWebSearchType(profile.model)) sent"
                            : "web_search not sent: " + (Self.webSearchRefusals[refusalKey].map { "refused earlier this launch (\($0))" } ?? "refused by this request")
                        continuation.yield(.diagnostic(title: "Hosted tools", detail: "\(sent) · model \(profile.model) · HTTP \(response.statusCode)"))
                    }
                    guard (200..<300).contains(response.statusCode) else { throw ChatRequestFailure(ChatError.http(response.statusCode), response: response) }
                    guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                        throw ChatError.invalidResponse
                    }
                    var decoder = ServerSentEventDecoder()
                    var state = AgentStreamState()
                    var searches = 0
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = try decoder.consume(line) else { continue }
                        for event in try decodeAgent(data, state: &state) {
                            switch event {
                            case .text(let text):
                                state.textLength += text.count
                                guard state.textLength <= 64000 else { throw ChatError.tooLarge }
                            case .toolCall: state.calls += 1
                            case .webSearch(let query): if query != nil { searches += 1 }
                            case .usage, .imageStarted, .image, .imageToolRefused, .webSearchRefused, .providerContent, .diagnostic: break
                            case .finished:
                                // A turn Claude paused while searching may hold no text yet.
                                guard state.textLength > 0 || state.calls > 0 || state.paused else { throw ChatError.emptyResponse }
                                if webSearch, searches == 0, allowTools {
                                    continuation.yield(.diagnostic(title: "Web search not used", detail: "offered and accepted; the model answered without searching"))
                                }
                                continuation.yield(event); continuation.finish(); return
                            }
                            continuation.yield(event)
                        }
                    }
                    throw ChatError.interrupted
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct AgentStreamState {
        var truncated = false
        var textLength = 0
        var calls = 0
        var usage = TokenUsage()
        /// Claude's content blocks as they stream, by index, to send back unchanged
        /// when the reply searched the web; tool inputs arrive as JSON fragments.
        var blocks: [Int: [String: Any]] = [:]
        var inputs: [Int: String] = [:]
        var searched = false
        var paused = false
        var answer = ""
        var sources: [WebSource] = []
        var content: Data? {
            guard searched else { return nil }
            let list = blocks.keys.sorted().compactMap { blocks[$0] }
            return try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
        }
        // Tool calls arrive in fragments, keyed by index, until they are complete.
        var pending: [Int: (id: String, name: String, arguments: String)] = [:]
        mutating func flush() -> [AgentEvent] {
            defer { pending = [:] }
            return pending.keys.sorted().compactMap { key in
                guard let call = pending[key], !call.name.isEmpty else { return nil }
                return .toolCall(AgentToolCall(id: call.id.isEmpty ? "call_\(key)" : call.id, name: call.name,
                                               arguments: call.arguments.isEmpty ? "{}" : call.arguments))
            }
        }
    }

    func decodeAgent(_ data: String, state: inout AgentStreamState) throws -> [AgentEvent] {
        if kind == .chatCompletions, data == "[DONE]" { return state.flush() + [.finished(truncated: state.truncated)] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { throw ChatError.invalidResponse }
        if kind == .anthropic {
            let index = (object["index"] as? NSNumber)?.intValue ?? 0
            switch object["type"] as? String {
            case "content_block_start":
                if let block = object["content_block"] as? [String: Any] {
                    state.blocks[index] = block
                    switch block["type"] as? String {
                    case "tool_use":
                        state.pending[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
                        return []
                    case "server_tool_use":
                        state.searched = true
                        return block["name"] as? String == AgentTool.webSearchName ? [.webSearch(nil)] : []
                    case "web_search_tool_result":
                        state.searched = true
                        // A failed search returns an error object instead of a list of results.
                        if let failure = block["content"] as? [String: Any] {
                            return [.diagnostic(title: "Web search error", detail: failure["error_code"] as? String ?? "unknown")]
                        }
                        return []
                    default: break // Text, which the plain decoder below reads, and thinking.
                    }
                }
            case "content_block_delta":
                if let delta = object["delta"] as? [String: Any] {
                    switch delta["type"] as? String {
                    case "input_json_delta":
                        let part = delta["partial_json"] as? String ?? ""
                        state.inputs[index, default: ""] += part
                        state.pending[index]?.arguments += part
                        return []
                    case "text_delta":
                        let text = state.blocks[index]?["text"] as? String ?? ""
                        state.blocks[index]?["text"] = text + (delta["text"] as? String ?? "")
                    case "thinking_delta":
                        let thinking = state.blocks[index]?["thinking"] as? String ?? ""
                        state.blocks[index]?["thinking"] = thinking + (delta["thinking"] as? String ?? "")
                        return []
                    case "signature_delta":
                        state.blocks[index]?["signature"] = delta["signature"] as? String ?? ""
                        return []
                    case "citations_delta":
                        if let citation = delta["citation"] as? [String: Any] {
                            let citations = state.blocks[index]?["citations"] as? [Any] ?? []
                            state.blocks[index]?["citations"] = citations + [citation]
                            if citation["type"] as? String == "web_search_result_location",
                               let source = WebSource(url: citation["url"] as? String, title: citation["title"] as? String),
                               !state.sources.contains(where: { $0.url == source.url }) { state.sources.append(source) }
                        }
                        return []
                    default: break
                    }
                }
            case "content_block_stop":
                var events: [AgentEvent] = []
                if let raw = state.inputs.removeValue(forKey: index) {
                    let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                    state.blocks[index]?["input"] = input
                }
                if let block = state.blocks[index], block["type"] as? String == "server_tool_use", block["name"] as? String == AgentTool.webSearchName {
                    let query = (block["input"] as? [String: Any])?["query"] as? String ?? ""
                    events.append(.webSearch(query.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                if let call = state.pending.removeValue(forKey: index), !call.name.isEmpty {
                    events.append(.toolCall(AgentToolCall(id: call.id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments)))
                }
                return events
            case "message_start":
                let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
                state.usage.input = usage?["input_tokens"] as? Int
                state.usage.cachedInput = usage?["cache_read_input_tokens"] as? Int
                return []
            case "message_stop":
                var events = state.flush()
                // Web results always show where they came from.
                if let footnote = WebSource.footnote(state.sources, after: state.answer) { events.append(.text(footnote)) }
                if let content = state.content { events.append(.providerContent(content, paused: state.paused)) }
                return events + (state.usage.isEmpty ? [] : [.usage(state.usage)]) + [.finished(truncated: state.truncated)]
            default: break
            }
        } else if let choice = (object["choices"] as? [[String: Any]])?.first {
            for fragment in (choice["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] ?? [] {
                let index = (fragment["index"] as? NSNumber)?.intValue ?? 0
                var call = state.pending[index] ?? ("", "", "")
                if let id = fragment["id"] as? String { call.id = id }
                if let function = fragment["function"] as? [String: Any] {
                    call.name += function["name"] as? String ?? ""
                    call.arguments += function["arguments"] as? String ?? ""
                }
                state.pending[index] = call
            }
        }
        // Text, errors, finish reasons and message_delta use the plain chat decoder.
        var truncated = state.truncated
        var events = try decode(data, truncated: &truncated).map(\.agentEvent)
        state.truncated = truncated
        // Completions end tool calls with a finish reason before [DONE].
        if kind == .chatCompletions, (object["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "tool_calls" {
            events += state.flush()
        }
        // Token usage: Anthropic reports output in message_delta; Completions in a final usage chunk.
        if kind == .anthropic, object["type"] as? String == "message_delta", let usage = object["usage"] as? [String: Any] {
            state.usage.output = usage["output_tokens"] as? Int
        }
        // Claude stopped its own searching mid-turn and expects the reply back to go on.
        if kind == .anthropic, object["type"] as? String == "message_delta",
           (object["delta"] as? [String: Any])?["stop_reason"] as? String == "pause_turn" { state.paused = true }
        for case .text(let text) in events { state.answer += text }
        if kind == .chatCompletions, let usage = object["usage"] as? [String: Any] {
            let reported = TokenUsage(input: usage["prompt_tokens"] as? Int, output: usage["completion_tokens"] as? Int,
                                      cachedInput: (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
                                      reasoning: (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int)
            if !reported.isEmpty { events.insert(.usage(reported), at: 0) }
        }
        return events
    }
}

/// Hosted tools a provider refused during this launch, with the reason; requests skip them.
final class HostedToolRefusals: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String: String] = [:]
    subscript(key: String) -> String? {
        get { lock.withLock { reasons[key] } }
        set { lock.withLock { reasons[key] = newValue } }
    }
}
