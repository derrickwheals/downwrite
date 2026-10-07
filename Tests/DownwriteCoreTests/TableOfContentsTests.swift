import XCTest
@testable import DownwriteCore

final class TableOfContentsTests: XCTestCase {
    private func toc(_ s: String) -> TableOfContents { MarkdownAnalyzer.analyze(s).tableOfContents }

    // MARK: Nesting

    func testNestsByLevel() {
        let t = toc("# A\n## B\n### C\n## D\n# E\n")
        XCTAssertEqual(t.rows.map(\.title), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(t.rows.map(\.level), [1, 2, 3, 2, 1])
        XCTAssertEqual(t.rows.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(t.rows.map(\.parent), [nil, 0, 1, 0, nil])
        XCTAssertEqual(t.rows.map(\.hasChildren), [true, true, false, false, false])
        XCTAssertEqual(t.rows.map(\.id), [0, 1, 2, 3, 4])
    }

    func testSkippedLevelsDoNotAddDepth() {
        // # → ### nests a single step; the ## that follows is a sibling of the ###.
        let t = toc("# A\n### C\n## B\n")
        XCTAssertEqual(t.rows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(t.rows.map(\.parent), [nil, 0, 0])
    }

    func testDocumentMayStartBelowLevelOne() {
        let t = toc("## A\n# B\n## C\n###### D\n")
        XCTAssertEqual(t.rows.map(\.depth), [0, 0, 1, 2])
        XCTAssertEqual(t.rows.map(\.parent), [nil, nil, 1, 2])
    }

    func testEmptyDocumentAndDocumentWithoutHeadings() {
        XCTAssertTrue(toc("").isEmpty)
        XCTAssertTrue(toc("just text\n\n- a list\n").isEmpty)
        XCTAssertNil(MarkdownAnalyzer.analyze("").headingIndex(at: 0))
    }

    func testOnlyRealHeadingsAppear() {
        let s = "---\n# yaml comment\n---\n# Real\n\n```\n# in code\n```\n\n    # indented code\n\nSetext\n---\n"
        XCTAssertEqual(toc(s).rows.map(\.title), ["Real", "Setext"])
    }

    func testSetextHeadingsNestLikeAtx() {
        let t = toc("Title\n=====\n\nSub\n---\n\n### Deep\n")
        XCTAssertEqual(t.rows.map(\.title), ["Title", "Sub", "Deep"])
        XCTAssertEqual(t.rows.map(\.depth), [0, 1, 2])
    }

    // MARK: Titles

    func testPlainTitleIsWhatTheEditorShows() {
        let s = """
        # **Bold** and *it* with `code`
        ## A [link](https://example.com/x) here
        ### ![alt text](img.png) after
        #### Closed ####
        #####    spaced    out
        """
        XCTAssertEqual(toc(s).rows.map(\.title), [
            "Bold and it with code", "A link here", "alt text after", "Closed", "spaced out",
        ])
        // `title` keeps the inline source for slugs.
        XCTAssertEqual(MarkdownAnalyzer.analyze(s).headings[0].title, "**Bold** and *it* with `code`")
    }

    func testBareHashHasEmptyTitleButIsListed() {
        let t = toc("# \n## Next\n")
        XCTAssertEqual(t.rows.map(\.title), ["", "Next"])
    }

    func testHeadingInsideQuoteOrListShowsJustItsText() {
        XCTAssertEqual(toc("> # Quoted\n").rows.map(\.title), ["Quoted"])
        XCTAssertEqual(toc("> ## Closed ##\n").rows.map(\.title), ["Closed"])
        XCTAssertEqual(toc("- # In list\n").rows.map(\.title), ["In list"])
        XCTAssertEqual(toc("1. ## Numbered\n").rows.map(\.title), ["Numbered"])
    }

    func testHashesThatAreContentStayPut() {
        XCTAssertEqual(toc("# Learning C#\n").rows.map(\.title), ["Learning C#"])
        XCTAssertEqual(toc("## #hashtag\n").rows.map(\.title), ["#hashtag"])
    }

    func testUnicodeTitles() {
        let t = toc("# Café ☕ 日本語\n## 👩‍💻 emoji\n")
        XCTAssertEqual(t.rows.map(\.title), ["Café ☕ 日本語", "👩‍💻 emoji"])
    }

    func testCRLFDocument() {
        let t = toc("# One\r\n\r\n## Two\r\n")
        XCTAssertEqual(t.rows.map(\.title), ["One", "Two"])
    }

    // MARK: Caret → heading

    func testHeadingIndexFollowsTheCaret() {
        let s = "intro\n\n# A\ntext\n## B\nmore\n"
        let a = MarkdownAnalyzer.analyze(s)
        let ns = NSString(string: s)
        XCTAssertNil(a.headingIndex(at: 0))
        XCTAssertNil(a.headingIndex(at: ns.range(of: "# A").location - 1))
        XCTAssertEqual(a.headingIndex(at: ns.range(of: "# A").location), 0, "start of the heading line")
        XCTAssertEqual(a.headingIndex(at: ns.range(of: "# A").location + 3), 0, "end of the heading line")
        XCTAssertEqual(a.headingIndex(at: ns.range(of: "text").location + 2), 0, "body belongs to the heading above")
        XCTAssertEqual(a.headingIndex(at: ns.range(of: "## B").location), 1)
        XCTAssertEqual(a.headingIndex(at: ns.length), 1, "caret at the very end")
    }

    func testHeadingIndexUsesUTF16Offsets() {
        let s = "# 😀😀 one\n\ntext 😀\n\n## two\n"
        let a = MarkdownAnalyzer.analyze(s)
        let ns = NSString(string: s)
        XCTAssertEqual(a.headingIndex(at: ns.range(of: "text").location), 0)
        XCTAssertEqual(a.headingIndex(at: ns.range(of: "two").location), 1)
    }

    func testHeadingRangesPointAtTheHeadingLine() {
        let s = "text\n\n## Title ##\n\nSetext\n===\n"
        let a = MarkdownAnalyzer.analyze(s)
        let ns = NSString(string: s)
        XCTAssertEqual(ns.substring(with: a.headings[0].range), "## Title ##")
        XCTAssertEqual(ns.substring(with: a.headings[1].range), "Setext")
    }

    func testThousandsOfHeadings() {
        var s = ""
        for i in 0..<3000 { s += "## Heading \(i)\n\ntext\n\n" }
        let a = MarkdownAnalyzer.analyze(s)
        let t = a.tableOfContents
        XCTAssertEqual(t.rows.count, 3000)
        XCTAssertEqual(t.rows.last?.title, "Heading 2999")
        XCTAssertEqual(a.headingIndex(at: NSString(string: s).length), 2999)
    }
}
