import AppKit
import DownwriteCore

// MARK: - Shared bits

enum GridMetrics {
    static let padX: CGFloat = 12
    static let padY: CGFloat = 7
    static let minColumn: CGFloat = 76
    /// Room left of the table for the row grips, right of it for the "add column" strip.
    static let leftGutter: CGFloat = 28
    static let rightGutter: CGFloat = 28
    /// Room above the table for the column grips.
    static let top: CGFloat = 18
    /// Room below the table for the "add row" strip and some air before the next paragraph.
    static let bottom: CGFloat = 30
    static let corner: CGFloat = 9
}

/// Carries a `TableCommand` through the responder chain (`NSApp.sendAction` takes an `Any?` sender).
final class TableCommandBox: NSObject {
    let command: TableCommand
    init(_ command: TableCommand) { self.command = command }
}

/// What a context-menu item should do and where.
final class TableMenuPayload: NSObject {
    let command: TableCommand
    let position: TableCellPosition
    init(_ command: TableCommand, _ position: TableCellPosition) { self.command = command; self.position = position }
}

extension TableCommand {
    var title: String {
        switch self {
        case .insertRowAbove: return "Insert Row Above"
        case .insertRowBelow: return "Insert Row Below"
        case .insertColumnLeft: return "Insert Column Left"
        case .insertColumnRight: return "Insert Column Right"
        case .deleteRow: return "Delete Row"
        case .deleteColumn: return "Delete Column"
        case .moveRowUp: return "Move Row Up"
        case .moveRowDown: return "Move Row Down"
        case .moveColumnLeft: return "Move Column Left"
        case .moveColumnRight: return "Move Column Right"
        case .duplicateRow: return "Duplicate Row"
        case .duplicateColumn: return "Duplicate Column"
        case .clearRow: return "Clear Row"
        case .clearColumn: return "Clear Column"
        case .align(let a):
            switch a {
            case .left: return "Align Left"
            case .center: return "Align Center"
            case .right: return "Align Right"
            case .none: return "Default Alignment"
            }
        case .sortAscending: return "Sort Column A → Z"
        case .sortDescending: return "Sort Column Z → A"
        case .editAsMarkdown: return "Edit as Markdown"
        case .deleteTable: return "Delete Table"
        }
    }
}

// MARK: - Cell

/// One editable cell of a table grid: a small TextKit 1 text view that edits the cell's Markdown source and shows it
/// with the same hide-the-syntax behaviour as the main editor.
final class TableCellView: NSTextView, NSTextViewDelegate {
    weak var grid: TableGridView?
    var position = TableCellPosition(row: 0, column: 0)
    private(set) var isHeader = false
    private(set) var cellAlignment = TableModel.Alignment.none
    private var analysis = MarkdownAnalyzer.analyzeTableCell("")
    private var lastHidden = Set<Int>()
    private var isStyling = false
    private var focused = false

    static func make() -> TableCellView {
        let storage = NSTextStorage()
        let layout = DWLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let tv = TableCellView(frame: NSRect(x: 0, y: 0, width: 100, height: 30), textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = false          // edits are written to the document, which owns undo
        tv.usesFindBar = false
        tv.usesFontPanel = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.drawsBackground = false
        tv.focusRingType = .none
        tv.textContainerInset = NSSize(width: GridMetrics.padX, height: GridMetrics.padY)
        tv.delegate = tv
        return tv
    }

    // MARK: Content

    /// Brings the view in line with the model. Text the user is typing is left alone when it already means the same.
    func configure(position p: TableCellPosition, text: String, header: Bool, alignment: TableModel.Alignment, force: Bool = false) {
        position = p
        setAccessibilityIdentifier("table-cell-\(p.row)-\(p.column)")
        setAccessibilityLabel(header ? "Table header, column \(p.column + 1)" : "Table cell, row \(p.row), column \(p.column + 1)")
        var restyle = force
        if TableModel.normalize(string) != text {
            string = text
            if focused { setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) }
            restyle = true
        }
        if header != isHeader || alignment != cellAlignment { isHeader = header; cellAlignment = alignment; restyle = true }
        if restyle || textStorage?.length != analysis.length { restyleCell(reanalyze: true) }
    }

    private var textAlignment: NSTextAlignment {
        switch cellAlignment {
        case .center: return .center
        case .right: return .right
        default: return .left
        }
    }

