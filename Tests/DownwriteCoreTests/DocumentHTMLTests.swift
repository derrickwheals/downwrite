import XCTest
@testable import DownwriteCore

/// R6 to R13: what the renderer makes of each Markdown construct. `body` is what `prepare` produces for the page's `<main>`, after the
/// sanitiser, with block boundaries removed.
final class DocumentHTMLTests: XCTestCase {
    private func body(_ markdown: String, target: DocumentHTML.Target = .screen) -> String {
        DocumentHTML.prepare(markdown, options: .init(target: target, documentName: "doc.md")).body
    }

    // MARK: 6a: blocks

    func testParagraphsAndHeadingsOfEveryLevel() {
        XCTAssertEqual(body("one\n\ntwo\n"), "<p>one</p>\n<p>two</p>\n")
        for level in 1...6 {
            XCTAssertEqual(body(String(repeating: "#", count: level) + " Title\n"), "<h\(level) id=\"title\">Title</h\(level)>\n")
        }
    }

    func testSetextAndClosedATXHeadings() {
        XCTAssertEqual(body("Title\n=====\n"), "<h1 id=\"title\">Title</h1>\n")
        XCTAssertEqual(body("Sub\n---\n"), "<h2 id=\"sub\">Sub</h2>\n")
        XCTAssertEqual(body("## Two ##\n"), "<h2 id=\"two\">Two</h2>\n")
    }

    func testHeadingsKeepTheirInlineFormatting() {
        XCTAssertEqual(body("# **Bold** and [a link](https://example.com) and `code`\n"),
                       "<h1 id=\"bold-and-a-linkhttpsexamplecom-and-code\"><strong>Bold</strong> and <a href=\"https://example.com\">a link</a> and <code>code</code></h1>\n")
    }

    func testBlockQuotesNestAndHoldAnyBlock() {
        XCTAssertEqual(body("> quoted\n"), "<blockquote>\n<p>quoted</p>\n</blockquote>\n")
        XCTAssertEqual(body("> a\n>\n> > b\n"), "<blockquote>\n<p>a</p>\n<blockquote>\n<p>b</p>\n</blockquote>\n</blockquote>\n")
        XCTAssertEqual(body("> - item\n> ```\n> code\n> ```\n"), "<blockquote>\n<ul>\n<li>item</li>\n</ul>\n<pre><code>code\n</code></pre>\n</blockquote>\n")
    }

    // MARK: Callouts (DW-006)

    /// The markup of a callout with an empty title line and one body paragraph.
    private func calloutHTML(_ kind: String, _ name: String, title: String = "", blocks: String = "<p>body</p>\n") -> String {
        "<blockquote class=\"callout callout-\(kind)\">\n<p class=\"callout-title\"><span class=\"callout-type\">\(name)</span>"
            + (title.isEmpty ? "" : " " + title) + "</p>\n" + blocks + "</blockquote>\n"
    }

    func testEveryKindIsAClassedQuoteWhoseFirstLineNamesIt() {
        for (marker, kind, name) in [("NOTE", "note", "Note"), ("TIP", "tip", "Tip"), ("IMPORTANT", "important", "Important"),
                                     ("WARNING", "warning", "Warning"), ("CAUTION", "caution", "Caution")] {
            XCTAssertEqual(body("> [!\(marker)]\n> body\n"), calloutHTML(kind, name), marker)
            XCTAssertEqual(body("> [!\(marker.lowercased())]\n> body\n"), calloutHTML(kind, name), "\(marker) in lower case")
        }
        XCTAssertEqual(body("> [!wArNiNg]\n> body\n"), calloutHTML("warning", "Warning"))
    }

    func testTheTitleFollowsTheTypeNameAndAloneItIsACallout() {
        XCTAssertEqual(body("> [!WARNING] Data loss\n> body\n"), calloutHTML("warning", "Warning", title: "Data loss"))
        XCTAssertEqual(body("> [!WARNING] Data loss\n"), calloutHTML("warning", "Warning", title: "Data loss", blocks: ""))
        XCTAssertEqual(body("> [!NOTE]  \t Spaced title \t \n> body\n"), calloutHTML("note", "Note", title: "Spaced title"))
    }

    func testTheTitleKeepsItsInlineFormattingAndIsEscaped() {
        XCTAssertEqual(body("> [!TIP] **Bold** and `code` and [link](https://example.com)\n> body\n"),
                       calloutHTML("tip", "Tip", title: "<strong>Bold</strong> and <code>code</code> and <a href=\"https://example.com\">link</a>"))
        XCTAssertEqual(body("> [!NOTE] a < b & \"c\" <i>x</i>\n> body\n"), calloutHTML("note", "Note", title: "a &lt; b &amp; \"c\" <i>x</i>"))
        XCTAssertEqual(body("> [!NOTE] ==hi== there\n> body\n"), calloutHTML("note", "Note", title: "<mark>hi</mark> there"))
        XCTAssertEqual(body("> [!NOTE] Héllo 😀 wörld\n> body\n"), calloutHTML("note", "Note", title: "Héllo 😀 wörld"))
    }

    func testTheBodyStartsOnTheLineAfterTheMarkerLine() {
        XCTAssertEqual(body("> [!NOTE]\n> line one\n> line two\n"), calloutHTML("note", "Note", blocks: "<p>line one\nline two</p>\n"))
        XCTAssertEqual(body("> [!NOTE] T\n> line one\n> line two\n"), calloutHTML("note", "Note", title: "T", blocks: "<p>line one\nline two</p>\n"))
        XCTAssertEqual(body("> [!NOTE]\nlazy line\n"), calloutHTML("note", "Note", blocks: "<p>lazy line</p>\n"))
        XCTAssertEqual(body(">\n> [!NOTE]\n> body\n"), calloutHTML("note", "Note"), "a blank quote line before the marker")
        XCTAssertEqual(body("   > [!NOTE]\n   > body\n"), calloutHTML("note", "Note"))
    }

    /// Two trailing spaces after the marker line are a hard break in cmark's tree; the export must not show it as a `<br />`.
    func testNoLineBreakAppearsAfterTheMarkerLine() {
        XCTAssertEqual(body("> [!NOTE]  \n> body\n"), calloutHTML("note", "Note"))
        XCTAssertEqual(body("> [!NOTE] My title   \n> body\n"), calloutHTML("note", "Note", title: "My title"))
        XCTAssertEqual(body("> [!NOTE]\n> a  \n> b\n"), calloutHTML("note", "Note", blocks: "<p>a<br />\nb</p>\n"), "later breaks are kept")
    }

