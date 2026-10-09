import XCTest
@testable import DownwriteCore

/// Fold regions (which headings and list items can fold, and which lines they hide) and the pure fold state machine.
/// Line numbers in descriptions are 1-based, as in the spec; the analyzer's own indices are 0-based.
final class FoldingTests: XCTestCase {
    // MARK: Helpers

    /// Fixture F, shared with the app tests and the end-to-end step (`Tests/Fixtures/fold-demo.md`, no trailing newline).
    static func fixtureF(file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fold-demo.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func analyze(_ s: String) -> MarkdownAnalysis { MarkdownAnalyzer.analyze(s) }

    /// `H2 5-5 hides 6-19`: kind, header lines, hidden lines (1-based, inclusive).
    private func describe(_ r: FoldRegion) -> String {
        let kind: String
        switch r.kind {
        case .heading(let level): kind = "H\(level)"
        case .item: kind = "item"
        }
        return "\(kind) \(r.headerLines.lowerBound + 1)-\(r.headerLines.upperBound + 1) hides \(r.hiddenLines.lowerBound + 1)-\(r.hiddenLines.upperBound + 1)"
    }

    private func regions(_ s: String) -> [String] { analyze(s).foldRegions.map(describe) }

    /// Checks everything that must hold for any document, whatever its regions are.
    private func assertInvariants(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        let a = analyze(s)
        var previous = -1
        for r in a.foldRegions {
            XCTAssertGreaterThan(r.anchor, previous, "regions are in document order with unique anchors", file: file, line: line)
            previous = r.anchor
            XCTAssertEqual(r.anchor, a.lines[r.headerLines.lowerBound].range.location, "anchor is the start of the header's first line", file: file, line: line)
            XCTAssertEqual(r.headerLines.upperBound + 1, r.hiddenLines.lowerBound, "hidden lines follow the header with no gap", file: file, line: line)
            XCTAssertLessThan(r.hiddenLines.upperBound, a.lines.count, file: file, line: line)
            let first = a.lines[r.hiddenLines.lowerBound].range, last = a.lines[r.hiddenLines.upperBound].range
            XCTAssertEqual(r.hiddenRange, NSRange(location: first.location, length: NSMaxRange(last) - first.location),
                           "hidden range runs from the first hidden line's start through the last one's terminator", file: file, line: line)
            let ns = NSString(string: s)
            let hidden = ns.substring(with: r.hiddenRange)
            XCTAssertFalse(hidden.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }, "at least one hidden line has content", file: file, line: line)
        }
    }

    // MARK: Fixture F (R3)

    func testFixtureFRegionsMatchTheSpecTable() throws {
        let text = try Self.fixtureF()
        XCTAssertEqual(regions(text), [
            "H1 1-1 hides 2-36",       // # Project: no later H1, so the section runs to the end
            "H2 5-5 hides 6-19",       // ## Plan: ends before ## Notes
            "H3 9-9 hides 10-19",      // ### Tasks: ends before ## Notes, a higher level
            "item 11-11 hides 12-13",  // - [ ] Write spec: its nested items
            "H2 20-20 hides 21-32",    // ## Notes: includes the Mermaid block, ends before ## Empty
            "item 26-26 hides 27-30",  // - Groceries: its nested items and the paragraph under Eggs
            "item 28-28 hides 29-30",  // - Eggs: the blank line and the extra paragraph
            "H2 35-35 hides 36-36",    // ## Last: the final line
        ])
        assertInvariants(text)
    }

    func testFixtureFAnchorsAndHiddenRanges() throws {
        let text = try Self.fixtureF()
        let a = analyze(text)
        let ns = NSString(string: text)
        let plan = try XCTUnwrap(a.foldRegions.first { $0.headerLines == 4...4 })
        XCTAssertEqual(plan.anchor, ns.range(of: "## Plan").location)
        XCTAssertTrue(ns.substring(with: plan.hiddenRange).hasPrefix("\nPlan text.\n\n### Tasks\n"))
        XCTAssertTrue(ns.substring(with: plan.hiddenRange).hasSuffix("| 1 | 2 |\n\n"), "ends with the blank line before ## Notes, terminator included")
        let last = try XCTUnwrap(a.foldRegions.last)
        XCTAssertEqual(NSMaxRange(last.hiddenRange), ns.length, "the last line has no terminator, the range stops at the end of the text")
        XCTAssertEqual(ns.substring(with: last.hiddenRange), "Final line, no trailing newline")
    }

    func testNotRegions() throws {
        let a = analyze(try Self.fixtureF())
        let headers = Set(a.foldRegions.map { $0.headerLines.lowerBound + 1 })
        for line in [33, 12, 13, 14, 27, 31, 16, 22] {       // ## Empty, Draft, Review, Build, Milk, Done, the table, the Mermaid fence
            XCTAssertFalse(headers.contains(line), "line \(line) is not a fold header")
        }
    }

