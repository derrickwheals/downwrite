import XCTest
@testable import DownwriteCore

/// `MarkdownAnalysis.codeBlocks`: what a reader would copy from each code block (DW-012). The text is cmark's own
/// `CodeBlock.code`, so fence lines, the language tag and any quote or list prefix are already gone, minus one final line break.
final class CodeBlockTests: XCTestCase {
    private func texts(_ s: String) -> [String] { MarkdownAnalyzer.analyze(s).codeBlocks.map(\.text) }

    private func slice(_ s: String, _ r: NSRange) -> String { NSString(string: s).substring(with: r) }

    // MARK: What is copied

    func testBacktickFenceWithLanguage() {
        let doc = "```swift\nlet a = 1\nlet b = 2\n```\n"
        let a = MarkdownAnalyzer.analyze(doc)
        XCTAssertEqual(a.codeBlocks.count, 1)
        let b = a.codeBlocks[0]
        XCTAssertEqual(b.text, "let a = 1\nlet b = 2")
        XCTAssertEqual(b.firstLine, 0)
        XCTAssertEqual(b.lastLine, 3)
        // The range is the whole block, fences included, up to the end of the closing fence's content (not its line break).
        XCTAssertEqual(slice(doc, b.range), "```swift\nlet a = 1\nlet b = 2\n```")
    }

    func testTildeFenceWithInfoStringAndNoLanguage() {
        XCTAssertEqual(texts("~~~sh title=\"x\"\necho hi\n~~~\n"), ["echo hi"])
        XCTAssertEqual(texts("```\nplain\n```\n"), ["plain"])
    }

    func testLongerFenceKeepsInnerFence() {
        XCTAssertEqual(texts("````md\n```\ninner\n```\n````\n"), ["```\ninner\n```"])
    }

    func testUnclosedFenceRunsToTheEndOfTheDocument() {
        let a = MarkdownAnalyzer.analyze("```\nabc\ndef")
        XCTAssertEqual(a.codeBlocks.map(\.text), ["abc\ndef"])
        XCTAssertEqual(a.codeBlocks[0].lastLine, 2)
        XCTAssertEqual(texts("```\nabc\n"), ["abc"])
    }

    func testOnlyOneFinalLineBreakIsRemoved() {
        XCTAssertEqual(texts("```\na\n\n```\n"), ["a\n"])
        XCTAssertEqual(texts("```\na\n\n\n```\n"), ["a\n\n"])
    }

    func testBlankLinesInsideAreKept() {
        XCTAssertEqual(texts("```\na\n\nb\n```\n"), ["a\n\nb"])
    }

    func testEmptyAndBlankOnlyBlocksHaveNothingToCopy() {
        XCTAssertEqual(texts("```\n```\n"), [])
        XCTAssertEqual(texts("```\n\n```\n"), [])
        XCTAssertEqual(texts("```"), [])
        XCTAssertEqual(texts("```\n"), [])
        XCTAssertEqual(texts("~~~python\n~~~"), [])
    }

    func testIndentedBlockLosesItsIndentButKeepsDeeperIndent() {
        XCTAssertEqual(texts("para\n\n    one\n      two\n\n    three\n"), ["one\n  two\n\nthree"])
    }

    func testTabsAreKept() {
        XCTAssertEqual(texts("```\n\tfoo\n\t\tbar\n```\n"), ["\tfoo\n\t\tbar"])
    }

    func testNonBMPTextAndUTF16Range() {
        let doc = "😀 intro\n\n```\n😀 x\n𝒜 y\n```\n"
        let a = MarkdownAnalyzer.analyze(doc)
        XCTAssertEqual(a.codeBlocks.map(\.text), ["😀 x\n𝒜 y"])
        XCTAssertEqual(slice(doc, a.codeBlocks[0].range), "```\n😀 x\n𝒜 y\n```")
    }

    func testCodeBlockInsideAQuoteHasNoQuotePrefix() {
        let doc = "> ```sh\n> echo hi\n> ls\n> ```\n"
        let a = MarkdownAnalyzer.analyze(doc)
        XCTAssertEqual(a.codeBlocks.map(\.text), ["echo hi\nls"])
        XCTAssertEqual(a.codeBlocks[0].firstLine, 0)
        XCTAssertEqual(a.codeBlocks[0].lastLine, 3)
    }

    func testCodeBlockInsideAListHasNoListIndent() {
        XCTAssertEqual(texts("- item\n\n  ```sh\n  npm i\n  npm test\n  ```\n"), ["npm i\nnpm test"])
        XCTAssertEqual(texts("1. item\n\n   ```\n   a\n\n   b\n   ```\n"), ["a\n\nb"])
    }

    func testFenceOnTheListMarkerLine() {
        XCTAssertEqual(texts("- ```sh\n  npm i\n  ```\n"), ["npm i"])
    }

    func testMermaidBlockCopiesItsSourceAndIsStillAMermaidBlock() {
        let a = MarkdownAnalyzer.analyze("```mermaid\ngraph TD\n  A-->B\n```\n")
        XCTAssertEqual(a.codeBlocks.map(\.text), ["graph TD\n  A-->B"])
        XCTAssertEqual(a.mermaid.count, 1)
        XCTAssertEqual(a.mermaid[0].range, a.codeBlocks[0].range)
        XCTAssertEqual(a.mermaid[0].source, a.codeBlocks[0].text)
    }

