import AppKit

/// Draws what plain text attributes cannot: rounded code-block cards, inline "pills" (code, highlight),
/// block-quote bars and horizontal rules. Everything is drawn *behind* the glyphs.
final class DWLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Our cards, pills and bars go down first and the system's own background (which includes the selection
        // highlight) last, so a selection inside a code block or inline code stays visible instead of being painted over.
        drawCustomBackgrounds(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Vertical breathing room between an inline pill's edge and the nearest ink (capital letters above, descenders
    /// below), as a fraction of the font size.
    static let pillGapRatio: CGFloat = 0.14

    /// The rectangles (text-container coordinates) to fill for an inline pill covering `charRange`, one per line the
    /// range occupies. A pill runs from just above the capital letters to just below the descenders of its font, with
    /// the same gap at both ends, rather than filling the whole line height.
    func pillRects(forCharacterRange charRange: NSRange) -> [NSRect] {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return [] }
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var out: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            guard part.length > 0 else { return }
            let box = self.boundingRect(forGlyphRange: part, in: container)
            let firstChar = min(self.characterIndexForGlyph(at: part.location), storage.length - 1)
            let font = (storage.attribute(.font, at: firstChar, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            let baseline = lineRect.minY + self.location(forGlyphAt: part.location).y
            let gap = max(1.5, font.pointSize * Self.pillGapRatio)
            let top = baseline - font.capHeight - gap
            let bottom = baseline - font.descender + gap          // `descender` is negative
            out.append(NSRect(x: box.minX, y: top, width: box.width, height: bottom - top))
        }
        return out
    }

    private func drawCustomBackgrounds(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, textContainers.first != nil, storage.length > 0 else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)

        // Block cards (code blocks, tables, front matter).
        var drawn = Set<Int>()
        storage.enumerateAttribute(.dwBlockBackground, in: charRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            var full = NSRange()
            _ = storage.attribute(.dwBlockBackground, at: range.location, longestEffectiveRange: &full, in: whole)
            guard drawn.insert(full.location).inserted else { return }
            let glyphs = self.glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            var rect = NSRect.null
            self.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                if lineRect.height > 1 { rect = rect.union(lineRect) }
            }
            guard !rect.isNull else { return }
            let card = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -6)
            color.setFill()
            NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9).fill()
        }

        // Inline pills (inline code, highlights).
        storage.enumerateAttribute(.dwPill, in: charRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            for rect in self.pillRects(forCharacterRange: range) {
                let r = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2.5, dy: 0)
                color.setFill()
                NSBezierPath(roundedRect: r, xRadius: min(4.5, r.height / 2), yRadius: min(4.5, r.height / 2)).fill()
            }
        }

        // Block-quote bars: one bar per nesting level, spanning contiguous quoted lines.
        var barsDrawn = Set<Int>()
        storage.enumerateAttribute(.dwQuoteDepth, in: charRange, options: []) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            var full = NSRange()
            _ = storage.attribute(.dwQuoteDepth, at: range.location, longestEffectiveRange: &full, in: whole)
            guard barsDrawn.insert(full.location).inserted else { return }
            let glyphs = self.glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            var rect = NSRect.null
            self.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                if lineRect.height > 1 { rect = rect.union(lineRect) }
            }
            guard !rect.isNull else { return }
            let color = (storage.attribute(.dwQuoteBarColor, at: full.location, effectiveRange: nil) as? NSColor) ?? NSColor.tertiaryLabelColor
            for level in 1...depth {
                let x = rect.minX + origin.x + 2 + CGFloat(level - 1) * 16
                let bar = NSRect(x: x, y: rect.minY + origin.y + 2, width: 3, height: max(0, rect.height - 4))
                color.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }

        // Horizontal rules.
        storage.enumerateAttribute(.dwRule, in: charRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                let y = (lineRect.midY + origin.y).rounded() + 0.5
                color.setFill()
                NSRect(x: lineRect.minX + origin.x, y: y, width: lineRect.width, height: 1).fill()
            }
        }
    }
}

extension NSAttributedString.Key {
    static let dwQuoteBarColor = NSAttributedString.Key("dw.quoteBarColor")
}