    func testOtherBlocksFollowTheTitleLine() {
        XCTAssertEqual(body("> [!NOTE]\n> text\n>\n> - item\n>\n> ```\n> code\n> ```\n"),
                       calloutHTML("note", "Note", blocks: "<p>text</p>\n<ul>\n<li>item</li>\n</ul>\n<pre><code>code\n</code></pre>\n"))
        XCTAssertEqual(body("> [!NOTE]\n> - one\n> - two\n"), calloutHTML("note", "Note", blocks: "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n"))
        XCTAssertEqual(body("> [!NOTE]\n> a\n>\n> b\n"), calloutHTML("note", "Note", blocks: "<p>a</p>\n<p>b</p>\n"))
        XCTAssertEqual(body("> [!NOTE]\n> body\n>\n> > inner\n"),
                       calloutHTML("note", "Note", blocks: "<p>body</p>\n<blockquote>\n<p>inner</p>\n</blockquote>\n"), "a plain quote inside a callout")
        XCTAssertEqual(body("> [!NOTE]\n> [!TIP]\n> body\n"), calloutHTML("note", "Note", blocks: "<p>[!TIP]\nbody</p>\n"), "a second marker is text")
    }

    func testAHeadingInsideACalloutKeepsItsPlaceInTheNumbering() {
        let out = body("# A\n\n> [!NOTE]\n> ## Inside\n\n# B\n")
        XCTAssertTrue(out.contains("<h1 id=\"a\">A</h1>"), out)
        XCTAssertTrue(out.contains("<h2 id=\""), out)
        XCTAssertTrue(out.contains("<h1 id=\"b\">B</h1>"), "the heading after the callout still gets its own id: \(out)")
        XCTAssertTrue(body("> [!NOTE]\n> # H\n>\n> text\n").contains("<div class=\"keep\">\n<h1 id="), "a heading run is still kept with the block after it")
    }

    /// The edge D8 leaves alone: an inline element that spans the marker line and the next one cannot be split.
    func testAnInlineElementSpanningTheMarkerLineStaysWhole() {
        XCTAssertEqual(body("> [!NOTE] **a\n> b**\n"),
                       "<blockquote class=\"callout callout-note\">\n<p class=\"callout-title\"><span class=\"callout-type\">Note</span> <strong>a\nb</strong></p>\n</blockquote>\n")
    }

    /// A table right below the marker splits the first paragraph off without a source range; it is still a callout, in the export too.
    func testACalloutWhoseBodyIsATableIsStillACallout() {
        for text in ["> [!NOTE]\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n", "> [!NOTE]\r\n> | a | b |\r\n> |---|---|\r\n> | 1 | 2 |\r\n"] {
            let out = body(text)
            XCTAssertTrue(out.hasPrefix("<blockquote class=\"callout callout-note\">\n<p class=\"callout-title\"><span class=\"callout-type\">Note</span></p>\n"), out)
            XCTAssertTrue(out.contains("<table") && out.hasSuffix("</table></div>\n</blockquote>\n"), out)
            XCTAssertFalse(out.contains("[!"), "the marker text is gone: \(out)")
        }
        let titled = body("> [!NOTE] with a title\n> | a | b |\n> |---|---|\n")
        XCTAssertTrue(titled.contains("<span class=\"callout-type\">Note</span> with a title</p>"), titled)
        XCTAssertEqual(body("> intro\n> | a | b |\n> |---|---|\n").hasPrefix("<blockquote>\n"), true, "a quote that is not a callout is unchanged")
    }

    func testPlainQuotesAreUnchanged() {
        XCTAssertEqual(body("> [!INFO]\n> body\n"), "<blockquote>\n<p>[!INFO]\nbody</p>\n</blockquote>\n")
        XCTAssertEqual(body("> [!NOTE]\n"), "<blockquote>\n<p>[!NOTE]</p>\n</blockquote>\n")
        XCTAssertEqual(body("> [!NOTE]\n>\n"), "<blockquote>\n<p>[!NOTE]</p>\n</blockquote>\n")
        XCTAssertEqual(body("> [!NOTE]+\n> body\n"), "<blockquote>\n<p>[!NOTE]+\nbody</p>\n</blockquote>\n")
        XCTAssertEqual(body("> hello\n> [!NOTE]\n> body\n"), "<blockquote>\n<p>hello\n[!NOTE]\nbody</p>\n</blockquote>\n")
        XCTAssertEqual(body("> **[!NOTE]**\n> body\n"), "<blockquote>\n<p><strong>[!NOTE]</strong>\nbody</p>\n</blockquote>\n")
    }

    func testQuotesNestedInOtherBlocksAreNeverCallouts() {
        for text in ["- item\n  > [!NOTE]\n  > body\n", "> > [!NOTE]\n> > body\n", "1. one\n\n   > [!NOTE]\n   > body\n"] {
            let out = body(text)
            XCTAssertFalse(out.contains("callout"), text.debugDescription)
            XCTAssertTrue(out.contains("[!NOTE]"), "the literal text stays for a quote that is not a callout: \(text.debugDescription)")
        }
    }

    func testAReferenceDefinitionMakesTheMarkerALinkSoTheQuoteStaysPlain() {
        let out = body("> [!NOTE]\n> body\n\n[!note]: https://example.com\n")
        XCTAssertFalse(out.contains("callout"), out)
    }

    func testCalloutsSurviveFrontMatterFootnoteDefinitionsAndCRLF() {
        XCTAssertEqual(body("---\ntitle: x\n---\n\n> [!TIP] t\n> body\n"), calloutHTML("tip", "Tip", title: "t"))
        XCTAssertEqual(body("[^1]: a footnote\n\n> [!TIP] t\n> body\n"), "<p>[^1]: a footnote</p>\n" + calloutHTML("tip", "Tip", title: "t"))
        XCTAssertEqual(body("> [!TIP] t\r\n> body\r\n"), calloutHTML("tip", "Tip", title: "t"))
        XCTAssertEqual(body("> [!NOTE]  \r\n> body\r\n"), calloutHTML("note", "Note"))
    }

    func testSeveralCalloutsAndQuotesKeepTheirOrder() {
        let out = body("> [!NOTE]\n> a\n\n> plain\n\n> [!CAUTION] c\n> b\n")
        XCTAssertEqual(out, calloutHTML("note", "Note", blocks: "<p>a</p>\n") + "<blockquote>\n<p>plain</p>\n</blockquote>\n"
                       + calloutHTML("caution", "Caution", title: "c", blocks: "<p>b</p>\n"))
    }

    func testTheReservedCharactersCannotComeOutOfACalloutTitle() {
        let out = body("> [!NOTE] a\u{E000}b\u{E001}c\u{E002}d\n> body\n")
        XCTAssertFalse(out.unicodeScalars.contains { (0xE000...0xE002).contains($0.value) }, out.debugDescription)
        XCTAssertTrue(out.contains("a&#xE000;b&#xE001;c&#xE002;d"), out.debugDescription)
    }

