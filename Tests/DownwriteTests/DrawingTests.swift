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
        /// Share of the pixels in `r` that are within `tolerance` of `target`.
        func share(_ r: NSRect, _ target: NSColor, tolerance: CGFloat = 0.15) -> CGFloat {
            var hit = 0, total = 0
            var y = r.minY
            while y < r.maxY {
                var x = r.minX
                while x < r.maxX {
                    total += 1
                    if distance(color(rep, atViewPoint: NSPoint(x: x, y: y), in: h), target) < tolerance { hit += 1 }
                    x += 0.5
                }
                y += 0.5
            }
            return total == 0 ? 0 : CGFloat(hit) / CGFloat(total)
        }
        XCTAssertGreaterThan(share(done, palette.accent.nsColor), 0.4, "a ticked box is mostly filled with the accent colour")
        XCTAssertLessThan(share(open, palette.accent.nsColor), 0.02, "an open box is not filled")
        XCTAssertGreaterThan(share(open.insetBy(dx: 3, dy: 3), palette.background.nsColor), 0.9, "an open box is empty inside")
        XCTAssertLessThan(share(open, palette.background.nsColor), 0.9, "…but has an outline")
        XCTAssertGreaterThan(share(open.insetBy(dx: -6, dy: -1).offsetBy(dx: -open.width, dy: 0), palette.background.nsColor), 0.97, "nothing is drawn left of the box")
    }
}
