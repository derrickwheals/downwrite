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
                       "<div class=\"dw-table\"><table>\n<thead>\n"
                       + "<tr><th style=\"text-align:left\">Left</th><th style=\"text-align:center\">Center</th><th style=\"text-align:right\">Right</th></tr>\n"
                       + "</thead>\n<tbody>\n"
                       + "<tr><td style=\"text-align:left\">a</td><td style=\"text-align:center\"><strong>b</strong></td><td style=\"text-align:right\"><code>c</code></td></tr>\n"
                       + "<tr><td style=\"text-align:left\">d</td><td style=\"text-align:center\">e</td><td style=\"text-align:right\">f</td></tr>\n"
                       + "</tbody>\n</table></div>\n")
    }

    func testColumnsWithoutAlignmentHaveNoStyle() {
        XCTAssertEqual(body("| a | b |\n|---|---|\n| 1 | 2 |\n"),
                       "<div class=\"dw-table\"><table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table></div>\n")
    }

    func testAHeaderOnlyTableHasNoBody() {
        XCTAssertEqual(body("| a |\n|---|\n"), "<div class=\"dw-table\"><table>\n<thead>\n<tr><th>a</th></tr>\n</thead>\n</table></div>\n")
    }

    func testALineBreakInACellIsABreak() {
        XCTAssertTrue(body("| a |\n|---|\n| x<br>y |\n").contains("<td>x<br>y</td>"))
        XCTAssertTrue(body("| a |\n|---|\n| x<br/>y |\n").contains("<td>x<br />y</td>"))
    }

    func testTablesInsideQuotesAndListItemsAreTablesToo() {
        XCTAssertEqual(body("> | a |\n> |---|\n> | 1 |\n"),
                       "<blockquote>\n<div class=\"dw-table\"><table>\n<thead>\n<tr><th>a</th></tr>\n</thead>\n<tbody>\n<tr><td>1</td></tr>\n</tbody>\n</table></div>\n</blockquote>\n")
        let inList = body("- item\n\n  | a |\n  |---|\n  | 1 |\n")
        XCTAssertTrue(inList.hasPrefix("<ul>\n<li>\n<p>item</p>\n<div class=\"dw-table\"><table>"), inList)
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
}
