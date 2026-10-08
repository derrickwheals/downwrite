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
        let tv = h.textView!
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

    /// Fraction of *light* pixels in `r` that differ from `background` (selection tint) rather than being glyph ink.
    private func tintedFraction(_ rep: NSBitmapImageRep, in r: NSRect, background: NSColor, _ h: EditorHarness) -> CGFloat {
        var light = 0, tinted = 0
        var y = r.minY
        while y < r.maxY {
            var x = r.minX
            while x < r.maxX {
                let c = color(rep, atViewPoint: NSPoint(x: x, y: y), in: h)
                if c.brightnessComponent > 0.55 {
                    light += 1
                    if distance(c, background) > 0.05 { tinted += 1 }
                }
                x += 0.5
            }
            y += 0.5
        }
        return light == 0 ? 0 : CGFloat(tinted) / CGFloat(light)
    }

    // MARK: Item 1 — selection must stay visible

    func testSelectionIsVisibleInsideACodeBlock() {
        let h = EditorHarness(text: "intro\n\n```\ntest\n```\n\nafter\n")
        makeKey(h)
        let word = NSRange(location: h.index(of: "test"), length: 4)
        h.select(word.location + 1)                       // caret inside: fences revealed, same layout as below
        let r = rect(of: word, in: h)
        let card = AppearanceResolver.palette(for: h.textView.effectiveAppearance).codeBackground.nsColor
        let before = tintedFraction(render(h), in: r.insetBy(dx: 1, dy: 3), background: card, h)
        h.select(word.location, word.length)
        let after = tintedFraction(render(h), in: r.insetBy(dx: 1, dy: 3), background: card, h)
        XCTAssertGreaterThan(after, before + 0.3, "selected text in a code block must show a selection highlight (\(before) → \(after))")
    }

    func testSelectionIsVisibleInsideInlineCode() {
        let h = EditorHarness(text: "Some `Agy code` here and more words\n")
        makeKey(h)
        let word = NSRange(location: h.index(of: "Agy code"), length: 8)
        h.select(word.location + 1)
        let r = rect(of: word, in: h)
        let pill = AppearanceResolver.palette(for: h.textView.effectiveAppearance).inlineCodeBackground.nsColor
        let before = tintedFraction(render(h), in: r.insetBy(dx: 1, dy: 4), background: pill, h)
        h.select(word.location, word.length)
        let after = tintedFraction(render(h), in: r.insetBy(dx: 1, dy: 4), background: pill, h)
        XCTAssertGreaterThan(after, before + 0.3, "selected inline code must show a selection highlight (\(before) → \(after))")
    }

    func testSelectionStillShowsOverAHighlightPill() {
        let h = EditorHarness(text: "Some ==marked words== here\n")
        makeKey(h)
        let word = NSRange(location: h.index(of: "marked words"), length: 12)
        h.select(word.location + 1)
        let r = rect(of: word, in: h)
        let pill = AppearanceResolver.palette(for: h.textView.effectiveAppearance).highlightBackground.nsColor
        let flat = NSColor.white.blended(withFraction: pill.alphaComponent, of: pill.withAlphaComponent(1)) ?? pill
        let before = tintedFraction(render(h), in: r.insetBy(dx: 1, dy: 4), background: flat, h)
        h.select(word.location, word.length)
        let after = tintedFraction(render(h), in: r.insetBy(dx: 1, dy: 4), background: flat, h)
        XCTAssertGreaterThan(after, before + 0.2, "(\(before) → \(after))")
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
        let x = pill.minX + origin.x - 1.5                        // in the side padding, clear of the glyphs
        func at(_ y: CGFloat) -> NSColor { color(rep, atViewPoint: NSPoint(x: x, y: y + origin.y), in: h) }
        XCTAssertLessThan(distance(at(pill.minY + 3), palette.inlineCodeBackground.nsColor), 0.03, "inside the pill")
        XCTAssertGreaterThan(distance(at(pill.minY - 3), palette.inlineCodeBackground.nsColor), 0.03, "just above the pill is page background")
        XCTAssertGreaterThan(distance(at(pill.maxY + 3), palette.inlineCodeBackground.nsColor), 0.03, "just below the pill is page background")
    }

    func testWrappedInlineCodeGetsOnePillPerLine() {
        let long = String(repeating: "word ", count: 60)
        let h = EditorHarness(text: "\(long)`" + String(repeating: "code ", count: 40) + "end`\n", size: NSSize(width: 520, height: 600))
        h.select(0)
        let start = h.index(of: "code code")
        let range = NSRange(location: start, length: 40 * 5)
        XCTAssertGreaterThan(lm(h).pillRects(forCharacterRange: range).count, 1)
    }
}
