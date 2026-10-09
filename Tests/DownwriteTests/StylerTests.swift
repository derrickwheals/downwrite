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

    func testInlineHTMLTagsHideLikeMarkdownSyntax() {
        let h = EditorHarness(text: "press <kbd>⌘K</kbd> for <b>bold</b>, <u>under</u>, <mark>marked</mark>, x<sup>2</sup> and H<sub>2</sub>O end")
        h.select(h.textView.string.utf16.count)
        let kbd = h.index(of: "<kbd>"), bold = h.index(of: "<b>")
        XCTAssertTrue(h.isHidden(at: kbd), "tags hide while the caret is elsewhere")
        XCTAssertTrue(h.isHidden(at: h.index(of: "</kbd>")))
        XCTAssertTrue(h.isHidden(at: bold))
        XCTAssertNotNil(h.attrs(at: h.index(of: "⌘K"))[.dwPill], "kbd is drawn like inline code")
        XCTAssertTrue(h.font(at: h.index(of: "⌘K")).isFixedPitch)
        XCTAssertTrue(h.font(at: h.index(of: "bold<")).isBold)
        XCTAssertNotNil(h.attrs(at: h.index(of: "under"))[.underlineStyle])
        XCTAssertNotNil(h.attrs(at: h.index(of: "marked"))[.dwPill], "mark gets the highlight pill")
        h.select(kbd + 7)                                            // inside the pair
        XCTAssertFalse(h.isHidden(at: kbd), "the tags come back around the caret")
        XCTAssertFalse(h.isHidden(at: h.index(of: "</kbd>")))
        XCTAssertTrue(h.isHidden(at: bold), "…and only around it")
        XCTAssertGreaterThan(h.font(at: kbd).pointSize, 10)
    }

    func testSuperAndSubscriptAreSmallerAndShifted() {
        let h = EditorHarness(text: "x<sup>2</sup> and H<sub>2</sub>O\n")
        h.select(h.textView.string.utf16.count)
        let body = h.font(at: h.index(of: "x<")).pointSize
        let sup = h.index(of: "2</sup>"), sub = h.index(of: "2</sub>")
        XCTAssertLessThan(h.font(at: sup).pointSize, body)
        XCTAssertLessThan(h.font(at: sub).pointSize, body)
        XCTAssertGreaterThan((h.attrs(at: sup)[.baselineOffset] as? NSNumber)?.doubleValue ?? 0, 0, "raised")
        XCTAssertLessThan((h.attrs(at: sub)[.baselineOffset] as? NSNumber)?.doubleValue ?? 0, 0, "lowered")
        XCTAssertNil(h.attrs(at: h.index(of: " and"))[.baselineOffset])
    }

    func testHTMLAnchorIsALinkAndTheTagIsHidden() {
        let h = EditorHarness(text: "go <a href=\"https://example.com\">there</a> now")
        h.select(h.textView.string.utf16.count)
        XCTAssertNotNil(h.attrs(at: h.index(of: "there"))[.underlineStyle])
        XCTAssertEqual(h.color(at: h.index(of: "there")), h.coordinator.styler.palette.link.nsColor)
        XCTAssertTrue(h.isHidden(at: h.index(of: "<a href")))
        XCTAssertTrue(h.isHidden(at: h.index(of: "https://example.com")))
        XCTAssertEqual(h.coordinator.analysis.link(at: h.index(of: "there") + 1)?.destination, "https://example.com")
    }

    func testUnsupportedInlineHTMLStaysDimMonospaceSource() {
        let h = EditorHarness(text: "a <span style=\"color:red\">b</span> c <br> d\n")
        h.select(h.textView.string.utf16.count)
        let tag = h.index(of: "<span")
        XCTAssertFalse(h.isHidden(at: tag))
        XCTAssertTrue(h.font(at: tag).isFixedPitch)
        XCTAssertEqual(h.color(at: tag), h.coordinator.styler.palette.secondaryText.nsColor)
        XCTAssertFalse(h.isHidden(at: h.index(of: "<br>")))
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

    func testTableSourceUsesMonospaceCardWhenShownAsMarkdown() {
        let h = EditorHarness(text: "| a | b |\n| - | - |\n| 1 | 2 |\n\nend\n")
        h.coordinator.showTableSource(order: 0, at: TableCellPosition(row: 1, column: 0))
        XCTAssertTrue(h.font(at: 2).isFixedPitch)
        XCTAssertNotNil(h.attrs(at: 2)[.dwBlockBackground])
        XCTAssertTrue(h.font(at: 2).isBold, "header row is bold")
    }

    func testQuotedTableKeepsTheMonospaceSourceCard() {
        let h = EditorHarness(text: "> | a | b |\n> | - | - |\n> | 1 | 2 |\n\nend\n")
        h.select(h.textView.string.utf16.count)
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 0, "only top-level tables become grids")
        XCTAssertTrue(h.font(at: 4).isFixedPitch)
        XCTAssertNotNil(h.attrs(at: 4)[.dwBlockBackground])
    }

    func testGridTableSourceIsCollapsedBehindTheGrid() {
        let h = EditorHarness(text: "| a | b |\n| - | - |\n| 1 | 2 |\n\nend\n")
        h.select(h.textView.string.utf16.count)
        for i in [0, 2, 10, 20] { XCTAssertTrue(h.isHidden(at: i) || h.font(at: i).pointSize < 1, "source character \(i) is collapsed") }
        XCTAssertEqual(h.paragraph(at: 2).maximumLineHeight, 0.1, accuracy: 0.001)
        XCTAssertGreaterThan(h.coordinator.tableOverlay.grids[0].totalHeight, 60)
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
