import XCTest
@testable import DownwriteCore

/// Step 2 of the renderer (`assemble`), the omission summary, file names and the size gate (R14 to R16, R23, R24, R27).
final class DocumentAssembleTests: XCTestCase {
    private let png = "data:image/png;base64,QQ=="

    private func page(_ markdown: String, name: String = "doc.md", target: DocumentHTML.Target = .screen,
                      images: [String: DocumentHTML.ImageOutcome] = [:], diagrams: [DocumentHTML.DiagramOutcome] = []) -> (html: String, omissions: [DocumentHTML.Omission]) {
        let p = DocumentHTML.prepare(markdown, options: .init(target: target, documentName: name))
        return DocumentHTML.assemble(p, images: images, diagrams: diagrams)
    }

    private func main(_ html: String) -> String {
        let start = html.range(of: "<main>\n")!.upperBound, end = html.range(of: "</main>")!.lowerBound
        return String(html[start..<end])
    }

    // MARK: The page (R23)

    func testThePageStartsWithTheDoctypeThenThePolicyBeforeAnythingElseInTheHead() {
        let html = page("# T\n\ntext\n").html
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(HTMLSupport.contentSecurityPolicy)\">"
        XCTAssertTrue(html.hasPrefix("<!doctype html>\n<html>\n<head>\n\(csp)\n<meta charset=\"utf-8\">\n"), String(html.prefix(400)))
        XCTAssertEqual(html.components(separatedBy: "<head>").count, 2)
        XCTAssertTrue(html.hasSuffix("</main>\n</body>\n</html>\n"))
    }

    func testThePageDeclaresAViewportALightColourSchemeATitleAndInlineCSS() {
        let html = page("# Hello\n\ntext\n", target: .screen).html
        XCTAssertTrue(html.contains("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"))
        XCTAssertTrue(html.contains("<meta name=\"color-scheme\" content=\"light\">"))
        XCTAssertTrue(html.contains("<title>Hello</title>"))
        XCTAssertTrue(html.contains("<style>" + PrintStyle.css(for: .screen) + "</style>"))
        XCTAssertEqual(html.components(separatedBy: "<style>").count, 2, "one style element: the document's own <style> is gone")
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<link"))
        XCTAssertTrue(page("x\n", target: .print).html.contains("<style>" + PrintStyle.css(for: .print) + "</style>"))
    }

    func testTheTitleIsEscapedAndFallsBackToTheDocumentNameThenUntitled() {
        XCTAssertTrue(page("# A & B <c> \"d\"\n\ntext\n").html.contains("<title>A &amp; B &lt;c&gt; \"d\"</title>"))
        XCTAssertTrue(page("no heading\n", name: "Notes.md").html.contains("<title>Notes</title>"))
        XCTAssertTrue(page("no heading\n", name: "").html.contains("<title>Untitled</title>"))
    }

    func testTheBodyIsInsideOneMain() {
        let html = page("# T\n\ntext\n").html
        XCTAssertEqual(main(html), "<div class=\"keep\">\n<h1 id=\"t\">T</h1>\n<p>text</p>\n</div>\n")
        XCTAssertEqual(html.components(separatedBy: "<main>").count, 2)
    }

    func testEmptyAndFrontMatterOnlyDocumentsMakeAValidPageWithAnEmptyBody() {
        for md in ["", "   \n", "---\ntitle: x\n---\n"] {
            let html = page(md).html
            XCTAssertEqual(main(html), "", md.debugDescription)
            XCTAssertTrue(html.hasPrefix("<!doctype html>") && html.hasSuffix("</html>\n"))
            XCTAssertTrue(html.contains("<title>doc</title>"))
        }
    }

    func testAssemblingTwiceGivesTheSameBytes() {
        let md = "# T\n\ntext ==hi== https://example.com\n\n![i](a.png)\n\n```mermaid\ngraph TD\n```\n"
        let images: [String: DocumentHTML.ImageOutcome] = ["a.png": .embedded(dataURI: png)]
        let svgs: [DocumentHTML.DiagramOutcome] = [.svg("<svg id=\"x-123\"><g id=\"y\"/></svg>")]
        XCTAssertEqual(page(md, images: images, diagrams: svgs).html, page(md, images: images, diagrams: svgs).html)
    }

    // MARK: Images (R14, R16)

    func testAnEmbeddedImageGetsItsDataURI() {
        let out = page("![alt](pic.png)\n", images: ["pic.png": .embedded(dataURI: png)])
        XCTAssertEqual(main(out.html), "<p><img src=\"\(png)\" alt=\"alt\"></p>\n")
        XCTAssertEqual(out.omissions, [])
    }

