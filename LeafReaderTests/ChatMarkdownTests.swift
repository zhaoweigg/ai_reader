import XCTest
import UIKit
@testable import LeafReader

final class ChatMarkdownTests: XCTestCase {
    @MainActor func testScrollUpdatesReuseFormattedReplyAndMeasuredWidths() {
        let view = UITextView(); view.isScrollEnabled = false
        let coordinator = SelectableChatText.Coordinator()
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let paragraph = String(repeating: "这是**李香玲**，云瑶的队友。", count: 4)
        let source = String(repeating: paragraph + "\n\n- 保留线索。\n", count: 28)
        coordinator.update(source: source, markdown: true, traits: traits, in: view)
        let portrait = coordinator.fittedSize(width: 350, in: view)
        let landscape = coordinator.fittedSize(width: 700, in: view)
        for _ in 0..<100 {
            coordinator.update(source: source, markdown: true, traits: traits, in: view)
            XCTAssertEqual(coordinator.fittedSize(width: 350, in: view), portrait)
            XCTAssertEqual(coordinator.fittedSize(width: 700, in: view), landscape)
        }
        XCTAssertEqual(coordinator.formatCount, 1)
        XCTAssertEqual(coordinator.measurementCount, 2)
        XCTAssertGreaterThan(portrait.height, landscape.height)
        for width: CGFloat in [350, 700] {
            let size = coordinator.fittedSize(width: width, in: view)
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            let lastLine = view.caretRect(for: view.endOfDocument)
            XCTAssertGreaterThan(lastLine.height, 0)
            XCTAssertLessThanOrEqual(lastLine.maxY, size.height + 1, "Cached height must contain the final rendered line at both widths")
        }
    }

    @MainActor func testLongReplyTakesTheColumnWithoutMeasuringItsOneLineExtent() {
        let view = UITextView(); view.isScrollEnabled = false
        let coordinator = SelectableChatText.Coordinator()
        coordinator.update(source: "Short.", markdown: true, traits: view.traitCollection, in: view)
        XCTAssertLessThan(coordinator.fittedSize(width: 320, in: view).width, 320, "A short reply keeps its natural width")
        coordinator.update(source: String(repeating: "A longer reply that wraps around. ", count: 12), markdown: true, traits: view.traitCollection, in: view)
        XCTAssertEqual(coordinator.fittedSize(width: 320, in: view).width, 320, "A long reply spans the column")
        coordinator.update(source: "Two\n\nlines", markdown: true, traits: view.traitCollection, in: view)
        XCTAssertEqual(coordinator.fittedSize(width: 320, in: view).width, 320, "A multi-paragraph reply spans the column")
    }

    @MainActor func testChangedTextFormattingAndDynamicTypeInvalidateCachedLayout() {
        let view = UITextView(); view.isScrollEnabled = false
        let coordinator = SelectableChatText.Coordinator()
        let normal = UITraitCollection(preferredContentSizeCategory: .large)
        let source = String(repeating: "**人物**和线索。", count: 20)
        coordinator.update(source: source, markdown: true, traits: normal, in: view)
        let original = coordinator.fittedSize(width: 300, in: view)
        coordinator.update(source: source, markdown: true, traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), in: view)
        XCTAssertGreaterThan(coordinator.fittedSize(width: 300, in: view).height, original.height)
        coordinator.update(source: "**literal**", markdown: false, traits: normal, in: view)
        XCTAssertEqual(view.text, "**literal**")
        XCTAssertLessThan(coordinator.fittedSize(width: 300, in: view).height, original.height)
        coordinator.update(source: "**literal**", markdown: true, traits: normal, in: view)
        XCTAssertEqual(view.text, "literal")
        XCTAssertEqual(coordinator.formatCount, 4)
    }

    @MainActor func testCachedLayoutKeepsSelectionAndAppliesDeferredStreamingText() {
        let view = UITextView(); view.isScrollEnabled = false
        let coordinator = SelectableChatText.Coordinator()
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        coordinator.update(source: "第一句 selected passage", markdown: true, traits: traits, in: view)
        let original = coordinator.fittedSize(width: 300, in: view)
        let range = (view.text as NSString).range(of: "selected passage")
        view.selectedRange = range; coordinator.textViewDidChangeSelection(view)
        let latest = "第一句 selected passage\n\n" + String(repeating: "新增**一句**。", count: 80)
        coordinator.update(source: latest, markdown: true, traits: traits, in: view)
        XCTAssertEqual(view.selectedRange, range)
        XCTAssertEqual(coordinator.fittedSize(width: 300, in: view), original)
        coordinator.endSelection(in: view)
        XCTAssertGreaterThan(coordinator.fittedSize(width: 300, in: view).height, original.height)
        XCTAssertEqual(view.text, ChatMarkdown.selectableText(latest).string)
    }

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

    @MainActor func testStreamingPreservesSelectedRangeAndAppliesLatestReplyAfterSelectionEnds() throws {
        let view = SelectableChatTextView()
        let coordinator = SelectableChatText.Coordinator()
        view.isEditable = false
        view.onSelectionEnd = { [weak view, weak coordinator] in
            if let view { coordinator?.endSelection(in: view) }
        }
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
        // Resigning only succeeds for a view that actually owns focus. Host the
        // read-only view in a real scene before exercising that UIKit lifecycle.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.rootViewController?.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
        defer { window.isHidden = true; previousWindow?.makeKey() }
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.isFirstResponder)
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

    func testModelStyleBoldMarkersStillRenderAsBold() {
        func bold(_ rendered: AttributedString) -> [String] {
            rendered.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }.map { String(rendered[$0.range].characters) }
        }
        // A space before the closer, as in the reported reply.
        let spaced = ChatMarkdown.render("**“朔望月”在这里是地猴珍藏的一副牌、也是他想与齐夏对赌的游戏名称。 **上一章里，这副牌装在木盒中。")
        XCTAssertEqual(String(spaced.characters), "“朔望月”在这里是地猴珍藏的一副牌、也是他想与齐夏对赌的游戏名称。 上一章里，这副牌装在木盒中。")
        XCTAssertEqual(bold(spaced), ["“朔望月”在这里是地猴珍藏的一副牌、也是他想与齐夏对赌的游戏名称。 "])
        // A closer glued to Chinese punctuation, and a space after the opener.
        let glued = ChatMarkdown.render("**标题：**内容在这里。\n\n** 词**之后\n\n再来**正常**的。")
        XCTAssertEqual(String(glued.characters), "标题：内容在这里。\n\n 词之后\n\n再来正常的。")
        XCTAssertEqual(bold(glued), ["标题：", " 词", "正常"])
        // Two paragraphs each pair on their own; code keeps its asterisks; a
        // marker still streaming stays literal, as does a longer run of asterisks.
        let mixed = ChatMarkdown.render("**第一段：**甲\n\n`a **literal**` 和 **第二段。 **乙\n\n```\n**code**\n```\n\n未完的**粗体 ***三星***")
        XCTAssertEqual(String(mixed.characters), "第一段：甲\n\na **literal** 和 第二段。 乙\n\n**code**\n\n未完的**粗体 三星")
        XCTAssertEqual(bold(mixed), ["第一段：", "第二段。 ", "三星"])
        let selectable = ChatMarkdown.selectableText("**标题：**内容") as NSAttributedString
        let font = selectable.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(selectable.string, "标题：内容")
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        let plain = selectable.attribute(.font, at: 3, effectiveRange: nil) as? UIFont
        XCTAssertFalse(plain?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
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
