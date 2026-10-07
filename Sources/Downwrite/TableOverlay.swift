import AppKit
import DownwriteCore

/// Keeps one `TableGridView` per grid table in the document, sits it over the table's collapsed source, writes every
/// edit back to the document as Markdown, and moves focus between the text view and the grids.
@MainActor
final class TableOverlay {
    private struct TypingKey: Hashable { var order: Int; var row: Int; var column: Int }
    private struct StyleSignature: Equatable { var choice: FontChoice; var size: CGFloat; var palette: Palette }

    unowned let coordinator: EditorCoordinator
    private weak var textView: EditorTextView?
    private(set) var grids: [TableGridView] = []
    var onReservedHeightsChanged: (() -> Void)?
    private var pendingFocus: (order: Int, position: TableCellPosition, selection: NSRange?)?
    private var lastSignature: StyleSignature?
    private var handOffScheduled = false

    init(coordinator: EditorCoordinator, textView: EditorTextView) {
        self.coordinator = coordinator
        self.textView = textView
    }

    var styler: MarkdownStyler { coordinator.styler }
    private var analysis: MarkdownAnalysis { coordinator.analysis }

    /// The document's tables that are shown as grids, in order.
    var gridBlocks: [TableBlock] { analysis.tables.filter(\.isGrid) }

    private var availableWidth: CGFloat {
        guard let tv = textView else { return 600 }
        return max(200, tv.bounds.width - tv.textContainerInset.width * 2)
    }

    /// True while the keyboard focus is inside any grid.
    var hasFocus: Bool { grids.contains { $0.hasFocus } }

    // MARK: Sync

    /// Re-reads the document's tables into the grids (creating, updating and removing views as needed).
    func sync() {
        guard let tv = textView else { return }
        let blocks = gridBlocks
        while grids.count > blocks.count {
            let gone = grids.removeLast()
            // Do not leave the window without a first responder when the focused grid disappears.
            if gone.hasFocus { tv.window?.makeFirstResponder(tv) }
            gone.removeFromSuperview()
        }
        let signature = StyleSignature(choice: styler.typography.choice, size: styler.typography.size, palette: styler.palette)
        let restyle = signature != lastSignature
        lastSignature = signature
        for (k, block) in blocks.enumerated() {
            guard let model = block.model else { continue }
            let grid: TableGridView
            var created = false
            if k < grids.count {
                grid = grids[k]
            } else {
                grid = TableGridView(overlay: self, model: model)
                tv.addSubview(grid)
                grids.append(grid)
                created = true
            }
            grid.order = k
            grid.isHidden = block.firstLine == coordinator.sourceTableFirstLine
            // Typing elsewhere re-analyses the document on every keystroke: leave untouched tables alone.
            let width = availableWidth
            if grid.model != model || restyle || created {
                grid.apply(model: model, forceRestyle: restyle)
                grid.relayout(maxTableWidth: width)
            } else if abs(grid.maxTableWidth - width) > 0.5 {
                grid.relayout(maxTableWidth: width)
            }
        }
        highlightSelection()
        consumePendingFocus()
    }

    func setPalette() {
        lastSignature = nil           // forces a restyle on the next sync
        grids.forEach { $0.restyleAllCells() }
    }

    /// Reserved vertical space below each grid table's first line (keyed like the Mermaid cards, by first source line).
    func reservedHeights() -> [Int: CGFloat] {
        var out: [Int: CGFloat] = [:]
        for (k, block) in gridBlocks.enumerated() where k < grids.count && !grids[k].isHidden {
            out[block.firstLine] = grids[k].totalHeight
        }
        return out
    }

    func heightsChanged() { onReservedHeightsChanged?() }

