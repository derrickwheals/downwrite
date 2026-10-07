import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

@MainActor
final class StylerTests: XCTestCase {
    func testHeadingIsLargerAndBold() {
        let h = EditorHarness(text: "# Title\n\nBody text\n")
        h.select(12)   // in the body
        let title = h.font(at: h.index(of: "Title")), body = h.font(at: h.index(of: "Body"))
        XCTAssertGreaterThan(title.pointSize, body.pointSize * 1.5)
        XCTAssertTrue(title.isBold)
        XCTAssertFalse(body.isBold)
    }

    func testBoldMarkersHiddenUntilCaretTouchesThem() {
        let h = EditorHarness(text: "plain **bold** tail")
        h.select(0)
        let marker = h.index(of: "**")
        XCTAssertTrue(h.isHidden(at: marker), "opening ** should be hidden with caret elsewhere")
        XCTAssertTrue(h.isHidden(at: marker + 6 + 1), "closing ** should be hidden")
        XCTAssertTrue(h.font(at: marker + 2).isBold)
        h.select(marker + 4)   // inside the word
        XCTAssertFalse(h.isHidden(at: marker), "marker must reappear when the caret is inside the pair")
        XCTAssertGreaterThan(h.font(at: marker).pointSize, 10)
        h.select(h.textView.string.utf16.count)   // far away again
        XCTAssertTrue(h.isHidden(at: marker))
    }

    func testItalicStrikeAndInlineCode() {
        let h = EditorHarness(text: "an *it* and ~~gone~~ and `code` end")
        h.select(h.textView.string.utf16.count)
        XCTAssertTrue(h.font(at: h.index(of: "it*") ).isItalic)
        XCTAssertNotNil(h.attrs(at: h.index(of: "gone"))[.strikethroughStyle])
        let code = h.font(at: h.index(of: "code`"))
        XCTAssertTrue(code.isFixedPitch)
        XCTAssertNotNil(h.attrs(at: h.index(of: "code`"))[.dwPill])
    }

    func testLinkTextStyledAndDestinationHidden() {
        let h = EditorHarness(text: "go [there](https://example.com) now")
        h.select(h.textView.string.utf16.count)
        XCTAssertNotNil(h.attrs(at: h.index(of: "there"))[.underlineStyle])
        XCTAssertTrue(h.isHidden(at: h.index(of: "](")))
        XCTAssertTrue(h.isHidden(at: h.index(of: "example")))
        h.select(h.index(of: "there") + 2)
        XCTAssertFalse(h.isHidden(at: h.index(of: "](")))
    }

    func testCodeBlockCardAndHiddenFences() {
        let h = EditorHarness(text: "intro\n\n```swift\nlet x = 1\n```\n\nafter\n")
        h.select(0)
        let code = h.index(of: "let x")
        XCTAssertNotNil(h.attrs(at: code)[.dwBlockBackground])
        XCTAssertTrue(h.font(at: code).isFixedPitch)
        let fence = h.index(of: "```swift")
        XCTAssertTrue(h.isHidden(at: fence), "fence line collapses when the caret is outside the block")
        XCTAssertLessThan(h.paragraph(at: fence).maximumLineHeight, 1)
        h.select(code + 2)
        XCTAssertFalse(h.isHidden(at: fence), "fence returns when the caret enters the block")
    }

    func testBlockQuoteIndentAndBar() {
        let h = EditorHarness(text: "> quoted text\n\nplain\n")
        h.select(h.index(of: "plain"))
        let q = h.index(of: "quoted")
        XCTAssertGreaterThan(h.paragraph(at: q).headIndent, 8)
        XCTAssertEqual(h.attrs(at: q)[.dwQuoteDepth] as? Int, 1)
        XCTAssertTrue(h.isHidden(at: 0), "'> ' marker hidden off-line")
    }

