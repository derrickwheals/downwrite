import XCTest
@testable import DownwriteCore

final class HTMLSupportTests: XCTestCase {
    private let style = HTMLPageStyle(fontFamily: "'Avenir Next', sans-serif", fontSize: 17, lineHeight: 1.45, palette: Palette.palette(for: .light))

    // MARK: isRenderable

    func testBlocksThatDrawSomethingAreRenderable() {
        XCTAssertTrue(HTMLSupport.isRenderable("<p align=\"center\">\n  <img src=\"a.png\" width=\"48%\">\n</p>"))
        XCTAssertTrue(HTMLSupport.isRenderable("<img src=\"a.png\">"))
        XCTAssertTrue(HTMLSupport.isRenderable("<IMG SRC=\"a.png\">"))
        XCTAssertTrue(HTMLSupport.isRenderable("<hr>"))
        XCTAssertTrue(HTMLSupport.isRenderable("<div>hello</div>"))
        XCTAssertTrue(HTMLSupport.isRenderable("<details>\n<summary>More</summary>"))
        XCTAssertTrue(HTMLSupport.isRenderable("<table>\n<tr><td>1</td><td>2</td></tr>\n</table>"))
        XCTAssertTrue(HTMLSupport.isRenderable("<svg width=\"10\" height=\"10\"><circle r=\"4\"/></svg>"))
        XCTAssertTrue(HTMLSupport.isRenderable("<!-- note -->\n<div>shown</div>"))
    }

    func testBlocksThatDrawNothingAreNot() {
        XCTAssertFalse(HTMLSupport.isRenderable(""))
        XCTAssertFalse(HTMLSupport.isRenderable("   \n"))
        XCTAssertFalse(HTMLSupport.isRenderable("<!-- just a comment -->"))
        XCTAssertFalse(HTMLSupport.isRenderable("<!--\nmulti\nline\n-->"))
        XCTAssertFalse(HTMLSupport.isRenderable("<!-- never closed"))
        XCTAssertFalse(HTMLSupport.isRenderable("</details>"))
        XCTAssertFalse(HTMLSupport.isRenderable("</div>\n</div>"))
        XCTAssertFalse(HTMLSupport.isRenderable("<div align=\"center\">"), "a bare wrapper has nothing to show")
        XCTAssertFalse(HTMLSupport.isRenderable("<br>"))
        XCTAssertFalse(HTMLSupport.isRenderable("<script>document.title = 'x'</script>"))
        XCTAssertFalse(HTMLSupport.isRenderable("<script>\nalert(1)\n</script>"))
        XCTAssertFalse(HTMLSupport.isRenderable("<style>\np { color: red }\n</style>"))
        XCTAssertFalse(HTMLSupport.isRenderable("<style>\np { color: red }"))
        XCTAssertFalse(HTMLSupport.isRenderable("<?php echo 1; ?>"))
        XCTAssertFalse(HTMLSupport.isRenderable("<!DOCTYPE html>"))
        XCTAssertFalse(HTMLSupport.isRenderable("<![CDATA[ x ]]>"))
    }

    func testScriptDoesNotHideTheRestOfTheBlock() {
        XCTAssertTrue(HTMLSupport.isRenderable("<script>x()</script><p>text</p>"))
        XCTAssertTrue(HTMLSupport.isRenderable("<p>text</p><SCRIPT>x()</SCRIPT>"))
    }

    // MARK: Images

    func testImageSourcesInAllQuotingStyles() {
        let html = "<img src=\"a.png\"> <img alt=\"x\" SRC='b c.png' width=3> <img src=d.png/> <img\n  src=\"a.png\"\n  alt=\"dup\"> <img alt=\"none\">"
        XCTAssertEqual(HTMLSupport.imageSources(in: html), ["a.png", "b c.png", "d.png/"])
    }

    func testReplacingImageSourcesKeepsEverythingElse() {
        let html = "<p><img src=\"a.png\" width=\"10\"> and <img alt='x' src='b.png'>é😀<img src=\"https://x.example/c.png\"></p>"
        let out = HTMLSupport.replacingImageSources(in: html, with: ["a.png": "data:image/png;base64,AAAA", "b.png": "data:image/png;base64,BBBB"])
        XCTAssertEqual(out, "<p><img src=\"data:image/png;base64,AAAA\" width=\"10\"> and <img alt='x' src='data:image/png;base64,BBBB'>é😀<img src=\"https://x.example/c.png\"></p>")
        XCTAssertEqual(HTMLSupport.replacingImageSources(in: html, with: [:]), html)
    }

    func testImageSourcesOnlyLookInsideImgTags() {
        let html = "<a href=\"x\" src=\"no.png\">link</a> <video src=\"clip.mp4\"></video> <img src=\"yes.png\">"
        XCTAssertEqual(HTMLSupport.imageSources(in: html), ["yes.png"])
    }

