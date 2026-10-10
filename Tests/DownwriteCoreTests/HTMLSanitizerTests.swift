import XCTest
@testable import DownwriteCore

/// R12 (link destinations) and R13 (the sanitiser). The sanitiser re-emits every tag it keeps in one canonical form, so most expectations
/// below are exact strings.
final class LinkPolicyTests: XCTestCase {
    // MARK: Character references

    func testNumericReferencesAreDecodedWithOrWithoutTheSemicolon() {
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#106;"), "j")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#x6A;"), "j")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#X6a;"), "j")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#106avascript"), "javascript")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#0000106;avascript"), "javascript")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#128512;"), "😀")
    }

    func testInvalidNumericReferencesBecomeTheReplacementCharacter() {
        let bad = "\u{FFFD}"
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#0;"), bad)
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#xD800;"), bad)
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#x110000;"), bad)
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#99999999999999999999;"), bad)
    }

    func testNamedReferencesThatCanFormAScheme() {
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("javascript&colon;x"), "javascript:x")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("java&Tab;script"), "java\tscript")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("java&NewLine;script"), "java\nscript")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&lt;&gt;&amp;&quot;&apos;"), "<>&\"'")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("a&period;b&sol;c&plus;d&lpar;e&rpar;"), "a.b/c+d(e)")
    }

    func testAmpersandsThatAreNotReferencesStay() {
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("?a=1&b=2"), "?a=1&b=2")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("a & b"), "a & b")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&amp"), "&amp", "a name without its semicolon is left as text")
        XCTAssertEqual(LinkPolicy.decodeCharacterReferences("&#;"), "&#;")
    }

    func testAnUnknownNamedReferenceCannotBeRead() {
        XCTAssertNil(LinkPolicy.decodeCharacterReferences("&bogus;"))
        XCTAssertNil(LinkPolicy.decodeCharacterReferences("java&nope;script:alert(1)"))
    }

    // MARK: Link destinations (R12)

    func testAllowedDestinations() {
        let ok = [
            "https://example.com", "HTTP://EXAMPLE.COM/a?b=1&c=2#d", "mailto:a@b.example", "MAILTO:a@b.example", "tel:+61123456",
            "file:///tmp/a.md", "File:///tmp/a.md", "other.md", "../up/other.md", "./here.md", "dir/file:with-colon", "#heading",
            "#a:b:c", "?q=a:b", "", "   ", "//host.example/x", "~/notes.md", "/abs/path.md", "a%20b.md", "https://x.test/&amp;ok",
        ]
        for d in ok { XCTAssertTrue(LinkPolicy.isAllowedLinkDestination(d), d.debugDescription) }
    }

    func testDangerousAndUnreadableDestinationsAreRefused() {
        let bad = [
            "javascript:alert(1)", "JaVaScRiPt:alert(1)", " JaVaScRiPt:alert(1)", " \t javascript:alert(1)", "\u{1}javascript:alert(1)",
            "java\tscript:alert(1)", "java\nscript:alert(1)", "java\r\nscript:alert(1)", "j a v a s c r i p t:alert(1)",
            "&#106;avascript:alert(1)", "&#x6A;avascript:alert(1)", "&#106avascript:alert(1)", "&#0000106;avascript:alert(1)",
            "jav&#x09;ascript:alert(1)", "java&Tab;script:alert(1)", "java&NewLine;script:alert(1)", "javascript&colon;alert(1)",
            "javascript&#58;alert(1)", "javascript&#x3a;alert(1)", "&#x6a&#x61vascript:alert(1)", "vbscript:msgbox(1)",
            "data:text/html,<script>alert(1)</script>", "data:image/png;base64,AAAA", "blob:https://x.test/uuid", "ftp://x.test/a",
            "view-source:https://x.test", "jar:file:///a.jar!/b", "about:blank", "x-apple-help:foo", "c:\\windows\\x", "C:/dir/file.md",
            "1abc:x", "-abc:x", "foo bar:baz", "jav\u{0}ascript:alert(1)", "\u{A0}javascript:alert(1)", "java&nope;script:alert(1)",
            "javascript\u{FF1A}alert(1)x:y",
        ]
        for d in bad { XCTAssertFalse(LinkPolicy.isAllowedLinkDestination(d), d.debugDescription) }
    }

    func testAColonAfterAPathOrQueryDoesNotMakeASchemeAndIsAllowed() {
        XCTAssertTrue(LinkPolicy.isAllowedLinkDestination("a/b:c"))
        XCTAssertTrue(LinkPolicy.isAllowedLinkDestination("a?b:c"))
        XCTAssertTrue(LinkPolicy.isAllowedLinkDestination("a#b:c"))
    }

    // MARK: Image sources

    func testCandidateImageSources() {
        let yes = ["pic.png", "../img/a%20b.png", "/abs/p.jpg", "~/p.jpg", "file:///tmp/p.jpg", "https://e.test/p.png", "http://e.test/p.png",
                   "data:image/png;base64,AAAA", "DATA:IMAGE/SVG+XML,%3Csvg/%3E", " pic.png ", "pic.png?raw=true"]
        for s in yes { XCTAssertTrue(LinkPolicy.isCandidateImageSource(s), s.debugDescription) }
        let no = ["javascript:alert(1)", "data:text/html;base64,AAAA", "data:application/pdf;base64,AA", "ftp://e.test/p.png", "//e.test/p.png",
                  "blob:https://e.test/x", "&#106;avascript:alert(1)", "java\tscript:alert(1)", "mailto:a@b.example", "c:/p.png"]
        for s in no { XCTAssertFalse(LinkPolicy.isCandidateImageSource(s), s.debugDescription) }
    }
}

