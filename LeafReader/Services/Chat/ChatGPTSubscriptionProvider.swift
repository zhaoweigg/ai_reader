import Foundation

struct ChatGPTSubscriptionProvider: ChatProvider {
    let accounts: ChatGPTAccountStore
    let accountID: String
    let model: String
    var transport: any ChatTransport = URLSessionChatTransport()

    func makeRequest(_ conversation: ChatRequest, accessToken: String) throws -> URLRequest {
        guard !model.isEmpty else { throw ChatGPTError.missingModel }
        guard !conversation.turns.isEmpty else { throw ChatError.configuration("Write a question first.") }
        return try makeRequest(instructions: conversation.system, input: conversation.turns.map { ["role": $0.role, "content": $0.content] }, accessToken: accessToken)
    }
    private func makeRequest(instructions: String, input: [[String: Any]], extra: [String: Any] = [:], accessToken: String) throws -> URLRequest {
        guard !model.isEmpty else { throw ChatGPTError.missingModel }
        guard !input.isEmpty else { throw ChatError.configuration("Write a question first.") }
        var request = URLRequest(url: ChatGPTEndpoints.responses)
        request.httpMethod = "POST"; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Subscription permission has its own Responses contract. In particular,
        // max_output_tokens, temperature, and persistent conversation IDs are omitted.
        var body: [String: Any] = ["model": model, "instructions": instructions, "store": false, "stream": true, "input": input]
        body.merge(extra) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
    func stream(_ conversation: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let events = open({ try makeRequest(conversation, accessToken: $0) }) { data, _ in
            try Self.decode(data).map { event -> AgentEvent in
                switch event { case .text(let text): return .text(text); case .finished(let value): return .finished(truncated: value) }
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        switch event {
                        case .text(let text): continuation.yield(.text(text))
                        case .finished(let value): continuation.yield(.finished(truncated: value))
                        case .toolCall, .usage: break
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    /// Registers the request with its account, refreshes the token, and decodes
    /// SSE. A reply must contain answer text or tool calls and a terminal event.
    private func open(_ build: @escaping @MainActor (String) throws -> URLRequest,
                      decode: @escaping (String, inout Int) throws -> [AgentEvent]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let requestID = UUID()
                defer { accounts.unregisterRequest(requestID) }
                do {
                    try accounts.registerRequest(requestID, accountID: accountID) {
                        continuation.finish(throwing: ChatGPTError.signInRequired)
                    }
                    try await accounts.validateModel(model, accountID: accountID)
                    let token = try await accounts.accessToken(accountID: accountID)
                    try Task.checkCancellation()
                    let request = try build(token)
                    let (response, lines) = try await transport.open(request)
                    guard (200..<300).contains(response.statusCode) else {
                        var errorData = Data()
                        for try await line in lines {
                            errorData.append(Data(line.utf8))
                            if errorData.count > 16384 { break }
                        }
                        throw ChatRequestFailure(ChatGPTOAuthClient.error(errorData, status: response.statusCode), response: response)
                    }
                    // Some successful Responses replies arrive without Content-Type on iOS.
                    // A missing header must not discard a valid SSE body. We still
                    // require JSON events, answer text, and a terminal Responses event.
                    if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
                        let mediaType = contentType.split(separator: ";", maxSplits: 1).first?
                            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard mediaType == "text/event-stream" else { throw ChatGPTError.invalidResponse }
                    }
                    var decoder = ServerSentEventDecoder()
                    var textLength = 0, calls = 0
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = try decoder.consume(line) else { continue }
                        for event in try decode(data, &calls) {
                            switch event {
                            case .text(let text):
                                textLength += text.count
                                guard textLength <= 64000 else { throw ChatError.tooLarge }
                            case .toolCall, .usage: break
                            case .finished:
                                guard textLength > 0 || calls > 0 else { throw ChatError.emptyResponse }
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
    static func decode(_ data: String) throws -> [ChatEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { throw ChatGPTError.invalidResponse }
        switch object["type"] as? String {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = object["delta"] as? String else { throw ChatGPTError.invalidResponse }
            return [.text(delta)]
        case "response.completed": return [.finished(truncated: false)]
        case "response.incomplete": return [.finished(truncated: true)]
        case "response.failed":
            let response = object["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            throw ChatGPTError.response(status: 400, code: error?["code"] as? String)
        case "error": throw ChatGPTError.response(status: 400, code: object["code"] as? String)
        default: return [] // Never render reasoning, tool arguments, or usage as text.
        }
    }
}

extension ChatGPTSubscriptionProvider: ToolChatProvider {
    static func input(_ items: [AgentItem]) -> [[String: Any]] {
        items.flatMap { item -> [[String: Any]] in
            switch item {
            case .turn(let turn): return [["role": turn.role, "content": turn.content]]
            case .toolCalls(_, let calls):
                return calls.map { ["type": "function_call", "call_id": $0.id, "name": $0.name, "arguments": $0.arguments] }
            case .toolResults(let results):
                return results.map { ["type": "function_call_output", "call_id": $0.id, "output": $0.output] }
            }
        }
    }
    func makeAgentRequest(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool, accessToken: String) throws -> URLRequest {
        try makeRequest(instructions: system, input: Self.input(items), extra: tools.isEmpty ? [:] : [
            "tools": tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters] },
            "tool_choice": allowTools ? "auto" : "none", "parallel_tool_calls": true
        ], accessToken: accessToken)
    }
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        open({ try makeAgentRequest(system: system, items: items, tools: tools, allowTools: allowTools, accessToken: $0) }) { data, calls in
            let events = try Self.decodeAgent(data)
            calls += events.filter { if case .toolCall = $0 { return true }; return false }.count
            return events
        }
    }
    static func decodeAgent(_ data: String) throws -> [AgentEvent] {
        if let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any],
           object["type"] as? String == "response.completed", let usage = (object["response"] as? [String: Any])?["usage"] as? [String: Any] {
            let reported = TokenUsage(input: usage["input_tokens"] as? Int, output: usage["output_tokens"] as? Int,
                                      cachedInput: (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
                                      reasoning: (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int)
            return (reported.isEmpty ? [] : [.usage(reported)]) + [.finished(truncated: false)]
        }
        if let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any],
           object["type"] as? String == "response.output_item.done",
           let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" {
            guard let id = item["call_id"] as? String, let name = item["name"] as? String else { throw ChatGPTError.invalidResponse }
            let arguments = item["arguments"] as? String ?? "{}"
            return [.toolCall(AgentToolCall(id: id, name: name, arguments: arguments.isEmpty ? "{}" : arguments))]
        }
        return try decode(data).map { event -> AgentEvent in
            switch event { case .text(let text): return .text(text); case .finished(let value): return .finished(truncated: value) }
        }
    }
}