    func testBackToBackBlocksAreTwoRecords() {
        let a = MarkdownAnalyzer.analyze("```\na\n```\n```\nb\n```\n")
        XCTAssertEqual(a.codeBlocks.map(\.text), ["a", "b"])
        XCTAssertEqual(a.codeBlocks.map(\.firstLine), [0, 3])
        XCTAssertEqual(a.codeBlocks.map(\.lastLine), [2, 5])
    }

    func testBlocksAreInDocumentOrder() {
        let doc = "    indented\n\ntext\n\n```\nfenced\n```\n\n> ```\n> quoted\n> ```\n\n- x\n\n  ```\n  listed\n  ```\n"
        let a = MarkdownAnalyzer.analyze(doc)
        XCTAssertEqual(a.codeBlocks.map(\.text), ["indented", "fenced", "quoted", "listed"])
        XCTAssertEqual(a.codeBlocks.map(\.range.location), a.codeBlocks.map(\.range.location).sorted())
    }

    // MARK: What is not a code block

    func testFrontMatterAndInlineCodeAreNotCodeBlocks() {
        XCTAssertEqual(texts("---\ntitle: x\nbody: |\n  ```\n  nope\n  ```\n---\n\nuse `x` and ``y`` here\n"), [])
        XCTAssertEqual(texts("---\ntitle: x\n---\n\n```\na\n```\n"), ["a"])
    }

    func testTablesAndHTMLBlocksAreNotCodeBlocks() {
        XCTAssertEqual(texts("| a | `b` |\n| - | - |\n| c | d |\n\n<pre>\nx\n</pre>\n"), [])
    }

    func testTableCellAnalysisHasNoCodeBlocks() {
        XCTAssertEqual(MarkdownAnalyzer.analyzeTableCell("`x`").codeBlocks, [])
        XCTAssertEqual(MarkdownAnalyzer.analyzeTableCell("plain").codeBlocks, [])
    }

    func testNoBlocksInAnEmptyDocument() {
        XCTAssertEqual(MarkdownAnalyzer.analyze("").codeBlocks, [])
    }

    // MARK: Lookups

    func testContainingOffsetIncludesBothEnds() {
        let doc = "before\n\n```sh\nls\n```\n\nafter\n"
        let a = MarkdownAnalyzer.analyze(doc)
        let r = a.codeBlocks[0].range
        XCTAssertEqual(slice(doc, r), "```sh\nls\n```")
        XCTAssertNil(a.codeBlock(containing: r.location - 1))
        XCTAssertEqual(a.codeBlock(containing: r.location), a.codeBlocks[0])
        XCTAssertEqual(a.codeBlock(containing: r.location + 8), a.codeBlocks[0])
        XCTAssertEqual(a.codeBlock(containing: NSMaxRange(r)), a.codeBlocks[0])
        XCTAssertNil(a.codeBlock(containing: NSMaxRange(r) + 1))
        XCTAssertNil(a.codeBlock(containing: 0))
        XCTAssertNil(a.codeBlock(containing: -1))
        XCTAssertNil(a.codeBlock(containing: a.length + 5))
    }

    func testContainingOffsetPicksTheRightOfSeveral() {
        let doc = "```\na\n```\n\n```\nb\n```\n\n```\nc\n```\n"
        let a = MarkdownAnalyzer.analyze(doc)
        XCTAssertEqual(a.codeBlocks.map(\.text), ["a", "b", "c"])
        for (i, b) in a.codeBlocks.enumerated() {
            XCTAssertEqual(a.codeBlock(containing: b.range.location + 4)?.text, ["a", "b", "c"][i])
            XCTAssertEqual(a.codeBlock(containing: NSMaxRange(b.range))?.text, ["a", "b", "c"][i])
        }
        // The blank line between two blocks belongs to neither.
        XCTAssertNil(a.codeBlock(containing: NSMaxRange(a.codeBlocks[0].range) + 1))
    }

    func testContainingLine() {
        let a = MarkdownAnalyzer.analyze("x\n\n```\na\n```\n\ny\n")
        XCTAssertNil(a.codeBlock(containingLine: 0))
        XCTAssertNil(a.codeBlock(containingLine: 1))
        for l in 2...4 { XCTAssertEqual(a.codeBlock(containingLine: l)?.text, "a") }
        XCTAssertNil(a.codeBlock(containingLine: 5))
        XCTAssertNil(a.codeBlock(containingLine: -1))
        XCTAssertNil(a.codeBlock(containingLine: 99))
    }

    func testLookupsOnADocumentWithoutBlocks() {
        let a = MarkdownAnalyzer.analyze("just text\n")
        XCTAssertNil(a.codeBlock(containing: 0))
        XCTAssertNil(a.codeBlock(containingLine: 0))
    }

    // MARK: Ranges stay inside the text

    func testRangesAndLinesAgreeWithTheLineTable() {
        let doc = "```\na\n```\n\n> ```\n> b\n> ```\n\n    c\n\n- ```\n  d\n  ```\n```\nunclosed"
        let a = MarkdownAnalyzer.analyze(doc)
        XCTAssertFalse(a.codeBlocks.isEmpty)
        for b in a.codeBlocks {
            XCTAssertGreaterThanOrEqual(b.range.location, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(b.range), a.length)
            XCTAssertEqual(b.range.location, a.lines[b.firstLine].range.location)
            XCTAssertEqual(NSMaxRange(b.range), a.lines[b.lastLine].contentEnd)
            XCTAssertFalse(b.text.isEmpty)
        }
    }
}
