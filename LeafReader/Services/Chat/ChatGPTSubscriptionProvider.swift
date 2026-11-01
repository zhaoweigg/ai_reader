import Foundation

struct ChatGPTSubscriptionProvider: ChatProvider {
    let accounts: ChatGPTAccountStore
    let accountID: String
    let model: String
    var transport: any ChatTransport = URLSessionChatTransport()
    /// Offer OpenAI's hosted image tool, so asking for a picture returns one.
    var imageGeneration = true

    /// Medium-quality JPEG keeps one picture to a few hundred kilobytes on the wire.
    static let imageTool: [String: Any] = ["type": "image_generation", "quality": "medium", "output_format": "jpeg", "output_compression": 85]
    /// Account and model pairs that refused the image tool during this launch,
    /// with the reason; their requests go out without it.
    @MainActor static var imageToolRejected: [String: String] = [:]
    private var imageKey: String { accountID + "\n" + model }
    /// Added to the instructions whenever the image tool is offered: the reading
    /// prompt describes only the book tools, and earlier replies in a conversation
    /// may have said that drawing is impossible.
    static let drawingInstruction = """
        You can also draw: the image_generation tool is available. When the reader asks for a picture, image, illustration or drawing (for example 生成一张图片 or 画一张…), call image_generation with a detailed description, then reply with one or two sentences about the picture. Do not write a prompt for another tool instead. Earlier answers in this conversation that said you cannot draw are outdated.
        """

    func makeRequest(_ conversation: ChatRequest, accessToken: String, images: Bool = false) throws -> URLRequest {
        guard !model.isEmpty else { throw ChatGPTError.missingModel }
        guard !conversation.turns.isEmpty else { throw ChatError.configuration("Write a question first.") }
        return try makeRequest(instructions: images ? conversation.system + "\n\n" + Self.drawingInstruction : conversation.system,
                               input: conversation.turns.map { ["role": $0.role, "content": $0.content] },
                               extra: images ? ["tools": [Self.imageTool], "tool_choice": "auto"] : [:], accessToken: accessToken)
    }
    /// Why a request with the image tool was refused, from fields that name the
    /// problem (status, code, type, parameter), never the server's message text.
    static func refusalReason(_ body: Data, status: Int) -> String {
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"]
        let fields = error as? [String: Any]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-[]"))
        var parts = ["HTTP \(status)"]
        for value in [fields?["code"], fields?["type"], fields?["param"], error] {
            guard let text = value as? String else { continue }
            let safe = String(String(text.unicodeScalars.filter { allowed.contains($0) && $0.isASCII }).prefix(60))
            if !safe.isEmpty, !parts.contains(safe) { parts.append(safe) }
        }
        return parts.joined(separator: " · ")
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
        let events = open({ try makeRequest(conversation, accessToken: $0, images: $1) }) { data, _ in
            try Self.decode(data).map(\.agentEvent)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        switch event {
                        case .text(let text): continuation.yield(.text(text))
                        case .imageStarted: continuation.yield(.imageStarted)
                        case .image(let data): continuation.yield(.image(data))
                        case .imageToolRefused(let reason): continuation.yield(.imageToolRefused(reason))
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
    /// SSE. A reply must contain answer text, a picture or tool calls, and a terminal event.
    /// `build` receives whether to offer the hosted image tool.
    private func open(_ build: @escaping @MainActor (String, Bool) throws -> URLRequest,
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
                    var images = imageGeneration && Self.imageToolRejected[imageKey] == nil
                    if imageGeneration, let reason = Self.imageToolRejected[imageKey] { continuation.yield(.imageToolRefused(reason)) }
                    var (response, lines) = try await transport.open(try build(token, images))
                    if images, [400, 422].contains(response.statusCode) {
                        // A model or plan without the hosted image tool rejects the whole
                        // request. Ask once more without it; only if that is accepted is
                        // the tool set aside for this account and model until relaunch,
                        // and the reason reported so the reply and trace can say so.
                        var body = Data()
                        for try await line in lines {
                            body.append(Data(line.utf8))
                            if body.count > 16384 { break }
                        }
                        let reason = Self.refusalReason(body, status: response.statusCode)
                        images = false
                        (response, lines) = try await transport.open(try build(token, images))
                        if (200..<300).contains(response.statusCode) {
                            Self.imageToolRejected[imageKey] = reason
                            continuation.yield(.imageToolRefused(reason))
                        }
                    }
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
                    var textLength = 0, calls = 0, pictures = 0
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = try decoder.consume(line) else { continue }
                        for event in try decode(data, &calls) {
                            switch event {
                            case .text(let text):
                                textLength += text.count
                                guard textLength <= 64000 else { throw ChatError.tooLarge }
                            case .image: pictures += 1
                            case .toolCall, .usage, .imageStarted, .imageToolRefused: break
                            case .finished:
                                guard textLength > 0 || calls > 0 || pictures > 0 else { throw ChatError.emptyResponse }
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
        case "response.image_generation_call.in_progress", "response.image_generation_call.generating": return [.imageStarted]
        case "response.output_item.done":
            // A finished picture arrives whole, base64 encoded. A failed or empty call
            // adds nothing; the model's own text then explains.
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "image_generation_call",
                  let result = item["result"] as? String, !result.isEmpty,
                  let data = Data(base64Encoded: result, options: .ignoreUnknownCharacters) else { return [] }
            return [.image(data)]
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
    func makeAgentRequest(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool, accessToken: String, images: Bool = false) throws -> URLRequest {
        var offered: [[String: Any]] = tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters] }
        // Pictures are offered whenever the model may still act: every agent round
        // that allows tools, and a plain traced reply. The closing round answers in words.
        let drawing = images && (allowTools || tools.isEmpty)
        if drawing { offered.append(Self.imageTool) }
        var extra: [String: Any] = offered.isEmpty ? [:] : ["tools": offered, "tool_choice": allowTools || drawing ? "auto" : "none"]
        if !tools.isEmpty { extra["parallel_tool_calls"] = true }
        return try makeRequest(instructions: drawing ? system + "\n\n" + Self.drawingInstruction : system,
                               input: Self.input(items), extra: extra, accessToken: accessToken)
    }
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        open({ try makeAgentRequest(system: system, items: items, tools: tools, allowTools: allowTools, accessToken: $0, images: $1) }) { data, calls in
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
        return try decode(data).map(\.agentEvent)
    }
}
