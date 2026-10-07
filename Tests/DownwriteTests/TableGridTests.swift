import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// The table grid in a real editor: layout over the collapsed source, typing, undo, Tab navigation, menus, drags,
/// focus hand-off and the Markdown-source view.
@MainActor
final class TableGridTests: XCTestCase {
    static let doc = "# Title\n\n| Name | Qty |\n| :--- | ---: |\n| apple | 3 |\n| pear | **12** |\n\nAfter the table.\n"

    private func harness(_ text: String = TableGridTests.doc, dark: Bool = false) -> EditorHarness {
        let h = EditorHarness(text: text, dark: dark, size: NSSize(width: 960, height: 700))
        h.window.makeFirstResponder(h.textView)
        settle(h)
        return h
    }

    private func settle(_ h: EditorHarness) {
        h.window.displayIfNeeded()
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        h.coordinator.tableOverlay.reposition()
        tick()
    }

    /// Lets the run loop turn once (closes undo groups, runs queued hand-offs).
    private func tick(_ seconds: TimeInterval = 0.03) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func grid(_ h: EditorHarness, _ i: Int = 0) -> TableGridView { h.coordinator.tableOverlay.grids[i] }
    private func cell(_ h: EditorHarness, _ r: Int, _ c: Int, table i: Int = 0) -> TableCellView { grid(h, i).cells[r][c] }
    private func model(_ h: EditorHarness, table i: Int = 0) -> TableModel? {
        MarkdownAnalyzer.analyze(h.textView.string).tables.filter(\.isGrid)[safe: i]?.model
    }