final class HTMLSanitizerTests: XCTestCase {
    private func clean(_ s: String, openDetails: Bool = false, allow: @escaping (String) -> Bool = LinkPolicy.isCandidateImageSource) -> String {
        HTMLSanitizer.scan(s, openDetails: openDetails, allowImageSource: allow).html
    }

    // MARK: Allowed HTML stays

    func testAllowedHTMLIsLeftIntact() {
        let same = [
            "<p align=\"center\"><img src=\"local.png\" width=\"120\"></p>",
            "<details><summary>More</summary><p>x</p></details>",
            "<a href=\"https://example.com/a?b=1&amp;c=2\" title=\"t\">x</a>",
            "<b>bold</b> <i>it</i> <u>u</u> H<sub>2</sub>O <mark>m</mark> <kbd>K</kbd>",
            "<span style=\"color:red\">x</span>",
            "<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>",
            "<p>a &amp; b &lt; c &copy; d</p>",
            "<details open><summary>S</summary>x</details>",
            "<input type=\"checkbox\" disabled>",
            "<h2 id=\"top\" class=\"c\">T</h2>",
            "<a href=\"#top\">up</a> <a href=\"other.md\">o</a> <a href=\"mailto:a@b.example\">m</a> <a href=\"tel:+61123\">t</a>",
        ]
        for s in same { XCTAssertEqual(clean(s), s) }
    }

    func testTagsAreWrittenInOneCanonicalForm() {
        XCTAssertEqual(clean("<a href='https://x.test' title=hi>x</a>"), "<a href=\"https://x.test\" title=\"hi\">x</a>")
        XCTAssertEqual(clean("<br/>"), "<br />")
        XCTAssertEqual(clean("<br>"), "<br>")
        XCTAssertEqual(clean("<P ALIGN=center>x</P>"), "<P ALIGN=\"center\">x</P>")
        XCTAssertEqual(clean("<svg viewBox=\"0 0 10 10\"><path d=\"M0 0L10 10\"/></svg>"), "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0L10 10\" /></svg>")
        XCTAssertEqual(clean("<p   class = \"a\"   id=b >x</p  >"), "<p class=\"a\" id=\"b\">x</p>")
        XCTAssertEqual(clean("<img\tsrc=x\nalt=y>"), "<img src=\"x\" alt=\"y\">")
    }

    func testAttributeValuesAreQuotedAndTagCharactersInThemAreEscaped() {
        XCTAssertEqual(clean("<p title='a\"b'>x</p>"), "<p title=\"a&quot;b\">x</p>")
        XCTAssertEqual(clean("<p title=\"<b>x</b>\">x</p>"), "<p title=\"&lt;b&gt;x&lt;/b&gt;\">x</p>")
        XCTAssertEqual(clean("<p title=\"a&lt;b\">x</p>"), "<p title=\"a&lt;b\">x</p>", "references in values are kept as written")
    }

