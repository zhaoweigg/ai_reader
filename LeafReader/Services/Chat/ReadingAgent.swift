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

enum AgentEvent: Equatable { case text(String), toolCall(AgentToolCall), usage(TokenUsage), imageStarted, image(Data), imageToolRefused(String), finished(truncated: Bool) }

extension ChatEvent {
    var agentEvent: AgentEvent {
        switch self {
        case .text(let text): return .text(text)
        case .imageStarted: return .imageStarted
        case .image(let data): return .image(data)
        case .imageToolRefused(let reason): return .imageToolRefused(reason)
        case .finished(let value): return .finished(truncated: value)
        }
    }
}

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
    /// Tools that read the app screen a chat was opened from, outside any book.
    static let view: [AgentTool] = [
        AgentTool(name: "get_current_view",
                  description: "Read what the reader's screen shows right now: which list it is and its items in on-screen order, ranked from 1 at the top. Call it whenever the question refers to anything on screen, such as \"the top 5\", \"these\" or \"the third one\", even if you read it earlier: the screen may have changed.",
                  parameters: ["type": "object", "additionalProperties": false, "properties": [
                    "max_items": ["type": "integer", "minimum": 1, "maximum": ChatScreen.itemLimit, "description": "Number of items to return from the top (default 30)."]]]),
        AgentTool(name: "get_item_details",
                  description: "More about one item on the current screen, by its rank from get_current_view: a catalog book's details and description when the catalog has one, or a saved passage's full text and note.",
                  parameters: ["type": "object", "additionalProperties": false, "required": ["rank"], "properties": [
                    "rank": ["type": "integer", "minimum": 1, "maximum": 500]]])
    ]
}

/// One of the app's screens, read when a view tool runs so a reply always
/// describes the screen as it is now, not as it was when the question was sent.
struct ChatScreen {
    static let itemLimit = 100
    /// The screen's name as the reader sees it, such as “Discover”.
    let name: String
    /// The screen's list, top first; passages and notes only when passage sharing is on.
    let view: @MainActor (_ limit: Int, _ sharePassages: Bool) -> [String: Any]
    /// Details for one ranked item, or nil when that rank is not on screen.
    let details: @MainActor (_ rank: Int, _ sharePassages: Bool) async throws -> [String: Any]?
}

/// The book a toolbox reads and the reader's position in it.
struct ReadingAgentBook {
    let index: BookTextIndex
    let boundary: BookTextBoundary
}

@MainActor
final class ReadingAgentToolbox {
    let book: ReadingAgentBook?
    let screen: ChatScreen?
    /// The rest of the app, read by the app-wide tools.
    let app: AppChatTools?
    /// Whether passages and notes from the screen may leave the device.
    var sharePassages = true
    private let conversation: ([String]) -> String
    var activity: ((String) -> Void)?
    private(set) var steps: [String] = []
    var limits = AgentLimits()
    var indexDeadline: TimeInterval { TimeInterval(limits.preparationSeconds) }

    init(book: ReadingAgentBook?, screen: ChatScreen? = nil, app: ChatAppData? = nil, conversation: @escaping ([String]) -> String) {
        self.book = book; self.screen = screen; self.app = app.map(AppChatTools.init); self.conversation = conversation
    }
    /// The tools this chat can use: the book's when one is open, the screen's when
    /// the chat was opened from one, the rest of the app's, and earlier discussion always.
    var tools: [AgentTool] {
        let reading = book == nil ? AgentTool.all.filter { $0.name == "search_conversation" } : AgentTool.all
        let everywhere = app == nil ? [] : AppChatTools.tools(sharePassages: sharePassages)
        return (reading + (screen == nil ? [] : AgentTool.view) + everywhere).filter { !limits.disabledTools.contains($0.name) }
    }

