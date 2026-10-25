import Foundation

// The book search agent: the model calls on-device tools that read the book up
// to the reader's position, then answers. Providers translate these neutral
// items into their own tool-calling formats.

struct AgentToolCall: Equatable {
    let id: String
    let name: String
    let arguments: String
}

struct AgentToolResult: Equatable {
    let id: String
    let name: String
    let output: String
}

enum AgentItem: Equatable {
    case turn(ChatTurn)
    case toolCalls(text: String, calls: [AgentToolCall])
    case toolResults([AgentToolResult])
}

enum AgentEvent: Equatable { case text(String), toolCall(AgentToolCall), finished(truncated: Bool) }

protocol ToolChatProvider: ChatProvider {
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error>
}

struct AgentTool {
    let name: String
    let description: String
    let parameters: [String: Any]

    private static let terms: [String: Any] = [
        "type": "array", "minItems": 1, "maxItems": 6,
        "items": ["type": "string", "minLength": 1, "maxLength": 40],
        "description": "Alternative words to find, such as full name, short name, nickname, title or a distinctive related word. Case-insensitive exact match; use exact characters for Chinese."
    ]
    static let all: [AgentTool] = [
        AgentTool(name: "search_book",
                  description: "Search this book's text from the beginning up to the reader's current position. Returns ranked passages with section numbers, chapter labels and positions. Pass several alternative terms in one call.",
                  parameters: ["type": "object", "additionalProperties": false, "required": ["terms"],
                               "properties": ["terms": terms,
                                              "max_results": ["type": "integer", "minimum": 1, "maximum": 10, "description": "Number of passages to return (default 6)."]]]),
        AgentTool(name: "read_passage",
                  description: "Read continuous text from a section the reader has reached, starting at a character position. Use a section and position from search results; start a little before a match for context.",
                  parameters: ["type": "object", "additionalProperties": false, "required": ["section"],
                               "properties": ["section": ["type": "integer", "minimum": 0],
                                              "position": ["type": "integer", "minimum": 0, "description": "Character position in the section (default 0)."],
                                              "length": ["type": "integer", "minimum": 200, "maximum": 4000, "description": "Characters to read (default 2000)."]]]),
        AgentTool(name: "list_chapters",
                  description: "List chapter labels with their section numbers, only up to the reader's position.",
                  parameters: ["type": "object", "additionalProperties": false, "properties": [
                    "start": ["type": "integer", "minimum": 0, "description": "First section number (default 0)."],
                    "count": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Number of chapters (default 40)."]]]),
        AgentTool(name: "search_conversation",
                  description: "Search this book's earlier chat messages with the reader, including ones older than the recent turns you can see.",
                  parameters: ["type": "object", "additionalProperties": false, "required": ["terms"], "properties": ["terms": terms]])
    ]
}

/// The book a toolbox reads and the reader's position in it.
struct ReadingAgentBook {
    let index: BookTextIndex
    let boundary: BookTextBoundary
}

@MainActor
final class ReadingAgentToolbox {
    let book: ReadingAgentBook
    private let conversation: ([String]) -> String
    var activity: ((String) -> Void)?
    private(set) var steps: [String] = []
    var indexDeadline: TimeInterval = 20

    init(book: ReadingAgentBook, conversation: @escaping ([String]) -> String) {
        self.book = book; self.conversation = conversation
    }

    /// Runs one call and returns JSON for the model. Bad arguments become an
    /// error the model can correct; only cancellation propagates.
    func run(_ call: AgentToolCall) async throws -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "search_book": return try await search(arguments)
        case "read_passage": return try await read(arguments)
        case "list_chapters": return try await chapters(arguments)
        case "search_conversation":
            let terms = Self.terms(arguments)
            guard !terms.isEmpty else { return Self.json(["error": "Provide at least one term."]) }
            activity?("Searching earlier discussion…"); steps.append("searched earlier chat")
            return conversation(terms)
        default: return Self.json(["error": "Unknown tool \(call.name.prefix(40))."])
        }
    }

    static func terms(_ arguments: [String: Any]) -> [String] {
        var raw = arguments["terms"] as? [Any] ?? []
        // Accept a single query string from models that ignore the array schema.
        if raw.isEmpty, let query = arguments["query"] as? String { raw = query.components(separatedBy: CharacterSet(charactersIn: "|,，、;；\n")) }
        var seen = Set<String>(), terms: [String] = []
        for case let value as String in raw {
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...40).contains(term.count), seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == 6 { break }
        }
        return terms
    }
    private static func integer(_ value: Any?, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        let number = (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? fallback
        return min(range.upperBound, max(range.lowerBound, number))
    }
    private func prepare() async throws -> BookTextIndex.Coverage {
        try await book.index.prepare(through: book.boundary, deadline: Date().addingTimeInterval(indexDeadline)) { [weak self] done, total in
            if total > 24 { self?.activity?("Reading the book… \(done)/\(total)") }
        }
    }
    private func search(_ arguments: [String: Any]) async throws -> String {
        let terms = Self.terms(arguments)
        guard !terms.isEmpty else { return Self.json(["error": "Provide at least one term in terms."]) }
        let quoted = terms.map { "“\($0)”" }.joined(separator: ", ")
        activity?("Searching the book for \(quoted)…")
        let coverage = try await prepare()
        let limit = Self.integer(arguments["max_results"], default: 6, in: 1...10)
        let (hits, counts) = book.index.search(terms, within: book.boundary, limit: limit)
        steps.append("searched \(quoted) (\(hits.count))")
        var body: [String: Any] = [
            "results": hits.map { ["section": $0.section, "chapter": $0.chapter, "position": $0.position, "text": $0.text] },
            "term_counts": counts,
            "searched": ["sections": coverage.indexed, "sections_reached": coverage.eligible, "complete": coverage.complete],
            "note": "Only text up to the reader's current position is searched."
        ]
        if !coverage.complete {
            body["note"] = "Only text up to the reader's position is searched. Some reached sections are not prepared yet; searching again continues preparing them."
        }
        return Self.json(body)
    }
    private func read(_ arguments: [String: Any]) async throws -> String {
        guard arguments["section"] != nil else { return Self.json(["error": "Provide section."]) }
        let section = Self.integer(arguments["section"], default: 0, in: 0...Int(Int32.max))
        guard section <= book.boundary.section else {
            return Self.json(["error": "That section is after the reader's position and cannot be read."])
        }
        let position = Self.integer(arguments["position"], default: 0, in: 0...Int(Int32.max))
        let length = Self.integer(arguments["length"], default: 2000, in: 200...4000)
        activity?("Reading \(book.index.label(section))…")
        try await book.index.prepareSection(section)
        guard let passage = book.index.read(section: section, position: position, length: length, within: book.boundary) else {
            return Self.json(["error": "That section could not be read."])
        }
        steps.append("read \(book.index.label(section))")
        return Self.json(["section": section, "chapter": book.index.label(section), "position": min(position, passage.end),
                          "end": passage.end, "has_more_before_reader_position": passage.more, "text": passage.text])
    }
    private func chapters(_ arguments: [String: Any]) async throws -> String {
        activity?("Listing chapters…")
        let coverage = try await prepare()
        let start = Self.integer(arguments["start"], default: 0, in: 0...Int(Int32.max))
        let count = Self.integer(arguments["count"], default: 40, in: 1...100)
        var items: [[String: Any]] = [], previous = ""
        for section in start...max(start, book.boundary.section) where section <= book.boundary.section {
            let label = book.index.label(section)
            guard label != previous else { continue }
            previous = label; items.append(["section": section, "chapter": label])
            if items.count == count { break }
        }
        steps.append("listed chapters")
        return Self.json(["chapters": items, "reader_section": book.boundary.section, "sections_prepared": coverage.indexed])
    }
    nonisolated static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"error\":\"Result could not be encoded.\"}" }
        return text
    }
}