    func testALoneLessThanInTextIsEscaped() {
        XCTAssertEqual(clean("a < b"), "a &lt; b")
        XCTAssertEqual(clean("<3 and <"), "&lt;3 and &lt;")
        XCTAssertEqual(clean("<<b>x</b>"), "&lt;<b>x</b>")
    }

    func testNULBecomesTheReplacementCharacterAndBoundariesPassThrough() {
        XCTAssertEqual(clean("a\u{0}b"), "a\u{FFFD}b")
        XCTAssertEqual(clean("a\u{E002}b"), "a\u{E002}b")
        XCTAssertEqual(clean("a\u{E000}D1\u{E001}b"), "a\u{E000}D1\u{E001}b", "diagram slots are plain text")
    }

    // MARK: Elements

    func testScriptAndStyleAreRemovedWithTheirContent() {
        XCTAssertEqual(clean("a<script>alert(1)</script>b"), "ab")
        XCTAssertEqual(clean("a<SCRIPT>alert(1)</SCRIPT>b"), "ab")
        XCTAssertEqual(clean("<script src=\"x.js\"></script>"), "")
        XCTAssertEqual(clean("<script >alert(1)</script >x"), "x")
        XCTAssertEqual(clean("<script>alert(1)</script\n>x"), "x")
        XCTAssertEqual(clean("<script/src=//evil.test/x.js></script>x"), "x")
        XCTAssertEqual(clean("<script>\"</scripts>\"</script>x"), "x", "</scripts> does not end a script")
        XCTAssertEqual(clean("a<style>p{color:red}</style>b"), "ab")
        XCTAssertEqual(clean("<STYLE>@import 'x';</STYLE>"), "")
        XCTAssertEqual(clean("<svg><script>alert(1)</script></svg>"), "<svg></svg>")
        XCTAssertEqual(clean("</script>stray</style>"), "stray")
    }

    func testAnUnclosedScriptOrStyleRemovesEverythingToTheEndOfItsBlock() {
        XCTAssertEqual(clean("a<script>alert(1)"), "a")
        XCTAssertEqual(clean("<style>p{}"), "")
        XCTAssertEqual(clean("a<script>alert(1)\u{E002}rest"), "a\u{E002}rest", "the block boundary stops it")
        XCTAssertEqual(clean("<p>a <style> b</p>\u{E002}<p>c</p>"), "<p>a \u{E002}<p>c</p>")
    }

    func testElementsThatAreRemovedKeepTheirContent() {
        let table: [(String, String)] = [
            ("<iframe src=\"https://e.test\">fallback</iframe>", "fallback"),
            ("<IFrame srcdoc=\"<script>alert(1)</script>\"></IFrame>", ""),
            ("<frameset><frame src=x></frameset>", ""),
            ("<object data=\"x\">alt<param name=a></object>", "alt<param name=\"a\">"),
            ("<embed src=x>", ""),
            ("<applet code=x>t</applet>", "t"),
            ("<form action=\"x\" method=post><input name=a></form>", "<input name=\"a\">"),
            ("<link rel=stylesheet href=x.css>", ""),
            ("<meta http-equiv=\"refresh\" content=\"0;url=https://e.test\">", ""),
            ("<base href=\"https://evil.test/\">", ""),
            ("<title>T</title>", "T"),
            ("a<Meta charset=utf-8>b", "ab"),
        ]
        for (input, expected) in table { XCTAssertEqual(clean(input), expected, input) }
    }

    // MARK: Attributes