    /// Runs one call and returns JSON for the model. Bad arguments become an
    /// error the model can correct; only cancellation propagates.
    func run(_ call: AgentToolCall) async throws -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        if limits.disabledTools.contains(call.name) { return Self.json(["error": "\(call.name) is turned off in AI settings."]) }
        switch call.name {
        case "get_current_view": return currentView(arguments)
        case "get_item_details": return try await itemDetails(arguments)
        case "search_book": return try await search(arguments)
        case "read_passage": return try await read(arguments)
        case "list_chapters": return try await chapters(arguments)
        case "search_conversation":
            let terms = Self.terms(arguments)
            guard !terms.isEmpty else { return Self.json(["error": "Provide at least one term."]) }
            activity?("Searching earlier discussion…"); steps.append("searched earlier chat")
            return conversation(terms)
        default:
            if let app, let result = try await app.run(call.name, arguments, sharePassages: sharePassages, activity: activity) {
                steps.append(result.step); return result.output
            }
            return Self.json(["error": "Unknown tool \(call.name.prefix(40))."])
        }
    }

    /// A selection short enough to be a name or term, without sentence punctuation.
    nonisolated static func nameLike(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”「」『』\"'，,：:、")))
        let pronouns: Set<String> = ["he", "she", "it", "they", "him", "her", "them", "this", "that", "他", "她", "它", "他们", "她们", "这个", "那个"]
        guard (2...40).contains(value.count), !pronouns.contains(value.lowercased()),
              !value.contains(where: { "。！？!?\n".contains($0) }) else { return nil }
        return value
    }
    /// The name a reminder question asks about, which Leaf searches before the model
    /// answers. `previous` is the subject of the reader's last question, kept for
    /// follow-ups such as “再说一遍是谁”.
    nonisolated static func followUpTerm(question: String, context: ReadingChatContext, previous: String? = nil) -> String? {
        let recall = question.range(of: "回忆|忘|角色|人物|是谁|谁是|前情|之前|以前|身份|来历|关系|remind|remember|forgot|character|relationship|backstory|who (?:is|was)|earlier|recap", options: [.regularExpression, .caseInsensitive]) != nil
        guard recall else { return nil }
        let selected = context.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”「」『』\"'，,：:、")))
        let generic: Set<String> = ["a", "an", "the", "he", "she", "it", "they", "him", "her", "them", "this", "that", "他", "她", "它", "他们", "她们", "这个", "那个",
                                    "这人", "那人", "此人", "这个人", "那个人", "这位", "那位", "对方", "他是", "她是"]
        if context.source == "selection", (2...40).contains(selected.count), !generic.contains(selected.lowercased()), !selected.contains(where: { "。！？!?\n".contains($0) }) { return selected }
        for pattern in ["[“「『\"]([^”」』\"]{2,40})[”」』\"]", "([\\p{Han}]{2,8})(?:是谁|的身份)", "(?i:who (?:is|was)) ([A-Z][a-z]+(?: [A-Z][a-z]+)?)"] {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)),
                  let range = Range(match.range(at: 1), in: question) else { continue }
            var candidate = String(question[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Words before “是谁” are often phrasing, not a name: “再说一遍是谁”, “所以他到底是谁”.
            for filler in ["再说一遍", "再说一次", "再讲一遍", "再讲一次", "说一下", "请问", "所以", "那么", "刚才", "到底", "究竟", "这个", "那个", "他", "她", "它"] {
                while candidate.hasPrefix(filler) { candidate.removeFirst(filler.count) }
                while candidate.hasSuffix(filler) { candidate.removeLast(filler.count) }
            }
            if candidate.count >= 2, !generic.contains(candidate.lowercased()) { return candidate }
        }
        return previous
    }
    /// Leaf's own first search, for a highlighted name or a follow-up's subject,
    /// presented to the model as an earlier tool call it can build on.
    func seed(_ selection: String?, followUp: String?, recorder: AgentTraceRecorder? = nil) async throws -> [AgentItem] {
        guard book != nil, limits.seedSearch, !limits.disabledTools.contains("search_book"),
              let term = selection.flatMap(Self.nameLike) ?? followUp.flatMap(Self.nameLike) else { return [] }
        let call = AgentToolCall(id: "call_leaf_seed", name: "search_book", arguments: Self.json(["terms": [term]]))
        let output = String(try await run(call).prefix(limits.toolResultLimit))
        recorder?.tool(call, output: output, seed: true)
        return [.toolCalls(text: "", calls: [call]), .toolResults([AgentToolResult(id: call.id, name: call.name, output: output)])]
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
    private func currentView(_ arguments: [String: Any]) -> String {
        guard let screen else { return Self.json(["error": "This chat was not opened from a screen with a list."]) }
        activity?("Looking at \(screen.name)…")
        let limit = Self.integer(arguments["max_items"], default: 30, in: 1...ChatScreen.itemLimit)
        let view = screen.view(limit, sharePassages)
        steps.append("read the \(screen.name) screen (\((view["items"] as? [Any])?.count ?? 0))")
        return Self.json(view)
    }
    private func itemDetails(_ arguments: [String: Any]) async throws -> String {
        guard let screen else { return Self.json(["error": "This chat was not opened from a screen with a list."]) }
        guard arguments["rank"] != nil else { return Self.json(["error": "Provide rank from get_current_view."]) }
        let rank = Self.integer(arguments["rank"], default: 1, in: 1...Int(Int32.max))
        activity?("Looking at item \(rank) on \(screen.name)…")
        do {
            guard let details = try await screen.details(rank, sharePassages) else {
                return Self.json(["error": "Nothing is at rank \(rank) on the screen now. Call get_current_view for the current list."])
            }
            steps.append("details for #\(rank)")
            return Self.json(details)
        } catch {
            // A list that changed under the call is reported, not a stopped reply.
            try Task.checkCancellation()
            steps.append("details for #\(rank) unavailable")
            return Self.json(["rank": rank, "error": "Details could not be loaded (\(String(error.localizedDescription.prefix(200)))). Answer from the listing in get_current_view."])
        }
    }
    private func prepare(_ book: ReadingAgentBook) async throws -> BookTextIndex.Coverage {
        try await book.index.prepare(through: book.boundary, deadline: Date().addingTimeInterval(indexDeadline)) { [weak self] done, total in
            if total > 24 { self?.activity?("Reading the book… \(done)/\(total)") }
        }
    }
    private func search(_ arguments: [String: Any]) async throws -> String {
        guard let book else { return Self.noBook }
        let terms = Self.terms(arguments)
        guard !terms.isEmpty else { return Self.json(["error": "Provide at least one term in terms."]) }
        let quoted = terms.map { "“\($0)”" }.joined(separator: ", ")
        activity?("Searching the book for \(quoted)…")
        let coverage = try await prepare(book)
        let limit = Self.integer(arguments["max_results"], default: limits.resultsPerSearch, in: AgentLimits.resultRange)
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
        guard let book else { return Self.noBook }
        guard arguments["section"] != nil else { return Self.json(["error": "Provide section."]) }
        let section = Self.integer(arguments["section"], default: 0, in: 0...Int(Int32.max))
        guard section <= book.boundary.section else {
            return Self.json(["error": "That section is after the reader's position and cannot be read."])
        }
        let position = Self.integer(arguments["position"], default: 0, in: 0...Int(Int32.max))
        let length = Self.integer(arguments["length"], default: limits.passageLength, in: 200...AgentLimits.passageRange.upperBound)
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
        guard let book else { return Self.noBook }
        activity?("Listing chapters…")
        let coverage = try await prepare(book)
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
    private static let noBook = json(["error": "No book is open in this chat."])
    nonisolated static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"error\":\"Result could not be encoded.\"}" }
        return text
    }
}

