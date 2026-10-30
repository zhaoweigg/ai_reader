import XCTest
@testable import LeafReader

final class ReadAloudSentenceSplitterTests: XCTestCase {
    func testSplitterKeepsChineseSentencesShortAndOffsetsExact() {
        let text = "那是一个寒冷的冬夜，雪花悄无声息地落在青石板路上。林远站在巷口，手里攥着那封信，犹豫了很久。他知道，一旦推开那扇门，很多事情就再也回不去了。"
        let sentences = ReadAloudSentenceSplitter.split(text)
        XCTAssertEqual(sentences.map(\.text), ["那是一个寒冷的冬夜，雪花悄无声息地落在青石板路上。", "林远站在巷口，手里攥着那封信，犹豫了很久。", "他知道，一旦推开那扇门，很多事情就再也回不去了。"])
        for sentence in sentences {
            XCTAssertEqual((text as NSString).substring(with: sentence.range), sentence.text)
            XCTAssertLessThanOrEqual(sentence.range.length, ReadAloudSentenceSplitter.chineseLimit)
        }
        let long = String(repeating: "很长的一段话没有任何标点符号一直写下去", count: 12)
        XCTAssertGreaterThan(ReadAloudSentenceSplitter.split(long).count, 2)
        XCTAssertTrue(ReadAloudSentenceSplitter.split(long).allSatisfy { $0.range.length <= ReadAloudSentenceSplitter.chineseLimit })
        // A long mixed sentence is cut at its commas so the first chunk starts playing quickly.
        let mixed = "我们昨天讨论了 Transformer 架构中的 attention 机制，会议定在下周三下午 3:30，地点是 Building B 的 Room 204。"
        let clauses = ReadAloudSentenceSplitter.split(mixed)
        // The first cut prefers the comma over the space before "3:30"; the remainder is
        // mostly Latin script, so it falls under the English limit and stays whole.
        XCTAssertEqual(clauses.map(\.text), ["我们昨天讨论了 Transformer 架构中的 attention 机制，", "会议定在下周三下午 3:30，地点是 Building B 的 Room 204。"])
        for clause in clauses { XCTAssertEqual((mixed as NSString).substring(with: clause.range), clause.text) }
    }

    func testSplitterHandlesEnglishAbbreviationsQuotesAndLineBreaks() {
        let text = "Dr. Smith paid $3.50 at 9 a.m.! \"Really?\" she asked.\nThe next line has no terminator"
        let sentences = ReadAloudSentenceSplitter.split(text)
        XCTAssertEqual(sentences.map(\.text), ["Dr. Smith paid $3.50 at 9 a.m.!", "\"Really?\"", "she asked.", "The next line has no terminator"])
        XCTAssertEqual(sentences.last?.range, NSRange(location: 53, length: 31))
        XCTAssertEqual(ReadAloudSentenceSplitter.split("J. K. Rowling wrote it. Then more.").map(\.text), ["J. K. Rowling wrote it.", "Then more."])
        let emoji = "Alpha 😀 beta. Gamma 𝄞 delta."
        for sentence in ReadAloudSentenceSplitter.split(emoji) {
            XCTAssertEqual((emoji as NSString).substring(with: sentence.range), sentence.text)
        }
        XCTAssertEqual(ReadAloudSentenceSplitter.split("   \n ... \n").count, 0, "Punctuation-only text has nothing to say")
        let run = String(repeating: "word ", count: 120)
        XCTAssertTrue(ReadAloudSentenceSplitter.split(run).allSatisfy { $0.range.length <= ReadAloudSentenceSplitter.englishLimit })
        XCTAssertGreaterThan(ReadAloudSentenceSplitter.split(run).count, 1)
    }
}
