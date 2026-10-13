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

    // MARK: Callouts (DW-006)

    private func palette(_ h: EditorHarness) -> Palette { AppearanceResolver.palette(for: h.textView.effectiveAppearance) }

    /// The height of the line fragment that holds the character at `index`.
    private func lineHeight(_ h: EditorHarness, at index: Int) -> CGFloat {
        let layout = h.textView.layoutManager!
        layout.ensureLayout(for: h.textView.textContainer!)
        return layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil).height
    }

    func testEveryLineOfACalloutCarriesItsBarColourAndKeepsTheQuoteBar() {
        let h = EditorHarness(text: "intro\n\n> [!WARNING] T\n> body\n>\n> > deeper\n\nafter\n")
        h.select(0)
        let p = palette(h)
        for word in ["[!WARNING]", "body", "deeper"] {
            let at = h.index(of: word)
            XCTAssertEqual(h.attrs(at: at)[.dwCalloutBar] as? NSColor, p.calloutColor(.warning).nsColor, word)
            XCTAssertEqual(h.attrs(at: at)[.dwQuoteBarColor] as? NSColor, p.quoteBar.nsColor, "\(word) keeps the quote bar colour for deeper levels")
        }
        let blank = h.index(of: ">\n> >")
        XCTAssertEqual(h.attrs(at: blank)[.dwCalloutBar] as? NSColor, p.calloutColor(.warning).nsColor, "the empty `>` line too")
        XCTAssertEqual(h.attrs(at: h.index(of: "deeper"))[.dwQuoteDepth] as? Int, 2)
        for word in ["intro", "after"] { XCTAssertNil(h.attrs(at: h.index(of: word))[.dwCalloutBar], word) }
    }

    func testTheMarkerHidesAndTheLabelMarkSitsOnItsFirstCharacter() throws {
        let h = EditorHarness(text: "intro\n\n> [!NOTE] My title\n> body text\n\nafter\n")
        h.select(0)
        let p = palette(h)
        let marker = h.index(of: "[!NOTE]")
        let mark = try XCTUnwrap(h.attrs(at: marker)[.dwCallout] as? CalloutMark)
        XCTAssertEqual(mark.kind, .note)
        XCTAssertEqual(mark.name, "Note")
        XCTAssertEqual(mark.color, p.calloutColor(.note).nsColor)
        XCTAssertTrue(mark.font.isBold)
        XCTAssertGreaterThan(h.font(at: marker).pointSize, 10, "the mark's character keeps the line's real font")
        XCTAssertEqual(h.color(at: marker), NSColor.clear, "…but draws nothing itself")
        for offset in 1..<"[!NOTE] ".utf16.count {
            XCTAssertTrue(h.isHidden(at: marker + offset), "marker character \(offset) is hidden")
            XCTAssertNil(h.attrs(at: marker + offset)[.dwCallout], "only the first character carries the mark")
        }
        XCTAssertTrue(h.isHidden(at: h.index(of: "> [!NOTE]")), "the line's own `> ` hides too")
        XCTAssertNotNil(h.attrs(at: marker)[.kern], "a title follows, so the label's room is reserved")
        XCTAssertEqual(h.textView.string, "intro\n\n> [!NOTE] My title\n> body text\n\nafter\n", "nothing is deleted")
        for word in ["body", "intro", "My title"] { XCTAssertNil(h.attrs(at: h.index(of: word))[.dwCallout], word) }
    }

    func testTheTitleIsBoldInTheCalloutColourWithItsInlineFormatting() {
        let h = EditorHarness(text: "> [!TIP] Plain **strong** `code` end\n> body\n")
        h.select(h.textView.string.utf16.count)
        let tip = palette(h).calloutColor(.tip).nsColor
        for word in ["Plain", "end"] {
            XCTAssertTrue(h.font(at: h.index(of: word)).isBold, word)
            XCTAssertEqual(h.color(at: h.index(of: word)), tip, word)
        }
        XCTAssertTrue(h.font(at: h.index(of: "strong")).isBold)
        XCTAssertTrue(h.isHidden(at: h.index(of: "**")), "inline markers in the title still hide")
        XCTAssertNotNil(h.attrs(at: h.index(of: "code"))[.dwPill], "inline code keeps its pill")
        XCTAssertFalse(h.font(at: h.index(of: "body")).isBold, "the body is not part of the title")
        XCTAssertNotEqual(h.color(at: h.index(of: "body")), tip)
    }

    func testBodyLinesLookExactlyLikeAPlainQuotesLines() {
        let callout = EditorHarness(text: "> [!NOTE]\n> body **bold** text\n")
        let plain = EditorHarness(text: "> [?NOTE]\n> body **bold** text\n")
        callout.select(callout.textView.string.utf16.count); plain.select(plain.textView.string.utf16.count)
        let a = callout.index(of: "body"), b = plain.index(of: "body")
        for offset in [0, 1, 6, 7, 8, 12] {
            XCTAssertEqual(callout.font(at: a + offset), plain.font(at: b + offset), "font at +\(offset)")
            XCTAssertEqual(callout.color(at: a + offset), plain.color(at: b + offset), "colour at +\(offset)")
            XCTAssertEqual(callout.paragraph(at: a + offset), plain.paragraph(at: b + offset), "paragraph style at +\(offset)")
            XCTAssertEqual(callout.attrs(at: a + offset)[.dwQuoteDepth] as? Int, plain.attrs(at: b + offset)[.dwQuoteDepth] as? Int)
            XCTAssertEqual(callout.attrs(at: a + offset)[.dwQuoteBarColor] as? NSColor, plain.attrs(at: b + offset)[.dwQuoteBarColor] as? NSColor)
        }
        XCTAssertEqual(callout.isHidden(at: callout.index(of: "> body")), plain.isHidden(at: plain.index(of: "> body")), "`> ` hides alike")
    }

    func testSelectionOnTheMarkerLineShowsTheLiteralLineAndTheLabelComesBack() throws {
        let h = EditorHarness(text: "intro\n\n> [!NOTE] My title\n> body text\n\nafter\n")
        let p = palette(h)
        let marker = h.index(of: "[!NOTE]")
        let lineStart = h.index(of: "> [!NOTE]"), lineEnd = h.index(of: "\n> body")
        XCTAssertNotNil(h.attrs(at: marker)[.dwCallout], "precondition: the label shows while the caret is away")
        for caret in [lineStart, marker + 3, lineEnd] {
            h.select(caret)
            XCTAssertNil(h.attrs(at: marker)[.dwCallout], "no label with the caret at \(caret)")
            XCTAssertFalse(h.isHidden(at: marker), "the marker shows")
            XCTAssertFalse(h.isHidden(at: lineStart), "…and the line's `> `")
            XCTAssertEqual(h.color(at: marker), p.marker.nsColor)
            XCTAssertEqual(h.color(at: lineStart), p.marker.nsColor)
            XCTAssertNotNil(h.attrs(at: lineStart)[.dwCalloutBar], "the bar stays in the callout colour")
            XCTAssertTrue(h.font(at: h.index(of: "My title")).isBold, "the title is still styled as a title")
            XCTAssertEqual(h.color(at: h.index(of: "My title")), p.calloutColor(.note).nsColor)
        }
        h.select(marker + 3, 4)
        XCTAssertNil(h.attrs(at: marker)[.dwCallout], "a selection inside counts too")
        h.select(lineEnd + 3)                                  // body line
        XCTAssertNotNil(h.attrs(at: marker)[.dwCallout], "the label returns when the selection leaves the line")
        h.select(lineStart - 1)                                // the blank line above
        XCTAssertNotNil(h.attrs(at: marker)[.dwCallout])
    }

    func testAMarkerLineWithoutATitleKeepsItsHeightAndReservesNoRoom() throws {
        let h = EditorHarness(text: "intro\n\n> [!CAUTION]\n> body\n\nafter\n")
        h.select(0)
        let marker = h.index(of: "[!CAUTION]")
        let mark = try XCTUnwrap(h.attrs(at: marker)[.dwCallout] as? CalloutMark)
        XCTAssertEqual(mark.kind, .caution)
        let body = lineHeight(h, at: h.index(of: "body"))
        XCTAssertGreaterThan(lineHeight(h, at: marker), body * 0.9, "the marker line is not a sliver")
        let width = ("[" as NSString).size(withAttributes: [.font: h.font(at: marker)]).width
        XCTAssertEqual(((h.attrs(at: marker)[.kern] as? NSNumber)?.doubleValue ?? 99) + Double(width), 0, accuracy: 0.001, "nothing follows, so it advances by nothing")
    }

    func testTheKernReservesExactlyTheLabelAndTheGapBeforeATitle() throws {
        let h = EditorHarness(text: "> [!IMPORTANT] Title\n> body\n")
        h.select(h.textView.string.utf16.count)
        let marker = h.index(of: "[!IMPORTANT]")
        let mark = try XCTUnwrap(h.attrs(at: marker)[.dwCallout] as? CalloutMark)
        let width = ("[" as NSString).size(withAttributes: [.font: h.font(at: marker)]).width
        XCTAssertEqual(CGFloat((h.attrs(at: marker)[.kern] as? NSNumber)?.doubleValue ?? 0) + width, mark.reservedWidth, accuracy: 0.001)
        XCTAssertGreaterThan(mark.reservedWidth, mark.labelWidth, "a gap separates the label from the title")
        XCTAssertGreaterThan(mark.labelWidth, mark.nameWidth + mark.iconSide, "icon, gap and name")
    }

    func testEachKindGetsItsOwnMarkAndColour() throws {
        let text = "> [!NOTE]\n> a\n\n> [!TIP]\n> a\n\n> [!IMPORTANT]\n> a\n\n> [!WARNING]\n> a\n\n> [!CAUTION]\n> a\n"
        let h = EditorHarness(text: text)
        h.select(text.utf16.count)
        var colours: [NSColor] = []
        for kind in CalloutKind.allCases {
            let mark = try XCTUnwrap(h.attrs(at: h.index(of: "[!\(kind.rawValue.uppercased())]"))[.dwCallout] as? CalloutMark, kind.rawValue)
            XCTAssertEqual(mark.kind, kind)
            XCTAssertEqual(mark.name, kind.title)
            colours.append(mark.color)
        }
        XCTAssertEqual(Set(colours.map { $0.hashValue }).count, 5)
    }

    func testPlainQuotesCarryNoCalloutAttributesAtAll() throws {
        let rows = try CalloutFixture.rows().filter { !$0.isCallout }
        for row in rows {
            let h = EditorHarness(text: row.source + "\n")
            h.select(h.textView.string.utf16.count)
            h.storage.enumerateAttributes(in: NSRange(location: 0, length: h.storage.length), options: []) { attrs, range, _ in
                XCTAssertNil(attrs[.dwCallout], "row \(row.id) at \(range)")
                XCTAssertNil(attrs[.dwCalloutBar], "row \(row.id) at \(range)")
            }
        }
    }

    func testEveryCalloutRowOfTheFixtureIsStyledAsOneAndNothingElseIs() throws {
        let h = EditorHarness(text: try CalloutFixture.text(), size: NSSize(width: 900, height: 760))
        h.select(0)
        let analysis = h.coordinator.analysis
        var withMark = 0
        h.storage.enumerateAttribute(.dwCallout, in: NSRange(location: 0, length: h.storage.length), options: []) { value, _, _ in
            if value != nil { withMark += 1 }
        }
        XCTAssertEqual(withMark, analysis.callouts.count, "one label per callout, none for a plain quote")
        XCTAssertEqual(analysis.callouts.count, try CalloutFixture.rows().filter(\.isCallout).count)
        for c in analysis.callouts {
            for line in c.firstLine...c.lastLine where analysis.lines[line].range.length > 0 {
                XCTAssertNotNil(h.attrs(at: analysis.lines[line].range.location)[.dwCalloutBar], "line \(line + 1) of a \(c.kind) callout")
            }
        }
    }
}
