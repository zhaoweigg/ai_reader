import XCTest
@testable import LeafReader

final class ChatMarkdownTests: XCTestCase {
    func testChineseBoldAdjacentToPunctuationAndText() {
        let source = "这是**李香玲**，云瑶新组织里的队友。"
        let rendered = ChatMarkdown.render(source)
        XCTAssertEqual(String(rendered.characters), "这是李香玲，云瑶新组织里的队友。")
        let bold = rendered.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(bold.map { String(rendered[$0.range].characters) }, ["李香玲"])
        XCTAssertEqual(source, "这是**李香玲**，云瑶新组织里的队友。")
    }

    func testParagraphsHeadingsAndHardBreaksKeepTheirSeparation() {
        let rendered = ChatMarkdown.render("## 人物\n\n第一段。  \n下一行。\n\n第二段。")
        XCTAssertEqual(String(rendered.characters), "人物\n\n第一段。\n下一行。\n\n第二段。")
        XCTAssertNotNil(rendered.runs.first?.font)
    }

    func testListsRetainMarkersNumberingAndNestedItems() {
        let rendered = ChatMarkdown.render("- 第一项\n- 第二项\n  - 子项\n\n3. 第三项\n4. 第四项")
        XCTAssertEqual(String(rendered.characters), "• 第一项\n• 第二项\n\n  • 子项\n\n3. 第三项\n4. 第四项")
    }

    func testLinksEmphasisAndInlineCodeHaveAttributes() {
        let rendered = ChatMarkdown.render("*重点*、`a **literal**`、[来源](https://example.com)")
        XCTAssertEqual(String(rendered.characters), "重点、a **literal**、来源")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil })
        XCTAssertTrue(rendered.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    func testCodeAndQuoteRemainSeparatedAndCodeStaysLiteral() {
        let rendered = ChatMarkdown.render("> 引用 **重点**\n\n```swift\nlet text = \"**literal**\"\n```\n\n回答。")
        XCTAssertEqual(String(rendered.characters), "▎ 引用 重点\n\nlet text = \"**literal**\"\n\n回答。")
        XCTAssertTrue(rendered.runs.contains { String(rendered[$0.range].characters).contains("let text") && $0.font != nil })
    }

    func testEveryStreamingPrefixIsRenderableAndCompletedBoldFormats() {
        let source = "这是**李香玲**。\n\n- 说明 `code`。"
        for end in source.indices {
            let partial = String(source[..<end])
            let rendered = String(ChatMarkdown.render(partial).characters)
            if partial.contains("李") { XCTAssertTrue(rendered.contains("李")) }
        }
        XCTAssertEqual(String(ChatMarkdown.render("这是**李香玲").characters), "这是**李香玲")
        XCTAssertEqual(String(ChatMarkdown.render(source).characters), "这是李香玲。\n\n• 说明 code。")
    }
}