    func testEventAttributesAreRemoved() {
        let table: [(String, String)] = [
            ("<img src=\"a.png\" onerror=\"alert(1)\">", "<img src=\"a.png\">"),
            ("<img src=\"a.png\" ONERROR=\"alert(1)\">", "<img src=\"a.png\">"),
            ("<img src=x onerror=alert(1)>", "<img src=\"x\">"),
            ("<img src=x onerror = alert(1) alt=ok>", "<img src=\"x\" alt=\"ok\">"),
            ("<svg onload=alert(1)>", "<svg>"),
            ("<svg/onload=alert(1)>", "<svg>"),
            ("<a href=\"https://x.test\" onclick = \"x()\">y</a>", "<a href=\"https://x.test\">y</a>"),
            ("<div onmouseover='a()' class=c>x</div>", "<div class=\"c\">x</div>"),
            ("<p onclick=x ONFOCUS=y onanimationend=z title=t>x</p>", "<p title=\"t\">x</p>"),
            ("<img\tsrc=x\nonerror=alert(1)>", "<img src=\"x\">"),
            ("<img src=x onerror=alert(1) <b>", "<img src=\"x\">"),
            ("<img &#111;nerror=alert(1) src=x>", "<img src=\"x\">"),
            ("<img src=x \"onerror=alert(1)>", "<img src=\"x\">"),
            ("<img src=\"x\"onerror=alert(1)>", "<img src=\"x\">"),
        ]
        for (input, expected) in table { XCTAssertEqual(clean(input), expected, input) }
    }

    func testSlashesInsideATagFollowTheHTMLTokeniser() {
        // `/` is not a separator between attributes when the next character is not `>`: the browser reads one unquoted value.
        XCTAssertEqual(clean("<img/src=x/onerror=alert(1)>"), "<img src=\"x/onerror=alert(1)\">")
    }

    func testSrcsetIsRemovedEverywhere() {
        XCTAssertEqual(clean("<img src=\"a.png\" srcset=\"a.png 1x, b.png 2x\">"), "<img src=\"a.png\">")
        XCTAssertEqual(clean("<picture><source SRCSET=\"x\"><img src=\"a.png\"></picture>"), "<picture><source><img src=\"a.png\"></picture>")
    }

    func testHrefAndFriendsMustPassTheLinkPolicy() {
        let table: [(String, String)] = [
            ("<a href=\"javascript:alert(1)\">x</a>", "<a>x</a>"),
            ("<a href=\"JaVaScRiPt:alert(1)\">x</a>", "<a>x</a>"),
            ("<a href=\" javascript:alert(1)\">x</a>", "<a>x</a>"),
            ("<a href=\"&#x6A;avascript:alert(1)\">x</a>", "<a>x</a>"),
            ("<a href=\"jav&#9;ascript:alert(1)\">x</a>", "<a>x</a>"),
            ("<a href=\"java\nscript:alert(1)\">x</a>", "<a>x</a>"),
            ("<a href=\"javascript&colon;alert(1)\">x</a>", "<a>x</a>"),
            ("<a href='vbscript:x'>x</a>", "<a>x</a>"),
            ("<a href=\"data:text/html;base64,AAAA\">x</a>", "<a>x</a>"),
            ("<a href=\"https://x.test\" href=\"javascript:alert(1)\">x</a>", "<a href=\"https://x.test\">x</a>"),
            ("<svg><use xlink:href=\"javascript:x\"/></svg>", "<svg><use /></svg>"),
            ("<svg><a XLINK:HREF=\"javascript:x\">t</a></svg>", "<svg><a>t</a></svg>"),
            ("<math><mi xlink:href=\"javascript:alert(1)\">x</mi></math>", "<math><mi>x</mi></math>"),
            ("<button formaction=\"javascript:x\">b</button>", "<button>b</button>"),
            ("<input type=submit formaction=javascript:x>", "<input type=\"submit\">"),
            ("<a href>x</a>", "<a href>x</a>"),
        ]
        for (input, expected) in table { XCTAssertEqual(clean(input), expected, input) }
    }

    func testSvgAnimationCannotSetAnHrefToAScript() {
        XCTAssertEqual(clean("<svg><a><animate attributeName=\"href\" values=\"javascript:alert(1)\"/></a></svg>"), "<svg><a><animate attributeName=\"href\" /></a></svg>")
        XCTAssertEqual(clean("<svg><a><set attributeName=\"xlink:href\" to=\"javascript:alert(1)\"/></a></svg>"), "<svg><a><set attributeName=\"xlink:href\" /></a></svg>")
        XCTAssertEqual(clean("<svg><circle><animate attributeName=\"r\" values=\"1;2\"/></circle></svg>"), "<svg><circle><animate attributeName=\"r\" values=\"1;2\" /></circle></svg>")
    }