    func testRawHTMLInATitleIsSanitisedLikeAnywhereElse() {
        let script = body("> [!NOTE] <script>alert(1)</script> x\n> body\n")
        XCTAssertFalse(script.contains("<script") || script.contains("alert(1)"), script)
        XCTAssertTrue(script.contains("callout-note"), script)
        let image = body("> [!NOTE] <img src=\"x.png\" onerror=\"alert(1)\">\n> body\n")
        XCTAssertFalse(image.contains("onerror"), image)
        let link = body("> [!NOTE] [x](javascript:alert(1))\n> body\n")
        XCTAssertFalse(link.contains("javascript"), link)
    }

    func testThematicBreaks() {
        XCTAssertEqual(body("a\n\n***\n\nb\n"), "<p>a</p>\n<hr />\n<p>b</p>\n")
        XCTAssertEqual(body("a\n\n- - -\n\nb\n"), "<p>a</p>\n<hr />\n<p>b</p>\n")
    }

    func testAnEmptyDocumentHasAnEmptyBody() {
        XCTAssertEqual(body(""), "")
        XCTAssertEqual(body("   \n\n"), "")
    }

    // MARK: 6a: inline formatting and escaping

    func testInlineFormatting() {
        XCTAssertEqual(body("*em* **strong** ***both*** ~~gone~~ `code`\n"),
                       "<p><em>em</em> <strong>strong</strong> <em><strong>both</strong></em> <del>gone</del> <code>code</code></p>\n")
        XCTAssertEqual(body("_em_ __strong__\n"), "<p><em>em</em> <strong>strong</strong></p>\n")
        XCTAssertEqual(body("``double `tick` code``\n"), "<p><code>double `tick` code</code></p>\n")
    }

    func testDocumentTextIsEscaped() {
        XCTAssertEqual(body("a < b & c > d \"q\" 'r'\n"), "<p>a &lt; b &amp; c &gt; d \"q\" 'r'</p>\n")
        XCTAssertEqual(body("`<b>&amp;</b>`\n"), "<p><code>&lt;b&gt;&amp;amp;&lt;/b&gt;</code></p>\n")
        XCTAssertEqual(body("&copy; &lt;script&gt; &#65;\n"), "<p>© &lt;script&gt; A</p>\n")
        XCTAssertEqual(body("\\<script\\>alert(1)\\</script\\>\n"), "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n")
    }

    func testTextIsShownAsTypedWithNoSmartPunctuation() {
        XCTAssertEqual(body("\"straight quotes\" -- ... 'single' don't\n"), "<p>\"straight quotes\" -- ... 'single' don't</p>\n")
    }

    func testHardBreaksAreBreaksAndSoftBreaksAreSpaces() {
        XCTAssertEqual(body("a  \nb\nc\\\nd\n"), "<p>a<br />\nb\nc<br />\nd</p>\n")
    }

    func testTheSentinelCharactersCannotBeForgedByADocument() {
        let sneaky = "text \u{E000}D1\u{E001} and \u{E002} here\n"
        let html = body(sneaky)
        XCTAssertEqual(html, "<p>text &#xE000;D1&#xE001; and &#xE002; here</p>\n")
        XCTAssertEqual(DocumentHTML.prepare(sneaky, options: .init(target: .screen, documentName: "")).diagrams, [])
    }

    // MARK: 6a: front matter

    func testFrontMatterIsLeftOut() {
        let md = "---\ntitle: Secret front matter\ntags: [a]\n---\n\n# Body\n\ntext\n"
        XCTAssertEqual(body(md), "<div class=\"keep\">\n<h1 id=\"body\">Body</h1>\n<p>text</p>\n</div>\n")
        XCTAssertFalse(body(md).contains("Secret"))
        XCTAssertEqual(body("---\na: b\n...\nafter\n"), "<p>after</p>\n")
        XCTAssertEqual(body("---\nonly: front matter\n---\n"), "")
    }

    func testAThematicBreakAtTheTopWithoutAClosingLineIsNotFrontMatter() {
        XCTAssertEqual(body("---\n\ntext\n"), "<hr />\n<p>text</p>\n")
    }

    // MARK: 6a: a heading stays with the block after it (R19)

    func testAHeadingIsWrappedWithTheBlockThatFollowsIt() {
        XCTAssertEqual(body("# T\n\ntext\n\nmore\n"), "<div class=\"keep\">\n<h1 id=\"t\">T</h1>\n<p>text</p>\n</div>\n<p>more</p>\n")
        XCTAssertEqual(body("## T\n\n- a\n- b\n"), "<div class=\"keep\">\n<h2 id=\"t\">T</h2>\n<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n</div>\n")
        XCTAssertEqual(body("## T\n\n```\ncode\n```\n"), "<div class=\"keep\">\n<h2 id=\"t\">T</h2>\n<pre><code>code\n</code></pre>\n</div>\n")
    }

    func testAHeadingFollowedByAHeadingKeepsTheWholeRunTogether() {
        XCTAssertEqual(body("# A\n## B\n\ntext\n"), "<div class=\"keep\">\n<h1 id=\"a\">A</h1>\n<h2 id=\"b\">B</h2>\n<p>text</p>\n</div>\n")
    }

    func testAHeadingAtTheEndOfAContainerOrBeforeRawHTMLIsNotWrapped() {
        XCTAssertEqual(body("text\n\n# End\n"), "<p>text</p>\n<h1 id=\"end\">End</h1>\n")
        XCTAssertEqual(body("# T\n\n<details>\n\ntext\n\n</details>\n"), "<h1 id=\"t\">T</h1>\n<details>\n<p>text</p>\n</details>\n")
    }

    func testHeadingsInsideQuotesAreKeptWithTheirBlockToo() {
        XCTAssertEqual(body("> # Q\n>\n> text\n"), "<blockquote>\n<div class=\"keep\">\n<h1 id=\"--q\">Q</h1>\n<p>text</p>\n</div>\n</blockquote>\n")
    }

    // MARK: 6b: lists