    /// While the cell is not being edited no selection touches it, so every marker is hidden.
    private var effectiveSelection: NSRange { focused ? selectedRange() : NSRange(location: Int.max / 2, length: 0) }

    func restyleCell(reanalyze: Bool) {
        guard let styler = grid?.styler, let storage = textStorage, !isStyling else { return }
        isStyling = true
        defer { isStyling = false }
        if reanalyze || analysis.length != storage.length { analysis = MarkdownAnalyzer.analyzeTableCell(string) }
        let sel = effectiveSelection
        styler.styleCell(storage: storage, analysis: analysis, selection: sel, header: isHeader, alignment: textAlignment)
        lastHidden = analysis.hiddenMarkerIndices(selection: sel)
        typingAttributes = styler.cellBaseAttributes(header: isHeader, alignment: textAlignment)
        insertionPointColor = styler.palette.accent.nsColor
        selectedTextAttributes = [.backgroundColor: styler.palette.selection.nsColor]
        needsDisplay = true
    }

    // MARK: Measuring

    var naturalWidth: CGFloat {
        guard let storage = textStorage else { return 0 }
        return ceil(storage.size().width) + 2 * GridMetrics.padX + 2
    }

    func height(forColumnWidth width: CGFloat, minLine: CGFloat) -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return minLine + 2 * GridMetrics.padY }
        tc.containerSize = NSSize(width: max(1, width - 2 * GridMetrics.padX), height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return max(lm.usedRect(for: tc).height, minLine) + 2 * GridMetrics.padY
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            focused = true
            restyleCell(reanalyze: false)
            grid?.cellDidBecomeFocused(self)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            focused = false
            restyleCell(reanalyze: false)
            grid?.cellDidResignFocus(self)
        }
        return ok
    }

    // MARK: Delegate

    func textDidChange(_ notification: Notification) {
        guard !isStyling, !hasMarkedText() else { return }
        restyleCell(reanalyze: true)
        grid?.cellTextChanged(self)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isStyling, focused, !hasMarkedText() else { return }
        if analysis.hiddenMarkerIndices(selection: selectedRange()) != lastHidden { restyleCell(reanalyze: false) }
    }

    // MARK: Keys

    override func insertTab(_ sender: Any?) {
        if hasMarkedText() { super.insertTab(sender) } else { grid?.tab(from: position, backwards: false) }
    }

    override func insertBacktab(_ sender: Any?) {
        if hasMarkedText() { super.insertBacktab(sender) } else { grid?.tab(from: position, backwards: true) }
    }

    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() { super.insertNewline(sender) } else { grid?.returnKey(from: position) }
    }

    /// ⇧Return / ⌥Return: a line break inside the cell (Markdown tables cannot hold real newlines).
    override func insertLineBreak(_ sender: Any?) { insertText("<br>", replacementRange: selectedRange()) }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertText("<br>", replacementRange: selectedRange()) }

    override func cancelOperation(_ sender: Any?) { grid?.leave(after: true) }

    private func fragmentTop(forCharacter loc: Int) -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer, (string as NSString).length > 0 else { return 0 }
        lm.ensureLayout(for: tc)
        let ch = min(max(0, loc), (string as NSString).length - 1)
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ch), effectiveRange: nil).minY
    }

    private var caretOnFirstLine: Bool { fragmentTop(forCharacter: selectedRange().location) <= fragmentTop(forCharacter: 0) + 0.5 }
    private var caretOnLastLine: Bool {
        fragmentTop(forCharacter: selectedRange().location) >= fragmentTop(forCharacter: (string as NSString).length - 1) - 0.5
    }

    override func moveUp(_ sender: Any?) {
        if selectedRange().length == 0, caretOnFirstLine, !hasMarkedText() { grid?.step(from: position, dRow: -1, dColumn: 0, atEnd: true) }
        else { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if selectedRange().length == 0, caretOnLastLine, !hasMarkedText() { grid?.step(from: position, dRow: 1, dColumn: 0, atEnd: false) }
        else { super.moveDown(sender) }
    }

    override func moveLeft(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location == 0, !hasMarkedText() { grid?.step(from: position, dRow: 0, dColumn: -1, atEnd: true) }
        else { super.moveLeft(sender) }
    }

    override func moveRight(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location == (string as NSString).length, !hasMarkedText() { grid?.step(from: position, dRow: 0, dColumn: 1, atEnd: false) }
        else { super.moveRight(sender) }
    }

    // MARK: Editing commands

    /// Pasting spreadsheet or Markdown-table data fills several cells; anything else is flattened to one line.
    override func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        if let values = TableModel.pastedGrid(from: s) {
            grid?.pasteGrid(values, from: position)
        } else {
            let flat = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
            insertText(flat, replacementRange: selectedRange())
        }
    }

    /// ⌘B, ⌘I … format the text of the cell.
    @objc func dwApplyFormat(_ sender: Any?) {
        guard let box = sender as? FormatCommandBox, !box.command.isBlockLevel,
              let edit = Formatter.apply(box.command, to: string, selection: selectedRange()) else { NSSound.beep(); return }
        let flat = edit.replacement.replacingOccurrences(of: "\n", with: " ")
        guard shouldChangeText(in: edit.range, replacementString: flat) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: flat)
        didChangeText()
        setSelectedRange(edit.selection)
    }

    @objc func dwIndent(_ sender: Any?) { grid?.tab(from: position, backwards: false) }
    @objc func dwOutdent(_ sender: Any?) { grid?.tab(from: position, backwards: true) }

    override func performTextFinderAction(_ sender: Any?) { grid?.forwardFindAction(sender) }

    override func menu(for event: NSEvent) -> NSMenu? { grid?.makeMenu(at: position, includeEditing: true) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.clickCount == 1 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if let link = analysis.link(at: index) { grid?.open(destination: link.destination); return }
        }
        super.mouseDown(with: event)
    }
}

