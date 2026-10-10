import AppKit
import DownwriteCore

/// Folding as the editor window sees it. `FoldState` (Core) decides what is hidden; this maps it onto the text view: which
/// lines the styler collapses, which table grids and diagram cards disappear, and where the caret goes. Folding is a display
/// state only — the text, the file, the undo history and the edited flag are never touched.
extension EditorCoordinator {
    // MARK: Following the text (R15, R18)

    /// Carries the folds through the change that produced the current analysis (R18): the smallest single replacement that
    /// turns the previous text into the new one, found by diffing. Typing, undo and redo, paste, Replace, an external reload and
    /// a debounced re-analysis all pass through `reanalyze`, so this is the one place that needs it. Free while nothing is folded.
    func carryFolds(from previous: MarkdownAnalysis, previousText: String, to text: String) {
        guard !foldState.isEmpty, previousText != text, let edit = TextDiff.replacement(from: previousText, to: text) else { return }
        foldState = foldState.mapped(through: edit, from: previous, to: analysis)
    }

    /// R15: when an edit, undo, paste or leaving the source view leaves the start of the selection in hidden text, the folds
    /// that hide it open (outermost first); folds that do not hide it stay as they are.
    func revealSelectionIfHidden() {
        guard !sourceMode, !foldState.isEmpty, let tv = textView, tv.textStorage?.length == analysis.length else { return }
        foldState = foldState.revealing(tv.selectedRange(), in: analysis)
    }

    // MARK: Changing the folds

    /// Replaces the fold state and updates what is drawn (R4: nothing else changes).
    func setFoldState(_ new: FoldState) {
        guard new != foldState else { return }
        foldState = new
        applyFoldState()
    }

    /// Brings the screen in line with `foldState`. Only the lines whose look changes are restyled — the header and the hidden
    /// lines (R23) — and when a fold now hides the caret, or the grid that has the keyboard, the caret goes to the end of the
    /// header of the outermost fold hiding it (R13).
    func applyFoldState() {
        guard !sourceMode, let tv = textView, let storage = tv.textStorage, analysis.length == storage.length else { return }
        var selection = tv.selectedRange()

        var landing: Int?
        if let hiding = foldState.foldHiding(offset: selection.location, in: analysis) {
            landing = foldState.headerEnd(of: hiding, in: analysis)
        } else if let line = tableOverlay.focusedTableFirstLine,
                  let hiding = foldState.foldHiding(offset: analysis.lines[line].range.location, in: analysis) {
            landing = foldState.headerEnd(of: hiding, in: analysis)
        }

        let old = preview
        var next = old
        next.setFolds(foldState, analysis: analysis, selection: landing.map { NSRange(location: $0, length: 0) } ?? selection)
        overlay.setHiddenLines(next.folded)
        tableOverlay.setHiddenLines(next.folded)          // (a cell that had the keyboard gives it back)
        next.heights = combinedHeights()

        var dirty = Set<Int>()
        for range in old.folded.symmetricDifference(next.folded) { dirty.formUnion(range) }
        for (line, header) in next.foldHeaders where old.foldHeaders[line] != header { dirty.insert(line) }
        for line in old.foldHeaders.keys where next.foldHeaders[line] == nil { dirty.insert(line) }
        preview = next

        isStyling = true
        if let landing {
            selection = NSRange(location: landing, length: 0)
            tv.setSelectedRange(selection)
        }
        styler.style(lines: dirty, storage: storage, analysis: analysis, selection: selection, preview: preview)
        isStyling = false

        if landing != nil {
            if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
            tv.scrollRangeToVisible(selection)
        }
        selectionChanged()                                 // markers at the (new) caret, the sidebar's active heading…
        scheduleReposition()
    }

    // MARK: Pointer and clicks (R8, R9)

