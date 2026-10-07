import XCTest
@testable import DownwriteCore

final class AnalyzerTests: XCTestCase {
    private func ns(_ s: String, _ r: NSRange) -> String { NSString(string: s).substring(with: r) }
    private func markerTexts(_ s: String, _ a: MarkdownAnalysis) -> [String] { a.markers.map { ns(s, $0.range) } }

    // MARK: Inline

    func testBoldItalicStrikeCodeMarkers() {
        let s = "a **bold** b *it* c ~~gone~~ d `code` e"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(markerTexts(s, a), ["**", "**", "*", "*", "~~", "~~", "`", "`"])
        let bold = a.spans.first { $0.flags.contains(.bold) }!
        XCTAssertEqual(ns(s, bold.range), "**bold**")
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.italic) && ns(s, $0.range) == "*it*" })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.strike) && ns(s, $0.range) == "~~gone~~" })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.code) && ns(s, $0.range) == "`code`" })
    }

    func testUnderscoreEmphasisAndTripleNesting() {
        let s = "_it_ __bold__ ***both***"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.italic) && ns(s, $0.range) == "_it_" })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.bold) && ns(s, $0.range) == "__bold__" })
        // ***both*** = italic + bold, all markers together total 6 chars on the right.
        let runs = a.runs(in: NSRange(location: 0, length: s.utf16.count), selection: NSRange(location: 0, length: 0))
        let both = runs.first { $0.flags.contains(.bold) && $0.flags.contains(.italic) && !$0.flags.contains(.marker) }!
        XCTAssertEqual(ns(s, both.range), "both")
        // Mixed shared delimiter runs must not leak stray asterisks into the styled text.
        for src in ["*a **b***", "***a** b*", "**_x_**", "_**x**_"] {
            let aa = MarkdownAnalyzer.analyze(src)
            let rr = aa.runs(in: NSRange(location: 0, length: src.utf16.count), selection: NSRange(location: 0, length: 0))
            for run in rr where !run.flags.contains(.marker) { XCTAssertFalse(ns(src, run.range).contains("*"), src) }
        }
    }

    func testInlineCodeProtectsContents() {
        let s = "`**not bold**` and `==no==`"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.bold) })
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.highlight) })
    }

    func testDoubleBacktickCode() {
        let s = "x ``a ` b`` y"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(markerTexts(s, a), ["``", "``"])
    }

    func testHighlightFootnoteMath() {
        let s = "This ==marked== text[^1] costs $5 or $x^2$ here.\n\n[^1]: A note.\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.highlight) && ns(s, $0.range) == "==marked==" })
        XCTAssertEqual(markerTexts(s, a).filter { $0 == "==" }.count, 2)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.footnote) && ns(s, $0.range) == "[^1]" })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.footnote) && ns(s, $0.range) == "[^1]:" })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.math) && ns(s, $0.range) == "$x^2$" })
    }

    func testLinkMarkersAndDestination() {
        let s = "See [the docs](https://example.com/a) now"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(markerTexts(s, a), ["[", "](https://example.com/a)"])
        XCTAssertEqual(a.links.count, 1)
        XCTAssertEqual(a.links[0].destination, "https://example.com/a")
        XCTAssertEqual(ns(s, a.links[0].textRange), "the docs")
        XCTAssertNotNil(a.link(at: 8))
        XCTAssertNil(a.link(at: 1))
    }

    func testAngleAutolinkAndReferenceLink() {
        let s = "<https://a.example> and [ref][1]\n\n[1]: https://b.example\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.links.contains { $0.destination == "https://a.example" })
        XCTAssertTrue(a.links.contains { $0.destination == "https://b.example" })
    }

    func testImageOnItsOwnLineGetsPreviewBlock() {
        let s = "text\n\n![A cat](cat.png)\n\ninline ![x](y.png) here\n\n> ![q](q.png)\n\n  ![ok](ok.png)  \n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.imageBlocks.map(\.source), ["cat.png", "ok.png"])
        XCTAssertEqual(a.imageBlocks[0].line, 2)
        XCTAssertEqual(a.imageBlocks[0].alt, "A cat")
        XCTAssertEqual(ns(s, a.imageBlocks[0].range), "![A cat](cat.png)")
    }

    func testPreviewBlocksMergeMermaidAndImagesInOrder() {
        let s = "![a](a.png)\n\n```mermaid\ngraph TD\n A-->B\n```\n\n![b](b.png)\n"
        let a = MarkdownAnalyzer.analyze(s)
        let blocks = a.previewBlocks
        XCTAssertEqual(blocks.map(\.firstLine), [0, 2, 7])
        XCTAssertEqual(blocks[1].lastLine, 5)
        if case .mermaid(let src) = blocks[1].kind { XCTAssertEqual(src, "graph TD\n A-->B") } else { XCTFail("kind") }
        if case .image(let src, let alt) = blocks[2].kind { XCTAssertEqual(src, "b.png"); XCTAssertEqual(alt, "b") } else { XCTFail("kind") }
        XCTAssertEqual(blocks[0].reveal, NSRange(location: 0, length: 11))
    }

    func testBareURLsBecomeLinks() {
        let s = "Visit https://example.com/a?b=1, or www.example.org. Not (https://wrapped.example) nor `https://code.example`."
        let a = MarkdownAnalyzer.analyze(s)
        let dests = a.links.map(\.destination)
        XCTAssertTrue(dests.contains("https://example.com/a?b=1"), "\(dests)")
        XCTAssertTrue(dests.contains("https://www.example.org"), "\(dests)")
        XCTAssertFalse(dests.contains { $0.contains("code.example") })
        // Trailing punctuation is excluded from the link text.
        let first = a.links.first { $0.destination == "https://example.com/a?b=1" }!
        XCTAssertEqual(ns(s, first.range), "https://example.com/a?b=1")
    }

    func testURLInsideExplicitLinkIsNotLinkedTwice() {
        let s = "[https://a.example](https://a.example) and https://b.example"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.links.count, 2)
    }

    func testImage() {
        let s = "![alt text](pic.png)"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.images.count, 1)
        XCTAssertEqual(a.images[0].source, "pic.png")
        XCTAssertEqual(a.images[0].alt, "alt text")
        XCTAssertEqual(markerTexts(s, a), ["![", "](pic.png)"])
    }

    // MARK: Hidden syntax

    func testMarkersHiddenUntilCaretInsidePair() {
        let s = "aa **bold** bb"
        let a = MarkdownAnalyzer.analyze(s)
        let all = NSRange(location: 0, length: s.utf16.count)
        func hiddenCount(_ caret: Int) -> Int {
            a.runs(in: all, selection: NSRange(location: caret, length: 0))
                .filter { $0.flags.contains(.hidden) }.reduce(0) { $0 + $1.range.length }
        }
        XCTAssertEqual(hiddenCount(0), 4)    // caret before: hidden
        XCTAssertEqual(hiddenCount(1), 4)
        XCTAssertEqual(hiddenCount(3), 0)    // caret at start boundary of the pair: revealed
        XCTAssertEqual(hiddenCount(6), 0)    // inside
        XCTAssertEqual(hiddenCount(11), 0)   // at end boundary
        XCTAssertEqual(hiddenCount(13), 4)   // after
    }

    func testNestedMarkersRevealIndependently() {
        let s = "**a *b* c**"
        let a = MarkdownAnalyzer.analyze(s)
        let all = NSRange(location: 0, length: s.utf16.count)
        // Caret in "a": bold markers shown, italic markers hidden.
        let runs = a.runs(in: all, selection: NSRange(location: 3, length: 0))
        let hidden = runs.filter { $0.flags.contains(.hidden) }.map { ns(s, $0.range) }
        XCTAssertEqual(hidden, ["*", "*"])
    }

    func testSelectionRangeRevealsEverythingItTouches() {
        let s = "**a** and **b**"
        let a = MarkdownAnalyzer.analyze(s)
        let hidden = a.hiddenMarkerIndices(selection: NSRange(location: 0, length: s.utf16.count))
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: 7, length: 0)).count, 4)
    }

    func testRunsCoverRangeContiguously() {
        let s = "# T\n\nplain **b** `c` [l](u)\n\n- x\n> q\n"
        let a = MarkdownAnalyzer.analyze(s)
        let r = NSRange(location: 0, length: s.utf16.count)
        let runs = a.runs(in: r, selection: NSRange(location: 0, length: 0))
        var pos = 0
        for run in runs { XCTAssertEqual(run.range.location, pos); pos = NSMaxRange(run.range) }
        XCTAssertEqual(pos, r.length)
        // Sub-range queries are consistent with the full pass.
        let sub = a.runs(in: NSRange(location: 6, length: 10), selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(sub.reduce(0) { $0 + $1.range.length }, 10)
    }

    // MARK: Blocks

    func testHeadingsAtxAndClosing() {
        let s = "# One\n\n## Two ##\n\n###### Six\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.headings.map(\.level), [1, 2, 6])
        XCTAssertEqual(a.headings.map(\.title), ["One", "Two", "Six"])
        XCTAssertEqual(a.lines[0].kind, .heading(1))
        XCTAssertEqual(a.lines[2].kind, .heading(2))
        XCTAssertEqual(markerTexts(s, a), ["# ", "## ", " ##", "###### "])
        // Heading marker reveals when the caret is on its line only.
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: 2, length: 0)).count, 3)
    }

    func testSetextHeading() {
        let s = "Title\n=====\n\nSub\n---\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.headings.map(\.level), [1, 2])
        XCTAssertEqual(a.lines[1].kind, .setextUnderline)
    }

    func testBlockQuoteMarkersAndDepth() {
        let s = "> one\n> > two\n>\n> three\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[0].quoteDepth, 1)
        XCTAssertEqual(a.lines[1].quoteDepth, 2)
        let texts = markerTexts(s, a)
        XCTAssertEqual(texts.filter { $0 == "> " }.count >= 3, true)
        XCTAssertEqual(a.line(at: 100).quoteDepth, 0)
    }

    func testFencedCodeBlock() {
        let s = "text\n\n```swift\nlet x = 1\n**not bold**\n```\n\nafter\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[2].kind, .fence)
        XCTAssertEqual(a.lines[3].kind, .codeBlock)
        XCTAssertEqual(a.lines[4].kind, .codeBlock)
        XCTAssertEqual(a.lines[5].kind, .fence)
        XCTAssertEqual(a.lines[7].kind, .body)
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.bold) })
        XCTAssertEqual(markerTexts(s, a), ["```swift", "```"])
        // Fences stay hidden unless the caret is inside the block.
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: 0, length: 0)).count, 2)
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: 25, length: 0)).count, 0)
    }

    func testUnterminatedFenceAndTildeFence() {
        let s = "~~~\ncode\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[0].kind, .fence)
        XCTAssertEqual(a.lines[1].kind, .codeBlock)
        XCTAssertEqual(markerTexts(s, a), ["~~~"])
    }

    func testIndentedCodeBlock() {
        let s = "para\n\n    indented\n    more\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[2].kind, .codeBlock)
        XCTAssertEqual(a.lines[3].kind, .codeBlock)
        XCTAssertTrue(a.markers.isEmpty)
    }

    func testMermaidBlockDetected() {
        let s = "Intro\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n```js\nx\n```\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.mermaid.count, 1)
        XCTAssertEqual(a.mermaid[0].source, "graph TD\n  A-->B")
        XCTAssertEqual(a.mermaid[0].firstLine, 2)
        XCTAssertEqual(a.mermaid[0].lastLine, 5)
        XCTAssertNotNil(a.mermaidBlock(containing: 20))
        XCTAssertNil(a.mermaidBlock(containing: 2))
    }

    func testThematicBreak() {
        let s = "a\n\n---\n\nb\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[2].kind, .hr)
        XCTAssertEqual(markerTexts(s, a), ["---"])
    }

    func testListsAndTasks() {
        let s = "- one\n  - nested\n1. first\n2) second\n- [ ] todo\n- [x] done\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[0].listPrefixLength, 2)
        XCTAssertEqual(a.lines[1].listPrefixLength, 4)
        XCTAssertEqual(a.lines[1].listDepth, 2)
        XCTAssertEqual(a.lines[2].listPrefixLength, 3)
        XCTAssertEqual(a.taskBoxes.map(\.checked), [false, true])
        XCTAssertEqual(ns(s, a.taskBoxes[0].range), "[ ]")
        XCTAssertEqual(ns(s, a.taskBoxes[1].range), "[x]")
        XCTAssertEqual(a.lines[4].listPrefixLength, 6)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.taskDone) && ns(s, $0.range) == "done" })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.listMarker) && ns(s, $0.range) == "1." })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.bullet) && ns(s, $0.range) == "-" })
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.bullet) && ns(s, $0.range) == "1." })
        XCTAssertNotNil(a.taskBox(at: a.taskBoxes[0].range.location + 1))
    }

    func testTableLinesAndPipes() {
        let s = "| A | B |\n| --- | :-: |\n| 1 | **2** |\n\nafter\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[0].kind, .tableHeader)
        XCTAssertEqual(a.lines[1].kind, .tableDelimiter)
        XCTAssertEqual(a.lines[2].kind, .tableRow)
        XCTAssertEqual(a.lines[4].kind, .body)
        XCTAssertEqual(a.tables.count, 1)
        XCTAssertEqual(a.tables[0].firstLine, 0)
        XCTAssertEqual(a.tables[0].lastLine, 2)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.dim) && ns(s, $0.range) == "|" })
        // Inline formatting inside a body cell is understood, and its markers never hide (columns stay aligned).
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.bold) && ns(s, $0.range) == "**2**" })
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: s.utf16.count - 2, length: 0)).count, 0)
    }

    func testFrontMatter() {
        let s = "---\ntitle: Hello\ntags: [a]\n---\n\n# Body\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[0].kind, .frontMatter)
        XCTAssertEqual(a.lines[3].kind, .frontMatter)
        XCTAssertEqual(a.lines[5].kind, .heading(1))
        XCTAssertEqual(a.headings.count, 1)
        XCTAssertTrue(a.markers.allSatisfy { $0.range.location >= 5 && ns(s, $0.range) == "# " })
    }

    func testHtmlBlockAndInline() {
        let s = "<div>\nhi\n</div>\n\nA <b>tag</b> here\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.lines[0].kind, .html)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.html) })
    }

    // MARK: Robustness

    func testUnicodeOffsetsAreUTF16() {
        let s = "你好 **世界** 😀 *x* é\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(markerTexts(s, a), ["**", "**", "*", "*"])
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.bold) && ns(s, $0.range) == "**世界**" })
    }

    func testCRLFAndCRLineEndings() {
        let s = "# T\r\n\r\n**b**\r\n- x\r\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(markerTexts(s, a), ["# ", "**", "**"])
        XCTAssertEqual(a.lines[3].kind, .body)
        XCTAssertEqual(a.lines[3].listPrefixLength, 2)
    }

    func testEmptyAndWhitespaceDocuments() {
        for s in ["", "\n", "   ", "\n\n\n"] {
            let a = MarkdownAnalyzer.analyze(s)
            XCTAssertTrue(a.runs(in: NSRange(location: 0, length: s.utf16.count), selection: NSRange(location: 0, length: 0))
                .reduce(0) { $0 + $1.range.length } == s.utf16.count)
        }
    }

    func testAdversarialInputsDoNotCrash() {
        let inputs = [
            "**", "* ", "[](", "![]()", "```", "~~~~~", "|", "| a |\n|---|", ">>>>>", "- [", "- [ ]", "1.", "####### x",
            "==", "====", "$$", "$", "[^", "\\", "`", "``", "<", "<!--", "***", "___", "a\u{0}b", "- \n- \n-",
            String(repeating: "*", count: 500), String(repeating: "> ", count: 200) + "x",
            String(repeating: "- ", count: 100) + "x",
        ]
        for s in inputs {
            let a = MarkdownAnalyzer.analyze(s)
            _ = a.runs(in: NSRange(location: 0, length: s.utf16.count), selection: NSRange(location: 0, length: 0))
            for m in a.markers {
                XCTAssertGreaterThanOrEqual(m.range.location, 0, s)
                XCTAssertLessThanOrEqual(NSMaxRange(m.range), s.utf16.count, s)
            }
            for sp in a.spans {
                XCTAssertGreaterThanOrEqual(sp.range.location, 0, s)
                XCTAssertLessThanOrEqual(NSMaxRange(sp.range), s.utf16.count, s)
            }
        }
    }

    func testLargeDocumentPerformance() {
        var s = ""
        for i in 0..<3000 { s += "## Heading \(i)\n\nSome **bold** and *italic* text with a [link](https://x.y/\(i)) and `code`.\n\n- item\n- [ ] task\n\n" }
        let start = Date()
        let a = MarkdownAnalyzer.analyze(s)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(a.headings.count, 2999)
        // ~190 KB; generous bound because this runs in an unoptimised debug build.
        XCTAssertLessThan(elapsed, 4.0, "analysis took \(elapsed)s")
    }
}