    func testListHangingIndentAndAccentMarker() {
        let h = EditorHarness(text: "- first item that is long\n1. second\n")
        h.select(h.textView.string.utf16.count)
        XCTAssertGreaterThan(h.paragraph(at: 5).headIndent, 5)
        XCTAssertEqual(h.color(at: 0), AppearanceResolver.palette(for: h.textView.effectiveAppearance).accent.nsColor)
        XCTAssertTrue(h.font(at: 0).isBold)
    }

    func testCompletedTaskIsStruckThrough() {
        let h = EditorHarness(text: "- [x] done thing\n- [ ] open thing\n")
        h.select(h.textView.string.utf16.count)
        XCTAssertNotNil(h.attrs(at: h.index(of: "done")) [.strikethroughStyle])
        XCTAssertNil(h.attrs(at: h.index(of: "open"))[.strikethroughStyle])
    }

    func testHorizontalRuleDrawnOnlyWhenSyntaxHidden() {
        let h = EditorHarness(text: "above\n\n---\n\nbelow\n")
        h.select(0)
        let hr = h.index(of: "---")
        XCTAssertNotNil(h.attrs(at: hr)[.dwRule])
        XCTAssertTrue(h.isHidden(at: hr))
        h.select(hr + 1)
        XCTAssertNil(h.attrs(at: hr)[.dwRule])
        XCTAssertFalse(h.isHidden(at: hr))
    }

    func testTableUsesMonospaceCard() {
        let h = EditorHarness(text: "| a | b |\n| - | - |\n| 1 | 2 |\n\nend\n")
        h.select(h.textView.string.utf16.count)
        XCTAssertTrue(h.font(at: 2).isFixedPitch)
        XCTAssertNotNil(h.attrs(at: 2)[.dwBlockBackground])
        XCTAssertTrue(h.font(at: 2).isBold, "header row is bold")
    }

    func testHighlightGetsPill() {
        let h = EditorHarness(text: "some ==marked== text")
        h.select(h.textView.string.utf16.count)
        XCTAssertNotNil(h.attrs(at: h.index(of: "marked"))[.dwPill])
        XCTAssertTrue(h.isHidden(at: h.index(of: "==")))
    }

    func testLightAndDarkPalettesDiffer() {
        let light = EditorHarness(text: "text", dark: false)
        let dark = EditorHarness(text: "text", dark: true)
        XCTAssertNotEqual(light.color(at: 0), dark.color(at: 0))
        XCTAssertNotEqual(light.textView.backgroundColor, dark.textView.backgroundColor)
        let lum: (NSColor) -> CGFloat = { $0.usingColorSpace(.sRGB)!.brightnessComponent }
        XCTAssertGreaterThan(lum(light.textView.backgroundColor), 0.8)
        XCTAssertLessThan(lum(dark.textView.backgroundColor), 0.2)
    }

    func testAppearanceSwitchRestylesLiveEditor() {
        let h = EditorHarness(text: "hello", dark: false)
        let before = h.color(at: 0)
        h.window.appearance = NSAppearance(named: .darkAqua)
        h.coordinator.appearanceDidChange()
        XCTAssertNotEqual(h.color(at: 0), before)
    }

    func testFontChoiceChangesBodyFont() {
        let a = EditorHarness(text: "x", font: .sfMono), b = EditorHarness(text: "x", font: .newYork)
        XCTAssertTrue(a.font(at: 0).isFixedPitch)
        XCTAssertFalse(b.font(at: 0).isFixedPitch)
    }

    func testLargeDocumentStylesQuickly() {
        var s = ""
        for i in 0..<2000 { s += "## Heading \(i)\n\nA paragraph with **bold**, *italic*, `code` and a [link](https://x.y/\(i)).\n\n" }
        let start = Date()
        let h = EditorHarness(text: s)
        h.select(100)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 10, "initial style of ~180KB took \(elapsed)s")
        let move = Date()
        for i in 0..<50 { h.select(200 + i * 40) }
        XCTAssertLessThan(Date().timeIntervalSince(move), 3, "50 caret moves should stay interactive")
    }
}