    /// The visible foldable header whose line `point` (text view coordinates) is on. The band covers the whole width of the
    /// view, margins included, so the pointer beside a header counts as over it.
    private func foldHeader(at point: NSPoint) -> FoldHeader? {
        guard !sourceMode, !preview.foldHeaders.isEmpty, let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
              analysis.length == tv.textStorage?.length, lm.numberOfGlyphs > 0 else { return nil }
        let origin = tv.textContainerOrigin
        let local = NSPoint(x: min(max(point.x - origin.x, 0), tc.size.width - 1), y: point.y - origin.y)
        let glyph = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: nil)
        let band = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= band.minY, local.y <= band.maxY else { return nil }
        return preview.foldHeaders[analysis.lineIndex(at: lm.characterIndexForGlyph(at: glyph))]
    }

    /// The header whose chevron or chip (the chip only while folded) is at `point`, if any.
    func foldControl(at point: NSPoint) -> FoldHeader? {
        guard let tv = textView, let lm = tv.layoutManager as? DWLayoutManager, let storage = tv.textStorage,
              let header = foldHeader(at: point) else { return nil }
        let origin = tv.textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var chevron: Int?
        storage.enumerateAttribute(.dwFold, in: analysis.lines[header.firstLine].range, options: []) { value, range, stop in
            if value != nil { chevron = range.location; stop.pointee = true }
        }
        if let chevron, let target = lm.foldChevronRect(forCharacterAt: chevron), target.contains(local) { return header }
        let end = analysis.lines[header.lastLine].contentEnd
        if header.folded, end > 0, let chip = lm.foldChipRect(forCharacterAt: end - 1), chip.contains(local) { return header }
        return nil
    }

    /// Folds or unfolds the region whose header starts on `headerLine`.
    func toggleFold(headerLine: Int) {
        guard analysis.lines.indices.contains(headerLine) else { return }
        let anchor = analysis.lines[headerLine].range.location
        guard let region = analysis.foldRegions.first(where: { $0.anchor == anchor }) else { return }
        setFoldState(foldState.toggled(region))
    }

    /// The chevron of the header under the pointer shows even while its region is open.
    func pointerMoved(to point: NSPoint) {
        guard let lm = textView?.layoutManager as? DWLayoutManager else { return }
        setHoveredHeader(foldHeader(at: point), in: lm)
    }

    func pointerLeft() {
        guard let lm = textView?.layoutManager as? DWLayoutManager else { return }
        setHoveredHeader(nil, in: lm)
    }

    private func setHoveredHeader(_ header: FoldHeader?, in lm: DWLayoutManager) {
        let range = header.map { h -> NSRange in
            let a = analysis.lines[h.firstLine].range, b = analysis.lines[h.lastLine].range
            return NSRange(location: a.location, length: NSMaxRange(b) - a.location)
        }
        guard range != lm.hoveredFoldRange else { return }
        let old = lm.hoveredFoldRange
        lm.hoveredFoldRange = range
        invalidateBand(of: old)
        invalidateBand(of: range)
    }

    /// Redraws the full width of the view beside `range`: the chevron lives in the margin, outside the text container.
    private func invalidateBand(of range: NSRange?) {
        guard let range, let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
              NSMaxRange(range) <= (tv.textStorage?.length ?? 0) else { return }
        var band = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
        band.origin.y += tv.textContainerOrigin.y
        band.origin.x = 0
        band.size.width = tv.bounds.width
        tv.setNeedsDisplay(band.insetBy(dx: 0, dy: -4))
    }

    /// R9: headers whose chip must be redrawn because the selection now covers (or no longer covers) their hidden text.
    /// Updates the styler's state and returns the lines to restyle.
    func refreshFoldCoverage(selection: NSRange) -> Set<Int> {
        guard !foldState.isEmpty else { return [] }
        var dirty = Set<Int>()
        for region in analysis.foldRegions where foldState.isFolded(region) {
            guard var header = preview.foldHeaders[region.headerLines.lowerBound], header.folded else { continue }
            let covered = NSIntersectionRange(selection, region.hiddenRange).length > 0
            guard covered != header.covered else { continue }
            header.covered = covered
            for line in region.headerLines { preview.foldHeaders[line] = header; dirty.insert(line) }
        }
        return dirty
    }

    // MARK: Commands (R10 to R13)

    /// Fold: the innermost open region around the caret (R11). Repeated, it folds outwards.
    func foldAtCaret() {
        guard !sourceMode, let tv = textView, analysis.length == tv.textStorage?.length,
              let next = foldState.folding(atCaret: tv.selectedRange().location, in: analysis) else { return beep() }
        setFoldState(next)
    }

    /// Unfold: the folded region whose header holds the caret (R11).
    func unfoldAtCaret() {
        guard !sourceMode, let tv = textView, analysis.length == tv.textStorage?.length,
              let next = foldState.unfolding(atCaret: tv.selectedRange().location, in: analysis) else { return beep() }
        setFoldState(next)
    }

    func foldAll() {
        guard !sourceMode else { return beep() }
        let next = foldState.foldingAll(in: analysis)
        guard next != foldState else { return beep() }
        setFoldState(next)
    }

    func unfoldAll() {
        guard !sourceMode, !foldState.isEmpty else { return beep() }
        setFoldState(foldState.unfoldingAll())
    }

    /// Fold to Level N: headings of level N and deeper fold, shallower ones open; list items keep their state (R12).
    func fold(toLevel level: Int) {
        guard !sourceMode else { return beep() }
        let next = foldState.folding(toLevel: level, in: analysis)
        guard next != foldState else { return beep() }
        setFoldState(next)
    }

    // MARK: Caret movement (R14)

    /// Movement commands: `moveDown:`, `moveWordRight:`, `moveToEndOfDocument:`, `pageUp:` and their `…AndModifySelection:` forms.
    func isCaretMovement(_ selector: Selector) -> Bool {
        guard !sourceMode, !foldState.isEmpty else { return false }
        let name = NSStringFromSelector(selector)
        return name.hasPrefix("move") || name.hasPrefix("page")
    }

    /// After a movement command: a moving end that landed in hidden text goes to the nearest visible position in the direction
    /// it travelled — the next visible line going forward, the end of the header going back, the header itself for ⌘↓ when the end
    /// of the document is hidden. Up and down keep the column where the target line is long enough. With Shift the selection
    /// extends to there (and may cover hidden text, R17); a selection's start never stays hidden.
    func snapCaretOverFolds(from before: NSRange, after selector: Selector) {
        guard let tv = textView, analysis.length == tv.textStorage?.length else { return }
        let after = tv.selectedRange()
        guard after != before else { return }
        // The end that moved: a collapsed result is the caret itself; otherwise the end that differs from before.
        let headIsStart = after.length > 0 && after.location != before.location && NSMaxRange(after) == NSMaxRange(before)
        let head = headIsStart || after.length == 0 ? after.location : NSMaxRange(after)
        let anchor = headIsStart ? NSMaxRange(after) : after.location
        let headBefore = (before.length == 0 || headIsStart) ? before.location : NSMaxRange(before)
        guard foldState.foldHiding(offset: head, in: analysis) != nil else { return }
        let forward = head >= headBefore
        var target = foldState.visibleOffset(from: head, forward: forward, in: analysis)
        let name = NSStringFromSelector(selector)
        if name.hasPrefix("moveUp") || name.hasPrefix("moveDown"), let x = caretX(at: headBefore), let column = offset(onLineOf: target, atX: x) {
            target = column
        }
        let collapsed = after.length == 0
        let range = collapsed ? NSRange(location: target, length: 0) : NSRange(location: min(anchor, target), length: abs(anchor - target))
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    /// The x position (text container coordinates) of the insertion point at `offset`.
    private func caretX(at offset: Int) -> CGFloat? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let length = tv.textStorage?.length, length > 0 else { return nil }
        let i = min(offset, length - 1)
        let box = lm.boundingRect(forGlyphRange: NSRange(location: lm.glyphIndexForCharacter(at: i), length: 1), in: tc)
        return offset >= length ? box.maxX : box.minX
    }

    /// The character of the line holding `offset` that is nearest to horizontal position `x`, kept inside the line's text.
    private func offset(onLineOf offset: Int, atX x: CGFloat) -> Int? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, tv.textStorage?.length ?? 0 > 0 else { return nil }
        let line = analysis.lines[analysis.lineIndex(at: offset)]
        let probe = min(max(line.range.location, offset), max(0, (tv.textStorage?.length ?? 1) - 1))
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: probe), effectiveRange: nil)
        let index = lm.characterIndex(for: NSPoint(x: x, y: rect.midY), in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        return min(max(index, line.range.location), line.contentEnd)
    }

    // MARK: Edits at a fold's edge (R16)

    /// Return inside or at the end of a folded header opens that fold first, and the editor then does exactly what Return does
    /// without a fold. Return at the very start of the header does not: it pushes the header and its fold down a line (R18).
    func openFoldBeforeReturn() {
        guard !sourceMode, !foldState.isEmpty, let tv = textView, !tv.hasMarkedText(), analysis.length == tv.textStorage?.length else { return }
        let location = tv.selectedRange().location
        guard let region = foldState.headerFold(containing: location, in: analysis), location != region.anchor else { return }
        setFoldState(foldState.toggled(region))
    }

    /// Backspace at the start of the first visible line after a fold, and forward Delete at the end of a folded header (with
    /// their word, line and paragraph variants and an empty selection), would join a visible line to hidden text. So would a word
    /// delete from just after `- ` or `## `, or from before a header's trailing `!`: `FoldState.openingBeforeDeleting` decides.
    /// The fold opens instead and nothing is deleted. Returns whether it did.
    func openFoldInsteadOfDeleting(backwards: Bool, byWord: Bool) -> Bool {
        guard !sourceMode, !foldState.isEmpty, let tv = textView, !tv.hasMarkedText(), tv.selectedRange().length == 0,
              analysis.length == tv.textStorage?.length,
              let opened = foldState.openingBeforeDeleting(at: tv.selectedRange().location, backwards: backwards, byWord: byWord,
                                                           in: tv.string, analysis: analysis) else { return false }
        setFoldState(opened)
        return true
    }

    /// After a click or drag: a selection that starts in hidden text (only possible on the blank page below a document whose end
    /// is folded) moves to the nearest visible position. A caret goes to the next visible line, or to the end of the header of the
    /// fold hiding the end of the document; a drag keeps its far end.
    func snapSelectionAfterMouse() {
        guard !sourceMode, !foldState.isEmpty, let tv = textView, analysis.length == tv.textStorage?.length else { return }
        let sel = tv.selectedRange()
        guard foldState.foldHiding(offset: sel.location, in: analysis) != nil else { return }
        let start = foldState.visibleOffset(from: sel.location, forward: true, in: analysis)
        tv.setSelectedRange(sel.length == 0 || start < sel.location ? NSRange(location: start, length: 0)
                                                                   : NSRange(location: start, length: max(0, NSMaxRange(sel) - start)))
    }
}