    func testAKeptImageIsLeftAsWritten() {
        let out = page("![a](https://e.test/p.png) ![b](data:image/png;base64,AAAA)\n",
                       images: ["https://e.test/p.png": .keep, "data:image/png;base64,AAAA": .keep])
        XCTAssertEqual(main(out.html), "<p><img src=\"https://e.test/p.png\" alt=\"a\"> <img src=\"data:image/png;base64,AAAA\" alt=\"b\"></p>\n")
        XCTAssertEqual(out.omissions, [])
    }

    func testALeftOutImageIsItsAltTextInMutedItalic() {
        let out = page("![the alt](missing.png)\n", images: ["missing.png": .leftOut(.notFound)])
        XCTAssertEqual(main(out.html), "<p><span class=\"dw-missing\">the alt</span></p>\n")
        XCTAssertEqual(out.omissions, [DocumentHTML.Omission(source: "missing.png", reason: .notFound)])
    }

    func testWithoutAltTextTheFileNameIsShown() {
        let out = page("![](dir/a%20b.png?raw=true) <img src=\"http://e.test/path/c.png\">\n",
                       images: ["dir/a%20b.png?raw=true": .leftOut(.notFound), "http://e.test/path/c.png": .leftOut(.insecure)])
        XCTAssertEqual(main(out.html), "<p><span class=\"dw-missing\">a b.png</span> <span class=\"dw-missing\">c.png</span></p>\n")
    }

    func testAltTextIsEscaped() {
        let out = page("![a <b> & \"c\"](m.png)\n", images: ["m.png": .leftOut(.tooLarge)])
        XCTAssertEqual(main(out.html), "<p><span class=\"dw-missing\">a &lt;b&gt; &amp; \"c\"</span></p>\n")
    }

    func testHTMLImagesAreRewrittenToo() {
        let out = page("<p align=\"center\"><img src=\"local.png\" width=\"48\" alt=\"c\"></p>\n", images: ["local.png": .embedded(dataURI: png)])
        XCTAssertEqual(main(out.html), "<p align=\"center\"><img src=\"\(png)\" width=\"48\" alt=\"c\"></p>\n")
    }

    func testAnImageInsideALinkKeepsTheLink() {
        let out = page("[![alt](gone.png)](https://x.test)\n", images: ["gone.png": .leftOut(.notFound)])
        XCTAssertEqual(main(out.html), "<p><a href=\"https://x.test\"><span class=\"dw-missing\">alt</span></a></p>\n")
    }

    func testOmissionsComeInDocumentOrderWithEachSourceOnce() {
        let md = "![a](b.png) ![c](a.png) ![d](b.png) ![e](c.png) ![f](http://e.test/f.png)\n"
        let out = page(md, images: ["a.png": .embedded(dataURI: png), "b.png": .leftOut(.tooLarge), "c.png": .leftOut(.notFound), "http://e.test/f.png": .leftOut(.insecure)])
        XCTAssertEqual(out.omissions, [
            DocumentHTML.Omission(source: "b.png", reason: .tooLarge), DocumentHTML.Omission(source: "c.png", reason: .notFound),
            DocumentHTML.Omission(source: "http://e.test/f.png", reason: .insecure),
        ])
    }

    func testASourceNobodyResolvedIsTreatedLikeAMissingFile() {
        let out = page("![a](unknown.png) ![b](https://e.test/p.png)\n")
        XCTAssertEqual(out.omissions, [DocumentHTML.Omission(source: "unknown.png", reason: .notFound)])
        XCTAssertTrue(main(out.html).contains("<img src=\"https://e.test/p.png\" alt=\"b\">"))
    }

    // MARK: Diagrams (R15)

    func testADiagramReplacesItsSlotInsideACentredBox() {
        let out = page("before\n\n```mermaid\ngraph TD\n```\n\nafter\n", diagrams: [.svg("<svg viewBox=\"0 0 10 10\"><path d=\"M0 0\"/></svg>")])
        XCTAssertEqual(main(out.html), "<p>before</p>\n<div class=\"dw-diagram\"><svg viewBox=\"0 0 10 10\"><path d=\"M0 0\"/></svg></div>\n<p>after</p>\n")
        XCTAssertFalse(out.html.contains("\u{E000}"))
    }

    func testTheDiagramsOwnStyleAndSVGSurviveTheSanitiser() {
        let svg = "<svg id=\"m\"><style>#m .a{fill:red}</style><foreignObject><div>label</div></foreignObject></svg>"
        let html = page("```mermaid\nA\n```\n", diagrams: [.svg(svg)]).html
        XCTAssertTrue(html.contains("<style>#dw-d1-1 .a{fill:red}</style>"))
        XCTAssertTrue(html.contains("<foreignObject><div>label</div></foreignObject>"))
    }