    func testSrcMustBeAnAcceptableImageSource() {
        XCTAssertEqual(clean("<img src=\"javascript:alert(1)\">"), "<img>")
        XCTAssertEqual(clean("<img src=\"&#106;avascript:alert(1)\">"), "<img>")
        XCTAssertEqual(clean("<img src=\"data:text/html;base64,AAAA\">"), "<img>")
        XCTAssertEqual(clean("<video src=\"javascript:x\"></video>"), "<video></video>")
        XCTAssertEqual(clean("<img src=\"https://e.test/a.png\">"), "<img src=\"https://e.test/a.png\">")
        XCTAssertEqual(clean("<img src=\"data:image/png;base64,AA==\">"), "<img src=\"data:image/png;base64,AA==\">")
        XCTAssertEqual(clean("<img src=\"a.png\">"), "<img src=\"a.png\">")
        XCTAssertEqual(clean("<img src=\"http://e.test/a.png\">"), "<img src=\"http://e.test/a.png\">", "left out later with a reason, not here")
        XCTAssertEqual(clean("<img src=\"no.png\">", allow: { $0 == "ok.png" }), "<img>", "the decision is the caller's")
        XCTAssertEqual(clean("<img src=\"ok.png\">", allow: { $0 == "ok.png" }), "<img src=\"ok.png\">")
    }

    // MARK: Comments, instructions, declarations

    func testCommentsInstructionsAndCDATAAreRemoved() {
        let table: [(String, String)] = [
            ("a<!-- c -->b", "ab"),
            ("a<!-- a -- b -->c", "ac"),
            ("a<!-->b", "ab"),
            ("a<!--->b", "ab"),
            ("a<!-- x --!>b", "ab"),
            ("a<!----!>b", "ab"),
            ("a<!---->b", "ab"),
            ("a<!-- never closed", "a"),
            ("<?php echo 1 ?>x", "x"),
            ("<![CDATA[ <b>x</b> ]]>y", "y"),
            ("<![CDATA[ never closed", ""),
            ("<!DOCTYPE html>x", "x"),
            ("<!ELEMENT x>y", "y"),
            ("</ bogus comment>z", "z"),
            ("a</>b", "ab"),
            ("<!--><script>alert(1)</script>-->", "-->"),
            ("<!-- <script>alert(1)</script> -->x", "x"),
            ("<![CDATA[><script>alert(1)</script>]]>x", "x"),
        ]
        for (input, expected) in table { XCTAssertEqual(clean(input), expected, input) }
    }

    func testAnUnterminatedConstructEndsAtTheBlockBoundary() {
        XCTAssertEqual(clean("a<!-- open\u{E002}b"), "a\u{E002}b")
        XCTAssertEqual(clean("a<img src=x onerror=alert(1)\u{E002}b"), "a\u{E002}b")
        XCTAssertEqual(clean("a<?pi\u{E002}b"), "a\u{E002}b")
        XCTAssertEqual(clean("a<![CDATA[ x\u{E002}b"), "a\u{E002}b")
    }

    func testAnUnterminatedTagIsDropped() {
        XCTAssertEqual(clean("<img src=x onerror=alert(1)//"), "")
        XCTAssertEqual(clean("text <a href=\"https://x.test"), "text ")
    }

    // MARK: Adversarial table

    func testAdversarialInputs() {
        let table: [(String, String)] = [
            ("<scr<script>ipt>alert(1)</scr</script>ipt>", "ipt>alert(1)ipt>"),
            // The tag name runs to the first `>` (`scr<!--`), so both are odd tags that go and the text around them stays.
            ("<scr<!-- -->ipt>alert(1)</scr<!-- -->ipt>", "ipt>alert(1)ipt>"),
            ("<<script>alert(1)</script>", "&lt;"),
            ("<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\"></noscript>",
             "<noscript><p title=\"&lt;/noscript&gt;&lt;img src=x onerror=alert(1)&gt;\"></noscript>"),
            ("<textarea></textarea><script>alert(1)</script>", "<textarea></textarea>"),
            ("<img src=x onerror=alert(1) onerror=again>", "<img src=\"x\">"),
            ("<a href=\"https://ok.test\" onclick=x href=javascript:y>t</a>", "<a href=\"https://ok.test\">t</a>"),
            ("<IMG SRC=JaVaScRiPt:alert(1)>", "<IMG>"),
            ("<body onload=alert(1)>x</body>", "<body>x</body>"),
            ("<style>@import url(javascript:alert(1));</style>y", "y"),
            ("<math><annotation-xml encoding=\"text/html\"><script>alert(1)</script></annotation-xml></math>", "<math><annotation-xml encoding=\"text/html\"></annotation-xml></math>"),
        ]
        for (input, expected) in table { XCTAssertEqual(clean(input), expected, input) }
    }

