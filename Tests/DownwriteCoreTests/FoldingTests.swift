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

    // MARK: FoldState (R6, R11, R12, R15)

    private struct F {
        let text: String
        let a: MarkdownAnalysis
        init() throws { text = try FoldingTests.fixtureF(); a = MarkdownAnalyzer.analyze(text) }

        /// The region whose header starts on 1-based line `n`.
        func region(_ n: Int) -> FoldRegion { a.foldRegions.first { $0.headerLines.lowerBound == n - 1 }! }
        /// Offset of the start / content end of 1-based line `n`.
        func start(_ n: Int) -> Int { a.lines[n - 1].range.location }
        func end(_ n: Int) -> Int { a.lines[n - 1].contentEnd }
        func offset(of s: String) -> Int { NSString(string: text).range(of: s).location }
        /// 1-based header lines of the folded regions.
        func folded(_ s: FoldState) -> [Int] { a.foldRegions.filter(s.isFolded).map { $0.headerLines.lowerBound + 1 } }
        func state(_ headers: Int...) -> FoldState { headers.reduce(FoldState()) { $0.toggled(region($1)) } }
    }

    func testToggleFoldsAndUnfoldsOneRegion() throws {
        let f = try F()
        let s = FoldState().toggled(f.region(5))
        XCTAssertTrue(s.isFolded(f.region(5)))
        XCTAssertEqual(f.folded(s), [5])
        XCTAssertEqual(s.toggled(f.region(5)), FoldState())
        XCTAssertTrue(FoldState().isEmpty)
    }

    func testHiddenLineRangesAreMergedAndNestedFoldsAddNothing() throws {
        let f = try F()
        XCTAssertEqual(FoldState().hiddenLineRanges(in: f.a), [])
        XCTAssertEqual(f.state(5).hiddenLineRanges(in: f.a), [5...18])
        XCTAssertEqual(f.state(11).hiddenLineRanges(in: f.a), [11...12])
        XCTAssertEqual(f.state(5, 20).hiddenLineRanges(in: f.a), [5...18, 20...31])
        XCTAssertEqual(f.state(5, 9).hiddenLineRanges(in: f.a), [5...18], "Tasks is inside Plan")
        XCTAssertEqual(f.state(5, 11).hiddenLineRanges(in: f.a), [5...18], "an item inside a folded heading")
        XCTAssertEqual(f.state(20, 26, 28).hiddenLineRanges(in: f.a), [20...31], "Groceries and Eggs are inside Notes")
        XCTAssertEqual(f.state(26, 28).hiddenLineRanges(in: f.a), [26...29], "Eggs is inside Groceries")
        XCTAssertEqual(f.state(1, 5, 20, 35).hiddenLineRanges(in: f.a), [1...35])
    }

    func testFoldHidingFindsTheOutermostFoldedRegionAndTreatsBoundariesExactly() throws {
        let f = try F()
        let plan = f.state(5)
        let hidden = f.region(5).hiddenRange
        XCTAssertEqual(plan.foldHiding(offset: f.offset(of: "Plan text."), in: f.a), f.region(5))
        XCTAssertNil(plan.foldHiding(offset: f.end(5), in: f.a), "the end of the header line is visible, where the chip sits")
        XCTAssertEqual(plan.foldHiding(offset: hidden.location, in: f.a), f.region(5), "the start of the first hidden line is hidden")
        XCTAssertEqual(plan.foldHiding(offset: NSMaxRange(hidden) - 1, in: f.a), f.region(5))
        XCTAssertNil(plan.foldHiding(offset: NSMaxRange(hidden), in: f.a), "the start of ## Notes is visible")
        XCTAssertEqual(NSMaxRange(hidden), f.start(20))
        XCTAssertNil(plan.foldHiding(offset: f.offset(of: "Intro paragraph."), in: f.a))
        XCTAssertNil(plan.foldHiding(offset: 0, in: f.a))
        XCTAssertEqual(f.state(1, 5).foldHiding(offset: f.offset(of: "Plan text."), in: f.a), f.region(1), "outermost wins")
        XCTAssertEqual(f.state(5, 9).foldHiding(offset: f.offset(of: "Write spec"), in: f.a), f.region(5))
        XCTAssertEqual(f.state(9).foldHiding(offset: f.offset(of: "Write spec"), in: f.a), f.region(9), "only the folded one counts")
        XCTAssertNil(FoldState().foldHiding(offset: f.offset(of: "Plan text."), in: f.a))
    }

    func testTheEndOfTheDocumentIsHiddenWhenTheLastSectionIsFolded() throws {
        let f = try F()
        let last = f.state(35)
        XCTAssertEqual(last.foldHiding(offset: f.text.utf16.count, in: f.a), f.region(35), "the caret at the very end sits on the hidden last line")
        XCTAssertNil(FoldState().foldHiding(offset: f.text.utf16.count, in: f.a))
        XCTAssertNil(last.foldHiding(offset: f.end(35), in: f.a))

        // A trailing newline adds an empty last line that hides with its section.
        let s = "# A\ntext\n"
        let a = MarkdownAnalyzer.analyze(s)
        let folded = FoldState().toggled(a.foldRegions[0])
        XCTAssertNil(folded.foldHiding(offset: 3, in: a), "the end of the header")
        XCTAssertNotNil(folded.foldHiding(offset: 4, in: a))
        XCTAssertNotNil(folded.foldHiding(offset: s.utf16.count, in: a), "the empty final line")

        // ...but an item's hidden lines stop before that empty final line, which stays visible.
        let item = "- a\n  - b\n"
        let ia = MarkdownAnalyzer.analyze(item)
        let foldedItem = FoldState().toggled(ia.foldRegions[0])
        XCTAssertEqual(NSMaxRange(ia.foldRegions[0].hiddenRange), item.utf16.count, "the hidden range reaches the end of the text")
        XCTAssertNotNil(foldedItem.foldHiding(offset: 7, in: ia), "inside `  - b`")
        XCTAssertNil(foldedItem.foldHiding(offset: item.utf16.count, in: ia), "the empty final line is not one of the item's hidden lines")
    }

    func testFoldAtTheCaretWorkedExampleOnFixtureF() throws {
        let f = try F()
        // Caret on line 13 (`- [x] Review`). Each fold moves the caret to the end of that fold's header (R13), as the editor does.
        var caret = f.offset(of: "- [x] Review") + 4
        var state = FoldState()
        var steps: [Int] = []
        while let next = state.folding(atCaret: caret, in: f.a) {
            let newly = f.a.foldRegions.first { next.isFolded($0) && !state.isFolded($0) }!
            steps.append(newly.headerLines.lowerBound + 1)
            state = next
            caret = f.a.lines[newly.headerLines.upperBound].contentEnd
        }
        XCTAssertEqual(steps, [11, 9, 5, 1], "Write spec, then Tasks, Plan and Project: repeated Fold folds outwards")
        XCTAssertEqual(f.folded(state), [1, 5, 9, 11])
        XCTAssertEqual(state.hiddenLineRanges(in: f.a), [1...35])
        XCTAssertNil(state.folding(atCaret: f.end(1), in: f.a), "nothing is left to fold")
    }

    func testFoldAtTheCaretChoosesTheInnermostRegionHoldingTheCaretLine() throws {
        let f = try F()
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.end(5), in: f.a)!), [5], "caret on a heading folds that heading")
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.start(5), in: f.a)!), [5])
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.offset(of: "Intro paragraph."), in: f.a)!), [1])
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.offset(of: "Plan text."), in: f.a)!), [5])
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.offset(of: "| 1 | 2 |"), in: f.a)!), [9], "a table row in Tasks")
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.offset(of: "graph TD"), in: f.a)!), [20], "inside the Mermaid block in Notes")
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.offset(of: "## Empty"), in: f.a)!), [1], "## Empty is not a region; its section is Project's")
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.offset(of: "Extra paragraph"), in: f.a)!), [28], "a paragraph hidden by the Eggs item")
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.offset(of: "Milk"), in: f.a)!), [26], "Milk has no region of its own; Groceries holds it")
        XCTAssertEqual(f.folded(FoldState().folding(atCaret: f.offset(of: "Eggs"), in: f.a)!), [28], "an item header folds the item")
        XCTAssertEqual(f.folded(f.state(5).folding(atCaret: f.end(5), in: f.a)!), [1, 5], "Plan is folded, so the next enclosing region folds")
        XCTAssertEqual(f.folded(f.state(11).folding(atCaret: f.end(11), in: f.a)!), [9, 11])
    }

    func testFoldAtTheCaretWithNothingToDo() throws {
        XCTAssertNil(FoldState().folding(atCaret: 0, in: MarkdownAnalyzer.analyze("just text\n\nmore")))
        XCTAssertNil(FoldState().folding(atCaret: 3, in: MarkdownAnalyzer.analyze("")))
        let f = try F()
        XCTAssertNil(f.state(1).folding(atCaret: f.end(1), in: f.a), "the only region around the caret is already folded")
        XCTAssertNil(FoldState().folding(atCaret: f.text.utf16.count, in: MarkdownAnalyzer.analyze("# Empty\n")), "a heading with nothing under it")
    }

    func testUnfoldAtTheCaretOpensTheFoldedRegionWhoseHeaderHoldsTheCaret() throws {
        let f = try F()
        let s = f.state(1, 5, 9)
        XCTAssertEqual(f.folded(s.unfolding(atCaret: f.end(1), in: f.a)!), [5, 9], "Project opens, Plan stays folded inside it (R6)")
        XCTAssertEqual(f.folded(f.state(5).unfolding(atCaret: f.start(5), in: f.a)!), [])
        XCTAssertEqual(f.folded(f.state(5).unfolding(atCaret: f.end(5), in: f.a)!), [])
        XCTAssertNil(f.state(5).unfolding(atCaret: f.end(20), in: f.a), "caret on another header")
        XCTAssertNil(FoldState().unfolding(atCaret: f.end(5), in: f.a), "nothing is folded")
        XCTAssertNil(f.state(9).unfolding(atCaret: f.end(5), in: f.a), "an unfolded header with a folded region inside")
    }

    func testFoldAllAndUnfoldAll() throws {
        let f = try F()
        let all = FoldState().foldingAll(in: f.a)
        XCTAssertEqual(f.folded(all), [1, 5, 9, 11, 20, 26, 28, 35], "headings and items")
        XCTAssertEqual(all.hiddenLineRanges(in: f.a), [1...35])
        XCTAssertEqual(all.foldingAll(in: f.a), all)
        XCTAssertEqual(all.unfoldingAll(), FoldState())
        XCTAssertEqual(FoldState().unfoldingAll(), FoldState())
        XCTAssertEqual(FoldState().foldingAll(in: MarkdownAnalyzer.analyze("plain text")), FoldState())
    }

    func testFoldToLevelTouchesHeadingsOnly() throws {
        let f = try F()
        // Heading regions: Project (1), Plan (2), Tasks (3), Notes (2), Last (2). Items: 11, 26, 28.
        XCTAssertEqual(f.folded(FoldState().folding(toLevel: 2, in: f.a)), [5, 9, 20, 35], "H2 and deeper fold, H1 stays open, items are left alone")
        XCTAssertEqual(f.folded(FoldState().folding(toLevel: 1, in: f.a)), [1, 5, 9, 20, 35])
        XCTAssertEqual(f.folded(FoldState().folding(toLevel: 3, in: f.a)), [9])
        XCTAssertEqual(f.folded(FoldState().folding(toLevel: 6, in: f.a)), [])
        // From everything folded: shallower headings open, list items keep their state.
        let all = FoldState().foldingAll(in: f.a)
        XCTAssertEqual(f.folded(all.folding(toLevel: 2, in: f.a)), [5, 9, 11, 20, 26, 28, 35])
        XCTAssertEqual(f.folded(all.folding(toLevel: 3, in: f.a)), [9, 11, 26, 28])
        // From a state with the item Write spec folded and Project folded.
        XCTAssertEqual(f.folded(f.state(1, 11).folding(toLevel: 3, in: f.a)), [9, 11])
        XCTAssertEqual(f.folded(f.state(11).folding(toLevel: 2, in: f.a)), [5, 9, 11, 20, 35])
    }

    func testRevealOpensTheFoldsHidingTheStartOfTheRangeOutermostFirst() throws {
        let f = try F()
        let state = f.state(1, 5, 9, 20)
        // "Write spec" is hidden by Project, Plan and Tasks; Notes does not hide it.
        let target = NSRange(location: f.offset(of: "Write spec"), length: 10)
        XCTAssertEqual(f.folded(state.revealing(target, in: f.a)), [20], "folds that do not hide it stay")
        // An inner fold only: just that one opens.
        XCTAssertEqual(f.folded(f.state(9, 20).revealing(target, in: f.a)), [20])
        XCTAssertEqual(f.folded(f.state(1, 5, 9).revealing(NSRange(location: f.offset(of: "Plan text."), length: 4), in: f.a)), [9], "Tasks does not hide Plan text")
        // Visible start: nothing changes, even when the range runs into hidden text (Select All, R17).
        XCTAssertEqual(state.revealing(NSRange(location: 0, length: f.text.utf16.count), in: f.a), state)
        XCTAssertEqual(state.revealing(NSRange(location: f.end(1), length: 0), in: f.a), state)
        XCTAssertEqual(FoldState().revealing(target, in: f.a), FoldState())
        // A match inside a folded item inside a folded heading.
        XCTAssertEqual(f.folded(f.state(20, 26).revealing(NSRange(location: f.offset(of: "Milk"), length: 4), in: f.a)), [])
    }

    // MARK: Caret helpers (R13, R14, R16)

    func testHeaderEndIsTheEndOfTheHeadersLastLineContent() throws {
        let f = try F()
        XCTAssertEqual(FoldState().headerEnd(of: f.region(5), in: f.a), f.end(5))
        XCTAssertEqual(FoldState().headerEnd(of: f.region(11), in: f.a), f.end(11))
        let wrapped = MarkdownAnalyzer.analyze("- first line\n  wrapped line\n  - nested")
        XCTAssertEqual(FoldState().headerEnd(of: wrapped.foldRegions[0], in: wrapped), "- first line\n  wrapped line".utf16.count, "an item header's last wrapped line")
        let setext = MarkdownAnalyzer.analyze("Title\n=====\ntext")
        XCTAssertEqual(FoldState().headerEnd(of: setext.foldRegions[0], in: setext), "Title\n=====".utf16.count, "a setext header ends after its underline")
    }

    func testVisibleOffsetLeavesVisiblePositionsAlone() throws {
        let f = try F()
        let s = f.state(5)
        for offset in [0, f.end(1), f.start(5), f.end(5), f.start(20), f.offset(of: "Intro"), f.text.utf16.count] {
            XCTAssertEqual(s.visibleOffset(from: offset, forward: true, in: f.a), offset)
            XCTAssertEqual(s.visibleOffset(from: offset, forward: false, in: f.a), offset)
        }
        XCTAssertEqual(FoldState().visibleOffset(from: f.offset(of: "Plan text."), forward: true, in: f.a), f.offset(of: "Plan text."))
    }

    func testVisibleOffsetStepsOverAFoldInTheDirectionOfTravel() throws {
        let f = try F()
        let plan = f.state(5)
        let inside = f.offset(of: "Plan text.")
        XCTAssertEqual(plan.visibleOffset(from: inside, forward: true, in: f.a), f.start(20), "down/right lands on the next visible line")
        XCTAssertEqual(plan.visibleOffset(from: inside, forward: false, in: f.a), f.end(5), "up/left lands on the end of the header")
        let first = f.region(5).hiddenRange.location        // where → from the end of the header lands
        XCTAssertEqual(plan.visibleOffset(from: first, forward: true, in: f.a), f.start(20))
        XCTAssertEqual(plan.visibleOffset(from: first, forward: false, in: f.a), f.end(5))
        let lastHidden = NSMaxRange(f.region(5).hiddenRange) - 1       // where ← from the start of ## Notes lands
        XCTAssertEqual(plan.visibleOffset(from: lastHidden, forward: false, in: f.a), f.end(5))
        XCTAssertEqual(f.state(20).visibleOffset(from: f.offset(of: "graph TD"), forward: true, in: f.a), f.start(33))
        XCTAssertEqual(f.state(20).visibleOffset(from: f.offset(of: "graph TD"), forward: false, in: f.a), f.end(20))
        XCTAssertEqual(f.state(11).visibleOffset(from: f.offset(of: "Draft"), forward: true, in: f.a), f.start(14), "an item fold: the next sibling")
        XCTAssertEqual(f.state(11).visibleOffset(from: f.offset(of: "Draft"), forward: false, in: f.a), f.end(11))
    }

    func testVisibleOffsetUsesTheOutermostFold() throws {
        let f = try F()
        // Plan is inside Project: both fold, Project hides everything after its header, including the end of the document.
        let nested = f.state(1, 5)
        let inside = f.offset(of: "Plan text.")
        XCTAssertEqual(nested.visibleOffset(from: inside, forward: false, in: f.a), f.end(1))
        XCTAssertEqual(nested.visibleOffset(from: inside, forward: true, in: f.a), f.end(1), "nothing is visible after it, so it stays on the header")
        // An inner fold under an outer one that is open: only the inner one matters.
        XCTAssertEqual(f.state(9).visibleOffset(from: f.offset(of: "Write spec"), forward: true, in: f.a), f.start(20))
    }

    func testVisibleOffsetAtTheHiddenEndOfTheDocument() throws {
        let f = try F()
        let last = f.state(35)
        let end = f.text.utf16.count
        XCTAssertEqual(last.visibleOffset(from: end, forward: true, in: f.a), f.end(35), "⌘↓ goes to the end of the header of the fold hiding the end")
        XCTAssertEqual(last.visibleOffset(from: end, forward: false, in: f.a), f.end(35))
        XCTAssertEqual(last.visibleOffset(from: f.start(36), forward: true, in: f.a), f.end(35))
        // The whole document folded under the first heading.
        XCTAssertEqual(f.state(1, 35).visibleOffset(from: end, forward: true, in: f.a), f.end(1), "the outermost fold hiding the end")
        // With a trailing newline the empty last line hides with its section.
        let s = "# A\ntext\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(FoldState().toggled(a.foldRegions[0]).visibleOffset(from: s.utf16.count, forward: true, in: a), 3)
        // An item at the end whose trailing empty line stays visible.
        let item = "- a\n  - b\n"
        let ia = MarkdownAnalyzer.analyze(item)
        XCTAssertEqual(FoldState().toggled(ia.foldRegions[0]).visibleOffset(from: 7, forward: true, in: ia), item.utf16.count, "forward lands on the visible empty last line")
        XCTAssertEqual(FoldState().toggled(ia.foldRegions[0]).visibleOffset(from: 7, forward: false, in: ia), 3)
    }

    func testHeaderFoldFindsTheFoldedRegionWhoseHeaderHoldsTheOffset() throws {
        let f = try F()
        let plan = f.state(5)
        XCTAssertEqual(plan.headerFold(containing: f.start(5), in: f.a), f.region(5))
        XCTAssertEqual(plan.headerFold(containing: f.start(5) + 3, in: f.a), f.region(5))
        XCTAssertEqual(plan.headerFold(containing: f.end(5), in: f.a), f.region(5), "at the end of the header, where Return opens the fold")
        XCTAssertNil(plan.headerFold(containing: f.start(20), in: f.a))
        XCTAssertNil(plan.headerFold(containing: f.start(3), in: f.a))
        XCTAssertNil(FoldState().headerFold(containing: f.start(5), in: f.a), "an unfolded header")
        // A wrapped item header spans two lines.
        let s = "- first line\n  wrapped line\n  - nested"
        let a = MarkdownAnalyzer.analyze(s)
        let folded = FoldState().toggled(a.foldRegions[0])
        XCTAssertNotNil(folded.headerFold(containing: 2, in: a))
        XCTAssertNotNil(folded.headerFold(containing: s.firstIndex(of: "w").map { s.utf16.distance(from: s.utf16.startIndex, to: $0) }!, in: a))
    }

    func testOutermostFoldEndingAtAnOffset() throws {
        let f = try F()
        // Plan and Tasks both end where ## Notes starts; the outermost is Plan.
        XCTAssertEqual(f.state(5, 9).outermostFold(endingAt: f.start(20), in: f.a), f.region(5))
        XCTAssertEqual(f.state(9).outermostFold(endingAt: f.start(20), in: f.a), f.region(9))
        XCTAssertEqual(f.state(11).outermostFold(endingAt: f.start(14), in: f.a), f.region(11), "an item fold ends at the next sibling")
        XCTAssertNil(f.state(5).outermostFold(endingAt: f.start(21), in: f.a))
        XCTAssertNil(FoldState().outermostFold(endingAt: f.start(20), in: f.a))
        XCTAssertNil(f.state(5).outermostFold(endingAt: f.end(5), in: f.a), "the end of the header is not where a fold ends")
    }

    func testStateIsPlainValueData() throws {
        let f = try F()
        let a = f.state(5, 20), b = f.state(20, 5)
        XCTAssertEqual(a, b, "the order of toggling does not matter")
        XCTAssertEqual(a.anchors, [f.region(5).anchor, f.region(20).anchor])
        XCTAssertEqual(FoldState(anchors: [7]).anchors, [7])
    }

    // MARK: Table cells

    func testTableCellAnalysisHasNoFoldRegions() {
        XCTAssertTrue(MarkdownAnalyzer.analyzeTableCell("# not a heading\n- nor an item").foldRegions.isEmpty)
    }
}