private extension FormatCommand {
    /// Commands that only make sense for whole lines of the document, not inside a table cell.
    var isBlockLevel: Bool {
        switch self {
        case .heading, .body, .bulletList, .numberedList, .taskList, .blockQuote, .codeBlock, .horizontalRule, .formatTable, .insertTable:
            return true
        default:
            return false
        }
    }
}

// MARK: - Grid

/// An editable grid for one Markdown table, drawn over the table's (collapsed) source: row and column grips that
/// drag to reorder and click for a menu, add strips, a right-click menu, Tab navigation. All changes go back to the
/// document as Markdown through `TableOverlay`.
final class TableGridView: NSView {
    private enum AddKind { case row, column }
    private struct Drag {
        var isRow: Bool
        var index: Int
        var gap: Int
    }
    private enum Hit {
        case none, cell(TableCellPosition), rowGrip(Int), columnGrip(Int), addRow, addColumn
    }

    unowned let overlay: TableOverlay
    private(set) var model: TableModel
    private(set) var cells: [[TableCellView]] = []
    /// Position among the document's grid tables.
    var order = 0

    private var columnWidths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private(set) var tableSize = CGSize.zero
    private(set) var totalHeight: CGFloat = GridMetrics.top + GridMetrics.bottom
    private(set) var maxTableWidth: CGFloat = 0

    private(set) var focusedPosition: TableCellPosition?
    /// Cells touched by a ranged selection in the document text (e.g. a find match), tinted.
    var highlighted: Set<TableCellPosition> = [] { didSet { if oldValue != highlighted { needsDisplay = true } } }
    private var hoverRow: Int?
    private var hoverColumn: Int?
    private var hoverAdd: AddKind?
    private var pointerInside = false
    private var drag: Drag?
    private var isReconciling = false

    var styler: MarkdownStyler { overlay.styler }
    private var palette: Palette { overlay.styler.palette }
    private var rowCount: Int { model.rowCount }
    private var columnCount: Int { model.columnCount }