    // MARK: details

    func testDetailsAreOpenedForPrintOnly() {
        XCTAssertEqual(clean("<details><summary>S</summary>x</details>", openDetails: true), "<details open><summary>S</summary>x</details>")
        XCTAssertEqual(clean("<details><summary>S</summary>x</details>"), "<details><summary>S</summary>x</details>")
        XCTAssertEqual(clean("<DETAILS class=c>x</DETAILS>", openDetails: true), "<DETAILS class=\"c\" open>x</DETAILS>")
        XCTAssertEqual(clean("<details open>x</details>", openDetails: true), "<details open>x</details>")
        XCTAssertEqual(clean("<details OPEN=\"\">x</details>", openDetails: true), "<details OPEN=\"\">x</details>")
    }

    // MARK: Surviving image sources

    func testSurvivingImageSourcesAreListedInOrderWithoutRepeats() {
        let out = HTMLSanitizer.scan("<img src='a.png'><p><img src=\"a.png\"><img src=b.png alt=x></p><img src=\"a&amp;c.png\">",
                                     openDetails: false, allowImageSource: LinkPolicy.isCandidateImageSource)
        XCTAssertEqual(out.imageSources, ["a.png", "b.png", "a&c.png"])
    }

    func testImagesInsideRemovedConstructsAreNotListed() {
        let html = "<style><img src=\"s.png\"></style><!-- <img src=\"c.png\"> --><script>x='<img src=\"j.png\">'</script>"
            + "<img src=\"javascript:alert(1)\"><img src=\"data:text/html;base64,AA\"><img src=\"keep.png\"><img>"
        XCTAssertEqual(HTMLSanitizer.scan(html, openDetails: false, allowImageSource: LinkPolicy.isCandidateImageSource).imageSources, ["keep.png"])
    }

    func testOnlyImgElementsContributeSources() {
        let out = HTMLSanitizer.scan("<video src=\"v.mp4\"></video><img src=\"i.png\"><source src=\"s.png\">",
                                     openDetails: false, allowImageSource: LinkPolicy.isCandidateImageSource)
        XCTAssertEqual(out.imageSources, ["i.png"])
    }

    // MARK: Rewriting images (used by assemble)

    func testRewritingImageSources() {
        let html = "<p><img src=\"a.png\" alt=\"A\"><img src=\"b.png\"><img src=\"c.png\" alt=\"C\" width=\"3\"></p>"
        let out = HTMLSanitizer.rewriteImages(in: html) { source, alt in
            switch source {
            case "a.png": return .source("data:image/png;base64,QQ==")
            case "b.png": return .replace("<span class=\"gone\">b.png</span>")
            default: _ = alt; return .keep
            }
        }
        XCTAssertEqual(out, "<p><img src=\"data:image/png;base64,QQ==\" alt=\"A\"><span class=\"gone\">b.png</span><img src=\"c.png\" alt=\"C\" width=\"3\"></p>")
    }

    func testRewritingPassesTheDecodedSourceAndAlt() {
        var seen: [(String, String?)] = []
        _ = HTMLSanitizer.rewriteImages(in: "<img src=\"a&amp;b.png\" alt=\"x &lt; y\"><img src=\"c.png\">") { s, a in seen.append((s, a)); return .keep }
        XCTAssertEqual(seen.map(\.0), ["a&b.png", "c.png"])
        XCTAssertEqual(seen.map { $0.1 }, ["x < y", nil])
    }

    // MARK: Properties