    private func usedRect(_ h: EditorHarness, line: Int) -> NSRect {
        let lm = h.textView.layoutManager!
        let loc = h.coordinator.analysis.lines[line].range.location
        return lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: loc), effectiveRange: nil)
    }

    private func menuItem(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let found = menuItem(sub, title) { return found }
        }
        return nil
    }

    private func choose(_ menu: NSMenu, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let item = menuItem(menu, title), item.isEnabled, let action = item.action else {
            return XCTFail("menu item “\(title)” missing or disabled", file: file, line: line)
        }
        NSApp.sendAction(action, to: item.target, from: item)
        tick()
    }

    // MARK: Layout

    func testTableIsShownAsAGridOverCollapsedSource() {
        let h = harness()
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 1)
        let g = grid(h)
        XCTAssertEqual(g.model.rows, [["Name", "Qty"], ["apple", "3"], ["pear", "**12**"]])
        XCTAssertEqual(g.model.alignments, [.left, .right])
        XCTAssertEqual(cell(h, 1, 0).string, "apple")
        for line in 2...5 { XCTAssertLessThan(usedRect(h, line: line).height, 2, "table source line \(line) is collapsed") }
        XCTAssertGreaterThan(g.totalHeight, 100)
        XCTAssertEqual(h.coordinator.tableOverlay.reservedHeights()[2] ?? 0, g.totalHeight, accuracy: 0.5)
        let after = usedRect(h, line: 7).minY + h.textView.textContainerOrigin.y
        XCTAssertGreaterThanOrEqual(after, g.frame.maxY - 1, "text after the table starts below the grid (\(after) vs \(g.frame.maxY))")
        XCTAssertGreaterThanOrEqual(g.frame.minY, usedRect(h, line: 1).maxY, "grid starts below the text above it")
        XCTAssertEqual(g.frame.minX, h.textView.textContainerOrigin.x - GridMetrics.leftGutter, accuracy: 0.5)
    }

    func testCellsAreLaidOutAsAnAlignedGrid() {
        let h = harness()
        let g = grid(h)
        let a = cell(h, 0, 0).frame, b = cell(h, 0, 1).frame, c = cell(h, 1, 0).frame
        XCTAssertEqual(a.maxX, b.minX, accuracy: 0.5)
        XCTAssertEqual(a.maxY, c.minY, accuracy: 0.5)
        XCTAssertEqual(a.minX, c.minX, accuracy: 0.5)
        XCTAssertEqual(cell(h, 2, 1).frame.maxX, g.tableRect.maxX, accuracy: 0.5)
        XCTAssertEqual(cell(h, 2, 1).frame.maxY, g.tableRect.maxY, accuracy: 0.5)
        XCTAssertEqual(cell(h, 1, 1).alignmentForTest, .right)
        XCTAssertEqual(cell(h, 1, 0).alignmentForTest, .left)
    }

    func testInlineSyntaxInCellsHidesUntilTheCellIsEdited() {
        let h = harness()
        let c = cell(h, 2, 1)                       // "**12**"
        XCTAssertLessThan((c.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 1, "markers hidden")
        XCTAssertTrue((c.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as! NSFont).isBold, "text is bold")
        grid(h).focus(.init(row: 2, column: 1), atEnd: true)
        XCTAssertGreaterThan((c.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 8, "markers revealed while editing")
        grid(h).focus(.init(row: 1, column: 0))
        XCTAssertLessThan((c.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 1, "hidden again after leaving")
    }

    func testTablesInQuotesAndListsStayRawSource() {
        let h = harness("> | a | b |\n> | - | - |\n> | 1 | 2 |\n\n- item\n\n  | x | y |\n  | - | - |\n  | 1 | 2 |\n")
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 0)
        XCTAssertGreaterThan(usedRect(h, line: 0).height, 8)
    }

    func testLongCellsWrapInsteadOfWideningTheTable() {
        let long = String(repeating: "words that go on and on ", count: 14)
        let h = harness("| Short | Long |\n| --- | --- |\n| a | \(long) |\n\nEnd\n")
        let g = grid(h)
        let width = h.textView.bounds.width - h.textView.textContainerInset.width * 2
        XCTAssertLessThanOrEqual(g.tableSize.width, width + 0.5)
        XCTAssertGreaterThan(cell(h, 1, 1).frame.height, cell(h, 0, 1).frame.height * 2, "long cell wraps onto several lines")
        XCTAssertLessThan(cell(h, 1, 0).frame.width, 200, "the short column keeps its natural width")
    }

    func testManyColumnsStayInsideTheTextColumnAndRemainClickable() {
        let cols = 12
        let head = "| " + (1...cols).map { "Heading \($0)" }.joined(separator: " | ") + " |"
        let rule = "| " + (1...cols).map { _ in "---" }.joined(separator: " | ") + " |"
        let body = "| " + (1...cols).map { "value \($0)" }.joined(separator: " | ") + " |"
        let h = harness(head + "\n" + rule + "\n" + body + "\n\nEnd\n")
        let g = grid(h)
        let width = h.textView.bounds.width - h.textView.textContainerInset.width * 2
        XCTAssertLessThanOrEqual(g.tableSize.width, width + 0.5, "table fits the text column")
        XCTAssertGreaterThanOrEqual(g.frame.width, g.tableSize.width + GridMetrics.leftGutter + GridMetrics.rightGutter - 0.5)
        let last = cell(h, 1, cols - 1)
        XCTAssertLessThanOrEqual(last.frame.maxX, g.tableRect.maxX + 0.5)
        let t = g.tableRect
        let hit = g.hitTest(g.superview!.convert(NSPoint(x: t.maxX - 10, y: t.maxY - 10), from: g))
        XCTAssertTrue(hit != nil && hit!.isDescendant(of: g), "the last column can be clicked")
        XCTAssertNotNil(g.hitTest(g.superview!.convert(NSPoint(x: t.maxX + 14, y: t.midY), from: g)), "add-column strip is reachable")
    }

    // MARK: Typing and undo

    func testTypingInACellWritesMarkdownAndOneUndoRevertsTheWholeRun() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 0))
        let c = cell(h, 1, 0)
        c.insertText("kiwi", replacementRange: c.selectedRange())
        XCTAssertEqual(model(h)?.rows[1], ["kiwi", "3"])
        c.insertText(" fruit", replacementRange: NSRange(location: c.string.utf16.count, length: 0))
        XCTAssertEqual(model(h)?.rows[1], ["kiwi fruit", "3"])
        XCTAssertEqual(h.box.value, h.textView.string, "binding follows the document")
        XCTAssertEqual(window(h).firstResponder as? TableCellView, c, "typing keeps the focus in the cell")
        tick()
        h.textView.undoManager?.undo()
        XCTAssertEqual(model(h)?.rows[1], ["apple", "3"], "the whole typing run is one undo step")
        XCTAssertEqual(cell(h, 1, 0).string, "apple")
        h.textView.undoManager?.redo()
        XCTAssertEqual(model(h)?.rows[1], ["kiwi fruit", "3"])
    }

    func testTypingKeepsTrailingSpaceAndEscapesPipes() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 0))
        let c = cell(h, 1, 0)
        c.insertText("a|b ", replacementRange: c.selectedRange())
        XCTAssertEqual(c.string, "a|b ", "what the person typed stays on screen")
        XCTAssertEqual(model(h)?.rows[1][0], "a\\|b")
        XCTAssertTrue(h.textView.string.contains("a\\|b"))
        XCTAssertEqual(MarkdownAnalyzer.analyze(h.textView.string).tables.first?.model?.columnCount, 2, "the pipe did not add a column")
    }

    func testFormatShortcutsApplyInsideTheCell() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 0))
        cell(h, 1, 0).dwApplyFormat(FormatCommandBox(.bold))
        XCTAssertEqual(model(h)?.rows[1][0], "**apple**")
        cell(h, 1, 0).dwApplyFormat(FormatCommandBox(.heading(2)))
        XCTAssertEqual(model(h)?.rows[1][0], "**apple**", "block formats do not apply inside a cell")
    }

    func testLineBreakShortcutInsertsBr() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 0), atEnd: true)
        cell(h, 1, 0).insertLineBreak(nil)
        XCTAssertEqual(model(h)?.rows[1][0], "apple<br>")
    }

    // MARK: Tab and Return

    func testTabWalksCellsAndTheLastCellAddsARow() {
        let h = harness()
        grid(h).focus(.init(row: 0, column: 0))
        cell(h, 0, 0).insertTab(nil)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 0, column: 1))
        XCTAssertTrue(window(h).firstResponder === cell(h, 0, 1))
        cell(h, 0, 1).insertTab(nil)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 1, column: 0), "Tab wraps to the next row")
        cell(h, 1, 0).insertBacktab(nil)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 0, column: 1))

        grid(h).focus(.init(row: 2, column: 1))
        tick()
        cell(h, 2, 1).insertTab(nil)
        XCTAssertEqual(model(h)?.rowCount, 4, "Tab out of the last cell appends a row")
        XCTAssertEqual(model(h)?.rows[3], ["", ""])
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 3, column: 0))
        XCTAssertTrue(window(h).firstResponder === cell(h, 3, 0))
        tick()
        h.textView.undoManager?.undo()
        XCTAssertEqual(model(h)?.rowCount, 3, "adding a row is one undo step")
    }

    func testKeyboardStaysInTheTableWhenTheFocusedCellIsUndoneAway() {
        let h = harness()
        grid(h).focus(.init(row: 2, column: 1))
        tick()
        cell(h, 2, 1).insertTab(nil)                       // adds row 3 and focuses it
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 3, column: 0))
        tick()
        h.textView.undoManager?.undo()                     // the focused cell no longer exists
        XCTAssertEqual(model(h)?.rowCount, 3)
        XCTAssertTrue(window(h).firstResponder is TableCellView, "focus moved to a surviving cell, not lost")
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 2, column: 0))
    }

    func testTheWindowKeepsAResponderWhenTheFocusedTableIsRemoved() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 0))
        h.coordinator.update(text: "no table now\n", settings: EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720))
        XCTAssertTrue(window(h).firstResponder === h.textView, "the text view takes the keyboard back")
    }

    func testTabSelectsTheWholeCell() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 0))
        cell(h, 1, 0).insertTab(nil)
        XCTAssertEqual(cell(h, 1, 1).selectedRange(), NSRange(location: 0, length: 1))
    }

    func testReturnMovesDownAndAppendsOnTheLastRow() {
        let h = harness()
        grid(h).focus(.init(row: 0, column: 1))
        cell(h, 0, 1).insertNewline(nil)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 1, column: 1))
        grid(h).focus(.init(row: 2, column: 1))
        tick()
        cell(h, 2, 1).insertNewline(nil)
        XCTAssertEqual(model(h)?.rowCount, 4)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 3, column: 1))
    }

    func testShiftTabInTheFirstCellLeavesAboveAndArrowsLeaveBelow() {
        let h = harness()
        let tableStart = h.coordinator.analysis.tables[0].range.location
        grid(h).focus(.init(row: 0, column: 0))
        cell(h, 0, 0).insertBacktab(nil)
        XCTAssertTrue(window(h).firstResponder === h.textView)
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: tableStart - 1, length: 0), "caret on the line above the table")
        tick()
        XCTAssertNil(grid(h).focusedPosition)

        let tableEnd = NSMaxRange(h.coordinator.analysis.tables[0].range)
        grid(h).focus(.init(row: 2, column: 1), atEnd: true)
        cell(h, 2, 1).moveRight(nil)
        XCTAssertTrue(window(h).firstResponder === h.textView)
        XCTAssertEqual(h.textView.selectedRange().location, tableEnd + 2, "start of the paragraph after the blank line")
        XCTAssertEqual(h.textView.selectedRange().location, h.index(of: "After the table."))
    }

    func testEscapeLeavesTheTable() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 0))
        cell(h, 1, 0).cancelOperation(nil)
        XCTAssertTrue(window(h).firstResponder === h.textView)
        XCTAssertEqual(h.textView.selectedRange().location, h.index(of: "After the table."))
    }

    func testLeavingBelowATableAtTheEndOfTheDocumentAddsTheBlankLine() {
        let h = harness("| a | b |\n| - | - |\n| 1 | 2 |")
        grid(h).focus(.init(row: 1, column: 1), atEnd: true)
        cell(h, 1, 1).moveDown(nil)
        XCTAssertTrue(h.textView.string.hasSuffix("| 1 | 2 |\n\n"), h.textView.string.debugDescription)
        XCTAssertEqual(h.textView.selectedRange().location, h.textView.string.utf16.count)
        XCTAssertTrue(window(h).firstResponder === h.textView)
    }

    func testArrowKeysMoveBetweenCellsAtTheEdges() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 0), atEnd: true)
        cell(h, 1, 0).moveRight(nil)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 1, column: 1))
        XCTAssertEqual(cell(h, 1, 1).selectedRange(), NSRange(location: 0, length: 0))
        cell(h, 1, 1).moveLeft(nil)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 1, column: 0))
        XCTAssertEqual(cell(h, 1, 0).selectedRange().location, 5, "caret at the end of the previous cell")
        cell(h, 1, 0).moveDown(nil)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 2, column: 0))
        cell(h, 2, 0).moveUp(nil)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 1, column: 0))
    }

    // MARK: Menu

    func testContextMenuOffersEveryTableAction() throws {
        let h = harness()
        let menu = grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false)
        for title in ["Insert Row Above", "Insert Row Below", "Insert Column Left", "Insert Column Right",
                      "Move Row Up", "Move Row Down", "Move Column Left", "Move Column Right",
                      "Duplicate Row", "Duplicate Column", "Clear Row", "Clear Column", "Delete Row", "Delete Column",
                      "Column Alignment", "Align Left", "Align Center", "Align Right", "Default Alignment",
                      "Sort Column A → Z", "Sort Column Z → A", "Edit as Markdown", "Delete Table"] {
            XCTAssertNotNil(menuItem(menu, title), title)
        }
        XCTAssertTrue(try XCTUnwrap(menuItem(menu, "Delete Row")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menuItem(menu, "Move Row Up")).isEnabled, "the first body row cannot move above the header")
        XCTAssertFalse(try XCTUnwrap(menuItem(menu, "Move Column Left")).isEnabled)
        XCTAssertEqual(try XCTUnwrap(menuItem(menu, "Align Left")).state, .on, "current alignment is ticked")
        let header = grid(h).makeMenu(at: .init(row: 0, column: 1), includeEditing: false)
        XCTAssertFalse(try XCTUnwrap(menuItem(header, "Delete Row")).isEnabled, "the header row cannot be deleted")
        XCTAssertFalse(try XCTUnwrap(menuItem(header, "Insert Row Above")).isEnabled)
        let editing = grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: true)
        XCTAssertNotNil(menuItem(editing, "Paste"), "cell menu also carries Cut/Copy/Paste")
    }

    func testMenuInsertRowsAndColumns() {
        let h = harness()
        let menu = { self.grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false) }
        choose(menu(), "Insert Row Below")
        XCTAssertEqual(model(h)?.rows, [["Name", "Qty"], ["apple", "3"], ["", ""], ["pear", "**12**"]])
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 2, column: 0), "focus lands in the new row")
        choose(menu(), "Insert Row Above")
        XCTAssertEqual(model(h)?.rows[1], ["", ""])
        choose(menu(), "Insert Column Right")
        XCTAssertEqual(model(h)?.columnCount, 3)
        XCTAssertEqual(model(h)?.rows[0], ["Name", "", "Qty"])
        XCTAssertEqual(model(h)?.alignments, [.left, .none, .right])
        choose(menu(), "Insert Column Left")
        XCTAssertEqual(model(h)?.rows[0], ["", "Name", "", "Qty"])
    }

    func testMenuDeleteMoveDuplicateAndAlign() {
        let h = harness()
        choose(grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false), "Move Row Down")
        XCTAssertEqual(model(h)?.rows.map { $0[0] }, ["Name", "pear", "apple"])
        choose(grid(h).makeMenu(at: .init(row: 2, column: 0), includeEditing: false), "Duplicate Row")
        XCTAssertEqual(model(h)?.rows.map { $0[0] }, ["Name", "pear", "apple", "apple"])
        choose(grid(h).makeMenu(at: .init(row: 3, column: 0), includeEditing: false), "Delete Row")
        XCTAssertEqual(model(h)?.rowCount, 3)
        choose(grid(h).makeMenu(at: .init(row: 1, column: 1), includeEditing: false), "Align Center")
        XCTAssertEqual(model(h)?.alignments, [.left, .center])
        XCTAssertTrue(h.textView.string.contains(":-"), "the delimiter row carries the alignment")
        choose(grid(h).makeMenu(at: .init(row: 0, column: 0), includeEditing: false), "Move Column Right")
        XCTAssertEqual(model(h)?.rows[0], ["Qty", "Name"])
        XCTAssertEqual(model(h)?.alignments, [.center, .left], "alignment travels with the column")
        choose(grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false), "Delete Column")
        XCTAssertEqual(model(h)?.columnCount, 1)
        XCTAssertFalse(menuItem(grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false), "Delete Column")!.isEnabled,
                       "the last column cannot be deleted")
    }

    func testMenuSortsAndClears() {
        let h = harness("| n |\n| - |\n| 10 |\n| 2 |\n| b |\n| a |\n")
        choose(grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false), "Sort Column A → Z")
        XCTAssertEqual(model(h)?.rows.map { $0[0] }, ["n", "2", "10", "a", "b"])
        choose(grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false), "Clear Row")
        XCTAssertEqual(model(h)?.rows[1], [""])
    }

    func testDeleteTableMenuRemovesItFromTheDocument() {
        let h = harness()
        choose(grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false), "Delete Table")
        XCTAssertFalse(h.textView.string.contains("apple"))
        XCTAssertTrue(h.textView.string.contains("After the table."))
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 0)
        tick()
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 1, "undo brings the table back")
    }

    func testFormatMenuCommandsReachTheFocusedGrid() {
        let h = harness()
        grid(h).focus(.init(row: 1, column: 1))
        grid(h).dwTableCommand(TableCommandBox(.insertColumnLeft))
        XCTAssertEqual(model(h)?.columnCount, 3)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 1, column: 1))
    }

    // MARK: Grips

    func testDragDestinationMath() {
        XCTAssertEqual(TableGridView.destination(from: 1, gap: 3), 2, "dropped after row 2")
        XCTAssertEqual(TableGridView.destination(from: 2, gap: 1), 1)
        XCTAssertEqual(TableGridView.destination(from: 1, gap: 1), 1, "dropped where it was")
        XCTAssertEqual(TableGridView.destination(from: 1, gap: 2), 1)
        XCTAssertEqual(TableGridView.destination(from: 0, gap: 2), 1)
        XCTAssertEqual(TableGridView.destination(from: 2, gap: 0), 0)
    }

    func testMovingRowsAndColumnsWithTheGrips() {
        let h = harness()
        grid(h).commitMove(isRow: true, from: 1, to: 2)
        XCTAssertEqual(model(h)?.rows.map { $0[0] }, ["Name", "pear", "apple"])
        tick()
        grid(h).commitMove(isRow: false, from: 0, to: 1)
        XCTAssertEqual(model(h)?.rows[0], ["Qty", "Name"])
        XCTAssertEqual(model(h)?.alignments, [.right, .left])
        tick()
        h.textView.undoManager?.undo()
        XCTAssertEqual(model(h)?.rows[0], ["Name", "Qty"])
    }

    func testGripAndAddStripHitTargets() throws {
        let h = harness()
        let g = grid(h)
        let t = g.tableRect
        XCTAssertNotNil(g.hitTest(g.superview!.convert(NSPoint(x: t.maxX + 14, y: t.midY), from: g)), "add-column strip is clickable")
        XCTAssertNotNil(g.hitTest(g.superview!.convert(NSPoint(x: t.midX, y: t.maxY + 14), from: g)), "add-row strip is clickable")
        XCTAssertNotNil(g.hitTest(g.superview!.convert(NSPoint(x: t.minX - 12, y: t.minY + 20), from: g)), "row grip is clickable")
        XCTAssertNotNil(g.hitTest(g.superview!.convert(NSPoint(x: t.minX + 40, y: 8), from: g)), "column grip is clickable")
        XCTAssertNil(g.hitTest(g.superview!.convert(NSPoint(x: t.maxX + 60, y: t.midY), from: g)), "empty space lets clicks through to the text")
        let inCell = g.hitTest(g.superview!.convert(NSPoint(x: t.minX + 30, y: t.minY + 10), from: g))
        XCTAssertTrue(inCell != nil && inCell !== g && inCell!.isDescendant(of: g), "a click inside the table reaches a cell editor")
    }

    func testAddStripsAppendRowsAndColumns() {
        let h = harness()
        let g = grid(h)
        g.perform(.insertRowBelow, at: .init(row: g.model.rowCount - 1, column: 0))
        XCTAssertEqual(model(h)?.rowCount, 4)
        g.perform(.insertColumnRight, at: .init(row: 0, column: g.model.columnCount - 1))
        XCTAssertEqual(model(h)?.columnCount, 3)
    }

    // MARK: Focus hand-off

    func testCaretMovingIntoTheTableFocusesTheGrid() async {
        let h = harness()
        h.select(h.coordinator.analysis.tables[0].range.location)
        let ok = await waitUntil(timeout: 3) { self.grid(h).focusedPosition != nil }
        XCTAssertTrue(ok, "grid takes the focus")
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 0, column: 0))
        XCTAssertTrue(window(h).firstResponder === cell(h, 0, 0))
    }

    func testCaretAtTheEndOfTheTableFocusesTheLastCell() async {
        let h = harness()
        h.select(NSMaxRange(h.coordinator.analysis.tables[0].range))
        _ = await waitUntil(timeout: 3) { self.grid(h).focusedPosition != nil }
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 2, column: 1))
    }

    func testFindMatchInsideACellSelectsTheTextInThatCell() async {
        let h = harness()
        let r = (h.textView.string as NSString).range(of: "pear")
        h.textView.setSelectedRange(r)
        _ = await waitUntil(timeout: 3) { self.grid(h).focusedPosition != nil }
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 2, column: 0))
        XCTAssertEqual(cell(h, 2, 0).selectedRange(), NSRange(location: 0, length: 4))
    }

    func testSelectionAcrossTheTableOnlyTintsIt() async {
        let h = harness()
        h.select(0, h.textView.string.utf16.count)
        tick(0.1)
        XCTAssertNil(grid(h).focusedPosition)
        XCTAssertEqual(grid(h).highlighted.count, 6, "all six cells are tinted")
        h.select(0)
        tick(0.1)
        XCTAssertTrue(grid(h).highlighted.isEmpty)
    }

    func testInsertTableCommandFocusesTheNewGrid() async {
        let h = harness("Intro\n\n")
        h.select(h.textView.string.utf16.count)
        h.textView.dwApplyFormat(FormatCommandBox(.insertTable))
        let ok = await waitUntil(timeout: 3) { self.grid(h).focusedPosition != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 1)
        XCTAssertEqual(grid(h).model.columnCount, 3)
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 0, column: 0))
        XCTAssertEqual(cell(h, 0, 0).selectedRange(), NSRange(location: 0, length: 8), "“Column 1” is selected, ready to overwrite")
    }

    func testBackspaceBelowTheTableGoesIntoItInsteadOfMergingText() async {
        let h = harness()
        let belowBlank = NSMaxRange(h.coordinator.analysis.tables[0].range) + 1
        let before = h.textView.string
        h.select(belowBlank)
        h.textView.deleteBackward(nil)
        XCTAssertEqual(h.textView.string, before, "nothing was deleted")
        XCTAssertEqual(grid(h).focusedPosition, .init(row: 2, column: 1))
    }

    func testWordAndLineDeletesBelowTheTableAreAlsoGuarded() {
        let h = harness()
        let before = h.textView.string
        let belowBlank = NSMaxRange(h.coordinator.analysis.tables[0].range) + 1
        for command in [h.textView.deleteWordBackward, h.textView.deleteToBeginningOfLine, h.textView.deleteToBeginningOfParagraph] {
            h.window.makeFirstResponder(h.textView)
            h.select(belowBlank)
            command(nil)
            XCTAssertEqual(h.textView.string, before)
        }
        h.window.makeFirstResponder(h.textView)
        h.select(h.coordinator.analysis.tables[0].range.location - 1)
        h.textView.deleteForward(nil)
        XCTAssertEqual(h.textView.string, before, "forward delete at the end of the line above stays out of the table too")
    }

    // MARK: Markdown source

    func testEditAsMarkdownShowsTheSourceUntilTheCaretLeaves() async {
        let h = harness()
        choose(grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false), "Edit as Markdown")
        XCTAssertTrue(grid(h).isHidden)
        XCTAssertNotNil(h.coordinator.sourceTableFirstLine)
        XCTAssertGreaterThan(usedRect(h, line: 4).height, 8, "source line is visible")
        XCTAssertTrue(window(h).firstResponder === h.textView)
        let sel = h.textView.selectedRange().location
        XCTAssertEqual(sel, h.index(of: "apple"), "caret lands in the cell that was chosen")
        tick(0.1)
        XCTAssertNil(grid(h).focusedPosition, "the grid does not steal the focus back")
        // Typing in the source still works and the grid follows.
        h.textView.insertText("green ", replacementRange: NSRange(location: sel, length: 0))
        XCTAssertEqual(model(h)?.rows[1][0], "green apple")
        h.select(h.index(of: "After the table."))
        XCTAssertNil(h.coordinator.sourceTableFirstLine, "caret left the table")
        XCTAssertFalse(grid(h).isHidden)
        XCTAssertLessThan(usedRect(h, line: 4).height, 2, "source is collapsed again")
        XCTAssertEqual(cell(h, 1, 0).string, "green apple")
    }

    func testClickingIntoAnotherTableEndsMarkdownSourceView() async {
        let h = harness("| a |\n| - |\n| 1 |\n\ntext\n\n| b |\n| - |\n| 2 |\n")
        h.coordinator.showTableSource(order: 0, at: .init(row: 1, column: 0))
        XCTAssertNotNil(h.coordinator.sourceTableFirstLine)
        XCTAssertTrue(grid(h, 0).isHidden)
        grid(h, 1).focus(.init(row: 1, column: 0))
        let ok = await waitUntil(timeout: 3) { h.coordinator.sourceTableFirstLine == nil }
        XCTAssertTrue(ok, "source view closes when another table takes the keyboard")
        XCTAssertFalse(grid(h, 0).isHidden)
    }

    func testTableCommandsWorkWhileMarkdownIsShowing() {
        let h = harness()
        choose(grid(h).makeMenu(at: .init(row: 1, column: 0), includeEditing: false), "Edit as Markdown")
        h.textView.dwTableCommand(TableCommandBox(.insertRowBelow))
        XCTAssertEqual(model(h)?.rowCount, 4)
    }

    // MARK: Documents

    func testMultipleTablesGetTheirOwnGrids() {
        let h = harness("| a |\n| - |\n| 1 |\n\ntext\n\n| b | c |\n| - | - |\n| 2 | 3 |\n")
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 2)
        grid(h, 1).focus(.init(row: 1, column: 1))
        cell(h, 1, 1, table: 1).insertText("x", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(model(h, table: 1)?.rows[1], ["2", "3x"])
        XCTAssertEqual(model(h, table: 0)?.rows[1], ["1"], "the other table is untouched")
        XCTAssertLessThan(grid(h, 0).frame.maxY, grid(h, 1).frame.minY + 1)
    }

    func testRemovingTheTableTextRemovesTheGrid() {
        let h = harness()
        h.coordinator.update(text: "just text\n", settings: EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720))
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 0)
    }

    func testGridFollowsThemeChanges() {
        let h = harness(dark: false)
        let light = h.coordinator.styler.palette
        h.window.appearance = NSAppearance(named: .darkAqua)
        h.coordinator.appearanceDidChange()
        XCTAssertNotEqual(h.coordinator.styler.palette, light)
        let color = cell(h, 1, 0).textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, h.coordinator.styler.palette.text.nsColor)
    }

    func testTableDocumentTextRoundTripsThroughTheEditorUntouched() {
        let h = harness()
        XCTAssertEqual(h.textView.string, TableGridTests.doc, "showing the grid never rewrites the document")
        grid(h).focus(.init(row: 1, column: 0))
        cell(h, 1, 0).insertTab(nil)
        XCTAssertEqual(h.textView.string, TableGridTests.doc, "navigating does not either")
    }

    private func window(_ h: EditorHarness) -> NSWindow { h.window }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private extension TableCellView {
    var alignmentForTest: NSTextAlignment? {
        (textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment
    }
}