    init(overlay: TableOverlay, model: TableModel) {
        self.overlay = overlay
        self.model = model
        super.init(frame: .zero)
        setAccessibilityIdentifier("table-grid")
        setAccessibilityLabel("Table")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    // MARK: Model → views

    func apply(model new: TableModel, forceRestyle: Bool = false) {
        model = new
        isReconciling = true
        defer { isReconciling = false }
        // Rows and columns beyond the new shape go; missing ones are created.
        while cells.count > new.rowCount { cells.removeLast().forEach { $0.removeFromSuperview() } }
        for r in 0..<new.rowCount {
            if r >= cells.count { cells.append([]) }
            while cells[r].count > new.columnCount { cells[r].removeLast().removeFromSuperview() }
            while cells[r].count < new.columnCount {
                let cell = TableCellView.make()
                cell.grid = self
                addSubview(cell)
                cells[r].append(cell)
            }
        }
        for r in 0..<new.rowCount {
            for c in 0..<new.columnCount {
                cells[r][c].configure(position: TableCellPosition(row: r, column: c), text: new.cell(r, c), header: r == 0,
                                      alignment: new.alignments[c], force: forceRestyle)
            }
        }
        if let f = focusedPosition, !new.contains(f) { focusedPosition = nil }
        needsDisplay = true
    }

    func restyleAllCells() {
        for row in cells { for cell in row { cell.restyleCell(reanalyze: false) } }
        needsDisplay = true
    }

    // MARK: Layout

    /// Sizes columns and rows for `maxTableWidth` and positions the cells. Returns true when the height changed.
    @discardableResult
    func relayout(maxTableWidth width: CGFloat) -> Bool {
        maxTableWidth = width
        guard cells.count == rowCount, cells.allSatisfy({ $0.count == columnCount }) else { return false }
        let natural = (0..<columnCount).map { c in (0..<rowCount).map { cells[$0][c].naturalWidth }.max() ?? 0 }
        columnWidths = TableLayout.columnWidths(natural: natural.map { Double($0) }, available: Double(width),
                                                minimum: Double(GridMetrics.minColumn)).map { CGFloat($0) }
        let minLine = styler.cellLineHeight
        rowHeights = (0..<rowCount).map { r in
            (0..<columnCount).map { cells[r][$0].height(forColumnWidth: columnWidths[$0], minLine: minLine) }.max() ?? (minLine + 2 * GridMetrics.padY)
        }
        var y = GridMetrics.top
        for r in 0..<rowCount {
            var x = GridMetrics.leftGutter
            for c in 0..<columnCount {
                let frame = NSRect(x: x, y: y, width: columnWidths[c], height: rowHeights[r])
                if cells[r][c].frame != frame { cells[r][c].frame = frame }
                x += columnWidths[c]
            }
            y += rowHeights[r]
        }
        tableSize = CGSize(width: columnWidths.reduce(0, +), height: rowHeights.reduce(0, +))
        let total = GridMetrics.top + tableSize.height + GridMetrics.bottom
        let changed = abs(total - totalHeight) > 0.5
        totalHeight = total
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        return changed
    }

    var tableRect: NSRect { NSRect(x: GridMetrics.leftGutter, y: GridMetrics.top, width: tableSize.width, height: tableSize.height) }

    private func rowRect(_ r: Int) -> NSRect {
        let y = GridMetrics.top + rowHeights.prefix(r).reduce(0, +)
        return NSRect(x: tableRect.minX, y: y, width: tableRect.width, height: rowHeights.indices.contains(r) ? rowHeights[r] : 0)
    }

    private func columnRect(_ c: Int) -> NSRect {
        let x = GridMetrics.leftGutter + columnWidths.prefix(c).reduce(0, +)
        return NSRect(x: x, y: tableRect.minY, width: columnWidths.indices.contains(c) ? columnWidths[c] : 0, height: tableRect.height)
    }

    private func rowGripRect(_ r: Int) -> NSRect {
        let rr = rowRect(r)
        let h = min(30, max(18, rr.height - 8))
        return NSRect(x: tableRect.minX - 22, y: rr.midY - h / 2, width: 15, height: h)
    }

    private func columnGripRect(_ c: Int) -> NSRect {
        let cr = columnRect(c)
        let w = min(36, max(20, cr.width - 16))
        return NSRect(x: cr.midX - w / 2, y: 3, width: w, height: 12)
    }

    private var addColumnRect: NSRect { NSRect(x: tableRect.maxX + 6, y: tableRect.minY, width: 18, height: tableRect.height) }
    private var addRowRect: NSRect { NSRect(x: tableRect.minX, y: tableRect.maxY + 6, width: tableRect.width, height: 18) }

    private func rowIndex(atY y: CGFloat) -> Int? {
        guard y >= tableRect.minY, y < tableRect.maxY else { return nil }
        var edge = tableRect.minY
        for (r, h) in rowHeights.enumerated() { edge += h; if y < edge { return r } }
        return rowHeights.indices.last
    }

    private func columnIndex(atX x: CGFloat) -> Int? {
        guard x >= tableRect.minX, x < tableRect.maxX else { return nil }
        var edge = tableRect.minX
        for (c, w) in columnWidths.enumerated() { edge += w; if x < edge { return c } }
        return columnWidths.indices.last
    }

    private func hit(at p: NSPoint) -> Hit {
        guard tableSize.width > 0 else { return .none }
        if tableRect.contains(p), let r = rowIndex(atY: p.y), let c = columnIndex(atX: p.x) { return .cell(TableCellPosition(row: r, column: c)) }
        if addColumnRect.insetBy(dx: -3, dy: 0).contains(p) { return .addColumn }
        if addRowRect.insetBy(dx: 0, dy: -3).contains(p) { return .addRow }
        if p.x >= tableRect.minX - 26, p.x < tableRect.minX - 1, let r = rowIndex(atY: p.y) { return .rowGrip(r) }
        if p.y >= 0, p.y < GridMetrics.top - 1, let c = columnIndex(atX: p.x) { return .columnGrip(c) }
        return .none
    }

    // MARK: Hit testing and mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), !isHidden else { return nil }
        switch hit(at: local) {
        case .none: return nil
        case .cell: return super.hitTest(point) ?? self
        default: return self
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsDisplay = true }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        hoverRow = nil; hoverColumn = nil; hoverAdd = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pointerInside = true
        var row: Int?, column: Int?, add: AddKind?
        if p.x >= tableRect.minX - 28, p.x <= tableRect.maxX + 28 { row = rowIndex(atY: p.y) }
        if p.y >= 0, p.y <= tableRect.maxY + 28 { column = columnIndex(atX: p.x) }
        switch hit(at: p) {
        case .addRow: add = .row
        case .addColumn: add = .column
        default: break
        }
        if row != hoverRow || column != hoverColumn || add != hoverAdd { hoverRow = row; hoverColumn = column; hoverAdd = add; needsDisplay = true }
    }