    func testSanitisingTwiceChangesNothing() {
        let corpus = [
            "<p align=center><IMG SRC=x onerror=alert(1)>t</p>", "a<script>x</script>b<!-- c -->d", "<a href='javascript:x' title=t>l</a>",
            "<svg/onload=alert(1)><path d='M0 0'/></svg>", "<details><summary>S</summary><b>x</b></details>", "x < y & z",
            "<table><tr><td>1<td>2</table>", "<scr<script>ipt>", "<img src=\"a&amp;b.png\" srcset=\"q\">",
        ]
        for s in corpus {
            let once = clean(s, openDetails: true)
            XCTAssertEqual(clean(once, openDetails: true), once, s)
        }
    }

    /// An independent check of the output: it is nothing but text without `<` and canonical tags, no tag is one that must go, no attribute
    /// is an event handler or `srcset`, and no link-like value starts with a script scheme once references and white space are undone.
    private func assertSafe(_ out: String, from input: String, file: StaticString = #filePath, line: UInt = #line) {
        let tag = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9:_.-]*)((?: [A-Za-z_:][-A-Za-z0-9_:.]*(?:=\"[^\"<>]*\")?)*)( ?/)?>")
        let ns = out as NSString
        var residue = out
        let removedNames: Set<String> = ["script", "style", "iframe", "frame", "frameset", "object", "embed", "applet", "form", "link", "meta", "base", "title"]
        let attr = try! NSRegularExpression(pattern: " ([A-Za-z_:][-A-Za-z0-9_:.]*)(?:=\"([^\"]*)\")?")
        for m in tag.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            XCTAssertFalse(removedNames.contains(name), "tag <\(name)> survived: \(out.debugDescription) from \(input.debugDescription)", file: file, line: line)
            let attrs = ns.substring(with: m.range(at: 3)) as NSString
            for a in attr.matches(in: attrs as String, range: NSRange(location: 0, length: attrs.length)) {
                let an = attrs.substring(with: a.range(at: 1)).lowercased()
                XCTAssertFalse(an.hasPrefix("on"), "handler \(an) survived: \(out.debugDescription)", file: file, line: line)
                XCTAssertNotEqual(an, "srcset", file: file, line: line)
                if ["href", "xlink:href", "action", "formaction", "src"].contains(an), a.range(at: 2).location != NSNotFound {
                    let v = oracleNormalise(attrs.substring(with: a.range(at: 2)))
                    for scheme in ["javascript:", "vbscript:"] { XCTAssertFalse(v.hasPrefix(scheme), "\(an)=\(v) survived: \(out.debugDescription) from \(input.debugDescription)", file: file, line: line) }
                    if an != "src" { XCTAssertFalse(v.hasPrefix("data:"), "\(an)=\(v) survived: \(out.debugDescription)", file: file, line: line) }
                }
            }
            residue = (residue as NSString).replacingCharacters(in: m.range, with: "")
        }
        XCTAssertFalse(residue.contains("<"), "a stray < survived: \(out.debugDescription) from \(input.debugDescription)", file: file, line: line)
        XCTAssertFalse(out.contains("<!") || out.contains("<?"), file: file, line: line)
    }

    /// What a browser's URL parser would see in an attribute value, written separately from `LinkPolicy`.
    private func oracleNormalise(_ value: String) -> String {
        var s = value
        let numeric = try! NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);?")
        for m in numeric.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).reversed() {
            let ns = s as NSString
            let hex = ns.substring(with: m.range(at: 1)).isEmpty == false
            if let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(n) {
                s = ns.replacingCharacters(in: m.range, with: String(Character(u)))
            }
        }
        for (name, ch) in [("&colon;", ":"), ("&Tab;", "\t"), ("&NewLine;", "\n"), ("&amp;", "&")] { s = s.replacingOccurrences(of: name, with: ch) }
        s = s.filter { !"\t\n\r".contains($0) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"..."\u{20}")).lowercased()
    }

    func testEveryAdversarialInputPassesTheIndependentCheck() {
        let seeds = SanitizerCorpus.dangerous + SanitizerCorpus.benign
        for s in seeds { assertSafe(clean(s), from: s) ; assertSafe(clean(s, openDetails: true), from: s) }
    }

    func testRandomMutationsNeverLetAForbiddenConstructThrough() {
        var rng = SeededGenerator(seed: 0x5EED_2026_1010)
        let seeds = SanitizerCorpus.dangerous + SanitizerCorpus.benign
        let pieces = ["<", ">", "\"", "'", "=", "/", "!", "-", "--", "--!>", "-->", "<!--", "<![CDATA[", "]]>", "<?", "&#", "&#x", ";", " ", "\t", "\n",
                      "\u{0}", "\u{E002}", "`", "<script>", "</script>", "<style>", "</style>", "on", "javascript:", "href=", "src=", "<a ", "<img ",
                      "<svg ", "&colon;", "&Tab;", "&#106;", "x", "A", "\\", "?", "#", "(", ")", "{", "}"]
        for i in 0..<4000 {
            var s = Array(seeds[Int(rng.next() % UInt64(seeds.count))])
            for _ in 0..<(1 + Int(rng.next() % 6)) {
                let at = s.isEmpty ? 0 : Int(rng.next() % UInt64(s.count + 1))
                switch rng.next() % 5 {
                case 0: s.insert(contentsOf: Array(pieces[Int(rng.next() % UInt64(pieces.count))]), at: min(at, s.count))
                case 1: if at < s.count { s.remove(at: at) }
                case 2: if at < s.count { s.insert(s[at], at: at) }
                case 3: if at < s.count { let c = String(s[at]); s[at] = Character(c == c.lowercased() ? c.uppercased() : c.lowercased()) }
                default: if s.count > 2, at + 1 < s.count { s.swapAt(at, at + 1) }
                }
            }
            let input = String(s)
            let out = clean(input, openDetails: i % 2 == 0)
            assertSafe(out, from: input)
            XCTAssertEqual(clean(out, openDetails: i % 2 == 0), out, "not idempotent for \(input.debugDescription)")
        }
    }
}

