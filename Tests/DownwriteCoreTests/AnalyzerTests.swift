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

    // MARK: Task checkboxes

    private func hiddenTexts(_ s: String, _ a: MarkdownAnalysis, caret: Int, length: Int = 0) -> [String] {
        a.hiddenMarkerIndices(selection: NSRange(location: caret, length: length)).sorted().map { ns(s, a.markers[$0].range) }
    }

    func testBulletTaskPrefixIsOneMarker() {
        let s = "- [ ] todo\n  - [x] nested done\n1. [ ] numbered\nplain\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.taskBoxes.count, 3)
        XCTAssertEqual(a.taskBoxes[0].prefix.map { ns(s, $0) }, "- [ ] ")
        XCTAssertEqual(a.taskBoxes[1].prefix.map { ns(s, $0) }, "- [x] ")
        XCTAssertEqual(a.taskBoxes[1].prefix?.location, (s as NSString).range(of: "- [x]").location)
        XCTAssertNil(a.taskBoxes[2].prefix, "numbered tasks keep their number and the raw box")
        let prefixes = a.markers.filter { $0.flags.contains(.taskPrefix) }.map { ns(s, $0.range) }
        XCTAssertEqual(prefixes, ["- [ ] ", "- [x] "])
    }

    func testTaskPrefixShowsOnlyWhileTheCaretIsInsideIt() {
        let s = "intro\n- [ ] todo\nafter\n"
        let a = MarkdownAnalyzer.analyze(s)
        let start = (s as NSString).range(of: "- [ ] ").location
        let textStart = start + 6
        XCTAssertEqual(hiddenTexts(s, a, caret: 0), ["- [ ] "], "hidden while the caret is elsewhere")
        XCTAssertEqual(hiddenTexts(s, a, caret: start), ["- [ ] "], "hidden with the caret at the very start of the item")
        XCTAssertEqual(hiddenTexts(s, a, caret: textStart), ["- [ ] "], "hidden with the caret where the item's text starts, i.e. where you type")
        XCTAssertEqual(hiddenTexts(s, a, caret: textStart + 2), ["- [ ] "])
        for inside in (start + 1)...(textStart - 1) {
            XCTAssertEqual(hiddenTexts(s, a, caret: inside), [], "revealed with the caret at \(inside - start) inside the prefix")
        }
        XCTAssertEqual(hiddenTexts(s, a, caret: start - 2, length: 5), [], "a selection reaching into the prefix reveals it")
        XCTAssertEqual(hiddenTexts(s, a, caret: 0, length: s.utf16.count), [], "select-all reveals it")
    }

    func testTaskPrefixWithoutTrailingText() {
        let s = "- [ ] \n- [x]\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.taskBoxes.compactMap { $0.prefix.map { ns(s, $0) } }.first, "- [ ] ")
        XCTAssertFalse(a.markers.isEmpty)
    }

    func testTaskBoxOnLine() {
        let s = "intro\n\n- [ ] one\n- plain\n- [x] two\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertNil(a.taskBox(onLine: 0))
        XCTAssertEqual(a.taskBox(onLine: 2)?.checked, false)
        XCTAssertNil(a.taskBox(onLine: 3))
        XCTAssertEqual(a.taskBox(onLine: 4)?.checked, true)
        XCTAssertNil(a.taskBox(onLine: 99))
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

    // MARK: HTML blocks as previews

    func testReadmeStyleHtmlBlockBecomesPreviewBlock() {
        let s = "# Title\n\n<p align=\"center\">\n  <img src=\"a.png\" width=\"48%\">\n  <img src=\"b.png\" width=\"48%\">\n</p>\n\nAfter\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.htmlBlocks.count, 1)
        let b = a.htmlBlocks[0]
        XCTAssertEqual(b.firstLine, 2)
        XCTAssertEqual(b.lastLine, 5)
        XCTAssertEqual(b.source, "<p align=\"center\">\n  <img src=\"a.png\" width=\"48%\">\n  <img src=\"b.png\" width=\"48%\">\n</p>")
        XCTAssertEqual(ns(s, b.range), b.source)
        XCTAssertEqual(a.previewBlocks.count, 1)
        XCTAssertEqual(a.previewBlocks[0].kind, .html(source: b.source))
        XCTAssertEqual(a.previewBlocks[0].reveal, b.range)
        let extent = a.collapsibleExtent(containingLine: 4)
        XCTAssertEqual(extent?.first, 2)
        XCTAssertEqual(extent?.last, 5)
        XCTAssertNil(a.collapsibleExtent(containingLine: 7))
        // The lines keep their HTML look for when the source is shown.
        XCTAssertEqual((2...5).map { a.lines[$0].kind }, [.html, .html, .html, .html])
    }

    func testHtmlPreviewBlocksSitInDocumentOrderWithMermaidAndImages() {
        let s = "![a](a.png)\n\n<div>one</div>\n\n```mermaid\ngraph TD\n A-->B\n```\n\n<p>two</p>\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.previewBlocks.map(\.firstLine), [0, 2, 4, 9])
        XCTAssertEqual(a.htmlBlocks.map(\.source), ["<div>one</div>", "<p>two</p>"])
    }

    func testHtmlBlocksThatDrawNothingStayPlainSource() {
        let s = "<!-- note -->\n\ntext\n\n</details>\n\n<div align=\"center\">\n\n<script>\nx()\n</script>\n\n<style>\np{}\n</style>\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.htmlBlocks.isEmpty, "\(a.htmlBlocks)")
        XCTAssertTrue(a.previewBlocks.isEmpty)
        XCTAssertEqual(a.lines[0].kind, .html)
        XCTAssertEqual(a.lines[4].kind, .html)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.html) && $0.range.location == 0 })
    }

    func testNestedHtmlBlocksAreNotPreviewed() {
        let s = "> <div>quoted</div>\n\n- item\n\n  <div>in a list</div>\n\n1. x\n   <p>y</p>\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.htmlBlocks.isEmpty, "\(a.htmlBlocks)")
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.html) }, "still styled as HTML source")
    }

    func testHtmlInsideFencedCodeIsNotPreviewed() {
        let s = "```html\n<div>shown as code</div>\n```\n\n    <p>indented code</p>\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.htmlBlocks.isEmpty)
        XCTAssertEqual(a.lines[1].kind, .codeBlock)
    }

    func testHtmlBlockRangesAreUTF16() {
        let s = "😀 é 你好\n\n<div>héllo 😀</div>\n\nend\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.htmlBlocks.count, 1)
        XCTAssertEqual(ns(s, a.htmlBlocks[0].range), "<div>héllo 😀</div>")
        XCTAssertEqual(a.htmlBlocks[0].source, "<div>héllo 😀</div>")
    }

    func testHtmlBlockInterruptingAParagraphAndCRLF() {
        let s = "text\r\n<div>\r\nhi\r\n</div>\r\n\r\nmore\r\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.htmlBlocks.count, 1)
        XCTAssertEqual(a.htmlBlocks[0].firstLine, 1)
        XCTAssertEqual(a.htmlBlocks[0].lastLine, 3)
        XCTAssertEqual(ns(s, a.htmlBlocks[0].range), "<div>\r\nhi\r\n</div>")
    }

    func testHtmlBlockRevealUsesTheWholeBlockInclusive() {
        let s = "intro\n\n<div>\nhi\n</div>\n\noutro\n"
        let a = MarkdownAnalyzer.analyze(s)
        let reveal = a.previewBlocks[0].reveal
        XCTAssertFalse(MarkdownAnalysis.isRevealed(reveal, by: NSRange(location: 4, length: 0)))
        XCTAssertTrue(MarkdownAnalysis.isRevealed(reveal, by: NSRange(location: reveal.location, length: 0)))
        XCTAssertTrue(MarkdownAnalysis.isRevealed(reveal, by: NSRange(location: NSMaxRange(reveal), length: 0)))
        XCTAssertFalse(MarkdownAnalysis.isRevealed(reveal, by: NSRange(location: NSMaxRange(reveal) + 1, length: 0)))
    }

    func testTableCellsNeverGetHtmlBlocks() {
        let a = MarkdownAnalyzer.analyzeTableCell("<div>x</div>")
        XCTAssertTrue(a.htmlBlocks.isEmpty)
    }

    // MARK: Inline HTML tags

    private func flagsRuns(_ s: String, _ a: MarkdownAnalysis, caret: Int? = nil) -> [(String, StyleFlags)] {
        let sel = NSRange(location: caret ?? s.utf16.count, length: 0)
        return a.runs(in: NSRange(location: 0, length: s.utf16.count), selection: sel).map { (ns(s, $0.range), $0.flags) }
    }

    func testInlineTagsAreStyledAndTheirTagsHide() {
        let cases: [(String, StyleFlags)] = [
            ("<b>x</b>", .bold), ("<strong>x</strong>", .bold), ("<i>x</i>", .italic), ("<em>x</em>", .italic),
            ("<s>x</s>", .strike), ("<del>x</del>", .strike), ("<strike>x</strike>", .strike), ("<u>x</u>", .underline),
            ("<ins>x</ins>", .underline), ("<mark>x</mark>", .highlight), ("<code>x</code>", .code), ("<kbd>x</kbd>", .code),
            ("<samp>x</samp>", .code), ("<sub>x</sub>", .sub), ("<sup>x</sup>", .sup),
        ]
        for (tagged, flag) in cases {
            let s = "a \(tagged) b"
            let a = MarkdownAnalyzer.analyze(s)
            XCTAssertEqual(a.markers.count, 2, tagged)
            XCTAssertEqual(markerTexts(s, a).joined().contains("x"), false, tagged)
            let span = a.spans.first { $0.flags.contains(flag) }
            XCTAssertEqual(span.map { ns(s, $0.range) }, "x", tagged)
            XCTAssertFalse(a.spans.contains { $0.flags.contains(.html) }, "\(tagged) is not dim source any more")
            // Caret elsewhere: both tags hidden; caret inside the pair: both shown.
            XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: 0, length: 0)).count, 2, tagged)
            let inside = (s as NSString).range(of: "x").location
            XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: inside, length: 0)).count, 0, tagged)
        }
    }

    func testInlineTagMarkersRevealAtBothEdgesOfThePair() {
        let s = "go <kbd>⌘K</kbd> now"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(markerTexts(s, a), ["<kbd>", "</kbd>"])
        let open = (s as NSString).range(of: "<kbd>"), close = (s as NSString).range(of: "</kbd>")
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: open.location - 1, length: 0)).count, 2)
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: open.location, length: 0)).count, 0)
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: NSMaxRange(close), length: 0)).count, 0)
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: NSMaxRange(close) + 1, length: 0)).count, 2)
    }

    func testInlineTagRunsLookLikeMarkdownEmphasis() {
        let s = "a <b>bold</b> b"
        let runs = flagsRuns(s, MarkdownAnalyzer.analyze(s), caret: 0)
        XCTAssertEqual(runs.map(\.0), ["a ", "<b>", "bold", "</b>", " b"])
        XCTAssertTrue(runs[1].1.contains(.hidden) && runs[1].1.contains(.marker))
        XCTAssertTrue(runs[2].1.contains(.bold) && !runs[2].1.contains(.hidden))
        XCTAssertFalse(runs[2].1.contains(.html))
    }

    func testInlineTagsNestAndMixWithMarkdown() {
        let s = "<b>one <i>two</i> **three**</b> <u>*four*</u>"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(markerTexts(s, a).sorted(), ["*", "*", "**", "**", "</b>", "</i>", "</u>", "<b>", "<i>", "<u>"])
        let runs = flagsRuns(s, a, caret: s.utf16.count)
        let two = runs.first { $0.0 == "two" }!
        XCTAssertTrue(two.1.contains(.bold) && two.1.contains(.italic))
        let four = runs.first { $0.0 == "four" }!
        XCTAssertTrue(four.1.contains(.underline) && four.1.contains(.italic))
    }

    func testTagsAreMatchedCaseInsensitivelyAndByName() {
        let s = "<B>x</b> <i>y</B> <u>z</u>"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.bold) && ns(s, $0.range) == "x" })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.underline) && ns(s, $0.range) == "z" })
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.italic) }, "<i> was never closed by an </i>")
        // The unmatched ones stay visible, in the dim HTML style.
        let dim = a.spans.filter { $0.flags.contains(.html) }.map { ns(s, $0.range) }
        XCTAssertEqual(dim.sorted(), ["</B>", "<i>"])
    }

    func testUnmatchedStrayAndUnsupportedTagsStayDimSource() {
        let s = "<b>never closed, stray </i>, <span style=\"color:red\">span</span>, <br>, <br/>, <font color=red>f</font>"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.markers.isEmpty)
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.bold) })
        let dim = a.spans.filter { $0.flags.contains(.html) }.sorted { $0.range.location < $1.range.location }.map { ns(s, $0.range) }
        XCTAssertEqual(dim, ["<b>", "</i>", "<span style=\"color:red\">", "</span>", "<br>", "<br/>", "<font color=red>", "</font>"])
    }

    func testTagOpenedInsideAPairButNeverClosedStaysSource() {
        let s = "<b>a <i>b</b> c"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.bold) && ns(s, $0.range) == "a <i>b" })
        XCTAssertEqual(a.spans.filter { $0.flags.contains(.html) }.map { ns(s, $0.range) }, ["<i>"])
        XCTAssertEqual(markerTexts(s, a), ["<b>", "</b>"])
    }

    func testTagsDoNotPairAcrossEmphasisOrParagraphs() {
        let s = "<b>a *b</b> c*\n\n<u>next paragraph</u> and <i>one\n\n</i>"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.bold) }, "an <b> outside an emphasis and its </b> inside do not pair")
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.underline) && ns(s, $0.range) == "next paragraph" })
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.italic) && ns(s, $0.range).contains("one") })
    }

    func testAnchorBecomesALink() {
        let s = "see <a href=\"https://example.com/a?x=1&amp;y=2\" title=\"t\">the *docs*</a> now"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.links.count, 1)
        XCTAssertEqual(a.links[0].destination, "https://example.com/a?x=1&y=2")
        XCTAssertEqual(ns(s, a.links[0].textRange), "the *docs*")
        XCTAssertTrue(ns(s, a.links[0].range).hasPrefix("<a href"))
        XCTAssertNotNil(a.link(at: (s as NSString).range(of: "docs").location))
        XCTAssertNil(a.link(at: 1))
        let runs = flagsRuns(s, a, caret: 0)
        XCTAssertTrue(runs.contains { $0.0 == "the " && $0.1.contains(.link) })
        // A named anchor is not a link.
        let b = MarkdownAnalyzer.analyze("<a name=\"top\">x</a> and <a href=\"\">y</a>")
        XCTAssertTrue(b.links.isEmpty)
        XCTAssertTrue(b.markers.isEmpty)
    }

    func testInlineTagOffsetsAreUTF16() {
        let s = "😀 é <sup>你好 😀</sup> **世界**"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.sup) && ns(s, $0.range) == "你好 😀" })
        XCTAssertEqual(markerTexts(s, a), ["<sup>", "</sup>", "**", "**"])
    }

    func testInlineTagsInsideHeadingsListsQuotesAndTablesWork() {
        let s = "# Title <kbd>⌘1</kbd>\n\n- item <b>bold</b>\n\n> quote <i>it</i>\n\n| a | b |\n| - | - |\n| <u>1</u> | 2 |\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.headings[0].plainTitle, "Title ⌘1", "tags are syntax, like **")
        for text in ["⌘1", "bold", "it"] { XCTAssertTrue(a.spans.contains { ns(s, $0.range) == text }, text) }
        // In a source-style table the markers never hide (the columns would shift).
        let tableMarkers = a.markers.filter { ns(s, $0.range) == "<u>" || ns(s, $0.range) == "</u>" }
        XCTAssertEqual(tableMarkers.count, 2)
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: 0, length: 0)).filter { ns(s, a.markers[$0].range) == "<u>" }.count, 0)
    }

    func testTableCellsStyleSupportedTagsButLeaveBrAlone() {
        let a = MarkdownAnalyzer.analyzeTableCell("<b>x</b><br>y")
        XCTAssertEqual(a.markers.count, 2)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.bold) })
        let br = a.spans.filter { $0.flags.contains(.html) }
        XCTAssertEqual(br.count, 1)
        XCTAssertEqual(br[0].range, NSRange(location: 8, length: 4))
        let plain = MarkdownAnalyzer.analyzeTableCell("line one<br>line two")
        XCTAssertTrue(plain.markers.isEmpty)
        XCTAssertEqual(plain.spans.filter { $0.flags.contains(.html) }.count, 1)
    }

    func testInlineTagsAreProtectedFromHighlightAndAutolinks() {
        let s = "<a href=\"https://x.example/==a==\">link</a> and <b title=\"==no==\">b</b>"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.highlight) })
        XCTAssertEqual(a.links.count, 1, "the URL inside the attribute is not turned into a second link")
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