    override func resetCursorRects() {
        guard tableSize.width > 0 else { return }
        for r in 0..<rowCount { addCursorRect(rowGripRect(r), cursor: .openHand) }
        for c in 0..<columnCount { addCursorRect(columnGripRect(c), cursor: .openHand) }
        addCursorRect(addColumnRect, cursor: .pointingHand)
        addCursorRect(addRowRect, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch hit(at: p) {
        case .rowGrip(let r): trackGrip(isRow: true, index: r, event: event)
        case .columnGrip(let c): trackGrip(isRow: false, index: c, event: event)
        case .addRow:
            perform(.insertRowBelow, at: TableCellPosition(row: rowCount - 1, column: 0))
        case .addColumn:
            perform(.insertColumnRight, at: TableCellPosition(row: 0, column: columnCount - 1))
        case .cell(let pos): focus(pos, atEnd: true)
        case .none: break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        switch hit(at: p) {
        case .rowGrip(let r): return makeMenu(at: TableCellPosition(row: r, column: focusedPosition?.column ?? 0), includeEditing: false)
        case .columnGrip(let c): return makeMenu(at: TableCellPosition(row: focusedPosition?.row ?? 0, column: c), includeEditing: false)
        case .cell(let pos): return makeMenu(at: pos, includeEditing: false)
        default: return nil
        }
    }

    // MARK: Grip dragging

    private func gap(forPointer p: NSPoint, isRow: Bool) -> Int {
        if isRow {
            var g = 1
            for r in 1..<max(1, rowCount) where p.y > rowRect(r).midY { g = r + 1 }
            return min(max(1, g), max(1, rowCount))
        }
        var g = 0
        for c in 0..<columnCount where p.x > columnRect(c).midX { g = c + 1 }
        return min(max(0, g), columnCount)
    }

    /// Final index of an item dragged from `index` and dropped into the gap before item `gap`.
    static func destination(from index: Int, gap: Int) -> Int { gap > index ? gap - 1 : gap }

    private func trackGrip(isRow: Bool, index: Int, event: NSEvent) {
        guard let window else { return }
        let start = convert(event.locationInWindow, from: nil)
        let draggable = isRow ? index >= 1 : true
        var dragging = false
        // A press that never moves is a click: it opens the menu for that row or column.
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = convert(e.locationInWindow, from: nil)
            if e.type == .leftMouseUp {
                if dragging, let d = drag {
                    let to = Self.destination(from: d.index, gap: d.gap)
                    drag = nil
                    needsDisplay = true
                    if to != d.index { commitMove(isRow: d.isRow, from: d.index, to: to) }
                } else {
                    drag = nil
                    needsDisplay = true
                    popUpMenu(isRow: isRow, index: index)
                }
                return
            }
            if !dragging, draggable, hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true }
            if dragging {
                drag = Drag(isRow: isRow, index: index, gap: gap(forPointer: p, isRow: isRow))
                needsDisplay = true
                displayIfNeeded()          // this loop owns the run loop, so draw by hand
            }
        }
        drag = nil
    }

