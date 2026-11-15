import Foundation

/// Token counts a provider reported for one model request; nil fields were not reported.
struct TokenUsage: Codable, Equatable {
    var input: Int?
    var output: Int?
    var cachedInput: Int?
    var reasoning: Int?
    var isEmpty: Bool { input == nil && output == nil }
    static func + (lhs: Self, rhs: Self) -> Self {
        func add(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        return Self(input: add(lhs.input, rhs.input), output: add(lhs.output, rhs.output),
                    cachedInput: add(lhs.cachedInput, rhs.cachedInput), reasoning: add(lhs.reasoning, rhs.reasoning))
    }
}

/// Limits for the book search agent, adjustable in AI settings. Defaults match
/// the values the agent shipped with.
struct AgentLimits: Codable, Equatable {
    var maxToolCalls = 8
    var maxRounds = 6
    var resultsPerSearch = 6
    var passageLength = 2000
    var toolResultLimit = 12000
    var preparationSeconds = 20
    var seedSearch = true
    var disabledTools: Set<String> = []

    static let toolCallRange = 1...16
    static let roundRange = 2...10
    static let resultRange = 1...10
    static let passageRange = 500...4000
    static let toolResultRange = 4000...20000
    static let preparationRange = 5...60

    init() {}
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        func value(_ key: CodingKeys, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            min(range.upperBound, max(range.lowerBound, (try? container.decodeIfPresent(Int.self, forKey: key)) ?? fallback))
        }
        maxToolCalls = value(.maxToolCalls, defaults.maxToolCalls, Self.toolCallRange)
        maxRounds = value(.maxRounds, defaults.maxRounds, Self.roundRange)
        resultsPerSearch = value(.resultsPerSearch, defaults.resultsPerSearch, Self.resultRange)
        passageLength = value(.passageLength, defaults.passageLength, Self.passageRange)
        toolResultLimit = value(.toolResultLimit, defaults.toolResultLimit, Self.toolResultRange)
        preparationSeconds = value(.preparationSeconds, defaults.preparationSeconds, Self.preparationRange)
        seedSearch = (try? container.decodeIfPresent(Bool.self, forKey: .seedSearch)) ?? true
        disabledTools = (try? container.decodeIfPresent(Set<String>.self, forKey: .disabledTools)) ?? []
    }
    var tools: [AgentTool] { AgentTool.all.filter { !disabledTools.contains($0.name) } }
    var summary: String { "\(maxToolCalls) calls / \(maxRounds) rounds / \(resultsPerSearch) results / \(passageLength)-char passages" }
}

/// One answer's full record for the troubleshooting view: what was sent, every
/// model round and tool call with timings and token usage, and the outcome.
struct AgentTrace: Codable, Identifiable, Equatable {
    enum Outcome: String, Codable { case complete, truncated, failed, stopped }
    struct Step: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case context, seed, round, tool, answer, lookup, error, request }
        var id = UUID()
        let kind: Kind
        var title: String
        var detail: String
        var payload: String = ""
        var payloadTitle: String = ""
        var seconds: Double = 0
        var usage: TokenUsage? = nil
        var withdrawn: String = ""
    }
    var id = UUID()
    var date = Date()
    /// "agent" for a reply that could use tools and "plain" for one sent without
    /// them; traces saved before pre-fetched evidence was retired may say "evidence".
    var harness = "agent"
    var provider: String
    var model: String
    var bookTitle: String
    var chapter: String
    var question: String
    var selection: String?
    var limits: AgentLimits?
    var steps: [Step] = []
    var outcome: Outcome = .complete
    var error: String?
    var totalSeconds: Double = 0
    var charactersSent = 0
    var rounds: Int { steps.filter { $0.kind == .round || $0.kind == .answer }.count }
    var toolCalls: Int { steps.filter { $0.kind == .tool || $0.kind == .seed }.count }
    var modelToolCalls: Int { steps.filter { $0.kind == .tool }.count }
    var usage: TokenUsage { steps.compactMap(\.usage).reduce(TokenUsage(), +) }
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Builds a trace while an answer runs. Times are measured from creation.
@MainActor
final class AgentTraceRecorder {
    private(set) var trace: AgentTrace
    private let start = Date()
    private var lap = Date()
    init(trace: AgentTrace) { self.trace = trace }

