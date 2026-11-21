import Foundation
import UIKit

#if DEBUG
// Explicit UI-test injection only; shipping builds never substitute sample replies.
struct UITestChatProvider: ChatProvider {
    var slow = false
    /// A landscape test picture: sky, sea and a sun, as JPEG like the hosted tool returns.
    static let samplePicture: Data = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).jpegData(withCompressionQuality: 0.85) { context in
        UIColor(red: 0.93, green: 0.76, blue: 0.55, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
        UIColor(red: 0.18, green: 0.36, blue: 0.47, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 240, width: 640, height: 160))
        UIColor(red: 0.98, green: 0.55, blue: 0.27, alpha: 1).setFill(); context.cgContext.fillEllipse(in: CGRect(x: 270, y: 170, width: 100, height: 100))
    }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if UITesting.flag(.chatScrollPerf) {
                        continuation.yield(.text((1...28).map {
                            "### 线索 \($0)\n\n白虎说完又看向几人。**人物的猜测**需要和已经发生的事情分开来看。读到这里，可以结合前文回顾这个角色的身份，观察他的话和行动是否一致。\n\n- 当前的解释还不是最终结论。\n- 保留阅读位置，继续寻找书中的证据。"
                        }.joined(separator: "\n\n")))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag(.chatScrollStream) {
                        // A real model takes seconds before its first token; that pause is
                        // when the question and its placeholder have the history to themselves.
                        if UITesting.flag(.chatSlowStart) { try await Task.sleep(for: .seconds(3)) }
                        continuation.yield(.text((1...10).map { "Paragraph \($0): Read this explanation at your own pace, without jumping to the newest words." }.joined(separator: "\n\n")))
                        continuation.yield(.text("\n\nUpdate 1:"))
                        for index in 1...600 {
                            try await Task.sleep(for: .milliseconds(500))
                            continuation.yield(.text(" next \(index)."))
                        }
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag(.chatFollow) {
                        // A placeholder first, then small Chinese chunks that wrap and break paragraphs.
                        try await Task.sleep(for: .milliseconds(700))
                        let reply = (1...3).map { "第\($0)段：有，是一场限时十分钟的体力型淘汰游戏，发生在第三十七到四十四章。场地四面高墙，中央有一块圆形铁板；大铁门打开后，一只体型异常巨大的黑熊进场，门随即关闭。" }.joined(separator: "\n\n")
                        var index = reply.startIndex
                        while index < reply.endIndex {
                            let next = reply.index(index, offsetBy: 4, limitedBy: reply.endIndex) ?? reply.endIndex
                            continuation.yield(.text(String(reply[index..<next])))
                            index = next
                            try await Task.sleep(for: .milliseconds(60))
                        }
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag(.chatImage) {
                        // The hosted image tool's order: drawing starts, the picture
                        // arrives whole, then the model's words.
                        continuation.yield(.imageStarted)
                        try await Task.sleep(for: .milliseconds(3000))
                        continuation.yield(.image(Self.samplePicture))
                        continuation.yield(.text("Here is the harbor "))
                        try await Task.sleep(for: .milliseconds(150))
                        continuation.yield(.text("at dawn, as the chapter describes it."))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag(.chatMarkdown) {
                        continuation.yield(.text("## 人物\n\n这是**李"))
                        try await Task.sleep(for: .milliseconds(250))
                        continuation.yield(.text("香玲**，云瑶的队友。**要点：**模型常把结尾标记贴在标点上。\n\n- 第一条\n- 第二条\n\n```swift\nlet value = 1\n```\n\n尾句。"))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag(.chatContextProbe) {
                        let content = request.turns.last?.content ?? ""
                        let body = content.components(separatedBy: "reading_context (source material):\n").last?.components(separatedBy: "\n\nReader question:\n").first ?? ""
                        let context = body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                        let valid = context["source"] as? String == "selection" && !(context["text"] as? String ?? "").isEmpty &&
                            (!(context["preceding_text"] as? String ?? "").isEmpty || !(context["following_text"] as? String ?? "").isEmpty) &&
                            context["approximate_book_progress_percent"] != nil && context["spoiler_boundary"] != nil &&
                            !content.contains("epubcfi(") &&
                            (request.system.contains("Previous assistant answers may be wrong") || request.system.contains("Treat previous assistant answers as fallible"))
                        continuation.yield(.text(valid ? "Reading context verified: focused quote, nearby passage, reading progress and spoiler boundary." : "Reading context verification failed: \(body)"))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    try await Task.sleep(for: .milliseconds(150))
                    continuation.yield(.text("Test reply: "))
                    try await Task.sleep(for: .milliseconds(slow ? 30000 : 150))
                    continuation.yield(.text("Consider what the passage states and what the character assumes."))
                    continuation.yield(.finished(truncated: false)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// Scripted agent: searches the words after “about” in the question, then
// answers from the real on-device tool result.
extension UITestChatProvider: ToolChatProvider {
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Every chat offers tools now. Only cases that script the agent call them;
                    // the rest, and a reply without tools, behave like the plain chat reply.
                    if tools.isEmpty || !UITesting.flag(.chatAgent) {
                        let turns = items.compactMap { item -> ChatTurn? in if case .turn(let turn) = item { return turn }; return nil }
                        for try await event in stream(ChatRequest(system: system, turns: turns)) {
                            switch event {
                            case .text(let text): continuation.yield(.text(text))
                            case .imageStarted: continuation.yield(.imageStarted)
                            case .image(let data): continuation.yield(.image(data))
                            case .imageToolRefused(let reason): continuation.yield(.imageToolRefused(reason))
                            case .finished(let value):
                                continuation.yield(.usage(TokenUsage(input: 900, output: 24)))
                                continuation.yield(.finished(truncated: value))
                            }
                        }
                        continuation.finish(); return
                    }
                    try await Task.sleep(for: .milliseconds(150))
                    // Web search: the provider searches by itself and cites a page.
                    let question = items.compactMap { item -> String? in if case .turn(let turn) = item, turn.role == "user" { return turn.content }; return nil }.last ?? ""
                    if allowTools, tools.contains(where: \.hosted), question.localizedCaseInsensitiveContains("search the web") {
                        continuation.yield(.webSearch(nil))
                        try await Task.sleep(for: .milliseconds(1500))
                        continuation.yield(.webSearch("Leaf reader app"))
                        continuation.yield(.text("Web reply: Leaf is a quiet reading app. [Leaf on the web](https://example.com/leaf)"))
                        continuation.yield(.usage(TokenUsage(input: 1000, output: 20)))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    continuation.yield(.usage(TokenUsage(input: 1200 + items.count * 300, output: 30, cachedInput: 800)))
                    let results = items.compactMap { item -> [AgentToolResult]? in if case .toolResults(let value) = item { return value }; return nil }.last
                    if tools.contains(where: { $0.name == "get_current_view" }) {
                        if let output = results?.first(where: { $0.name == "get_current_view" })?.output {
                            let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
                            if let open = object["open_book"] as? [String: Any] {
                                continuation.yield(.text("Screen reply: open book \(open["title"] ?? "?") · \(open["description"] ?? open["description_note"] ?? "?")"))
                            } else {
                                let rows = (object["items"] as? [[String: Any]] ?? []).prefix(3).map { "\($0["rank"] ?? "?"). \($0["title"] ?? $0["book"] ?? "?")" }
                                continuation.yield(.text("Screen reply: \(object["list"] ?? "?") · \(rows.joined(separator: "; "))"))
                            }
                        } else {
                            continuation.yield(.toolCall(AgentToolCall(id: "call_view", name: "get_current_view", arguments: ReadingAgentToolbox.json(["max_items": 5]))))
                        }
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    guard let output = results?.first?.output else {
                        let question = items.compactMap { item -> String? in if case .turn(let turn) = item, turn.role == "user" { return turn.content }; return nil }.last ?? ""
                        let asked = question.components(separatedBy: "Reader question:\n").last ?? question
                        let term = asked.components(separatedBy: "about ").dropFirst().first?
                            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)) ?? asked
                        let arguments = ReadingAgentToolbox.json(["terms": [String(term.prefix(40))]])
                        continuation.yield(.text("Let me look."))
                        continuation.yield(.toolCall(AgentToolCall(id: "call_1", name: "search_book", arguments: arguments)))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
                    let hits = object["results"] as? [[String: Any]] ?? []
                    let chapter = hits.first?["chapter"] as? String ?? "no chapter"
                    continuation.yield(.text("Agent reply: found \(hits.count) passages; earliest in \(chapter)."))
                    continuation.yield(.finished(truncated: false)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