    func testBulletedAndNumberedLists() {
        XCTAssertEqual(body("- a\n- b\n"), "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
        XCTAssertEqual(body("1. a\n2. b\n"), "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n")
    }

    func testANumberedListKeepsItsStartNumber() {
        XCTAssertEqual(body("3. a\n4. b\n"), "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>\n")
        XCTAssertEqual(body("0. zero\n"), "<ol start=\"0\">\n<li>zero</li>\n</ol>\n")
    }

    func testListsNestToAnyDepthAndMixKinds() {
        XCTAssertEqual(body("- one\n  1. two\n     - three\n"),
                       "<ul>\n<li>one\n<ol>\n<li>two\n<ul>\n<li>three</li>\n</ul>\n</li>\n</ol>\n</li>\n</ul>\n")
    }

    func testTightAndLooseListsFollowCommonMark() {
        XCTAssertEqual(body("- a\n\n- b\n"), "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n", "a blank line between items")
        XCTAssertEqual(body("- a\n\n  more\n- b\n"), "<ul>\n<li>\n<p>a</p>\n<p>more</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n", "a blank line inside an item")
        XCTAssertEqual(body("- a\n  - x\n\n  - y\n- b\n"),
                       "<ul>\n<li>a\n<ul>\n<li>\n<p>x</p>\n</li>\n<li>\n<p>y</p>\n</li>\n</ul>\n</li>\n<li>b</li>\n</ul>\n",
                       "a loose inner list does not make the outer one loose")
        XCTAssertEqual(body("1. a\n2. b\n\ntext\n"), "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n<p>text</p>\n", "a blank line after the last item")
    }

    func testAListItemMayHoldCodeAndQuotes() {
        XCTAssertEqual(body("- item\n\n  ```\n  code\n  ```\n"), "<ul>\n<li>\n<p>item</p>\n<pre><code>code\n</code></pre>\n</li>\n</ul>\n")
    }

    // MARK: 6b: task items (R8)

    func testBulletedTaskItems() {
        XCTAssertEqual(body("- [ ] todo\n- [x] done\n- [X] also\n"),
                       "<ul>\n<li class=\"task\"><span class=\"box\"></span><span class=\"t\">todo</span></li>\n"
                       + "<li class=\"task done\"><span class=\"box\"></span><span class=\"t\">done</span></li>\n"
                       + "<li class=\"task done\"><span class=\"box\"></span><span class=\"t\">also</span></li>\n</ul>\n")
    }

    func testNumberedTaskItemsKeepTheirNumberAndGetABox() {
        XCTAssertEqual(body("1. [ ] one\n2. [x] two\n"),
                       "<ol>\n<li class=\"task\"><span class=\"box\"></span><span class=\"t\">one</span></li>\n"
                       + "<li class=\"task done\"><span class=\"box\"></span><span class=\"t\">two</span></li>\n</ol>\n")
    }

    func testTaskItemsNestAtAnyDepthAndNeverUseAFormControl() {
        let html = body("- [ ] parent\n  - [x] child\n    1. [ ] grandchild\n")
        XCTAssertEqual(html.components(separatedBy: "class=\"box\"").count - 1, 3)
        XCTAssertTrue(html.contains("<li class=\"task\"><span class=\"box\"></span><span class=\"t\">parent</span>\n<ul>"))
        XCTAssertTrue(html.contains("<li class=\"task done\"><span class=\"box\"></span><span class=\"t\">child</span>\n<ol>"))
        XCTAssertFalse(html.contains("<input"))
        XCTAssertFalse(html.contains("[ ]"))
        XCTAssertFalse(html.contains("[x]"))
    }

    func testAnOrdinaryItemThatLooksLikeATaskInTheMiddleIsText() {
        XCTAssertEqual(body("- item [ ] not a task\n"), "<ul>\n<li>item [ ] not a task</li>\n</ul>\n")
    }

    // MARK: 6b: tables (R9)

    func testATableHasItsHeaderBodyAndColumnAlignment() {
        let md = "| Left | Center | Right |\n|:-----|:------:|------:|\n| a | **b** | `c` |\n| d | e | f |\n"
        XCTAssertEqual(body(md),
                       "<div class=\"dw-table\"><table style=\"--w1:4;--w2:6;--w3:5\">\n<thead>\n"
                       + "<tr><th style=\"text-align:left\">Left</th><th style=\"text-align:center\">Center</th><th style=\"text-align:right\">Right</th></tr>\n"
                       + "</thead>\n<tbody>\n"
                       + "<tr><td style=\"text-align:left\">a</td><td style=\"text-align:center\"><strong>b</strong></td><td style=\"text-align:right\"><code>c</code></td></tr>\n"
                       + "<tr><td style=\"text-align:left\">d</td><td style=\"text-align:center\">e</td><td style=\"text-align:right\">f</td></tr>\n"
                       + "</tbody>\n</table></div>\n")
    }

    func testColumnsWithoutAlignmentHaveNoStyle() {
        XCTAssertEqual(body("| a | b |\n|---|---|\n| 1 | 2 |\n"),
                       "<div class=\"dw-table\"><table style=\"--w1:4;--w2:4\">\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table></div>\n")
    }

    func testATableWithMoreColumnsThanThereAreWeightRulesHasEqualColumns() {
        // Weights exist for the first `maxWeightedColumns` only; a table wider than that carries none, so no column is squeezed.
        func table(columns n: Int) -> String {
            let header = "|" + (1...n).map { " c\($0) |" }.joined()
            return header + "\n|" + String(repeating: "---|", count: n) + "\n"
        }
        let limit = PrintStyle.maxWeightedColumns
        let atLimit = body(table(columns: limit))
        XCTAssertTrue(atLimit.contains("<table style=\"--w1:4;"), atLimit)
        XCTAssertTrue(atLimit.contains("--w\(limit):4\">"), atLimit)
        XCTAssertTrue(body(table(columns: limit + 1)).hasPrefix("<div class=\"dw-table\"><table>\n<thead>\n<tr><th>c1</th>"), "no style at all")
    }

    func testAHeaderOnlyTableHasNoBody() {
        XCTAssertEqual(body("| a |\n|---|\n"), "<div class=\"dw-table\"><table style=\"--w1:4\">\n<thead>\n<tr><th>a</th></tr>\n</thead>\n</table></div>\n")
    }


    func testAColumnsWidthWeightFollowsItsLongestTextWithinLimits() {
        let long = String(repeating: "w", count: 100)
        let html = body("| id | description of something long | \(long) |\n|--|--|--|\n| 1 | short | x |\n")
        XCTAssertTrue(html.contains("<table style=\"--w1:4;--w2:29;--w3:40\">"), html)
    }

    func testTextInsideAColumnCountsAsTypedNotAsMarkup() {
        let html = body("| a | b |\n|--|--|\n| **bold text here** | `code` and [a link](https://x.test) |\n")
        XCTAssertTrue(html.contains("<table style=\"--w1:14;--w2:15\">"), html)
    }

    func testALineBreakInACellIsABreak() {
        XCTAssertTrue(body("| a |\n|---|\n| x<br>y |\n").contains("<td>x<br>y</td>"))
        XCTAssertTrue(body("| a |\n|---|\n| x<br/>y |\n").contains("<td>x<br />y</td>"))
    }

    func testTablesInsideQuotesAndListItemsAreTablesToo() {
        XCTAssertEqual(body("> | a |\n> |---|\n> | 1 |\n"),
                       "<blockquote>\n<div class=\"dw-table\"><table style=\"--w1:4\">\n<thead>\n<tr><th>a</th></tr>\n</thead>\n<tbody>\n<tr><td>1</td></tr>\n</tbody>\n</table></div>\n</blockquote>\n")
        let inList = body("- item\n\n  | a |\n  |---|\n  | 1 |\n")
        XCTAssertTrue(inList.hasPrefix("<ul>\n<li>\n<p>item</p>\n<div class=\"dw-table\"><table style="), inList)
    }

    // MARK: 6b: tables end where the rows do (DW-025, D2)

    func testTextDirectlyUnderTheLastRowIsAParagraphNotARow() {
        let html = body("| a |\n|---|\n| 1 |\ntext\nmore\n")
        XCTAssertTrue(html.hasSuffix("<tbody>\n<tr><td>1</td></tr>\n</tbody>\n</table></div>\n<p>text\nmore</p>\n"), html)
        XCTAssertFalse(html.contains("<td>text"), html)
        let card = body(TableTailsTests.card)
        XCTAssertEqual(card.components(separatedBy: "<tr>").count - 1, 2, "a header row and the one empty row: \(card)")
        XCTAssertTrue(card.contains("<p>sxasdasdas\nsadasd\nIpsum duis elit"), card)
        XCTAssertTrue(card.hasSuffix("<p>After.</p>\n"), card)
    }

    func testATableWithoutOuterPipesStillExportsEveryRow() {
        let html = body("a | b\n- | -\n1 | 2\n3 | 4\ntext\n")
        XCTAssertEqual(html.components(separatedBy: "<tr>").count - 1, 3, html)
        XCTAssertTrue(html.hasSuffix("<p>text</p>\n"), html)
    }

    func testATextLineOverARuleUnderATableIsAHeadingInTheExportToo() {
        let html = body("| a |\n|---|\n| 1 |\ntext\n---\n")
        XCTAssertTrue(html.hasSuffix("</table></div>\n<h2 id=\"text\">text</h2>\n"), html)
    }

    func testATableInAListItemEndsAtItsLastRowToo() {
        let html = body("- | a |\n  |---|\n  | 1 |\n  text\n")
        XCTAssertTrue(html.contains("<tr><td>1</td></tr>"), html)
        XCTAssertFalse(html.contains("<td>text"), html)
        XCTAssertTrue(html.contains("<p>text</p>"), html)
        let quote = body("> | a |\n> |---|\n> | 1 |\n> text\n")
        XCTAssertFalse(quote.contains("<td>text"), quote)
        XCTAssertTrue(quote.contains("<p>text</p>"), quote)
    }

    // MARK: 6b: code (R10)

    func testFencedCodeIsShownExactly() {
        XCTAssertEqual(body("```\n  indented\n\nblank above\n```\n"), "<pre><code>  indented\n\nblank above\n</code></pre>\n")
        XCTAssertEqual(body("~~~\ntilde\n~~~\n"), "<pre><code>tilde\n</code></pre>\n")
        XCTAssertEqual(body("```\n\nfirst line is blank\n```\n"), "<pre><code>\nfirst line is blank\n</code></pre>\n")
        XCTAssertEqual(body("```\n```\n"), "<pre><code></code></pre>\n")
    }

    func testTheInfoStringIsNotShown() {
        let html = body("```swift {highlight: [1]}\nlet x = 1\n```\n")
        XCTAssertEqual(html, "<pre><code>let x = 1\n</code></pre>\n")
        XCTAssertFalse(html.contains("swift"))
    }

    func testIndentedCode() {
        XCTAssertEqual(body("para\n\n    code\n      more\n\nafter\n"), "<p>para</p>\n<pre><code>code\n  more\n</code></pre>\n<p>after</p>\n")
    }

    func testMarkupInsideCodeIsEscapedAndStaysInert() {
        let html = body("```\n</pre><script>alert(1)</script> & <b>\n```\n")
        XCTAssertEqual(html, "<pre><code>&lt;/pre&gt;&lt;script&gt;alert(1)&lt;/script&gt; &amp; &lt;b&gt;\n</code></pre>\n")
        XCTAssertFalse(html.contains("<script"))
    }

    func testALongCodeLineIsKeptWhole() {
        let line = String(repeating: "x", count: 300)
        XCTAssertEqual(body("```\n\(line)\n```\n"), "<pre><code>\(line)\n</code></pre>\n")
    }

    func testCodeInsideQuotesAndListsIsCode() {
        XCTAssertEqual(body("> ```\n> code\n> ```\n"), "<blockquote>\n<pre><code>code\n</code></pre>\n</blockquote>\n")
    }

    // MARK: 6c: links (R12)

    func testLinksKeepTheirTextAndTitleAndEscapeTheDestination() {
        XCTAssertEqual(body("[text](https://example.com)\n"), "<p><a href=\"https://example.com\">text</a></p>\n")
        XCTAssertEqual(body("[t](https://x.test \"The Title\")\n"), "<p><a href=\"https://x.test\" title=\"The Title\">t</a></p>\n")
        XCTAssertEqual(body("[x](https://x.test/?a=1&b=2)\n"), "<p><a href=\"https://x.test/?a=1&amp;b=2\">x</a></p>\n")
        XCTAssertEqual(body("[**b** `c`](https://x.test)\n"), "<p><a href=\"https://x.test\"><strong>b</strong> <code>c</code></a></p>\n")
        XCTAssertEqual(body("[![alt](pic.png)](https://x.test)\n"), "<p><a href=\"https://x.test\"><img src=\"pic.png\" alt=\"alt\"></a></p>\n")
    }

    func testReferenceLinksAndAutolinks() {
        XCTAssertEqual(body("[r][1]\n\n[1]: https://r.test \"T\"\n"), "<p><a href=\"https://r.test\" title=\"T\">r</a></p>\n")
        XCTAssertEqual(body("<https://a.test>\n"), "<p><a href=\"https://a.test\">https://a.test</a></p>\n")
    }

    func testRelativeFragmentMailAndFileDestinationsStayLinks() {
        XCTAssertEqual(body("[rel](other.md)\n"), "<p><a href=\"other.md\">rel</a></p>\n")
        XCTAssertEqual(body("[up](../up/x.md)\n"), "<p><a href=\"../up/x.md\">up</a></p>\n")
        XCTAssertEqual(body("[m](mailto:a@b.example)\n"), "<p><a href=\"mailto:a@b.example\">m</a></p>\n")
        XCTAssertEqual(body("[t](tel:+61123)\n"), "<p><a href=\"tel:+61123\">t</a></p>\n")
        XCTAssertEqual(body("[f](file:///tmp/x.md)\n"), "<p><a href=\"file:///tmp/x.md\">f</a></p>\n")
    }

    func testRefusedDestinationsLeaveOnlyTheLinkText() {
        let table: [String] = [
            "[js](javascript:alert(1))", "[mixed]( JaVaScRiPt:alert(1))", "[v](vbscript:x)", "[d](data:text/html;base64,AAAA)", "[e](&#106;avascript:alert(1))",
            "[x](<javascript:alert(1)>)", "[u](unknown:thing)", "[b](blob:https://x.test/u)", "[t](java&#9;script:alert(1))",
        ]
        for md in table {
            let html = body(md + "\n")
            XCTAssertFalse(html.contains("<a"), "\(md) -> \(html)")
            XCTAssertFalse(html.lowercased().contains("javascript:") && html.contains("href"), html)
        }
        XCTAssertEqual(body("[js](javascript:alert(1))\n"), "<p>js</p>\n")
        XCTAssertEqual(body("[**bold js**](javascript:alert(1))\n"), "<p><strong>bold js</strong></p>\n")
    }

    func testAnEmptyDestinationIsNotALink() {
        XCTAssertEqual(body("[x]()\n"), "<p>x</p>\n")
    }

    func testFragmentLinksAreLowerCasedLikeTheEditorLooksThemUp() {
        XCTAssertEqual(body("[jump](#Reading-This)\n"), "<p><a href=\"#reading-this\">jump</a></p>\n")
        XCTAssertEqual(body("[external](https://X.test/Path#Frag)\n"), "<p><a href=\"https://X.test/Path#Frag\">external</a></p>\n")
    }

    // MARK: 6c: heading ids (R12)

    func testHeadingIdsAreTheEditorsSlugsAndRepeatsGetASuffix() {
        let md = "# Same\n\ntext\n\n# Same\n\ntext\n\n## Same\n\ntext\n"
        let html = body(md)
        XCTAssertTrue(html.contains("<h1 id=\"same\">Same</h1>"))
        XCTAssertTrue(html.contains("<h1 id=\"same-1\">Same</h1>"))
        XCTAssertTrue(html.contains("<h2 id=\"same-2\">Same</h2>"))
    }

    func testASuffixNeverCollidesWithAHeadingThatIsLiterallyCalledThat() {
        let html = body("# Foo\n\na\n\n# Foo\n\nb\n\n# Foo 1\n\nc\n")
        XCTAssertTrue(html.contains("<h1 id=\"foo\">Foo</h1>"))
        XCTAssertTrue(html.contains("<h1 id=\"foo-2\">Foo</h1>"), "the repeat steps over foo-1, which the heading \"Foo 1\" owns")
        XCTAssertTrue(html.contains("<h1 id=\"foo-1\">Foo 1</h1>"), "so #foo-1 goes where the editor sends it")
    }

    func testAFragmentLinkAndItsHeadingAgree() {
        let html = body("# Reading **this**\n\n[jump](#reading-this)\n")
        XCTAssertTrue(html.contains("<h1 id=\"reading-this\">Reading <strong>this</strong></h1>"), html)
        XCTAssertTrue(html.contains("<a href=\"#reading-this\">jump</a>"), html)
    }

    func testEveryHeadingInTheFixtureHasTheIdTheEditorWouldResolve() {
        let md = "# One\n\nt\n\n> ## Quoted\n\n- ### In a list\n\nSetext\n======\n\n#### 日本語 Title\n\nt\n"
        let analysis = MarkdownAnalyzer.analyze(md)
        let expected = HeadingAnchor.unique(analysis.headings.map { HeadingAnchor.slug($0.title) }).compactMap { $0 }
        let html = body(md)
        let found = html.components(separatedBy: "<h").dropFirst().compactMap { piece -> String? in
            guard let r = piece.range(of: "id=\"") else { return nil }
            return String(piece[r.upperBound...].prefix(while: { $0 != "\"" }))
        }
        XCTAssertEqual(found, expected)
        XCTAssertEqual(expected.count, analysis.headings.count)
    }

    // MARK: 6c: ==highlight== (R7)

    func testHighlight() {
        XCTAssertEqual(body("==x==\n"), "<p><mark>x</mark></p>\n")
        XCTAssertEqual(body("a ==b== c\n"), "<p>a <mark>b</mark> c</p>\n")
        XCTAssertEqual(body("==one== and ==two==\n"), "<p><mark>one</mark> and <mark>two</mark></p>\n")
        XCTAssertEqual(body("== x== and ==y ==\n"), "<p>== x== and ==y ==</p>\n")
    }

    func testHighlightAcrossElementsStaysWellNested() {
        XCTAssertEqual(body("==a **b** c==\n"), "<p><mark>a </mark><strong><mark>b</mark></strong><mark> c</mark></p>\n")
        XCTAssertEqual(body("==a `code` b==\n"), "<p><mark>a </mark><mark><code>code</code></mark><mark> b</mark></p>\n")
        XCTAssertEqual(body("[==x==](https://a.test)\n"), "<p><a href=\"https://a.test\"><mark>x</mark></a></p>\n")
        XCTAssertEqual(body("==a <b>b</b> c==\n"), "<p><mark>a </mark><b><mark>b</mark></b><mark> c</mark></p>\n")
    }

    func testHighlightDoesNotSpanLinesOrReachIntoCode() {
        XCTAssertEqual(body("==a\nb==\n"), "<p>==a\nb==</p>\n")
        XCTAssertEqual(body("`==x==`\n"), "<p><code>==x==</code></p>\n")
        XCTAssertEqual(body("```\n==x==\n```\n"), "<pre><code>==x==\n</code></pre>\n")
    }

    func testHighlightInHeadingsAndTableCells() {
        XCTAssertTrue(body("# ==Title==\n\ntext\n").contains("<h1 id=\"title\"><mark>Title</mark></h1>"))
        XCTAssertTrue(body("| a |\n|---|\n| ==x== |\n").contains("<td><mark>x</mark></td>"))
    }

    // MARK: 6c: bare URLs (R7)

    func testBareURLsBecomeLinks() {
        XCTAssertEqual(body("see https://example.com now\n"), "<p>see <a href=\"https://example.com\">https://example.com</a> now</p>\n")
        XCTAssertEqual(body("go to https://example.com.\n"), "<p>go to <a href=\"https://example.com\">https://example.com</a>.</p>\n")
        XCTAssertEqual(body("www.example.com/x\n"), "<p><a href=\"https://www.example.com/x\">www.example.com/x</a></p>\n")
        XCTAssertEqual(body("http://insecure.test\n"), "<p><a href=\"http://insecure.test\">http://insecure.test</a></p>\n")
        XCTAssertEqual(body("**https://example.com**\n"), "<p><strong><a href=\"https://example.com\">https://example.com</a></strong></p>\n")
        XCTAssertEqual(body("https://a.test and https://b.test\n"),
                       "<p><a href=\"https://a.test\">https://a.test</a> and <a href=\"https://b.test\">https://b.test</a></p>\n")
    }

    func testABareURLInAHighlightIsLinkedInsideIt() {
        XCTAssertEqual(body("==see https://x.test==\n"), "<p><mark>see <a href=\"https://x.test\">https://x.test</a></mark></p>\n")
    }

    func testBareURLsAreNotLinkedInsideCodeOrInsideLinks() {
        XCTAssertEqual(body("`https://x.test`\n"), "<p><code>https://x.test</code></p>\n")
        XCTAssertEqual(body("```\nhttps://x.test\n```\n"), "<pre><code>https://x.test\n</code></pre>\n")
        XCTAssertEqual(body("[https://a.test](https://b.test)\n"), "<p><a href=\"https://b.test\">https://a.test</a></p>\n")
        XCTAssertEqual(body("[see www.a.test](https://b.test)\n"), "<p><a href=\"https://b.test\">see www.a.test</a></p>\n")
        XCTAssertEqual(body("<https://a.test>\n"), "<p><a href=\"https://a.test\">https://a.test</a></p>\n")
    }

    func testThingsThatLookLikeURLsButAreNotAreLeftAlone() {
        XCTAssertEqual(body("ftp://x.test and user@https://a.test and (https://a.test)\n"), "<p>ftp://x.test and user@https://a.test and (https://a.test)</p>\n")
    }

    // MARK: 6d: images (R14)

    private func prepared(_ markdown: String, target: DocumentHTML.Target = .screen) -> DocumentHTML.Prepared {
        DocumentHTML.prepare(markdown, options: .init(target: target, documentName: "doc.md"))
    }

    func testMarkdownImages() {
        XCTAssertEqual(body("![alt text](pic.png)\n"), "<p><img src=\"pic.png\" alt=\"alt text\"></p>\n")
        XCTAssertEqual(body("![a](pic.png \"The title\")\n"), "<p><img src=\"pic.png\" alt=\"a\" title=\"The title\"></p>\n")
        XCTAssertEqual(body("![a *b*](pic.png)\n"), "<p><img src=\"pic.png\" alt=\"a b\"></p>\n")
        XCTAssertEqual(body("![](pic.png)\n"), "<p><img src=\"pic.png\" alt=\"\"></p>\n")
    }

    func testImageSourcesAreListedInDocumentOrderWithoutRepeats() {
        let md = "![a](a.png) <img src=\"b.png\"> ![again](a.png)\n\n<p align=\"center\"><img src='c.png'></p>\n\n"
            + "![d](data:image/png;base64,AAAA) ![e](https://e.test/e.png) ![f](http://e.test/f.png) ![g](../up/g%20h.png)\n"
        XCTAssertEqual(prepared(md).imageSources,
                       ["a.png", "b.png", "c.png", "data:image/png;base64,AAAA", "https://e.test/e.png", "http://e.test/f.png", "../up/g%20h.png"])
    }

    func testAnImageThatCanNeverLoadIsShownAsMutedAltTextAndIsNotListed() {
        let p = prepared("![bad](javascript:alert(1)) ![](vbscript:x) ![empty]() ![t](data:text/html;base64,AAAA)\n")
        XCTAssertEqual(p.body, "<p><span class=\"dw-missing\">bad</span> <span class=\"dw-missing\">image</span> <span class=\"dw-missing\">empty</span> <span class=\"dw-missing\">t</span></p>\n")
        XCTAssertEqual(p.imageSources, [])
    }

    func testAnHTMLImageSourceIsDecodedWhenListed() {
        XCTAssertEqual(prepared("<img src=\"a&amp;b.png\">\n").imageSources, ["a&b.png"])
    }

    // MARK: 6d: raw HTML (R13)

    func testAnHTMLBlockPassesThroughTheSanitiser() {
        let html = body("<p align=\"center\"><img src=\"local.png\" width=\"48\"></p>\n")
        XCTAssertEqual(html, "<p align=\"center\"><img src=\"local.png\" width=\"48\"></p>\n")
    }

    func testDangerousHTMLInABlockIsGone() {
        let md = "<script>alert(1)</script>\n<style>p { color: red }</style>\n<iframe src=\"https://example.com\"></iframe>\n"
            + "<img src=x onerror=alert(1)>\n<a href=\"javascript:alert(1)\">bad link</a>\n<!-- a comment -->\n"
        let html = body(md)
        for forbidden in ["<script", "<style", "<iframe", "onerror", "javascript:", "<!--", "alert(1)"] { XCTAssertFalse(html.contains(forbidden), "\(forbidden) in \(html)") }
        XCTAssertTrue(html.contains("bad link"))
    }

    func testInlineHTMLTagsPassThroughAndDangerousOnesGo() {
        XCTAssertEqual(body("H<sub>2</sub>O and <u>under</u> and <mark>m</mark>\n"), "<p>H<sub>2</sub>O and <u>under</u> and <mark>m</mark></p>\n")
        XCTAssertEqual(body("a <script>alert(1)</script> b <b onclick=\"x()\">c</b>\n"), "<p>a  b <b>c</b></p>\n")
        XCTAssertEqual(body("a <a href=\"javascript:x\">link</a>\n"), "<p>a <a>link</a></p>\n")
    }

    func testAnUnclosedScriptRemovesTheRestOfItsBlockOnly() {
        let html = body("a <script>alert(1) and more\n\nnext paragraph\n")
        XCTAssertFalse(html.contains("alert"))
        XCTAssertTrue(html.contains("<p>next paragraph</p>"), html)
        let block = body("<style>\np { color: red }\n\nstill in the style block\n")
        XCTAssertEqual(block, "", "an unclosed style block runs to the end of the document in CommonMark, and goes with it")
    }

    func testRawHTMLInATableCellIsKept() {
        XCTAssertTrue(body("| a |\n|---|\n| <b>x</b> and <script>y</script> |\n").contains("<td><b>x</b> and </td>"))
    }

    func testTheSentinelCharactersInRawHTMLAreReplaced() {
        let p = prepared("<div>\u{E000}D1\u{E001} and \u{E002}</div>\n")
        XCTAssertEqual(p.body, "<div>\u{FFFD}D1\u{FFFD} and \u{FFFD}</div>\n")
        XCTAssertEqual(p.diagrams, [])
    }

    func testDetailsSplitAcrossThreeBlocksStayWellFormed() {
        let md = "<details>\n<summary>More</summary>\n\nText **inside** the details.\n\n</details>\n"
        XCTAssertEqual(body(md), "<details>\n<summary>More</summary>\n<p>Text <strong>inside</strong> the details.</p>\n</details>\n")
        XCTAssertEqual(body(md, target: .print), "<details open>\n<summary>More</summary>\n<p>Text <strong>inside</strong> the details.</p>\n</details>\n",
                       "paper cannot show a closed one (R20)")
    }

    func testDetailsKeepTheStateTheAuthorWroteOnScreen() {
        XCTAssertEqual(body("<details open>\n<summary>S</summary>\n\nx\n\n</details>\n"), "<details open>\n<summary>S</summary>\n<p>x</p>\n</details>\n")
    }

    // MARK: 6d: diagrams (R15)

    func testAMermaidFenceBecomesASlotAndItsSourceIsListed() {
        let p = prepared("before\n\n```mermaid\ngraph TD\n  A-->B\n```\n\nafter\n")
        XCTAssertEqual(p.body, "<p>before</p>\n\u{E000}D1\u{E001}\n<p>after</p>\n")
        XCTAssertEqual(p.diagrams, ["graph TD\n  A-->B"])
    }

    func testDiagramsAreNumberedInDocumentOrderIncludingRepeatsAndNesting() {
        let md = "```mermaid\nA\n```\n\n```Mermaid {x}\nB\n```\n\n> ```mermaid\n> C\n> ```\n\n- item\n\n  ```mermaid\n  A\n  ```\n"
        let p = prepared(md)
        XCTAssertEqual(p.diagrams, ["A", "B", "C", "A"])
        for n in 1...4 { XCTAssertTrue(p.body.contains("\u{E000}D\(n)\u{E001}"), "slot \(n)") }
    }

    func testOtherFencesAreNotDiagrams() {
        let p = prepared("```mermaidx\nA\n```\n\n```\nmermaid\n```\n")
        XCTAssertEqual(p.diagrams, [])
        XCTAssertFalse(p.body.contains("\u{E000}"))
    }

    // MARK: 6d: footnotes and math as typed (R11)

    func testFootnotesAreShownAsTyped() {
        let html = body("A marker[^1] and another[^2].\n\n[^1]: https://example.com/footnote\n[^2]: Plain note.\n")
        XCTAssertEqual(html, "<p>A marker[^1] and another[^2].</p>\n<p>[^1]: <a href=\"https://example.com/footnote\">https://example.com/footnote</a>\n[^2]: Plain note.</p>\n")
        XCTAssertFalse(html.contains("\\"))
    }

    func testAFootnoteDefinitionInsideCodeIsLeftAlone() {
        XCTAssertEqual(body("```\n[^1]: x\n```\n"), "<pre><code>[^1]: x\n</code></pre>\n")
        XCTAssertEqual(body("~~~\n[^1]: x\n~~~\n\n[^2]: y\n"), "<pre><code>[^1]: x\n</code></pre>\n<p>[^2]: y</p>\n")
    }

    func testMathIsShownAsTyped() {
        XCTAssertEqual(body("Inline $x^2$ here.\n"), "<p>Inline $x^2$ here.</p>\n")
        XCTAssertEqual(body("$$\nx^2\n$$\n"), "<p>$$\nx^2\n$$</p>\n")
    }

    // MARK: Title (R23)

    func testTheTitleIsTheFirstHeadingsPlainTitleElseTheDocumentName() {
        XCTAssertEqual(prepared("# A **bold** [link](u) title\n\ntext\n").title, "A bold link title")
        XCTAssertEqual(prepared("text\n\n## Later heading\n").title, "Later heading")
        XCTAssertEqual(prepared("no heading\n").title, "doc")
        XCTAssertEqual(DocumentHTML.prepare("x", options: .init(documentName: "")).title, "Untitled")
    }

    // MARK: Fixture P

    func testFixturePRendersEveryConstruct() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/export-demo.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        for target in [DocumentHTML.Target.screen, .print] {
            let p = prepared(text, target: target)
            let html = p.body
            // R11, R13: nothing from the front matter, nothing active.
            XCTAssertFalse(html.contains("Secret front matter"))
            for forbidden in ["<script", "<style", "<iframe", "onerror", "javascript:", "<!--", "alert(1)</script>"] { XCTAssertFalse(html.lowercased().contains(forbidden), forbidden) }
            // R12: ids, the suffix, lower-cased fragments.
            XCTAssertTrue(html.contains("id=\"same-name\"") && html.contains("id=\"same-name-1\""))
            XCTAssertTrue(html.contains("<h2 id=\"reading-this\">Reading <strong>this</strong></h2>"))
            XCTAssertTrue(html.contains("<a href=\"#reading-this\">jump</a>"))
            XCTAssertTrue(html.contains("<a href=\"#fixture-p-with-bold-and-a-linkhttpsexamplecom\">to the top</a>"))
            // R6 to R9.
            XCTAssertTrue(html.contains("<ol start=\"3\">"))
            XCTAssertEqual(html.components(separatedBy: "class=\"box\"").count - 1, 5)
            XCTAssertEqual(html.components(separatedBy: "<tr>").count - 1, 121)
            XCTAssertTrue(html.contains("<mark>"))
            XCTAssertTrue(html.contains("H<sub>2</sub>O") && html.contains("<u>under</u>"))
            XCTAssertTrue(html.contains("\"straight quotes\" -- ... 'single'"))
            // R10.
            XCTAssertTrue(html.contains("&lt;/pre&gt;&lt;script&gt;alert(1)&lt;/script&gt; &amp; &lt;b&gt;"))
            XCTAssertTrue(html.contains(String(repeating: "x", count: 300)))
            // R14, R15.
            XCTAssertEqual(p.diagrams.count, 3)
            XCTAssertEqual(p.imageSources, ["local.png", "local.svg", "big.png", "missing.png", "http://example.com/a.png", "https://example.com/logo.png"])
            // R20, R12 (links).
            XCTAssertEqual(html.contains("<details open>"), target == .print)
            XCTAssertFalse(html.contains("<a href=\"javascript"))
            XCTAssertTrue(html.contains("<a href=\"other.md\">rel</a>"))
            // R11.
            XCTAssertTrue(html.contains("[^1]") && html.contains("$x^2$") && html.contains("$$"))
            XCTAssertEqual(p.title, "Fixture P with bold and a link")
        }
    }

