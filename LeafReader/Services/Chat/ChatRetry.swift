import Foundation

/// Metadata for a rejected HTTP request. Keep the safe provider error for display,
/// and retain status / Retry-After without storing response bodies or credentials.
struct ChatRequestFailure: LocalizedError {
    let underlying: Error
    let status: Int
    let retryAfter: TimeInterval?
    init(_ underlying: Error, response: HTTPURLResponse, now: Date = Date()) {
        self.underlying = underlying; status = response.statusCode
        retryAfter = Self.delay(response.value(forHTTPHeaderField: "Retry-After"), now: now)
    }
    var errorDescription: String? { underlying.localizedDescription }
    static func delay(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
    static func source(_ error: Error) -> Error { (error as? Self)?.underlying ?? error }
}

@MainActor
struct ChatRetryPolicy {
    // Two extra requests for the entire answer, shared by all agent rounds and
    // fallback. Providers themselves do not retry, so budgets cannot multiply.
    var delays: [TimeInterval] = [0.6, 1.2]
    var maxDelay: TimeInterval = 8
    var maxTotalDelay: TimeInterval = 10
    var jitter: () -> Double = { Double.random(in: 0.8...1.2) }
    var sleep: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Recovery restarts one stateless model turn with the same input. All tools in
/// Leaf are local reads; only a successfully terminated turn can execute them.
/// This is not server-side stream resumption: a replacement answer can differ,
/// and an interrupted request may still consume the provider's allowance.
@MainActor
final class ChatRetryBudget {
    final class Attempt {
        var received = false
        var stage: String { received ? "stream" : "before_output" }
    }
    let policy: ChatRetryPolicy
    private(set) var retries = 0
    private var totalDelay: TimeInterval = 0
    init(policy: ChatRetryPolicy? = nil) { self.policy = policy ?? ChatRetryPolicy() }

    func run<T>(round: Int, recorder: AgentTraceRecorder? = nil, onRetry: () -> Void,
                operation: (Attempt) async throws -> T) async throws -> T {
        var number = 1
        while true {
            try Task.checkCancellation()
            let attempt = Attempt()
            recorder?.request(round: round, attempt: number, outcome: "started", stage: attempt.stage)
            do {
                let result = try await operation(attempt)
                try Task.checkCancellation()
                recorder?.request(round: round, attempt: number, outcome: "completed", stage: attempt.stage)
                return result
            } catch {
                let cancelled = Self.cancelled(error) || Task.isCancelled
                let retryable = !cancelled && Self.transient(error)
                let suggested = (error as? ChatRequestFailure)?.retryAfter
                let delay = retries < policy.delays.count ? suggested ?? policy.delays[retries] * policy.jitter() : nil
                // Do not shorten a valid provider delay to fit our UI budget.
                guard retryable, let delay, delay.isFinite, delay >= 0,
                      delay <= policy.maxDelay, totalDelay + delay <= policy.maxTotalDelay else {
                    recorder?.request(round: round, attempt: number,
                                      outcome: cancelled ? "stopped" : (retryable ? "exhausted" : "not_retryable"),
                                      stage: attempt.stage, error: error)
                    if cancelled { throw CancellationError() }
                    throw error
                }
                retries += 1; totalDelay += delay
                recorder?.request(round: round, attempt: number, outcome: "retry_scheduled", stage: attempt.stage, delay: delay, error: error)
                onRetry()
                do { try await policy.sleep(delay); try Task.checkCancellation() }
                catch {
                    recorder?.request(round: round, attempt: number, outcome: "stopped", stage: "backoff", error: error)
                    throw error
                }
                number += 1
            }
        }
    }

    static func cancelled(_ error: Error) -> Bool {
        let source = ChatRequestFailure.source(error)
        return source is CancellationError || (source as? URLError)?.code == .cancelled || (source as? ChatGPTError) == .cancelled
    }
    static func transient(_ error: Error) -> Bool {
        let source = ChatRequestFailure.source(error)
        // An allowance or account denial is not an ordinary HTTP rate limit.
        if let source = source as? ChatGPTError {
            if source == .network || source == .unavailable { return true }
            if source == .rejected, let status = (error as? ChatRequestFailure)?.status { return transient(status: status) }
            return false
        }
        if let status = (error as? ChatRequestFailure)?.status { return transient(status: status) }
        if let source = source as? ChatError {
            switch source {
            case .http(let status): return transient(status: status)
            case .interrupted: return true
            case .provider(let type): return ["overloaded_error", "rate_limit_error", "api_error"].contains(type)
            default: return false
            }
        }
        if let source = source as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .resourceUnavailable].contains(source.code)
        }
        return false
    }
    private static func transient(status: Int) -> Bool { [408, 409, 429].contains(status) || (500...599).contains(status) }
    static func errorCode(_ error: Error) -> String {
        let source = ChatRequestFailure.source(error)
        if let source = source as? URLError { return "NSURLErrorDomain:\(source.code.rawValue)" }
        if source is CancellationError { return "cancelled" }
        if let source = source as? ChatGPTError { return "ChatGPT:\(source)" }
        if let source = source as? ChatError {
            switch source {
            case .http(let status): return "HTTP:\(status)"
            case .provider(let type): return "provider:\(type)"
            case .interrupted: return "stream_interrupted"
            default: return "invalid_or_permanent_response"
            }
        }
        return "unclassified"
    }
}
