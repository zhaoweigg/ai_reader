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
    /// ChatGPT's own web search, offered in agent rounds that may still use tools.
    static let webSearchTool: [String: Any] = ["type": "web_search"]
    /// Account and model pairs that refused web search during this launch, with the reason.
    @MainActor static var webSearchRejected: [String: String] = [:]
    /// Which hosted tools a request may offer, and which it did offer.
    struct HostedTools: Equatable { var images = false; var web = false }
    /// What one streamed reply has said so far: its answer text, the tool calls it
    /// made and the web pages it cited.
    struct ResponseState {
        var text = ""
        var sources: [WebSource] = []
    }
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
        let events = open({ token, allowed in
            (try makeRequest(conversation, accessToken: token, images: allowed.images), HostedTools(images: allowed.images))
        }) { data, _ in
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
                        case .toolCall, .usage, .webSearch, .webSearchRefused, .providerContent: break
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
    /// `build` receives which hosted tools it may offer and returns the request with the
    /// tools it did offer.
    private func open(_ build: @escaping @MainActor (String, HostedTools) throws -> (URLRequest, HostedTools),
                      decode: @escaping (String, inout ResponseState) throws -> [AgentEvent]) -> AsyncThrowingStream<AgentEvent, Error> {
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
                    var allowed = HostedTools(images: imageGeneration && Self.imageToolRejected[imageKey] == nil,
                                              web: Self.webSearchRejected[imageKey] == nil)
                    if imageGeneration, let reason = Self.imageToolRejected[imageKey] { continuation.yield(.imageToolRefused(reason)) }
                    if let reason = Self.webSearchRejected[imageKey], try build(token, HostedTools(images: allowed.images, web: true)).1.web {
                        continuation.yield(.webSearchRefused(reason))
                    }
                    var (request, offered) = try build(token, allowed)
                    var (response, lines) = try await transport.open(request)
                    // A model, plan or workspace without a hosted tool rejects the whole
                    // request. Ask again without the tool, the picture tool first; only if a
                    // request is then accepted is the tool dropped last set aside for this
                    // account and model until relaunch, and the reason reported so the reply
                    // and trace can say so.
                    var blamed: (web: Bool, reason: String)?
                    while [400, 422].contains(response.statusCode), offered.images || offered.web {
                        var body = Data()
                        for try await line in lines {
                            body.append(Data(line.utf8))
                            if body.count > 16384 { break }
                        }
                        let reason = Self.refusalReason(body, status: response.statusCode)
                        if offered.images { allowed.images = false; blamed = (false, reason) } else { allowed.web = false; blamed = (true, reason) }
                        (request, offered) = try build(token, allowed)
                        (response, lines) = try await transport.open(request)
                    }
                    if let blamed, (200..<300).contains(response.statusCode) {
                        if blamed.web {
                            Self.webSearchRejected[imageKey] = blamed.reason
                            continuation.yield(.webSearchRefused(blamed.reason))
                        } else {
                            Self.imageToolRejected[imageKey] = blamed.reason
                            continuation.yield(.imageToolRefused(blamed.reason))
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
                    var state = ResponseState()
                    var textLength = 0, calls = 0, pictures = 0
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = try decoder.consume(line) else { continue }
                        for event in try decode(data, &state) {
                            switch event {
                            case .text(let text):
                                textLength += text.count
                                guard textLength <= 64000 else { throw ChatError.tooLarge }
                            case .image: pictures += 1
                            case .toolCall: calls += 1
                            case .usage, .imageStarted, .imageToolRefused, .webSearch, .webSearchRefused, .providerContent: break
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
            case .toolCalls(_, let calls), .providerContent(_, _, let calls):
                return calls.map { ["type": "function_call", "call_id": $0.id, "name": $0.name, "arguments": $0.arguments] }
            case .toolResults(let results):
                return results.map { ["type": "function_call_output", "call_id": $0.id, "output": $0.output] }
            }
        }
    }
    func makeAgentRequest(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool, accessToken: String,
                          images: Bool = false, webSearch: Bool = true) throws -> URLRequest {
        try makeAgentRequest(system: system, items: items, tools: tools, allowTools: allowTools, accessToken: accessToken,
                             allowed: HostedTools(images: images, web: webSearch)).0
    }
    /// The request, and which hosted tools it offers.
    func makeAgentRequest(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool, accessToken: String,
                          allowed: HostedTools) throws -> (URLRequest, HostedTools) {
        let functions = tools.filter { !$0.hosted }
        var offered: [[String: Any]] = functions.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters] }
        // Pictures are offered whenever the model may still act: every agent round
        // that allows tools, and a plain traced reply. The closing round answers in words.
        let drawing = allowed.images && (allowTools || functions.isEmpty)
        // Web search only in rounds that may still use tools, and only when the chat offers it.
        let searching = allowed.web && allowTools && tools.contains { $0.hosted }
        if drawing { offered.append(Self.imageTool) }
        if searching { offered.append(Self.webSearchTool) }
        var extra: [String: Any] = offered.isEmpty ? [:] : ["tools": offered, "tool_choice": allowTools || drawing ? "auto" : "none"]
        if !functions.isEmpty { extra["parallel_tool_calls"] = true }
        var instructions = system
        if drawing { instructions += "\n\n" + Self.drawingInstruction }
        if searching { instructions += "\n\n" + AgentTool.webSearchInstruction }
        return (try makeRequest(instructions: instructions, input: Self.input(items), extra: extra, accessToken: accessToken),
                HostedTools(images: drawing, web: searching))
    }
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        open({ try makeAgentRequest(system: system, items: items, tools: tools, allowTools: allowTools, accessToken: $0, allowed: $1) }) { data, state in
            try Self.decodeAgent(data, state: &state)
        }
    }
    static func decodeAgent(_ data: String) throws -> [AgentEvent] {
        var state = ResponseState()
        return try decodeAgent(data, state: &state)
    }
    static func decodeAgent(_ data: String, state: inout ResponseState) throws -> [AgentEvent] {
        let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
        let item = object?["item"] as? [String: Any]
        switch object?["type"] as? String {
        case "response.completed":
            var events: [AgentEvent] = []
            // Every page the answer cites stays reachable, even when the answer did not link it.
            if let footnote = WebSource.footnote(state.sources, after: state.text) { events.append(.text(footnote)) }
            if let usage = (object?["response"] as? [String: Any])?["usage"] as? [String: Any] {
                let reported = TokenUsage(input: usage["input_tokens"] as? Int, output: usage["output_tokens"] as? Int,
                                          cachedInput: (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
                                          reasoning: (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int)
                if !reported.isEmpty { events.append(.usage(reported)) }
            }
            return events + [.finished(truncated: false)]
        case "response.output_item.added" where item?["type"] as? String == "web_search_call":
            return [.webSearch(nil)]
        case "response.output_item.done" where item?["type"] as? String == "web_search_call":
            // Opening or reading inside a page belongs to the search already shown.
            let action = item?["action"] as? [String: Any]
            guard action == nil || action?["type"] as? String == "search" else { return [] }
            let query = action?["query"] as? String ?? (action?["queries"] as? [String])?.first ?? ""
            return [.webSearch(query.trimmingCharacters(in: .whitespacesAndNewlines))]
        case "response.output_item.done" where item?["type"] as? String == "function_call":
            guard let id = item?["call_id"] as? String, let name = item?["name"] as? String else { throw ChatGPTError.invalidResponse }
            let arguments = item?["arguments"] as? String ?? "{}"
            return [.toolCall(AgentToolCall(id: id, name: name, arguments: arguments.isEmpty ? "{}" : arguments))]
        case "response.output_item.done" where item?["type"] as? String == "message":
            for part in item?["content"] as? [[String: Any]] ?? [] {
                for annotation in part["annotations"] as? [[String: Any]] ?? [] { state.cite(annotation) }
            }
            return []
        case "response.output_text.annotation.added":
            if let annotation = object?["annotation"] as? [String: Any] { state.cite(annotation) }
            return []
        default:
            let events = try decode(data).map(\.agentEvent)
            for case .text(let text) in events { state.text += text }
            return events
        }
    }
}

extension ChatGPTSubscriptionProvider.ResponseState {
    /// Keeps a `url_citation` annotation's page, once.
    mutating func cite(_ annotation: [String: Any]) {
        guard annotation["type"] as? String == "url_citation", let source = WebSource(url: annotation["url"] as? String, title: annotation["title"] as? String),
              !sources.contains(where: { $0.url == source.url }) else { return }
        sources.append(source)
    }
}

/// A web page a reply cites.
struct WebSource: Equatable {
    let url: URL
    let title: String
    /// Only web links: a citation can never become an app or file link.
    init?(url: String?, title: String?) {
        guard let url = url.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        self.url = url
        let name = (title ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = name.isEmpty ? (url.host ?? url.absoluteString) : String(name.prefix(120))
    }
    /// Links to the cited pages the reply did not already link, in the reply's language,
    /// so web results always show where they came from.
    static func footnote(_ sources: [WebSource], after text: String) -> String? {
        let missing = sources.filter { !text.contains($0.url.absoluteString) }.prefix(8)
        guard !missing.isEmpty else { return nil }
        let chinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let lines = missing.map { source -> String in
            let label = source.title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            let link = source.url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            return "- [\(label)](\(link))"
        }
        return "\n\n" + (chinese ? "来源：" : "Sources:") + "\n" + lines.joined(separator: "\n")
    }
}