/// Seed inputs for the property tests.
enum SanitizerCorpus {
    static let dangerous = [
        "<script>alert(1)</script>", "<img src=x onerror=alert(1)>", "<a href=\"javascript:alert(1)\">x</a>", "<svg onload=alert(1)></svg>",
        "<iframe src=\"https://e.test\"></iframe>", "<style>p{}</style>", "<!-- c --><?pi ?><![CDATA[x]]>", "<a href=\"&#x6A;avascript:alert(1)\">x</a>",
        "<a href=\" JaVaScRiPt:alert(1)\">x</a>", "<img srcset=\"a 1x\" src=a.png>", "<scr<script>ipt>alert(1)</scr</script>ipt>",
        "<form action=\"javascript:x\"><input formaction=javascript:y></form>", "<svg><use xlink:href=\"javascript:x\"/></svg>",
        "<meta http-equiv=refresh content=0><base href=//e.test/><link rel=stylesheet href=x>", "<object data=x></object><embed src=y><applet></applet>",
        "<svg><a><animate attributeName=href values=javascript:alert(1)></a></svg>", "<a href='data:text/html,<script>alert(1)</script>'>x</a>",
        "<img src=\"javascript:alert(1)\"><video src=\"vbscript:x\">", "<title>t</title><frameset><frame src=x></frameset>",
        "<a href=\"jav&#9;ascript:alert(1)\">x</a><a href=\"java\nscript:alert(1)\">y</a>", "<noscript><p title=\"</noscript><img onerror=x>\"></noscript>",
        "<math><mi xlink:href=\"javascript:alert(1)\">x</mi></math>", "<script src=x>", "<style>", "<!--", "<img src=x onerror=alert(1)",
    ]
    static let benign = [
        "<p align=\"center\"><img src=\"local.png\"></p>", "<details><summary>More</summary><p>text</p></details>", "plain text with & and < and >",
        "<a href=\"https://example.com/?a=1&amp;b=2\" title=\"t\">link</a>", "<table><tr><td>1</td><td>2</td></tr></table>",
        "<svg viewBox=\"0 0 1 1\"><path d=\"M0 0\"/></svg>", "<b>b</b><i>i</i><u>u</u><sub>s</sub><sup>p</sup>", "<br/><hr><br />", "&lt;b&gt; &amp; &copy;",
    ]
}

/// SplitMix64, so the mutation test replays exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
