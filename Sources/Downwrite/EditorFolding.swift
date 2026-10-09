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
}