    func testFixtureHasNoTrailingNewline() throws {
        XCTAssertFalse(try Self.fixtureF().hasSuffix("\n"), "editors add a trailing newline; the fixture's expected regions assume none")
    }

    // MARK: Headings (R1)

    func testSetextHeadingsHideAfterTheirUnderline() {
        XCTAssertEqual(regions("Title\n=====\ntext"), ["H1 1-2 hides 3-3"])
        XCTAssertEqual(regions("Sub\n---\ntext\n\nmore"), ["H2 1-2 hides 3-5"])
        XCTAssertEqual(regions("Line one\nline two\n===\ntext"), ["H1 1-3 hides 4-4"], "a wrapped setext heading keeps all its lines as the header")
        assertInvariants("Title\n=====\ntext")
    }

    func testSetextHeadingEndsAtItsUnderlineWhateverFollows() {
        // cmark reports a setext heading's range as running over the line after the underline when text follows it directly.
        XCTAssertEqual(regions("Title\n=====\n\ntext"), ["H1 1-2 hides 3-4"], "blank line after the underline")
        XCTAssertEqual(regions("Title\n=====\ntext"), ["H1 1-2 hides 3-3"], "text directly after the underline")
        XCTAssertEqual(regions("Title\n=====\n# Next\nbody"), ["H1 3-3 hides 4-4"], "a heading directly after the underline ends the section; nothing under Title")
        XCTAssertEqual(regions("Title\n=====\n- a\n  - b"), ["H1 1-2 hides 3-4", "item 3-3 hides 4-4"], "a list directly after the underline")
        XCTAssertEqual(regions("Title\n=====\n"), [], "only the empty final line under it")
        XCTAssertEqual(regions("Title\n   ===   \ntext"), ["H1 1-2 hides 3-3"], "indented underline with trailing spaces")
    }

    func testHeadingInsideQuoteOrItemIsNotARegionAndDoesNotEndASection() {
        XCTAssertEqual(regions("> # Q\n> text\n\n# Real\ntext"), ["H1 4-4 hides 5-5"])
        XCTAssertEqual(regions("# A\n> # Q\n> text\n\ntail"), ["H1 1-1 hides 2-5"], "a quoted H1 does not end the section of A")
        XCTAssertEqual(regions("# A\n- # Inner\n  body\n\ntail"), ["H1 1-1 hides 2-5", "item 2-2 hides 3-3"], "a heading in an item neither ends A nor folds")
    }

    func testDeeperHeadingsNestAndALevelSkipIsFine() {
        // ### C ends at ## B (a higher level); # A has no later H1 so it runs to the end.
        XCTAssertEqual(regions("# A\n### C\ntext\n## B\nx"), ["H1 1-1 hides 2-5", "H3 2-2 hides 3-3", "H2 4-4 hides 5-5"])
        XCTAssertEqual(regions("## A\n# B\ntext"), ["H1 2-2 hides 3-3"], "A is followed directly by a higher level: nothing under it")
        XCTAssertEqual(regions("## A\ntext\n### B\nx\n## C\ny\n# D\nz"),
                       ["H2 1-1 hides 2-4", "H3 3-3 hides 4-4", "H2 5-5 hides 6-6", "H1 7-7 hides 8-8"])
    }

    func testHashInsideAFenceIsNotAHeading() {
        XCTAssertEqual(regions("```\n# not a heading\n```\ntext"), [])
        XCTAssertEqual(regions("# H\n```\n# not\n```"), ["H1 1-1 hides 2-4"])
        XCTAssertEqual(regions("    # indented code\ntext"), [])
    }

    func testDocumentWithoutHeadingsOrItems() {
        XCTAssertEqual(regions(""), [])
        XCTAssertEqual(regions("just text\n\nmore text"), [])
        XCTAssertEqual(regions("- a\n- b\n- c"), [], "items with only their first paragraph have no content to fold")
    }

    func testHeadingWithOnlyBlankLinesIsNotFoldable() {
        XCTAssertEqual(regions("# A\n\n\n# B\ntext"), ["H1 4-4 hides 5-5"])
        XCTAssertEqual(regions("# A\n\n# B"), [])
        XCTAssertEqual(regions("# A\n   \n\t\n# B\nx"), ["H1 4-4 hides 5-5"], "whitespace-only lines are blank")
        XCTAssertEqual(regions("# A"), [])
        // A deeper heading is part of the section, so a heading followed (after blanks) by one does have content.
        XCTAssertEqual(regions("# A\n\n\n## B\ntext"), ["H1 1-1 hides 2-5", "H2 4-4 hides 5-5"])
    }

