import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Pixel-level checks of what the custom drawing (code cards, inline pills) looks like, including that a selection
/// stays visible on top of them.
@MainActor
final class DrawingTests: XCTestCase {
    private func lm(_ h: EditorHarness) -> DWLayoutManager { h.textView.layoutManager as! DWLayoutManager }

    private func makeKey(_ h: EditorHarness) {
        h.window.makeKeyAndOrderFront(nil)
        h.window.makeFirstResponder(h.textView)
    }

    private func render(_ h: EditorHarness) -> NSBitmapImageRep {
        h.window.displayIfNeeded()
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        let tv: EditorTextView = h.textView
        let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
        tv.cacheDisplay(in: tv.bounds, to: rep)
        return rep
    }

    /// The text view's rect (view coordinates) covering the glyphs of `range`.
    private func rect(of range: NSRange, in h: EditorHarness) -> NSRect {
        let layout = h.textView.layoutManager!
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = layout.boundingRect(forGlyphRange: glyphs, in: h.textView.textContainer!)
        r.origin.x += h.textView.textContainerOrigin.x
        r.origin.y += h.textView.textContainerOrigin.y
        return r
    }

    private func color(_ rep: NSBitmapImageRep, atViewPoint p: NSPoint, in h: EditorHarness) -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / h.textView.bounds.width
        let x = min(max(0, Int((p.x * scale).rounded())), rep.pixelsWide - 1)
        let y = min(max(0, Int((p.y * scale).rounded())), rep.pixelsHigh - 1)
        return (rep.colorAt(x: x, y: y) ?? .black).usingColorSpace(.sRGB) ?? .black
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }

    /// Average colour of the *light* pixels (background, not glyph ink) inside `r`.
    private func meanLight(_ rep: NSBitmapImageRep, in r: NSRect, _ h: EditorHarness) -> NSColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, n: CGFloat = 0
        var y = r.minY
        while y < r.maxY {
            var x = r.minX
            while x < r.maxX {
                let c = color(rep, atViewPoint: NSPoint(x: x, y: y), in: h)
                if c.brightnessComponent > 0.55 { red += c.redComponent; green += c.greenComponent; blue += c.blueComponent; n += 1 }
                x += 0.5
            }
            y += 0.5
        }
        guard n > 0 else { return .black }
        return NSColor(srgbRed: red / n, green: green / n, blue: blue / n, alpha: 1)
    }

    /// How far the background inside `area` moves when `word` goes from "caret inside" to "selected" (same layout both
    /// times). Zero means the selection highlight is not visible; a selection tint moves it by about 0.3.
    private func selectionShift(_ h: EditorHarness, word: NSRange, area: () -> NSRect) -> CGFloat {
        h.select(word.location + 1)                        // caret inside: syntax revealed, so the layout matches the selected state
        let sample = area()
        XCTAssertGreaterThan(sample.width, 10)
        let before = meanLight(render(h), in: sample, h)
        h.select(word.location, word.length)
        let after = meanLight(render(h), in: sample, h)
        return distance(before, after)
    }

    /// The first inline pill's rectangle for `range`, in text view coordinates.
    private func pillRect(of range: NSRange, in h: EditorHarness) -> NSRect {
        let origin = h.textView.textContainerOrigin
        return (lm(h).pillRects(forCharacterRange: range).first ?? .zero).offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: Item 1 — selection must stay visible

    func testSelectionIsVisibleInsideACodeBlock() {
        let h = EditorHarness(text: "intro\n\n```\ntest\n```\n\nafter\n")
        makeKey(h)
        let word = NSRange(location: h.index(of: "test"), length: 4)
        let shift = selectionShift(h, word: word) { self.rect(of: word, in: h).insetBy(dx: 1, dy: 3) }
        XCTAssertGreaterThan(shift, 0.12, "selected text in a code block must show a selection highlight (shift \(shift))")
    }

    func testSelectionIsVisibleInsideInlineCode() {
        let h = EditorHarness(text: "Some `Agy code` here and more words\n")
        makeKey(h)
        let word = NSRange(location: h.index(of: "Agy code"), length: 8)
        let shift = selectionShift(h, word: word) { self.pillRect(of: word, in: h).insetBy(dx: 1, dy: 1) }
        XCTAssertGreaterThan(shift, 0.12, "selected inline code must show a selection highlight (shift \(shift))")
    }

    func testSelectionStillShowsOverAHighlightPill() {
        let h = EditorHarness(text: "Some ==marked words== here\n")
        makeKey(h)
        let word = NSRange(location: h.index(of: "marked words"), length: 12)
        let shift = selectionShift(h, word: word) { self.pillRect(of: word, in: h).insetBy(dx: 1, dy: 1) }
        XCTAssertGreaterThan(shift, 0.1, "selected highlighted text must show a selection highlight (shift \(shift))")
    }

    // MARK: Item 2 — pill height

    func testInlineCodePillIsTightAroundCapitalsAndDescenders() throws {
        let h = EditorHarness(text: "Some `Agy` code here\n")
        h.select(h.textView.string.utf16.count)
        let code = NSRange(location: h.index(of: "Agy"), length: 3)
        let layout = lm(h)
        let rects = layout.pillRects(forCharacterRange: code)
        XCTAssertEqual(rects.count, 1)
        let pill = try XCTUnwrap(rects.first)

        let glyph = layout.glyphIndexForCharacter(at: code.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = line.minY + layout.location(forGlyphAt: glyph).y
        let font = try XCTUnwrap(h.storage.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)

        let gapAbove = (baseline - font.capHeight) - pill.minY
        let gapBelow = pill.maxY - (baseline - font.descender)
        XCTAssertGreaterThan(gapAbove, 0, "the pill must reach above the capital letters")
        XCTAssertEqual(gapAbove, gapBelow, accuracy: 0.5, "same gap above capitals as below descenders")
        XCTAssertLessThan(gapAbove, font.pointSize * 0.3, "…and only a small one")
        XCTAssertLessThan(pill.height, line.height * 0.8, "much shorter than the full line (\(pill.height) vs \(line.height))")
    }

    func testPillPixelsStopJustAboveTheCapitals() throws {
        let h = EditorHarness(text: "Some `Agy` code here\n")
        h.select(h.textView.string.utf16.count)
        let code = NSRange(location: h.index(of: "Agy"), length: 3)
        let pill = try XCTUnwrap(lm(h).pillRects(forCharacterRange: code).first)
        let origin = h.textView.textContainerOrigin
        let rep = render(h)
        let palette = AppearanceResolver.palette(for: h.textView.effectiveAppearance)
        let x = pill.minX + origin.x - 1.25                       // in the side padding, clear of the glyphs
        func at(_ y: CGFloat) -> NSColor { color(rep, atViewPoint: NSPoint(x: x, y: y + origin.y), in: h) }
        // Colours read back from the bitmap differ slightly from the palette (colour space), the page white is ~0.18 away.
        XCTAssertLessThan(distance(at(pill.minY + 6), palette.inlineCodeBackground.nsColor), 0.09, "inside the pill")
        XCTAssertGreaterThan(distance(at(pill.minY - 3), palette.inlineCodeBackground.nsColor), 0.09, "just above the pill is page background")
        XCTAssertGreaterThan(distance(at(pill.maxY + 3), palette.inlineCodeBackground.nsColor), 0.09, "just below the pill is page background")
    }

    func testWrappedInlineCodeGetsOnePillPerLine() {
        let long = String(repeating: "word ", count: 60)
        let h = EditorHarness(text: "\(long)`" + String(repeating: "code ", count: 40) + "end`\n", size: NSSize(width: 520, height: 600))
        h.select(0)
        let start = h.index(of: "code code")
        let range = NSRange(location: start, length: 40 * 5)
        XCTAssertGreaterThan(lm(h).pillRects(forCharacterRange: range).count, 1)
    }

    // MARK: Task checkboxes

    func testCheckboxIsFilledWhenCheckedAndOutlinedWhenNot() throws {
        let h = EditorHarness(text: "- [ ] open\n- [x] done\n")
        makeKey(h)
        h.select(h.textView.string.utf16.count)
        let palette = AppearanceResolver.palette(for: h.textView.effectiveAppearance)
        func box(_ at: Int) throws -> NSRect {
            var r = try XCTUnwrap(lm(h).checkboxRect(forCharacterAt: at))
            r.origin.x += h.textView.textContainerOrigin.x; r.origin.y += h.textView.textContainerOrigin.y
            return r
        }
        let open = try box(0), done = try box(h.index(of: "- [x]"))
        let rep = render(h)
        /// Pixels in `r` that differ clearly from the page background (box fill, outline or tick), and their mean colour.
        func ink(_ r: NSRect) -> (share: CGFloat, mean: NSColor) {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, hit: CGFloat = 0, total: CGFloat = 0
            var y = r.minY
            while y < r.maxY {
                var x = r.minX
                while x < r.maxX {
                    total += 1
                    let c = color(rep, atViewPoint: NSPoint(x: x, y: y), in: h)
                    if distance(c, palette.background.nsColor) > 0.12 { hit += 1; red += c.redComponent; green += c.greenComponent; blue += c.blueComponent }
                    x += 0.5
                }
                y += 0.5
            }
            guard total > 0, hit > 0 else { return (0, .white) }
            return (hit / total, NSColor(srgbRed: red / hit, green: green / hit, blue: blue / hit, alpha: 1))
        }
        let filled = ink(done), outlined = ink(open)
        XCTAssertGreaterThan(filled.share, 0.6, "a ticked box is a filled square")
        XCTAssertGreaterThan(filled.mean.blueComponent - filled.mean.redComponent, 0.25, "…in the (blue) accent colour")
        XCTAssertGreaterThan(outlined.share, 0.1, "an open box has an outline")
        XCTAssertLessThan(outlined.share, 0.55, "…but is not filled")
        XCTAssertEqual(ink(open.insetBy(dx: 3, dy: 3)).share, 0, accuracy: 0.02, "an open box is empty inside")
        XCTAssertEqual(ink(open.offsetBy(dx: -(open.width + 8), dy: 0)).share, 0, accuracy: 0.02, "nothing is drawn to the left of the box")
    }

    // MARK: Fold chevron and chip (R8, R9)

    private func foldHarness(dark: Bool = false, theme: String? = nil, text: String? = nil) throws -> EditorHarness {
        let h = EditorHarness(text: try text ?? FoldTests.fixtureF(), dark: dark, size: NSSize(width: 900, height: 760))
        if let theme {
            h.coordinator.update(text: h.textView.string, settings: EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720,
                                                                                   lightTheme: theme, darkTheme: theme))
        }
        makeKey(h)
        h.select(h.textView.string.utf16.count)             // (away from every header: a caret on one shows its `#` markers)
        return h
    }

    private func folded(_ h: EditorHarness, _ headers: Int...) -> FoldState {
        headers.reduce(FoldState()) { s, n in s.toggled(h.coordinator.analysis.foldRegions.first { $0.headerLines.lowerBound == n - 1 }!) }
    }

    /// The chevron's click target for the header whose carrier character is the first character of `word`, in view coordinates.
    private func chevronTarget(_ h: EditorHarness, word: String) -> NSRect {
        let o = h.textView.textContainerOrigin
        return lm(h).foldChevronRect(forCharacterAt: h.index(of: word))!.offsetBy(dx: o.x, dy: o.y)
    }

    private func chipRect(_ h: EditorHarness, lastCharacterOf line: Int) -> NSRect {
        let o = h.textView.textContainerOrigin
        return lm(h).foldChipRect(forCharacterAt: h.coordinator.analysis.lines[line - 1].contentEnd - 1)!.offsetBy(dx: o.x, dy: o.y)
    }

    private func inkPoints(_ rep: NSBitmapImageRep, in r: NSRect, _ h: EditorHarness, threshold: CGFloat = 0.25) -> [NSPoint] {
        let page = h.coordinator.styler.palette.background.nsColor
        var out: [NSPoint] = []
        var y = r.minY
        while y < r.maxY {
            var x = r.minX
            while x < r.maxX {
                if distance(color(rep, atViewPoint: NSPoint(x: x, y: y), in: h), page) > threshold { out.append(NSPoint(x: x, y: y)) }
                x += 0.5
            }
            y += 0.5
        }
        return out
    }

    /// How the ink is spread: its horizontal extent in the upper and lower half of its own bounding box, and its vertical extent
    /// in the left and right half.
    private func shape(_ ink: [NSPoint]) -> (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        guard let minX = ink.map(\.x).min(), let maxX = ink.map(\.x).max(), let minY = ink.map(\.y).min(), let maxY = ink.map(\.y).max() else { return (0, 0, 0, 0) }
        func extent(_ pts: [NSPoint], _ v: (NSPoint) -> CGFloat) -> CGFloat {
            guard let lo = pts.map(v).min(), let hi = pts.map(v).max() else { return 0 }
            return hi - lo
        }
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        return (extent(ink.filter { $0.y < midY }, { $0.x }), extent(ink.filter { $0.y >= midY }, { $0.x }),
                extent(ink.filter { $0.x < midX }, { $0.y }), extent(ink.filter { $0.x >= midX }, { $0.y }))
    }

    func testChevronTargetIsSixteenPointsAndClearOfTheText() throws {
        let h = try foldHarness()
        h.coordinator.setFoldState(folded(h, 5))
        // (The chevron sits on the header's first visible character: a heading's first letter, an item's bullet.)
        for (needle, carrier) in [("Plan", 4), ("Notes", 5), ("Project", 7), ("- Groceries", 1)] {
            let target = chevronTarget(h, word: needle)
            XCTAssertEqual(target.width, 16, needle); XCTAssertEqual(target.height, 16, needle)
            let text = rect(of: NSRange(location: h.index(of: needle), length: carrier), in: h)
            XCTAssertLessThanOrEqual(target.maxX, text.minX, "\(needle): the target does not overlap the text")
            XCTAssertEqual(target.midY, text.midY, accuracy: 6, "\(needle): and sits on its line")
        }
        // Beside a drawn task checkbox it stays left of the box (Write spec is hidden while Plan is folded).
        h.coordinator.setFoldState(FoldState())
        let item = lm(h).foldChevronRect(forCharacterAt: h.index(of: "- [ ] Write spec"))!
        let box = lm(h).checkboxRect(forCharacterAt: h.index(of: "- [ ] Write spec"))!
        XCTAssertLessThanOrEqual(item.maxX, box.minX)
        XCTAssertEqual(item.midY, box.midY, accuracy: 6)
    }

    func testFoldedChevronPointsRightAndAnOpenOneShowsOnlyUnderThePointerPointingDown() throws {
        let h = try foldHarness()
        h.coordinator.setFoldState(folded(h, 5))
        let planTarget = chevronTarget(h, word: "Plan"), notesTarget = chevronTarget(h, word: "Notes")
        var rep = render(h)
        let folded = inkPoints(rep, in: planTarget, h)
        XCTAssertGreaterThan(folded.count, 15, "a folded header always shows its chevron")
        let right = shape(folded)
        XCTAssertGreaterThan(right.left, right.right + 2, "▸: tall on the left, a point on the right")
        XCTAssertEqual(inkPoints(rep, in: notesTarget, h).count, 0, "an open header shows no chevron while the pointer is elsewhere")

        // The pointer beside the header, in the left margin.
        h.coordinator.pointerMoved(to: NSPoint(x: 4, y: notesTarget.midY))
        rep = render(h)
        let open = inkPoints(rep, in: notesTarget, h)
        XCTAssertGreaterThan(open.count, 15, "the pointer over the header's margin shows the chevron")
        let down = shape(open)
        XCTAssertGreaterThan(down.top, down.bottom + 2, "▾: wide at the top, a point at the bottom")

        h.coordinator.pointerLeft()
        XCTAssertEqual(inkPoints(render(h), in: notesTarget, h).count, 0, "gone again when the pointer leaves")
        XCTAssertGreaterThan(inkPoints(render(h), in: planTarget, h).count, 15, "the folded one stays")
    }

    func testChipFollowsTheHeaderTextAndUsesTheChipColour() throws {
        for dark in [false, true] {
            let h = try foldHarness(dark: dark)
            h.coordinator.setFoldState(folded(h, 5))
            let chip = chipRect(h, lastCharacterOf: 5)
            let text = rect(of: NSRange(location: h.index(of: "Plan"), length: 4), in: h)
            XCTAssertGreaterThan(chip.minX, text.maxX, "dark=\(dark): the chip starts after the text")
            XCTAssertGreaterThan(chip.height, 8)
            let p = h.coordinator.styler.palette
            let rep = render(h)
            let sample = color(rep, atViewPoint: NSPoint(x: chip.minX + 2.5, y: chip.midY), in: h)
            XCTAssertLessThan(distance(sample, p.inlineCodeBackground.nsColor), 0.2, "dark=\(dark): chip fill")
            XCTAssertLessThan(distance(sample, p.inlineCodeBackground.nsColor), distance(sample, p.background.nsColor) + 0.02, "dark=\(dark): nearer the chip colour than the page")
            let dots = inkPoints(rep, in: chip.insetBy(dx: 4, dy: 3), h, threshold: 0.2)
            XCTAssertGreaterThan(dots.count, 6, "dark=\(dark): the three dots are drawn")
        }
    }

    func testCoveredChipIsDrawnInTheSelectionColour() throws {
        let h = try foldHarness()
        h.coordinator.setFoldState(folded(h, 5))
        let p = h.coordinator.styler.palette
        func probe() -> NSPoint { let chip = chipRect(h, lastCharacterOf: 5); return NSPoint(x: chip.minX + 2.5, y: chip.midY) }
        let plain = color(render(h), atViewPoint: probe(), in: h)
        // The selection runs from the paragraph above into the hidden lines. (It reveals the heading's `## `, so the chip moves.)
        let a = h.coordinator.analysis
        h.select(a.lines[2].range.location, a.lines[7].range.location + 3 - a.lines[2].range.location)
        let covered = color(render(h), atViewPoint: probe(), in: h)
        let page = p.background, sel = p.selection
        let tint = NSColor(srgbRed: page.r * (1 - sel.a) + sel.r * sel.a, green: page.g * (1 - sel.a) + sel.g * sel.a,
                           blue: page.b * (1 - sel.a) + sel.b * sel.a, alpha: 1)
        XCTAssertGreaterThan(distance(plain, covered), 0.1, "the chip changes colour when the selection covers hidden text")
        // (The system highlight of the selected line is painted over the chip as well, so it ends up a little deeper than the tint.)
        XCTAssertLessThan(distance(covered, tint), distance(plain, tint) - 0.01, "it moved from the chip colour towards the selection colour")
        // And goes back when the selection leaves.
        h.select(h.textView.string.utf16.count)
        XCTAssertLessThan(distance(color(render(h), atViewPoint: probe(), in: h), plain), 0.03)
    }

    func testChevronAndChipAreDrawnInEveryBuiltInTheme() throws {
        for theme in ThemeCatalog.builtIn {
            let h = try foldHarness(dark: theme.appearance == .dark, theme: theme.id)
            h.coordinator.setFoldState(folded(h, 5))
            let p = h.coordinator.styler.palette
            XCTAssertEqual(p, theme.palette, "\(theme.id): the editor uses the theme")
            let rep = render(h)
            let target = chevronTarget(h, word: "Plan"), chip = chipRect(h, lastCharacterOf: 5)
            XCTAssertGreaterThan(inkPoints(rep, in: target, h, threshold: 0.12).count, 10, "\(theme.id): chevron ink")
            // The chip fill is told apart from the page, and its dots from the fill (the palette floors give the contrast).
            let fill = color(rep, atViewPoint: NSPoint(x: chip.minX + 2.5, y: chip.midY), in: h)
            XCTAssertGreaterThan(distance(fill, p.background.nsColor), 0.01, "\(theme.id): chip fill differs from the page")
            XCTAssertGreaterThan(inkPoints(rep, in: chip.insetBy(dx: 4, dy: 3), h, threshold: 0.15).count, 4, "\(theme.id): dots")
            // Covered: dark text on the selection tint must stay readable.
            let tint = NSColor(srgbRed: p.background.r * (1 - p.selection.a) + p.selection.r * p.selection.a,
                               green: p.background.g * (1 - p.selection.a) + p.selection.g * p.selection.a,
                               blue: p.background.b * (1 - p.selection.a) + p.selection.b * p.selection.a, alpha: 1)
            let tintRGBA = RGBA(Double(tint.redComponent), Double(tint.greenComponent), Double(tint.blueComponent))
            XCTAssertGreaterThanOrEqual(p.text.contrast(with: tintRGBA), 4.5, "\(theme.id): chip dots over the selection colour")
        }
    }

    func testHiddenLinesLeaveNoHoleAndNoInk() throws {
        let h = try foldHarness()
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        let before = rect(of: NSRange(location: h.index(of: "Notes"), length: 5), in: h).minY - rect(of: NSRange(location: h.index(of: "Plan"), length: 4), in: h).minY
        h.coordinator.setFoldState(folded(h, 5))
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        let plan = rect(of: NSRange(location: h.index(of: "Plan"), length: 4), in: h), notes = rect(of: NSRange(location: h.index(of: "Notes"), length: 5), in: h)
        let gap = notes.minY - plan.minY
        XCTAssertLessThan(gap, before / 4, "Notes follows the folded Plan directly (was \(Int(before)) pt away, now \(Int(gap)))")
        XCTAssertLessThan(gap, 90, "a normal heading gap")
        let strip = NSRect(x: h.textView.textContainerOrigin.x, y: plan.maxY + 12, width: 500, height: max(0, notes.minY - plan.maxY - 16))
        XCTAssertEqual(inkPoints(render(h), in: strip, h).count, 0, "nothing is drawn between the two headings")
    }
}