enum ReadingAgentRunner {
    struct Outcome { let truncated: Bool }

    /// Runs tool rounds, then streams the final answer. Text from a round that
    /// ends in tool calls is withdrawn: it is preamble, not the answer.
    @MainActor
    static func run(provider: any ToolChatProvider, request: ChatRequest, toolbox: ReadingAgentToolbox, seed: [AgentItem] = [],
                    limits: AgentLimits = AgentLimits(), recorder: AgentTraceRecorder? = nil, recovery: ChatRetryBudget? = nil,
                    onRetry: @escaping () -> Void = {}, onText: (String) -> Void, onWithdraw: () -> Void,
                    onImageStarted: () -> Void = {}, onImage: (Data) -> Void = { _ in },
                    onImageRefused: (String) -> Void = { _ in }) async throws -> Outcome {
        let recovery = recovery ?? ChatRetryBudget()
        var items = request.turns.map(AgentItem.turn) + seed
        var used = 0
        let tools = toolbox.tools
        for round in 0..<limits.maxRounds {
            let allowTools = !tools.isEmpty && used < limits.maxToolCalls && round < limits.maxRounds - 1
            let (calls, text, images, truncated, usage) = try await recovery.run(round: round + 1, recorder: recorder, onRetry: {
                onWithdraw(); onRetry()
            }) { attempt in
                var calls: [AgentToolCall] = [], text = "", images = 0, truncated = false, finished = false
                var usage: TokenUsage?
                do {
                    // This transcript is unchanged throughout recovery of this round.
                    // Discard uncommitted text / calls / usage after any failed attempt.
                    for try await event in provider.streamAgent(system: request.system, items: items, tools: tools, allowTools: allowTools) {
                        try Task.checkCancellation()
                        attempt.received = true
                        switch event {
                        case .text(let delta): text += delta; onText(delta)
                        case .toolCall(let call): calls.append(call)
                        case .usage(let value): usage = (usage ?? TokenUsage()) + value
                        case .imageStarted: onImageStarted()
                        case .image(let data): images += 1; onImage(data)
                        case .imageToolRefused(let reason): onImageRefused(reason)
                        case .finished(let value): truncated = value; finished = true
                        }
                        if finished { break }
                    }
                } catch {
                    if round == 0, !attempt.received, rejectsTools(error) { throw ReadingAgentError.toolsUnsupported }
                    throw error
                }
                guard finished else { throw ChatError.interrupted }
                guard !text.isEmpty || !calls.isEmpty || images > 0 else { throw ChatError.emptyResponse }
                return (calls, text, images, truncated, usage)
            }
            recorder?.round(round + 1, text: text, calls: calls, usage: usage, final: calls.isEmpty)
            if calls.isEmpty {
                // A picture on its own is a complete answer.
                guard !text.isEmpty || images > 0 else { throw ChatError.emptyResponse }
                return Outcome(truncated: truncated)
            }
            if !text.isEmpty { onWithdraw() }
            var results: [AgentToolResult] = []
            for call in calls {
                try Task.checkCancellation()
                let output = used < limits.maxToolCalls ? try await toolbox.run(call)
                    : ReadingAgentToolbox.json(["error": "Tool limit reached. Answer with what you have found."])
                used += 1
                let bounded = String(output.prefix(limits.toolResultLimit))
                recorder?.tool(call, output: bounded, seed: false)
                results.append(AgentToolResult(id: call.id, name: call.name, output: bounded))
            }
            items.append(.toolCalls(text: text, calls: calls))
            items.append(.toolResults(results))
        }
        throw ChatError.emptyResponse
    }

    static func rejectsTools(_ error: Error) -> Bool {
        let error = ChatRequestFailure.source(error)
        if case ChatError.http(let status) = error { return status == 400 || status == 422 }
        if case ChatError.provider(let type) = error { return type == "invalid_request_error" }
        // Subscription errors arrive mapped; an unsupported capability or a plain
        // rejection of the first tool request is retried without tools.
        if let error = error as? ChatGPTError { return error == .unsupported || error == .rejected }
        return false
    }
}

enum ReadingAgentError: Error { case toolsUnsupported }