    /// Places every grid over its table. Call after layout changes.
    func reposition() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        let total = tv.textStorage?.length ?? 0
        guard total > 0, analysis.length == total else { return }
        let blocks = gridBlocks
        guard blocks.count == grids.count else { return }
        let origin = tv.textContainerOrigin
        let width = availableWidth
        var heightChanged = false
        for (k, block) in blocks.enumerated() {
            let grid = grids[k]
            guard !grid.isHidden, block.lastLine < analysis.lines.count else { continue }
            if abs(grid.maxTableWidth - width) > 0.5, grid.relayout(maxTableWidth: width) { heightChanged = true }
            let line = analysis.lines[block.lastLine]
            // Non-contiguous layout can report stale estimates for unlaid text; make everything above exact.
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(total, NSMaxRange(line.range))))
            let glyph = lm.glyphIndexForCharacter(at: min(max(0, line.range.location), total - 1))
            // The fragment of the last (collapsed) line carries the spacing we reserved; its *used* rect is just the line.
            let frag = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let frame = NSRect(x: origin.x - GridMetrics.leftGutter, y: frag.maxY + origin.y,
                               width: max(width, grid.tableSize.width) + GridMetrics.leftGutter + GridMetrics.rightGutter,
                               height: grid.totalHeight)
            if grid.frame != frame { grid.frame = frame }
        }
        if heightChanged { onReservedHeightsChanged?() }
    }

    /// Every way a visible grid disagrees with the text around it (empty means consistent): wrong column width, not
    /// lined up with the text column, wrong reserved height, or overlapping the paragraph below. Used by tests and the
    /// end-to-end run; it never changes anything.
    func layoutProblems() -> [String] {
        guard let tv = textView, let lm = tv.layoutManager, let storage = tv.textStorage else { return ["no text view"] }
        let total = storage.length
        guard total > 0, analysis.length == total else { return ["analysis is stale (\(analysis.length) vs \(total) characters)"] }
        let blocks = gridBlocks
        guard blocks.count == grids.count else { return ["\(blocks.count) tables but \(grids.count) grids"] }
        var out: [String] = []
        let origin = tv.textContainerOrigin
        let width = availableWidth
        for (k, block) in blocks.enumerated() {
            let grid = grids[k]
            guard !grid.isHidden, block.lastLine < analysis.lines.count else { continue }
            let line = analysis.lines[block.lastLine]
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(total, NSMaxRange(line.range))))
            let glyph = lm.glyphIndexForCharacter(at: min(max(0, line.range.location), total - 1))
            let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            func f(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
            if abs(grid.maxTableWidth - width) > 1 {
                out.append("grid \(k) was sized for a \(f(grid.maxTableWidth)) pt column but the text column is \(f(width)) pt")
            }
            let expectedX = origin.x - GridMetrics.leftGutter
            if abs(grid.frame.minX - expectedX) > 1 {
                out.append("grid \(k) starts at x=\(f(grid.frame.minX)) but the text column implies x=\(f(expectedX))")
            }
            let expectedY = used.maxY + origin.y
            if abs(grid.frame.minY - expectedY) > 1 {
                out.append("grid \(k) is at y=\(f(grid.frame.minY)) but its source line ends at y=\(f(expectedY))")
            }
            let spacing = (storage.attribute(.paragraphStyle, at: line.range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? -1
            if abs(spacing - grid.totalHeight) > 1 {
                out.append("grid \(k): the text reserves \(f(spacing)) pt but the grid is \(f(grid.totalHeight)) pt tall")
            }
            let overlap = grid.frame.maxY - (frag.maxY + origin.y)
            if overlap > 1 { out.append("grid \(k) overlaps the text below it by \(f(overlap)) pt") }
        }
        return out
    }

    // MARK: Writing edits back

    /// Writes `model` into the document as the table's new Markdown. `typing` marks keystrokes in one cell so they
    /// share a single undo step; `focus` is where the keyboard should land once the grid has been rebuilt.
    func commit(grid: TableGridView, model: TableModel, undoName: String, focus: TableCellPosition?,
                selection: NSRange? = nil, typing: TableCellPosition? = nil) {
        guard let tv = textView else { return }
        if analysis.length != tv.textStorage?.length { coordinator.reanalyze() }
        let blocks = gridBlocks
        guard grid.order < blocks.count else { return }
        if let focus { pendingFocus = (grid.order, focus, selection) }
        let key: AnyHashable? = typing.map { AnyHashable(TypingKey(order: grid.order, row: $0.row, column: $0.column)) }
        tv.applyTableText(tableStart: blocks[grid.order].range.location, markdown: model.markdown, undoName: undoName, coalesceKey: key)
        consumePendingFocus()
    }

    func endTypingSession() { textView?.gridTypingKey = nil }

    /// Clicking into a grid ends "Edit as Markdown" on another table (the text view's selection did not change).
    func focusMovedIntoGrid() {
        guard coordinator.sourceTableFirstLine != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.coordinator.endTableSource() }
    }

    private func consumePendingFocus() {
        guard let pending = pendingFocus else { return }
        // A debounced re-analysis (huge documents) has not rebuilt the grids yet: keep waiting for it.
        let current = analysis.length == textView?.textStorage?.length
        guard pending.order < grids.count, grids[pending.order].model.contains(pending.position) else {
            if current { pendingFocus = nil }
            return
        }
        pendingFocus = nil
        let grid = grids[pending.order]
        if grid.isHidden {
            // Markdown source is showing: put the caret in the same cell of the source.
            let blocks = gridBlocks
            if pending.order < blocks.count, let r = blocks[pending.order].range(of: pending.position) {
                textView?.setSelectedRange(NSRange(location: r.location, length: 0))
            }
        } else {
            grid.focus(pending.position, selection: pending.selection)
        }
    }

    /// Runs a table command on a cell (context menu, Format menu, grips).
    func perform(_ command: TableCommand, grid: TableGridView, at pos: TableCellPosition) {
        switch command {
        case .editAsMarkdown:
            coordinator.showTableSource(order: grid.order, at: pos)
        case .deleteTable:
            deleteTable(grid)
        default:
            guard let result = grid.model.applying(command, at: pos) else { NSSound.beep(); return }
            commit(grid: grid, model: result.model, undoName: command.title, focus: result.focus)
        }
    }

    /// Same, addressed by table order and a document offset (Markdown source showing, no cell has focus).
    func perform(_ command: TableCommand, atOffset offset: Int) {
        let blocks = gridBlocks
        guard let k = blocks.firstIndex(where: { offset >= $0.range.location && offset <= NSMaxRange($0.range) }), k < grids.count,
              let found = blocks[k].cell(nearest: offset) else { NSSound.beep(); return }
        perform(command, grid: grids[k], at: found.position)
    }

    private func deleteTable(_ grid: TableGridView) {
        guard let tv = textView else { return }
        let blocks = gridBlocks
        guard grid.order < blocks.count else { return }
        let edit = TableEditing.deleteTable(in: tv.string, table: blocks[grid.order])
        tv.window?.makeFirstResponder(tv)
        tv.apply(edit)
    }

    // MARK: Leaving the grid

    func leave(grid: TableGridView, after: Bool) {
        guard let tv = textView else { return }
        let blocks = gridBlocks
        guard grid.order < blocks.count else { return }
        let block = blocks[grid.order]
        let edit = after ? TableEditing.exitAfter(in: tv.string, table: block) : TableEditing.exitBefore(in: tv.string, table: block)
        tv.window?.makeFirstResponder(tv)
        if edit.replacement.isEmpty {
            tv.setSelectedRange(edit.selection)
            tv.scrollRangeToVisible(edit.selection)
        } else {
            tv.apply(edit)
        }
    }

    // MARK: Focus coming from the text view

    /// When the text view's caret lands inside a grid table (arrow keys, a click beside the table, Insert Table, undo,
    /// a find match), keyboard focus moves into the matching cell. Wider selections only tint the grid.
    func scheduleHandOff() {
        guard !handOffScheduled else { return }
        handOffScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.handOffScheduled = false
            self.handOffNow()
        }
    }

    @discardableResult
    func handOffNow() -> Bool {
        guard let tv = textView, let window = tv.window, window.firstResponder === tv, !hasFocus,
              analysis.length == tv.textStorage?.length else { return false }
        let sel = tv.selectedRange()
        let blocks = gridBlocks
        guard let k = blocks.firstIndex(where: { sel.location >= $0.range.location && sel.location <= NSMaxRange($0.range) }),
              k < grids.count, !grids[k].isHidden, blocks[k].firstLine != coordinator.sourceTableFirstLine,
              let found = blocks[k].cell(nearest: sel.location) else { return false }
        var local = NSRange(location: found.local, length: 0)
        if sel.length > 0 {
            guard let r = blocks[k].range(of: found.position), sel.location >= r.location, NSMaxRange(sel) <= NSMaxRange(r) else { return false }
            local.length = sel.length
        }
        grids[k].focus(found.position, selection: local)
        return true
    }

    /// Tints the cells covered by a ranged selection in the document text.
    func highlightSelection() {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        for (k, block) in gridBlocks.enumerated() where k < grids.count {
            var set = Set<TableCellPosition>()
            if sel.length > 0, NSIntersectionRange(sel, block.range).length > 0 || (sel.location <= block.range.location && NSMaxRange(sel) >= NSMaxRange(block.range)) {
                let whole = sel.location <= block.range.location && NSMaxRange(sel) >= NSMaxRange(block.range)
                for (r, row) in block.cellRanges.enumerated() {
                    for (c, range) in row.enumerated() where whole || NSIntersectionRange(range, sel).length > 0 {
                        set.insert(TableCellPosition(row: r, column: c))
                    }
                }
            }
            grids[k].highlighted = set
        }
    }

    /// A click in the reserved space around a grid (not on a cell) focuses the nearest cell.
    func focusNearestCell(atTextViewPoint point: NSPoint) -> Bool {
        guard let tv = textView else { return false }
        for grid in grids where !grid.isHidden && grid.frame.contains(point) {
            let local = grid.convert(point, from: tv)
            if let pos = grid.nearestCell(toLocal: local) { grid.focus(pos, atEnd: true); return true }
        }
        return false
    }

    /// Backspace at the start of the line below a grid table, or forward-delete at the end of the line above it,
    /// would silently merge text into the table; send the caret into the neighbouring cell instead.
    func enterTable(adjacentToCaret caret: Int, backwards: Bool) -> Bool {
        let blocks = gridBlocks
        for (k, block) in blocks.enumerated() where k < grids.count && !grids[k].isHidden {
            if backwards, caret == NSMaxRange(block.range) + 1 {
                grids[k].focus(TableCellPosition(row: block.cellRanges.count - 1, column: max(0, (block.model?.columnCount ?? 1) - 1)), atEnd: true)
                return true
            }
            if !backwards, caret + 1 == block.range.location {
                grids[k].focus(TableCellPosition(row: 0, column: 0), selection: NSRange(location: 0, length: 0))
                return true
            }
        }
        return false
    }

    func forwardFindAction(_ sender: Any?) { textView?.performTextFinderAction(sender) }
    func open(destination: String) { coordinator.open(destination: destination) }
}