    func testTrailingNewlineMakesTheEmptyFinalLineAHiddenLine() {
        XCTAssertEqual(regions("# A\ntext\n"), ["H1 1-1 hides 2-3"], "the empty last line is a real line and hides with its section")
        XCTAssertEqual(regions("# A\n\n"), [], "only blank lines under it")
        XCTAssertEqual(regions("# A\n"), [])
        let a = analyze("# A\ntext\n")
        XCTAssertEqual(a.foldRegions.first?.hiddenRange, NSRange(location: 4, length: 5))
        assertInvariants("# A\ntext\n")
    }

    func testFrontMatterIsNotAHeadingAndLinesStayAligned() {
        XCTAssertEqual(regions("---\ntitle: x\n---\n# A\ntext"), ["H1 4-4 hides 5-5"])
    }

    func testCRLFLineEndings() {
        let s = "# A\r\ntext\r\n## B\r\nx\r\n"
        XCTAssertEqual(regions(s), ["H1 1-1 hides 2-5", "H2 3-3 hides 4-5"])
        assertInvariants(s)
        XCTAssertEqual(analyze(s).foldRegions[0].hiddenRange, NSRange(location: 5, length: NSString(string: s).length - 5))
    }

    func testOffsetsAreUTF16() {
        let s = "# 😀 héllo\n😀 text\n## B\nx"
        XCTAssertEqual(regions(s), ["H1 1-1 hides 2-4", "H2 3-3 hides 4-4"])
        let a = analyze(s)
        XCTAssertEqual(a.foldRegions[1].anchor, NSString(string: s).range(of: "## B").location)
        assertInvariants(s)
    }

    // MARK: List items (R2)

    func testNumberedAndTaskItemsFoldOnTheirNestedContent() {
        XCTAssertEqual(regions("1. one\n   - nested\n2. two"), ["item 1-1 hides 2-2"])
        XCTAssertEqual(regions("- [ ] task\n  - [ ] sub\n- [x] other"), ["item 1-1 hides 2-2"])
        XCTAssertEqual(regions("3) three\n   more\n   - n"), ["item 1-2 hides 3-3"], "the second line is part of the first paragraph")
    }

    func testItemInsideABlockQuote() {
        XCTAssertEqual(regions("> - a\n>   - b\n> - c"), ["item 1-1 hides 2-2"])
        assertInvariants("> - a\n>   - b\n> - c")
    }

    func testItemWhoseFirstChildIsAFencedCodeBlock() {
        XCTAssertEqual(regions("- ```swift\n  code\n  ```\n- next"), ["item 1-1 hides 2-3"], "the header is only the item's first line")
        XCTAssertEqual(regions("-\n  - a\n  - b"), ["item 1-1 hides 2-3"], "an item that starts with a nested list")
    }

    func testItemWithAWrappedFirstParagraphKeepsEveryWrappedLineInTheHeader() {
        XCTAssertEqual(regions("- first line\n  wrapped line\n  - nested"), ["item 1-2 hides 3-3"])
        XCTAssertEqual(regions("- first\nlazy continuation\n  - nested"), ["item 1-2 hides 3-3"])
        XCTAssertEqual(regions("- only a long\n  wrapped paragraph\n- next"), [], "a wrapped paragraph alone is not content to fold")
    }

    func testItemWithFurtherParagraphsAndBlankLines() {
        XCTAssertEqual(regions("- a\n\n  second paragraph\n- b"), ["item 1-1 hides 2-3"])
    }

    func testItemsNeverHideTheirFollowingSibling() {
        let s = "- a\n  - a1\n- b\n  - b1\n- c"
        XCTAssertEqual(regions(s), ["item 1-1 hides 2-2", "item 3-3 hides 4-4"])
        assertInvariants(s)
    }

    func testNestedListOnTheItemsFirstLineGivesOneRegion() {
        // `- - a` starts two items on one line; a fold is identified by the header line's start, so only one may exist.
        let s = "- - a\n    - b"
        let r = analyze(s).foldRegions
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(Set(r.map(\.anchor)).count, r.count)
        assertInvariants(s)
    }

    func testHeadingsAndItemsTogetherStayInDocumentOrder() {
        let s = "# A\n- x\n  - y\n\n## B\n- z\n\n  text"
        XCTAssertEqual(regions(s), ["H1 1-1 hides 2-8", "item 2-2 hides 3-3", "H2 5-5 hides 6-8", "item 6-6 hides 7-8"])
        assertInvariants(s)
    }

    // MARK: Table cells

    func testTableCellAnalysisHasNoFoldRegions() {
        XCTAssertTrue(MarkdownAnalyzer.analyzeTableCell("# not a heading\n- nor an item").foldRegions.isEmpty)
    }
}