    func context(system: String, turns: [ChatTurn], detail: String) {
        let sent = system.count + turns.reduce(0) { $0 + $1.content.count }
        trace.charactersSent += sent
        let payload = "SYSTEM\n\(system)\n\n" + turns.map { "\($0.role.uppercased())\n\($0.content)" }.joined(separator: "\n\n")
        append(.init(kind: .context, title: "Request context", detail: detail + " · \(sent.formatted()) chars", payload: payload, payloadTitle: "System prompt and messages"))
    }
    /// The reply went out without tools: the provider or model has none.
    func withoutTools() { trace.harness = "plain"; trace.limits = nil }
    func tool(_ call: AgentToolCall, output: String, seed: Bool) {
        let summary = Self.summary(of: output, name: call.name)
        append(.init(kind: seed ? .seed : .tool, title: seed ? "Leaf search (seed) · \(call.name)" : "Tool result · \(call.name)",
                     detail: "\(call.arguments) → \(summary)", payload: output, payloadTitle: "Result JSON", seconds: elapsed()))
        trace.charactersSent += output.count
    }
    func round(_ number: Int, text: String, calls: [AgentToolCall], usage: TokenUsage?, final: Bool) {
        if final {
            append(.init(kind: .answer, title: "Answer (round \(number))", detail: "\(text.count.formatted()) chars",
                         payload: text, payloadTitle: "Answer", seconds: elapsed(), usage: usage))
        } else {
            append(.init(kind: .round, title: "Model round \(number)", detail: calls.map { "\($0.name) \($0.arguments)" }.joined(separator: "\n"),
                         seconds: elapsed(), usage: usage, withdrawn: text))
        }
    }
    func request(round: Int, attempt: Int, outcome: String, stage: String, delay: TimeInterval? = nil, error: Error? = nil) {
        var detail = "\(outcome) · stage \(stage)"
        if let delay { detail += String(format: " · delay %.2f s", delay) }
        if let error {
            detail += " · " + ChatRetryBudget.errorCode(error)
            if let response = error as? ChatRequestFailure { detail += " · HTTP \(response.status)" }
        }
        append(.init(kind: .request, title: "Request round \(round), attempt \(attempt)", detail: detail, seconds: elapsed()))
    }
    /// The request went out without the image tool because the model or plan refused it.
    func imageToolRefused(_ reason: String) {
        guard !trace.steps.contains(where: { $0.title == "Image tool refused" }) else { return }
        append(.init(kind: .request, title: "Image tool refused", detail: reason + " · asked again without it", seconds: 0))
    }
    func failed(_ message: String, outcome: AgentTrace.Outcome) {
        trace.outcome = outcome; trace.error = message
        append(.init(kind: .error, title: outcome == .stopped ? "Stopped" : "Failed", detail: message, seconds: elapsed()))
    }
    func finish(outcome: AgentTrace.Outcome) -> AgentTrace {
        if trace.outcome == .complete { trace.outcome = outcome }
        trace.totalSeconds = Date().timeIntervalSince(start)
        return trace
    }
    private func append(_ step: AgentTrace.Step) { trace.steps.append(step) }
    private func elapsed() -> Double {
        defer { lap = Date() }
        return Date().timeIntervalSince(lap)
    }
    private static func summary(of output: String, name: String) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] else { return "\(output.count.formatted()) chars" }
        if let error = object["error"] as? String { return "error: \(error)" }
        if let results = object["results"] as? [Any] {
            let counts = (object["term_counts"] as? [String: Int])?.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") ?? ""
            return "\(results.count) results" + (counts.isEmpty ? "" : " · counts \(counts)") + " · \(output.count.formatted()) chars"
        }
        if let chapter = object["chapter"] as? String, let text = object["text"] as? String { return "\(chapter) · \(text.count.formatted()) chars" }
        if let chapters = object["chapters"] as? [Any] { return "\(chapters.count) chapters" }
        if let matches = object["matches"] as? [Any] { return "\(matches.count) earlier exchanges" }
        return "\(output.count.formatted()) chars"
    }
}

/// The last traces, kept only on this device.
@MainActor
final class AgentTraceStore: ObservableObject {
    @Published private(set) var traces: [AgentTrace] = []
    static let limit = 50
    private let file: URL?
    init(directory: URL?) {
        file = directory?.appendingPathComponent("agent-traces.json")
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            traces = (try? decoder.decode([AgentTrace].self, from: data)) ?? []
        }
    }
    func add(_ trace: AgentTrace) { traces.insert(trace, at: 0); traces = Array(traces.prefix(Self.limit)); save() }
    func remove(_ id: UUID) { traces.removeAll { $0.id == id }; save() }
    func clear() { traces = []; save() }
    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try? encoder.encode(traces).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
