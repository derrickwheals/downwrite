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

    /// Where the checkbox attached to the character at `index` (the first character of a hidden `- [ ] ` prefix) is
    /// drawn, in text container coordinates; `nil` if that character carries none.
    func checkboxRect(forCharacterAt index: Int) -> NSRect? {
        guard let storage = textStorage, index >= 0, index < storage.length, let container = textContainers.first,
              let mark = storage.attribute(.dwCheckbox, at: index, effectiveRange: nil) as? CheckboxMark else { return nil }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
        let baseline = line.minY + location(forGlyphAt: glyph).y
        return NSRect(x: x, y: baseline - mark.centerAboveBaseline - mark.side / 2, width: mark.side, height: mark.side)
    }

    // MARK: Fold controls

    /// Edge length of a chevron's click target, and the gap between it and the text.
    static let foldTarget: CGFloat = 16
    static let foldGap: CGFloat = 4
    /// The characters of the header the pointer is over; its chevron shows even while the region is open.
    var hoveredFoldRange: NSRange?

    /// The font of the nearest character at or before `index` on its line that shows (a header can end in hidden syntax).
    private func visibleFont(atOrBefore index: Int, in storage: NSTextStorage) -> NSFont {
        let whole = storage.string as NSString
        let lineStart = whole.lineRange(for: NSRange(location: index, length: 0)).location
        var i = index
        while i >= lineStart {
            if let f = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont, f.pointSize > 1 { return f }
            i -= 1
        }
        return (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 14)
    }

    /// The chevron's click target (text container coordinates) for the `FoldMark` on the character at `index`: a square to the
    /// left of that character, clear of the text and of a drawn checkbox. `nil` if the character carries none.
    func foldChevronRect(forCharacterAt index: Int) -> NSRect? {
        guard let storage = textStorage, index >= 0, index < storage.length, let container = textContainers.first,
              storage.attribute(.dwFold, at: index, effectiveRange: nil) is FoldMark else { return nil }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
        let font = visibleFont(atOrBefore: index, in: storage)
        let centre = line.minY + location(forGlyphAt: glyph).y - (font.capHeight + font.xHeight) / 4
        return NSRect(x: x - Self.foldGap - Self.foldTarget, y: centre - Self.foldTarget / 2, width: Self.foldTarget, height: Self.foldTarget)
    }

    /// The ⋯ chip (text container coordinates) for the `FoldMark` on the header's last character at `index`: right after that
    /// character, as tall as an inline pill. It may run into the right margin when the line is full, but never over text.
    func foldChipRect(forCharacterAt index: Int) -> NSRect? {
        guard let storage = textStorage, index >= 0, index < storage.length, let container = textContainers.first,
              storage.attribute(.dwFoldChip, at: index, effectiveRange: nil) is FoldMark else { return nil }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let box = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let font = visibleFont(atOrBefore: index, in: storage)
        let baseline = line.minY + location(forGlyphAt: glyph).y
        let gap = max(1.5, font.pointSize * Self.pillGapRatio)
        let top = baseline - font.capHeight - gap, bottom = baseline - font.descender + gap
        return NSRect(x: box.maxX + Self.foldGap + 2, y: top, width: (font.pointSize * 1.45).rounded(), height: bottom - top)
    }

    /// Draws the chevron and the chip of every foldable header on the lines that meet `rect` (text view coordinates): a chevron
    /// always on a folded header and otherwise only under the pointer, a chip on a folded header. They reach outside the text
    /// container — the chevron into the left margin, a chip on a full line into the right one — where this layout manager's own
    /// drawing is clipped away, so the text view calls this from its background pass. That still puts them behind the text and
    /// behind the system selection highlight.
    func drawFoldControls(in rect: NSRect, origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let band = NSRect(x: 0, y: rect.minY - origin.y, width: container.size.width, height: rect.height)
        let chars = characterRange(forGlyphRange: glyphRange(forBoundingRect: band, in: container), actualGlyphRange: nil)
        storage.enumerateAttribute(.dwFold, in: chars, options: []) { value, range, _ in
            guard let mark = value as? FoldMark else { return }
            let hovered = self.hoveredFoldRange.map { NSLocationInRange(range.location, $0) } ?? false
            guard mark.folded || hovered, let target = self.foldChevronRect(forCharacterAt: range.location) else { return }
            self.drawChevron(mark, in: target.offsetBy(dx: origin.x, dy: origin.y))
        }
        storage.enumerateAttribute(.dwFoldChip, in: chars, options: []) { value, range, _ in
            guard let mark = value as? FoldMark, let chip = self.foldChipRect(forCharacterAt: range.location) else { return }
            self.drawChip(mark, in: chip.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    private func drawChevron(_ mark: FoldMark, in target: NSRect) {
        let c = NSPoint(x: target.midX, y: target.midY)
        let path = NSBezierPath()
        if mark.folded {                                  // ▸
            path.move(to: NSPoint(x: c.x - 2, y: c.y - 3.6))
            path.line(to: NSPoint(x: c.x + 2, y: c.y))
            path.line(to: NSPoint(x: c.x - 2, y: c.y + 3.6))
        } else {                                          // ▾
            path.move(to: NSPoint(x: c.x - 3.6, y: c.y - 2))
            path.line(to: NSPoint(x: c.x, y: c.y + 2))
            path.line(to: NSPoint(x: c.x + 3.6, y: c.y - 2))
        }
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        mark.chevron.setStroke()
        path.stroke()
    }

    private func drawChip(_ mark: FoldMark, in rect: NSRect) {
        mark.chipFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: min(4.5, rect.height / 2), yRadius: min(4.5, rect.height / 2)).fill()
        let r = max(1.1, rect.height * 0.08), spacing = r * 3.4
        mark.chipInk.setFill()
        for k in -1...1 {
            NSBezierPath(ovalIn: NSRect(x: rect.midX + CGFloat(k) * spacing - r, y: rect.midY - r, width: r * 2, height: r * 2)).fill()
        }
    }

    private func drawCheckbox(_ mark: CheckboxMark, in box: NSRect) {
        let radius = box.width * 0.3
        if mark.checked {
            mark.accent.setFill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + box.width * 0.26, y: box.minY + box.height * 0.53))
            tick.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.70))
            tick.line(to: NSPoint(x: box.minX + box.width * 0.75, y: box.minY + box.height * 0.32))
            tick.lineWidth = max(1.6, box.width * 0.13)
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            mark.tick.setStroke()
            tick.stroke()
        } else {
            let line = max(1.4, box.width * 0.1)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: line / 2, dy: line / 2), xRadius: radius, yRadius: radius)
            path.lineWidth = line
            mark.outline.setStroke()
            path.stroke()
        }
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

        // Task checkboxes (they stand in for hidden `- [ ] ` prefixes).
        storage.enumerateAttribute(.dwCheckbox, in: charRange, options: []) { value, range, _ in
            guard let mark = value as? CheckboxMark, let box = self.checkboxRect(forCharacterAt: range.location) else { return }
            self.drawCheckbox(mark, in: box.offsetBy(dx: origin.x, dy: origin.y))
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