    func testAFailedDiagramIsANoteAboveItsSource() {
        let out = page("```mermaid\ngraph TD\n  A --> ((\n```\n", diagrams: [.failed(reason: "Parse error on line 2 <here>")])
        XCTAssertEqual(main(out.html), "<p class=\"dw-note\">Diagram could not be rendered: Parse error on line 2 &lt;here&gt;</p>\n<pre><code>graph TD\n  A --&gt; ((</code></pre>\n")
    }

    func testDiagramsWithoutAnOutcomeAreANoteToo() {
        let out = page("```mermaid\nA\n```\n\n```mermaid\nB\n```\n", diagrams: [.svg("<svg/>")])
        XCTAssertTrue(main(out.html).contains("<div class=\"dw-diagram\"><svg/></div>"))
        XCTAssertTrue(main(out.html).contains("<p class=\"dw-note\">Diagram could not be rendered: not rendered</p>\n<pre><code>B</code></pre>"))
    }

    func testDiagramOutputThatCarriesAScriptOrAHandlerIsNotIncluded() {
        for svg in ["<svg><script>alert(1)</script></svg>", "<svg onload=\"alert(1)\"></svg>", "<svg><a href=\"javascript:x\"><text>t</text></a></svg>"] {
            let out = page("```mermaid\nA\n```\n", diagrams: [.svg(svg)])
            XCTAssertTrue(main(out.html).contains("Diagram could not be rendered: the diagram output was not safe to include"), svg)
            XCTAssertFalse(out.html.contains("alert(1)</script>") || out.html.contains("onload"), svg)
        }
    }

    // MARK: SVG ids (R15)

    func testIdsAreRenamedByPositionAndEveryReferenceFollows() {
        let svg = "<svg id=\"m-1\"><style>#m-1 .a{fill:red} #m-1_x{}</style><defs><marker id=\"m-1_arrow\"/></defs>"
            + "<path marker-end=\"url(#m-1_arrow)\"/><use href=\"#flow-A\"/><use xlink:href=\"#flow-A\"/><g id=\"flow-A\" aria-labelledby=\"flow-A\"/></svg>"
        let out = DocumentHTML.rewriteSVGIDs(svg, prefix: "dw-d3-")
        XCTAssertEqual(out, "<svg id=\"dw-d3-1\"><style>#dw-d3-1 .a{fill:red} #m-1_x{}</style><defs><marker id=\"dw-d3-2\"/></defs>"
            + "<path marker-end=\"url(#dw-d3-2)\"/><use href=\"#dw-d3-3\"/><use xlink:href=\"#dw-d3-3\"/><g id=\"dw-d3-3\" aria-labelledby=\"dw-d3-3\"/></svg>")
    }

    func testAnIdThatStartsLikeAnotherIsNotCaughtByIt() {
        let out = DocumentHTML.rewriteSVGIDs("<svg><g id=\"a\"/><g id=\"a-b\"/><use href=\"#a-b\"/><use href=\"#a\"/></svg>", prefix: "p-")
        XCTAssertEqual(out, "<svg><g id=\"p-1\"/><g id=\"p-2\"/><use href=\"#p-2\"/><use href=\"#p-1\"/></svg>")
    }

    func testRenamingDoesNotDependOnTheOriginalIds() {
        let a = DocumentHTML.rewriteSVGIDs("<svg id=\"mermaid-111\"><g id=\"n-1\"/></svg>", prefix: "dw-d1-")
        let b = DocumentHTML.rewriteSVGIDs("<svg id=\"mermaid-999\"><g id=\"n-1\"/></svg>", prefix: "dw-d1-")
        XCTAssertEqual(a, b, "two runs of the same renderer give the same text")
    }

