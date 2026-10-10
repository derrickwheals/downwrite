import XCTest
@testable import DownwriteCore

/// The front-matter rule and the highlight / bare-URL patterns are shared by the editor (`MarkdownAnalyzer`) and the exported document
/// (`DocumentHTML`), so these tests pin what the editor does today and fail if either side drifts.
final class SharedPatternsTests: XCTestCase {
    // MARK: FrontMatter

    func testFrontMatterEndLineAgreesWithTheAnalyzersLineKinds() {
        let inputs = [
            "---\ntitle: x\n---\n\n# Body\n",
            "---\na: b\n...\nbody\n",
            "--- \na\n---\nbody",
            "---\n---",
            "---\n---\n",
            "---\nunclosed\nstill\n",
            "# Heading\n---\nx\n---\n",
            " ---\na\n---\n",
            "---x\na\n---\n",
            "---\na\n--- \nb\n",
            "---\na\n---\nb\n---\nc\n",
            "---\r\ntitle: x\r\n---\r\nbody\r\n",
            "---\rtitle: x\r---\rbody",
            "",
            "just text",
            "----\na\n---\n",
        ]
        for s in inputs {
            let src = SourceText(s)
            let end = FrontMatter.endLine(in: src)
            let kinds = MarkdownAnalyzer.analyze(s).lines.map { $0.kind == .frontMatter }
            let expected = (0..<kinds.count).map { end != nil && $0 <= end! }
            XCTAssertEqual(kinds, expected, "\(s.debugDescription) end=\(String(describing: end))")
        }
    }

    func testFrontMatterEndLineValues() {
        XCTAssertEqual(FrontMatter.endLine(in: SourceText("---\ntitle: x\n---\n\n# Body\n")), 2)
        XCTAssertEqual(FrontMatter.endLine(in: SourceText("---\na: b\n...\nbody\n")), 2)
        XCTAssertEqual(FrontMatter.endLine(in: SourceText("---\na\n---\nb\n---\n")), 2, "the first closing line ends it")
        XCTAssertNil(FrontMatter.endLine(in: SourceText("---\n---")), "two lines are not front matter")
        XCTAssertNil(FrontMatter.endLine(in: SourceText("---\nunclosed\n")))
        XCTAssertNil(FrontMatter.endLine(in: SourceText("text\n---\na\n---\n")), "only at the very top")
    }

    func testFrontMatterEndOffsetIsAfterTheClosingLineTerminator() {
        let s = "---\nt: 1\n---\nBody"
        let src = SourceText(s)
        let end = FrontMatter.endLine(in: src)!
        XCTAssertEqual(String(decoding: src.units[src.lineEnds[end]...], as: UTF16.self), "Body")
    }

    // MARK: Highlight

    private func highlights(_ s: String) -> [String] {
        let ns = s as NSString
        return InlineExtensions.highlight.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    func testHighlightPattern() {
        XCTAssertEqual(highlights("a ==b== c"), ["==b=="])
        XCTAssertEqual(highlights("==one== and ==two=="), ["==one==", "==two=="])
        XCTAssertEqual(highlights("==a **b** c=="), ["==a **b** c=="])
        XCTAssertEqual(highlights("a==b==c"), ["==b=="])
        XCTAssertEqual(highlights("== spaced=="), [])
        XCTAssertEqual(highlights("==spaced =="), [])
        XCTAssertEqual(highlights("a == b"), [])
        XCTAssertEqual(highlights("===="), [])
    }

    // MARK: Bare URLs

    private func bareURLs(_ s: String) -> [String] {
        let ns = s as NSString
        return InlineExtensions.bareURL.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    func testBareURLPattern() {
        XCTAssertEqual(bareURLs("see https://example.com now"), ["https://example.com"])
        XCTAssertEqual(bareURLs("see https://example.com."), ["https://example.com"], "trailing punctuation is not part of it")
        XCTAssertEqual(bareURLs("http://a.b/c?d=e&f=g#h, and"), ["http://a.b/c?d=e&f=g#h"])
        XCTAssertEqual(bareURLs("go to www.example.com/path today"), ["www.example.com/path"])
        XCTAssertEqual(bareURLs("two https://a.com and https://b.com"), ["https://a.com", "https://b.com"])
        XCTAssertEqual(bareURLs("[t](https://a.com)"), [], "a link destination is not a bare URL")
        XCTAssertEqual(bareURLs("user@https://a.com"), [])
        XCTAssertEqual(bareURLs("<https://a.com>"), ["https://a.com"], "angle autolinks are left to cmark; the pattern still sees them")
        XCTAssertEqual(bareURLs("ftp://a.com"), [])
    }

    func testBareURLDestinationAddsASchemeToWWW() {
        XCTAssertEqual(InlineExtensions.destination(forBareURL: "www.example.com"), "https://www.example.com")
        XCTAssertEqual(InlineExtensions.destination(forBareURL: "https://example.com"), "https://example.com")
        XCTAssertEqual(InlineExtensions.destination(forBareURL: "http://example.com"), "http://example.com")
    }
}
