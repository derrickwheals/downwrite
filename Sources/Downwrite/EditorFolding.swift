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
}