    func commitMove(isRow: Bool, from: Int, to: Int) {
        var m = model
        let anchor = focusedPosition ?? TableCellPosition(row: isRow ? to : 0, column: isRow ? 0 : to)
        let moved = isRow ? m.moveRow(from: from, to: to) : m.moveColumn(from: from, to: to)
        guard moved else { return }
        let focus = isRow ? TableCellPosition(row: to, column: anchor.column) : TableCellPosition(row: anchor.row, column: to)
        overlay.commit(grid: self, model: m, undoName: isRow ? "Move Row" : "Move Column", focus: focus)
    }

    private func popUpMenu(isRow: Bool, index: Int) {
        let pos = isRow ? TableCellPosition(row: index, column: focusedPosition?.column ?? 0)
                        : TableCellPosition(row: focusedPosition?.row ?? 0, column: index)
        let menu = makeMenu(at: pos, includeEditing: false)
        let anchor = isRow ? NSPoint(x: rowGripRect(index).maxX, y: rowGripRect(index).maxY)
                           : NSPoint(x: columnGripRect(index).minX, y: columnGripRect(index).maxY + 2)
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    // MARK: Menu

    func makeMenu(at pos: TableCellPosition, includeEditing: Bool) -> NSMenu {
        let menu = NSMenu(title: "Table")
        menu.autoenablesItems = false
        func add(_ command: TableCommand, title: String? = nil, to target: NSMenu? = nil) {
            let item = NSMenuItem(title: title ?? command.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TableMenuPayload(command, pos)
            switch command {
            case .editAsMarkdown, .deleteTable: item.isEnabled = true
            case .align(let a): item.isEnabled = true; item.state = (model.alignments[min(pos.column, columnCount - 1)] == a) ? .on : .off
            default: item.isEnabled = model.applying(command, at: pos) != nil
            }
            (target ?? menu).addItem(item)
        }
        add(.insertRowAbove); add(.insertRowBelow)
        add(.insertColumnLeft); add(.insertColumnRight)
        menu.addItem(.separator())
        add(.moveRowUp); add(.moveRowDown)
        add(.moveColumnLeft); add(.moveColumnRight)
        menu.addItem(.separator())
        add(.duplicateRow); add(.duplicateColumn)
        add(.clearRow); add(.clearColumn)
        menu.addItem(.separator())
        add(.deleteRow); add(.deleteColumn)
        menu.addItem(.separator())
        let alignItem = NSMenuItem(title: "Column Alignment", action: nil, keyEquivalent: "")
        let alignMenu = NSMenu(title: "Column Alignment")
        alignMenu.autoenablesItems = false
        for a in [TableModel.Alignment.left, .center, .right, .none] { add(.align(a), to: alignMenu) }
        alignItem.submenu = alignMenu
        menu.addItem(alignItem)
        add(.sortAscending); add(.sortDescending)
        menu.addItem(.separator())
        add(.editAsMarkdown)
        add(.deleteTable)
        if includeEditing {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""))
        }
        return menu
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? TableMenuPayload else { return }
        perform(payload.command, at: payload.position)
    }

    /// Menu-bar commands (Format ▸ Table) reach the grid through the responder chain.
    @objc func dwTableCommand(_ sender: Any?) {
        guard let box = sender as? TableCommandBox, let pos = focusedPosition else { NSSound.beep(); return }
        perform(box.command, at: pos)
    }

    func perform(_ command: TableCommand, at pos: TableCellPosition) {
        overlay.perform(command, grid: self, at: pos)
    }

    // MARK: Focus and navigation

    func focus(_ p: TableCellPosition, selection: NSRange? = nil, atEnd: Bool = false) {
        guard cells.indices.contains(p.row), cells[p.row].indices.contains(p.column) else { return }
        let cell = cells[p.row][p.column]
        guard let window = cell.window else { return }
        window.makeFirstResponder(cell)
        let length = (cell.string as NSString).length
        if let s = selection {
            let loc = min(max(0, s.location), length)
            cell.setSelectedRange(NSRange(location: loc, length: min(max(0, s.length), length - loc)))
        } else if atEnd {
            cell.setSelectedRange(NSRange(location: length, length: 0))
        } else {
            cell.setSelectedRange(NSRange(location: 0, length: length))
        }
        cell.scrollToVisible(cell.bounds.insetBy(dx: 0, dy: -24))
    }

