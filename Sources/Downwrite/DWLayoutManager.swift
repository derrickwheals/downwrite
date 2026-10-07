import AppKit

/// Draws what plain text attributes cannot: rounded code-block cards, inline "pills" (code, highlight),
/// block-quote bars and horizontal rules. Everything is drawn *behind* the glyphs.
final class DWLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
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

        // Inline pills.
        storage.enumerateAttribute(.dwPill, in: charRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let r = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2.5, dy: 0.5)
                color.setFill()
                NSBezierPath(roundedRect: r, xRadius: 4.5, yRadius: 4.5).fill()
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