enum ReadingAgentRunner {
    static let maxRounds = 6
    static let maxCalls = 8
    struct Outcome { let truncated: Bool }

    /// Runs tool rounds, then streams the final answer. Text from a round that
    /// ends in tool calls is withdrawn: it is preamble, not the answer.
    @MainActor
    static func run(provider: any ToolChatProvider, request: ChatRequest, toolbox: ReadingAgentToolbox,
                    onText: (String) -> Void, onWithdraw: () -> Void) async throws -> Outcome {
        var items = request.turns.map(AgentItem.turn)
        var used = 0
        for round in 0..<maxRounds {
            let allowTools = used < maxCalls && round < maxRounds - 1
            var calls: [AgentToolCall] = [], text = "", truncated = false, finished = false, received = false
            do {
                for try await event in provider.streamAgent(system: request.system, items: items, tools: AgentTool.all, allowTools: allowTools) {
                    try Task.checkCancellation()
                    received = true
                    switch event {
                    case .text(let delta): text += delta; onText(delta)
                    case .toolCall(let call): calls.append(call)
                    case .finished(let value): truncated = value; finished = true
                    }
                }
            } catch {
                if round == 0, !received, rejectsTools(error) { throw ReadingAgentError.toolsUnsupported }
                throw error
            }
            guard finished else { throw ChatError.interrupted }
            if calls.isEmpty {
                guard !text.isEmpty else { throw ChatError.emptyResponse }
                return Outcome(truncated: truncated)
            }
            if !text.isEmpty { onWithdraw() }
            var results: [AgentToolResult] = []
            for call in calls {
                let output = used < maxCalls ? try await toolbox.run(call)
                    : ReadingAgentToolbox.json(["error": "Tool limit reached. Answer with what you have found."])
                used += 1
                results.append(AgentToolResult(id: call.id, name: call.name, output: String(output.prefix(12000))))
            }
            items.append(.toolCalls(text: text, calls: calls))
            items.append(.toolResults(results))
        }
        throw ChatError.emptyResponse
    }

    static func rejectsTools(_ error: Error) -> Bool {
        if case ChatError.http(let status) = error { return status == 400 || status == 422 }
        if case ChatError.provider(let type) = error { return type == "invalid_request_error" }
        // Subscription errors arrive mapped; an unsupported capability or a plain
        // rejection of the first tool request is retried without tools.
        if let error = error as? ChatGPTError { return error == .unsupported || error == .rejected }
        return false
    }
}

enum ReadingAgentError: Error { case toolsUnsupported }