    func cellDidBecomeFocused(_ cell: TableCellView) {
        focusedPosition = cell.position
        overlay.endTypingSession()
        needsDisplay = true
    }

    func cellDidResignFocus(_ cell: TableCellView) {
        if focusedPosition == cell.position { focusedPosition = nil }
        needsDisplay = true
    }

    var hasFocus: Bool { focusedPosition != nil }

    func tab(from p: TableCellPosition, backwards: Bool) {
        guard let result = model.tab(from: p, backwards: backwards) else {
            if backwards { leave(after: false) }
            return
        }
        if result.model == model { focus(result.focus) }
        else { overlay.commit(grid: self, model: result.model, undoName: "Add Row", focus: result.focus) }
    }

    func returnKey(from p: TableCellPosition) {
        guard let result = model.returnKey(from: p) else { return }
        if result.model == model { focus(result.focus) }
        else { overlay.commit(grid: self, model: result.model, undoName: "Add Row", focus: result.focus) }
    }

    /// Arrow keys at the edge of a cell move to the neighbouring cell, or out of the table.
    func step(from p: TableCellPosition, dRow: Int, dColumn: Int, atEnd: Bool) {
        var target = TableCellPosition(row: p.row + dRow, column: p.column + dColumn)
        if dColumn != 0 {                                // left/right wrap across rows like Tab
            guard let wrapped = dColumn > 0 ? model.nextCell(after: p) : model.previousCell(before: p) else {
                leave(after: dColumn > 0)
                return
            }
            target = wrapped
        }
        if !model.contains(target) { leave(after: dRow > 0); return }
        focus(target, selection: atEnd ? nil : NSRange(location: 0, length: 0), atEnd: atEnd)
    }

    func leave(after: Bool) { overlay.leave(grid: self, after: after) }

    /// The cell closest to a point in this view's coordinates (for clicks next to the table).
    func nearestCell(toLocal p: NSPoint) -> TableCellPosition? {
        guard !columnWidths.isEmpty, !rowHeights.isEmpty else { return nil }
        let y = min(max(p.y, tableRect.minY), tableRect.maxY - 0.5)
        let x = min(max(p.x, tableRect.minX), tableRect.maxX - 0.5)
        guard let r = rowIndex(atY: y), let c = columnIndex(atX: x) else { return nil }
        return TableCellPosition(row: r, column: c)
    }

    func pasteGrid(_ values: [[String]], from p: TableCellPosition) {
        var m = model
        let end = m.paste(values, at: p)
        overlay.commit(grid: self, model: m, undoName: "Paste", focus: end)
    }

    func cellTextChanged(_ cell: TableCellView) {
        guard !isReconciling else { return }
        var m = model
        m.setCell(cell.string, at: cell.position)
        guard m != model else { relayoutAfterTyping(); return }
        overlay.commit(grid: self, model: m, undoName: "Typing", focus: nil, typing: cell.position)
    }

    /// Wrapped lines (or trailing spaces) can change a row's height even when the Markdown did not change.
    private func relayoutAfterTyping() {
        if relayout(maxTableWidth: maxTableWidth) { overlay.heightsChanged() }
    }

