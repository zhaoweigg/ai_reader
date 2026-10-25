import XCTest
import UIKit
@testable import LeafReader

final class ChatMarkdownTests: XCTestCase {
    func testNativeSelectableReplyKeepsUnicodeFormattingAndLinks() {
        let native = ChatMarkdown.selectableText("## 人物\n\n🌿这是**李香玲**，*重点*与 `code`。[来源](https://example.com)\n\n- 第一条\n- 第二条")
        XCTAssertEqual(native.string, "人物\n\n🌿这是李香玲，重点与 code。来源\n\n• 第一条\n• 第二条")
        let text = native.string as NSString
        let bold = native.attribute(.font, at: text.range(of: "李香玲").location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        let italic = native.attribute(.font, at: text.range(of: "重点").location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(italic?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        let code = native.attribute(.font, at: text.range(of: "code").location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(code?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        XCTAssertEqual(native.attribute(.link, at: text.range(of: "来源").location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(ChatMarkdown.selectableText("**my literal question**", markdown: false).string, "**my literal question**")
    }

    @MainActor func testStreamingPreservesSelectedRangeAndAppliesLatestReplyAfterSelectionEnds() {
        let view = SelectableChatTextView()
        let coordinator = SelectableChatText.Coordinator()
        view.isEditable = false
        view.onSelectionEnd = { coordinator.endSelection(in: view) }
        coordinator.update(ChatMarkdown.selectableText("第一句 🌿 selected passage"), in: view)
        let range = (view.text as NSString).range(of: "selected passage")
        view.selectedRange = range
        coordinator.textViewDidChangeSelection(view)
        coordinator.update(ChatMarkdown.selectableText("第一句 🌿 selected passage，新增**一句**。"), in: view)
        coordinator.update(ChatMarkdown.selectableText("第一句 🌿 selected passage，新增**一句**。最后一句。"), in: view)
        XCTAssertEqual(view.selectedRange, range)
        XCTAssertEqual((view.text as NSString).substring(with: view.selectedRange), "selected passage")
        XCTAssertEqual(view.text, "第一句 🌿 selected passage")
        view.selectedRange = NSRange(location: range.location, length: 0)
        coordinator.textViewDidChangeSelection(view)
        XCTAssertEqual(view.text, "第一句 🌿 selected passage，新增一句。最后一句。")
        coordinator.update(ChatMarkdown.selectableText("下一条回复"), in: view)
        view.selectedRange = NSRange(location: 0, length: 2)
        coordinator.textViewDidChangeSelection(view)
        coordinator.update(ChatMarkdown.selectableText("下一条回复已完成"), in: view)
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(view.text, "下一条回复已完成", "Moving focus to the composer must release deferred streaming text")
    }

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