    func testLocalSources() {
        for s in ["a.png", "docs/a.png", "./a.png", "../a.png", "/Users/me/a.png", "~/a.png", "file:///tmp/a.png", " a b.png "] {
            XCTAssertTrue(HTMLSupport.isLocalSource(s), s)
        }
        for s in ["", "https://x.example/a.png", "HTTP://x.example/a.png", "data:image/png;base64,AAAA", "//cdn.example/a.png"] {
            XCTAssertFalse(HTMLSupport.isLocalSource(s), s)
        }
    }

    // MARK: Tags

    func testParseTag() {
        XCTAssertEqual(HTMLSupport.parseTag("<b>"), .init(name: "b", isClosing: false, isSelfClosing: false, attributes: [:]))
        XCTAssertEqual(HTMLSupport.parseTag("</B>"), .init(name: "b", isClosing: true, isSelfClosing: false, attributes: [:]))
        XCTAssertEqual(HTMLSupport.parseTag("<br/>"), .init(name: "br", isClosing: false, isSelfClosing: true, attributes: [:]))
        XCTAssertEqual(HTMLSupport.parseTag("<br />"), .init(name: "br", isClosing: false, isSelfClosing: true, attributes: [:]))
        XCTAssertEqual(HTMLSupport.parseTag("<A HREF=\"https://x.example/?a=1&amp;b=2\" Title='t' data-x=y hidden>")?.attributes,
                       ["href": "https://x.example/?a=1&b=2", "title": "t", "data-x": "y", "hidden": ""])
        XCTAssertEqual(HTMLSupport.parseTag("<a\n  href=\"x\"\n>")?.attributes, ["href": "x"])
        XCTAssertEqual(HTMLSupport.parseTag("<img src=\"a/b.png\"/>")?.isSelfClosing, true)
        XCTAssertEqual(HTMLSupport.parseTag("<img src=\"a/b.png\"/>")?.attributes, ["src": "a/b.png"])
        XCTAssertEqual(HTMLSupport.parseTag("<a href=\"1\" href=\"2\">")?.attributes, ["href": "1"], "the first duplicate wins, as in browsers")
    }

    func testParseTagRejectsEverythingElse() {
        for raw in ["", "text", "<>", "< b>", "<!-- c -->", "<?php?>", "<!DOCTYPE html>", "<b", "b>", "<b>x</b>", "<1a>", "</>"] {
            XCTAssertNil(HTMLSupport.parseTag(raw), raw)
        }
    }

    // MARK: Page

    func testPageStartsWithTheSecurityPolicy() {
        let page = HTMLSupport.page(body: "<p>hi</p>", style: style)
        let csp = page.range(of: "Content-Security-Policy")
        let firstStyle = page.range(of: "<style>")
        let body = page.range(of: "<p>hi</p>")
        XCTAssertNotNil(csp)
        XCTAssertTrue(csp!.lowerBound < firstStyle!.lowerBound && firstStyle!.lowerBound < body!.lowerBound)
        for directive in ["default-src 'none'", "base-uri 'none'", "form-action 'none'", "frame-src 'none'", "object-src 'none'", "img-src data: https:"] {
            XCTAssertTrue(HTMLSupport.contentSecurityPolicy.contains(directive), directive)
        }
        XCTAssertFalse(HTMLSupport.contentSecurityPolicy.contains("script-src"), "scripts fall back to default-src 'none'")
        XCTAssertFalse(HTMLSupport.contentSecurityPolicy.contains("file:"))
    }

    func testPageWrapsBodyInTheMeasuredRoot() {
        let page = HTMLSupport.page(body: "<p>hi</p>", style: style)
        XCTAssertTrue(page.contains("<div id=\"\(HTMLSupport.rootID)\"><p>hi</p></div>"))
        XCTAssertTrue(HTMLSupport.heightScript.contains(HTMLSupport.rootID))
    }

    func testPageUsesTheEditorTypographyAndPalette() {
        let light = HTMLSupport.page(body: "", style: style)
        XCTAssertTrue(light.contains("17.0px/1.45 'Avenir Next', sans-serif"), light)
        XCTAssertTrue(light.contains("color:\(Palette.palette(for: .light).text.css)"))
        XCTAssertTrue(light.contains("color-scheme\" content=\"light\""))
        let dark = HTMLSupport.page(body: "", style: HTMLPageStyle(fontFamily: "serif", fontSize: 20, lineHeight: 1.3, palette: Palette.palette(for: .dark)))
        XCTAssertTrue(dark.contains("color-scheme\" content=\"dark\""))
        XCTAssertTrue(dark.contains("color:\(Palette.palette(for: .dark).text.css)"))
        XCTAssertNotEqual(light, dark)
    }

    func testColourCSS() {
        XCTAssertEqual(RGBA(hex: 0xFFFFFF).css, "#ffffff")
        XCTAssertEqual(RGBA(hex: 0x00080F).css, "#00080f")
        XCTAssertEqual(RGBA(hex: 0x4054D6, alpha: 0.22).css, "rgba(64, 84, 214, 0.22)")
        XCTAssertEqual(RGBA(-1, 2, 0.5, 1).css, "#00ff80")
    }
}