    // MARK: Review findings (verifier): raw HTML after a heading, footnotes before a rule

    func testAHeadingIsKeptWithABalancedRawHTMLBlockButNotWithOneThatOpensATag() {
        XCTAssertEqual(body("# T\n\n<p align=\"center\">centred</p>\n"), "<div class=\"keep\">\n<h1 id=\"t\">T</h1>\n<p align=\"center\">centred</p>\n</div>\n")
        XCTAssertEqual(body("# T\n\n<img src=\"a.png\">\n"), "<div class=\"keep\">\n<h1 id=\"t\">T</h1>\n<img src=\"a.png\">\n</div>\n")
        XCTAssertFalse(body("# T\n\n<details>\n<summary>S</summary>\n\nx\n\n</details>\n").contains("class=\"keep\""), "it opens a tag that closes in a later block")
        XCTAssertFalse(body("# T\n\n</div>\n").contains("class=\"keep\""), "it closes one that opened earlier")
    }

    func testAFootnoteDefinitionBeforeARuleOrUnderlineStaysAParagraphAndMakesNoHeading() {
        for underline in ["---", "===", "-----"] {
            let html = body("# One\n\nA note[^1]\n\n[^1]: https://example.com/footnote\n\(underline)\n\n## Two\n\n[jump](#two)\n")
            XCTAssertEqual(html.components(separatedBy: "<h2").count - 1, 1, "only the real heading: \(html)")
            XCTAssertTrue(html.contains("<h2 id=\"two\">Two</h2>"), html)
            XCTAssertTrue(html.contains("[^1]: <a href=\"https://example.com/footnote\">"), html)
            XCTAssertEqual(html.contains("<hr />"), underline.hasPrefix("-"), "the editor shows a rule after the definition: \(html)")
        }
    }
}