    func testTwoDiagramsOrTheSameDiagramTwiceNeverShareAnId() {
        let svg = "<svg id=\"same\"><g id=\"node\"/></svg>"
        let html = page("```mermaid\nA\n```\n\n```mermaid\nA\n```\n", diagrams: [.svg(svg), .svg(svg)]).html
        let ids = html.components(separatedBy: "id=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
        XCTAssertEqual(ids.filter { $0.hasPrefix("dw-d") }, ["dw-d1-1", "dw-d1-2", "dw-d2-1", "dw-d2-2"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testASVGWithoutIdsIsUnchanged() {
        XCTAssertEqual(DocumentHTML.rewriteSVGIDs("<svg><g/></svg>", prefix: "p-"), "<svg><g/></svg>")
    }

    // MARK: The summary of left-out images (R16)

    func testSummaryLinesGiveEachSourceAndItsReason() {
        let lines = DocumentHTML.summaryLines(of: [
            .init(source: "missing.png", reason: .notFound), .init(source: "big.png", reason: .tooLarge), .init(source: "notes.txt", reason: .notAnImage),
            .init(source: "http://e.test/a.png", reason: .insecure), .init(source: "z.png", reason: .sizeLimit), .init(source: "rel.png", reason: .unsavedDocument),
        ])
        XCTAssertEqual(lines, ["missing.png (file not found)", "big.png (larger than 8 MB)", "notes.txt (not an image)",
                               "http://e.test/a.png (http images are not allowed)", "z.png (output size limit)", "rel.png (document not saved yet)"])
    }

    func testSummaryLinesStopAtTenAndSayHowManyMore() {
        let many = (1...13).map { DocumentHTML.Omission(source: "img\($0).png", reason: .notFound) }
        let lines = DocumentHTML.summaryLines(of: many)
        XCTAssertEqual(lines.count, 11)
        XCTAssertEqual(lines.first, "img1.png (file not found)")
        XCTAssertEqual(lines[9], "img10.png (file not found)")
        XCTAssertEqual(lines.last, "and 3 more")
        XCTAssertEqual(DocumentHTML.summaryLines(of: Array(many.prefix(10))).count, 10, "exactly ten is not 'and 0 more'")
        XCTAssertEqual(DocumentHTML.summaryLines(of: []), [])
    }

    func testALongSourceIsShortened() {
        let long = "https://example.com/" + String(repeating: "x", count: 200)
        let line = DocumentHTML.summaryLines(of: [.init(source: long, reason: .insecure)])[0]
        XCTAssertLessThan(line.count, 130)
        XCTAssertTrue(line.contains("…") && line.hasSuffix("(http images are not allowed)"))
    }

    // MARK: File names (R24)

    func testDefaultFileNames() {
        XCTAssertEqual(OutputNaming.defaultFileName(forDisplayName: "notes.md", extension: "pdf"), "notes.pdf")
        XCTAssertEqual(OutputNaming.defaultFileName(forDisplayName: "Notes.MARKDOWN", extension: "html"), "Notes.html")
        XCTAssertEqual(OutputNaming.defaultFileName(forDisplayName: "a.b.txt", extension: "pdf"), "a.b.pdf")
        XCTAssertEqual(OutputNaming.defaultFileName(forDisplayName: "no extension", extension: "pdf"), "no extension.pdf")
        XCTAssertEqual(OutputNaming.defaultFileName(forDisplayName: "report.docx", extension: "pdf"), "report.docx.pdf")
        XCTAssertEqual(OutputNaming.defaultFileName(forDisplayName: "  spaced.md ", extension: "html"), "spaced.html")
        XCTAssertEqual(OutputNaming.defaultFileName(forDisplayName: "", extension: "pdf"), "Untitled.pdf")
        XCTAssertEqual(OutputNaming.defaultFileName(forDisplayName: ".md", extension: "pdf"), "Untitled.pdf")
    }

    // MARK: Size (R27)

    func testATwentyThousandLineMegabyteDocumentIsRenderedWellUnderFiveSeconds() {
        var lines: [String] = ["---", "title: big", "---", ""]
        for i in 0..<1000 {
            lines += ["## Section \(i % 50)", "",
                      "A paragraph with **bold**, *italic*, `code`, a [link](https://example.com/\(i)), ==highlight== and https://example.org/page\(i) in it. "
                          + String(repeating: "Some more words to make the line a realistic length. ", count: 12), "",
                      "- item one", "  - nested [ ] text", "- [x] done task", "1. first", "2. second", "",
                      "> quote with ==mark== text", "",
                      "| a | b |", "|---|--:|", "| 1 | `x` |", "",
                      "```swift", "let x = \(i) // </pre><script>", "```", "", "![img](pic\(i % 20).png)", ""]
        }
        let text = lines.joined(separator: "\n")
        XCTAssertGreaterThanOrEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 20_000)
        XCTAssertGreaterThan(text.utf8.count, 900_000)
        let start = Date()
        let p = DocumentHTML.prepare(text, options: .init(target: .print, documentName: "big.md"))
        let images = DocumentHTML.resolveImages(p.imageSources, documentHasFolder: true) { _ in .notFound }
        let out = DocumentHTML.assemble(p, images: images, diagrams: [])
        let seconds = Date().timeIntervalSince(start)
        XCTAssertLessThan(seconds, 5, "took \(seconds)s")
        XCTAssertGreaterThan(out.html.count, 500_000)
        XCTAssertEqual(p.imageSources.count, 20)
    }
}