    func forwardFindAction(_ sender: Any?) { overlay.forwardFindAction(sender) }
    func open(destination: String) { overlay.open(destination: destination) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let t = tableRect
        guard t.width > 0, t.height > 0, rowHeights.count == rowCount, columnWidths.count == columnCount else { return }
        let p = palette
        let accent = p.accent.nsColor
        let rule = p.rule.nsColor

        // Body: header band, tints, separators — clipped to the rounded card.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: t, xRadius: GridMetrics.corner, yRadius: GridMetrics.corner).addClip()
        p.codeBackground.nsColor.withAlphaComponent(0.35).setFill()
        t.fill()
        p.codeBackground.nsColor.setFill()
        NSRect(x: t.minX, y: t.minY, width: t.width, height: rowHeights[0]).fill()
        if let r = hoverRow, drag == nil { accent.withAlphaComponent(0.05).setFill(); rowRect(r).fill() }
        if let c = hoverColumn, drag == nil { accent.withAlphaComponent(0.05).setFill(); columnRect(c).fill() }
        for pos in highlighted where model.contains(pos) { p.selection.nsColor.setFill(); cells[pos.row][pos.column].frame.fill() }
        if let d = drag {
            accent.withAlphaComponent(0.13).setFill()
            (d.isRow ? rowRect(d.index) : columnRect(d.index)).fill()
        }
        rule.setFill()
        var edge = t.minY
        for r in 0..<(rowCount - 1) { edge += rowHeights[r]; NSRect(x: t.minX, y: edge - 0.5, width: t.width, height: 1).fill() }
        edge = t.minX
        for c in 0..<(columnCount - 1) { edge += columnWidths[c]; NSRect(x: edge - 0.5, y: t.minY, width: 1, height: t.height).fill() }
        NSGraphicsContext.restoreGraphicsState()

        // Focused cell.
        if let f = focusedPosition, model.contains(f), f.row < cells.count, f.column < cells[f.row].count {
            let r = cells[f.row][f.column].frame
            accent.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            accent.setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            ring.lineWidth = 2
            ring.stroke()
        }

        // Outer border.
        rule.setStroke()
        let border = NSBezierPath(roundedRect: t.insetBy(dx: 0.5, dy: 0.5), xRadius: GridMetrics.corner, yRadius: GridMetrics.corner)
        border.lineWidth = 1
        border.stroke()

        // Drop indicator.
        if let d = drag {
            accent.setFill()
            if d.isRow {
                let y = d.gap >= rowCount ? t.maxY : rowRect(d.gap).minY
                NSBezierPath(roundedRect: NSRect(x: t.minX - 4, y: y - 1.5, width: t.width + 8, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            } else {
                let x = d.gap >= columnCount ? t.maxX : columnRect(d.gap).minX
                NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: t.minY - 4, width: 3, height: t.height + 8), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }

        // Grips for the active row/column, "+" strips while the pointer is over the table.
        let activeRows = Set([hoverRow, focusedPosition?.row, drag.flatMap { $0.isRow ? $0.index : nil }].compactMap { $0 })
        let activeColumns = Set([hoverColumn, focusedPosition?.column, drag.flatMap { $0.isRow ? nil : $0.index }].compactMap { $0 })
        for r in activeRows where r < rowCount { drawGrip(rowGripRect(r), vertical: true, strong: r == hoverRow || drag?.index == r && drag?.isRow == true) }
        for c in activeColumns where c < columnCount { drawGrip(columnGripRect(c), vertical: false, strong: c == hoverColumn || drag?.index == c && drag?.isRow == false) }
        if pointerInside || focusedPosition != nil {
            drawAddStrip(addColumnRect, strong: hoverAdd == .column)
            drawAddStrip(addRowRect, strong: hoverAdd == .row)
        }
    }

    private func drawGrip(_ rect: NSRect, vertical: Bool, strong: Bool) {
        let p = palette
        (strong ? p.accent.nsColor.withAlphaComponent(0.2) : p.codeBackground.nsColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        p.rule.nsColor.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        outline.lineWidth = 1
        outline.stroke()
        (strong ? p.accent.nsColor : p.marker.nsColor).setFill()
        let dot: CGFloat = 2.4, gap: CGFloat = 3.6
        let columns = vertical ? 2 : 3, lines = vertical ? 3 : 2
        let w = CGFloat(columns) * dot + CGFloat(columns - 1) * gap
        let h = CGFloat(lines) * dot + CGFloat(lines - 1) * gap
        for i in 0..<columns {
            for j in 0..<lines {
                let x = rect.midX - w / 2 + CGFloat(i) * (dot + gap)
                let y = rect.midY - h / 2 + CGFloat(j) * (dot + gap)
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            }
        }
    }

    private func drawAddStrip(_ rect: NSRect, strong: Bool) {
        let accent = palette.accent.nsColor
        accent.withAlphaComponent(strong ? 0.24 : 0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        accent.withAlphaComponent(strong ? 1 : 0.7).setStroke()
        let plus = NSBezierPath()
        let c = NSPoint(x: rect.midX, y: rect.midY)
        plus.move(to: NSPoint(x: c.x - 4.5, y: c.y)); plus.line(to: NSPoint(x: c.x + 4.5, y: c.y))
        plus.move(to: NSPoint(x: c.x, y: c.y - 4.5)); plus.line(to: NSPoint(x: c.x, y: c.y + 4.5))
        plus.lineWidth = 1.6
        plus.lineCapStyle = .round
        plus.stroke()
    }
}
