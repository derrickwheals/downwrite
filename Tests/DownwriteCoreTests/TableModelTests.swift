import XCTest
@testable import DownwriteCore

final class TableModelTests: XCTestCase {
    private func sub(_ s: String, _ r: NSRange) -> String { NSString(string: s).substring(with: r) }
    private let base = TableModel(rows: [["A", "B"], ["1", "2"], ["3", "4"]], alignments: [.none, .right])

    // MARK: Parsing

    func testParseRowsAlignmentsAndRanges() throws {
        let p = try XCTUnwrap(TableModel.parse(lines: ["| Name | Qty |", "| :--- | ---: |", "| apple | 3 |"]))
        XCTAssertEqual(p.model.rows, [["Name", "Qty"], ["apple", "3"]])
        XCTAssertEqual(p.model.alignments, [.left, .right])
        XCTAssertEqual(p.cellRanges[0], [2..<6, 9..<12])
        XCTAssertEqual(p.cellRanges[1], [2..<7, 10..<11])
    }

    func testParseWithoutOuterPipesAndWithIndent() throws {
        let m = try XCTUnwrap(TableModel(markdownLines: ["  a | b", " --|--", "1 | 2"]))
        XCTAssertEqual(m.rows, [["a", "b"], ["1", "2"]])
    }

    func testMissingCellsAreEmptyAndExtraCellsAreDropped() throws {
        let p = try XCTUnwrap(TableModel.parse(lines: ["| a | b |", "| - | - |", "| only |", "| x | y | z |"]))
        XCTAssertEqual(p.model.rows, [["a", "b"], ["only", ""], ["x", "y"]])
        XCTAssertEqual(p.cellRanges[1][1], 8..<8)
    }

    func testNotATableWithoutDelimiterRow() {
        XCTAssertNil(TableModel.parse(lines: ["| a | b |", "| 1 | 2 |"]))
        XCTAssertNil(TableModel.parse(lines: ["| a | b |"]))
    }

    func testEscapedPipesStayInTheCell() {
        XCTAssertEqual(TableModel.cells(of: "| a \\| b | c |"), ["a \\| b", "c"])
        XCTAssertEqual(TableModel.cells(of: "| a \\\\| b |"), ["a \\\\", "b"])   // escaped backslash, then a real pipe
    }

    func testPipesInCodeSpansSplitCellsLikeGFM() {
        XCTAssertEqual(TableModel.cells(of: "| `a|b` | c |"), ["`a", "b`", "c"])
        XCTAssertEqual(TableModel.cells(of: "| `a\\|b` | c |"), ["`a\\|b`", "c"])
    }

    func testModelAgreesWithCmarkAboutCells() throws {
        let text = "| h1 | h2 |\n| - | - |\n| `a|b` | c |\n| x \\| y | **z** |\n"
        let table = try XCTUnwrap(MarkdownAnalyzer.analyze(text).tables.first)
        let model = try XCTUnwrap(table.model)
        XCTAssertEqual(model.rows, [["h1", "h2"], ["`a", "b`"], ["x \\| y", "**z**"]])
    }

    // MARK: Cell text

    func testNormalizeEscapesPipesAndFlattensWhitespace() {
        XCTAssertEqual(TableModel.normalize("  a|b\nc\t "), "a\\|b c")
        XCTAssertEqual(TableModel.normalize("already \\| escaped"), "already \\| escaped")
        XCTAssertEqual(TableModel.escapePipes("a\\\\|b"), "a\\\\\\|b")
        for s in ["", " x ", "a|b|c", "tab\tsep", "multi\nline\r\ntext", "\\|", "a\\\\|b", "emoji 😀 | 名"] {
            let once = TableModel.normalize(s)
            XCTAssertEqual(TableModel.normalize(once), once, "idempotent for \(s.debugDescription)")
        }
    }

    func testAnyCellTextRoundTripsThroughMarkdown() throws {
        let texts = ["plain", "with | pipe", "a\\|b", "back\\", "`code | span`", "名 😀", "", "x\ty", "line1\nline2", "**b** and [l](http://x.y/a|b)"]
        var m = TableModel.blank(columns: 2, bodyRows: 1)
        for (i, t) in texts.enumerated() {
            m.setCell(t, at: TableCellPosition(row: 1, column: i % 2))
            let parsed = try XCTUnwrap(TableModel(markdownLines: m.markdownLines()), "text \(t.debugDescription)")
            XCTAssertEqual(parsed, m, "round trip for \(t.debugDescription)")
        }
    }

    // MARK: Serialising

    func testMarkdownIsAlignedAndParsesBack() throws {
        let m = TableModel(rows: [["Name", "Qty"], ["apple", "3"]], alignments: [.left, .right])
        XCTAssertEqual(m.markdownLines(), [
            "| Name  | Qty |",
            "| :---- | --: |",
            "| apple |   3 |",
        ])
        XCTAssertEqual(TableModel(markdownLines: m.markdownLines()), m)
    }

    func testBlankTable() {
        let m = TableModel.blank()
        XCTAssertEqual(m.rows, [["Column 1", "Column 2", "Column 3"], ["", "", ""]])
        XCTAssertEqual(m.markdownLines().count, 3)
    }

    func testHeaderOnlyTableSerialises() throws {
        let m = TableModel(rows: [["a", "b"]], alignments: [.none, .none])
        XCTAssertEqual(m.markdownLines(), ["| a   | b   |", "| --- | --- |"])
        XCTAssertNotNil(TableModel(markdownLines: m.markdownLines()))
    }

    // MARK: Commands

    func testInsertRows() throws {
        let below = try XCTUnwrap(base.applying(.insertRowBelow, at: .init(row: 1, column: 0)))
        XCTAssertEqual(below.model.rows, [["A", "B"], ["1", "2"], ["", ""], ["3", "4"]])
        XCTAssertEqual(below.focus, .init(row: 2, column: 0))
        let fromHeader = try XCTUnwrap(base.applying(.insertRowBelow, at: .init(row: 0, column: 1)))
        XCTAssertEqual(fromHeader.model.rows[1], ["", ""])
        let above = try XCTUnwrap(base.applying(.insertRowAbove, at: .init(row: 1, column: 1)))
        XCTAssertEqual(above.model.rows, [["A", "B"], ["", ""], ["1", "2"], ["3", "4"]])
        XCTAssertEqual(above.focus, .init(row: 1, column: 1))
        XCTAssertNil(base.applying(.insertRowAbove, at: .init(row: 0, column: 0)), "nothing can go above the header")
    }

    func testDeleteRow() throws {
        let r = try XCTUnwrap(base.applying(.deleteRow, at: .init(row: 2, column: 1)))
        XCTAssertEqual(r.model.rows, [["A", "B"], ["1", "2"]])
        XCTAssertEqual(r.focus, .init(row: 1, column: 1))
        XCTAssertNil(base.applying(.deleteRow, at: .init(row: 0, column: 0)), "the header row stays")
        let onlyHeader = try XCTUnwrap(r.model.applying(.deleteRow, at: .init(row: 1, column: 0)))
        XCTAssertEqual(onlyHeader.model.rowCount, 1)
    }

    func testInsertColumns() throws {
        let left = try XCTUnwrap(base.applying(.insertColumnLeft, at: .init(row: 1, column: 1)))
        XCTAssertEqual(left.model.rows, [["A", "", "B"], ["1", "", "2"], ["3", "", "4"]])
        XCTAssertEqual(left.model.alignments, [.none, .none, .right])
        XCTAssertEqual(left.focus, .init(row: 1, column: 1))
        let right = try XCTUnwrap(base.applying(.insertColumnRight, at: .init(row: 0, column: 1)))
        XCTAssertEqual(right.model.rows[0], ["A", "B", ""])
        XCTAssertEqual(right.focus, .init(row: 0, column: 2))
    }

    func testDeleteColumnKeepsAtLeastOne() throws {
        let r = try XCTUnwrap(base.applying(.deleteColumn, at: .init(row: 1, column: 1)))
        XCTAssertEqual(r.model.rows, [["A"], ["1"], ["3"]])
        XCTAssertEqual(r.model.alignments, [.none])
        XCTAssertEqual(r.focus, .init(row: 1, column: 0))
        XCTAssertNil(r.model.applying(.deleteColumn, at: .init(row: 0, column: 0)))
    }

    func testMoveRowsAndColumns() throws {
        let up = try XCTUnwrap(base.applying(.moveRowUp, at: .init(row: 2, column: 1)))
        XCTAssertEqual(up.model.rows, [["A", "B"], ["3", "4"], ["1", "2"]])
        XCTAssertEqual(up.focus, .init(row: 1, column: 1))
        XCTAssertNil(base.applying(.moveRowUp, at: .init(row: 1, column: 0)), "cannot move above the header")
        XCTAssertNil(base.applying(.moveRowUp, at: .init(row: 0, column: 0)))
        let down = try XCTUnwrap(base.applying(.moveRowDown, at: .init(row: 1, column: 0)))
        XCTAssertEqual(down.model.rows, [["A", "B"], ["3", "4"], ["1", "2"]])
        XCTAssertEqual(down.focus, .init(row: 2, column: 0))
        XCTAssertNil(base.applying(.moveRowDown, at: .init(row: 2, column: 0)))
        XCTAssertNil(base.applying(.moveRowDown, at: .init(row: 0, column: 0)), "the header does not move")

        let left = try XCTUnwrap(base.applying(.moveColumnLeft, at: .init(row: 0, column: 1)))
        XCTAssertEqual(left.model.rows, [["B", "A"], ["2", "1"], ["4", "3"]])
        XCTAssertEqual(left.model.alignments, [.right, .none], "alignment travels with its column")
        XCTAssertEqual(left.focus, .init(row: 0, column: 0))
        XCTAssertNil(base.applying(.moveColumnLeft, at: .init(row: 0, column: 0)))
        let right = try XCTUnwrap(base.applying(.moveColumnRight, at: .init(row: 2, column: 0)))
        XCTAssertEqual(right.model.rows[2], ["4", "3"])
        XCTAssertNil(base.applying(.moveColumnRight, at: .init(row: 0, column: 1)))
    }

    func testDuplicateClearAndAlign() throws {
        let dupRow = try XCTUnwrap(base.applying(.duplicateRow, at: .init(row: 1, column: 0)))
        XCTAssertEqual(dupRow.model.rows, [["A", "B"], ["1", "2"], ["1", "2"], ["3", "4"]])
        XCTAssertEqual(dupRow.focus, .init(row: 2, column: 0))
        XCTAssertNil(base.applying(.duplicateRow, at: .init(row: 0, column: 0)))
        let dupCol = try XCTUnwrap(base.applying(.duplicateColumn, at: .init(row: 0, column: 1)))
        XCTAssertEqual(dupCol.model.rows[0], ["A", "B", "B"])
        XCTAssertEqual(dupCol.model.alignments, [.none, .right, .right])
        let clearRow = try XCTUnwrap(base.applying(.clearRow, at: .init(row: 1, column: 0)))
        XCTAssertEqual(clearRow.model.rows[1], ["", ""])
        let clearCol = try XCTUnwrap(base.applying(.clearColumn, at: .init(row: 0, column: 0)))
        XCTAssertEqual(clearCol.model.rows.map { $0[0] }, ["", "", ""])
        let center = try XCTUnwrap(base.applying(.align(.center), at: .init(row: 2, column: 0)))
        XCTAssertEqual(center.model.alignments, [.center, .right])
        XCTAssertNil(base.applying(.editAsMarkdown, at: .init(row: 0, column: 0)))
        XCTAssertNil(base.applying(.insertRowBelow, at: .init(row: 9, column: 0)), "out-of-range cell")
    }

    func testSortBodyRowsNumbersTextAndEmpties() throws {
        let m = TableModel(rows: [["h"], ["b"], ["10"], ["2"], [""], ["a"]], alignments: [.none])
        let asc = try XCTUnwrap(m.applying(.sortAscending, at: .init(row: 0, column: 0)))
        XCTAssertEqual(asc.model.rows.map { $0[0] }, ["h", "2", "10", "a", "b", ""])
        let desc = try XCTUnwrap(m.applying(.sortDescending, at: .init(row: 0, column: 0)))
        XCTAssertEqual(desc.model.rows.map { $0[0] }, ["h", "b", "a", "10", "2", ""])
        XCTAssertNil(TableModel(rows: [["h"], ["x"]], alignments: [.none]).applying(.sortAscending, at: .init(row: 0, column: 0)))
    }

    func testSortIsStableAndKeepsRowsTogether() throws {
        let m = TableModel(rows: [["k", "v"], ["b", "1"], ["a", "2"], ["b", "3"]], alignments: [.none, .none])
        let s = try XCTUnwrap(m.applying(.sortAscending, at: .init(row: 0, column: 0)))
        XCTAssertEqual(s.model.rows, [["k", "v"], ["a", "2"], ["b", "1"], ["b", "3"]])
    }

    // MARK: Tab, Return, navigation

    func testTabWalksCellsAndAppendsRowAtTheEnd() throws {
        let a = try XCTUnwrap(base.tab(from: .init(row: 0, column: 0), backwards: false))
        XCTAssertEqual(a.focus, .init(row: 0, column: 1))
        XCTAssertEqual(a.model, base)
        let wrap = try XCTUnwrap(base.tab(from: .init(row: 0, column: 1), backwards: false))
        XCTAssertEqual(wrap.focus, .init(row: 1, column: 0))
        let end = try XCTUnwrap(base.tab(from: .init(row: 2, column: 1), backwards: false))
        XCTAssertEqual(end.model.rows.last, ["", ""])
        XCTAssertEqual(end.model.rowCount, 4)
        XCTAssertEqual(end.focus, .init(row: 3, column: 0))
        XCTAssertNil(base.tab(from: .init(row: 0, column: 0), backwards: true))
        XCTAssertEqual(base.tab(from: .init(row: 1, column: 0), backwards: true)?.focus, .init(row: 0, column: 1))
    }

    func testReturnMovesDownAndAppendsOnTheLastRow() throws {
        XCTAssertEqual(base.returnKey(from: .init(row: 1, column: 1))?.focus, .init(row: 2, column: 1))
        let end = try XCTUnwrap(base.returnKey(from: .init(row: 2, column: 1)))
        XCTAssertEqual(end.model.rowCount, 4)
        XCTAssertEqual(end.focus, .init(row: 3, column: 1))
    }

    func testNextAndPreviousCell() {
        XCTAssertEqual(base.nextCell(after: .init(row: 0, column: 1)), .init(row: 1, column: 0))
        XCTAssertNil(base.nextCell(after: .init(row: 2, column: 1)))
        XCTAssertEqual(base.previousCell(before: .init(row: 1, column: 0)), .init(row: 0, column: 1))
        XCTAssertNil(base.previousCell(before: .init(row: 0, column: 0)))
    }

    // MARK: Paste

    func testPasteGrowsTheTable() {
        var m = base
        let end = m.paste([["x", "y", "z"], ["p", "q"]], at: .init(row: 2, column: 1))
        XCTAssertEqual(m.columnCount, 4)
        XCTAssertEqual(m.rows[2], ["3", "x", "y", "z"])
        XCTAssertEqual(m.rows[3], ["", "p", "q", ""])
        XCTAssertEqual(m.alignments.count, 4)
        XCTAssertEqual(end, .init(row: 3, column: 3))
    }

    func testPastedGridDetection() {
        XCTAssertEqual(TableModel.pastedGrid(from: "a\tb\r\nc\td\r\n"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(TableModel.pastedGrid(from: "| a | b |\n| - | - |\n| 1 | 2 |"), [["a", "b"], ["1", "2"]])
        XCTAssertNil(TableModel.pastedGrid(from: "just some text"))
        XCTAssertNil(TableModel.pastedGrid(from: "two\nlines"))
        XCTAssertNil(TableModel.pastedGrid(from: ""))
    }

    // MARK: Layout

    func testColumnWidths() {
        XCTAssertEqual(TableLayout.columnWidths(natural: [100, 80], available: 400, minimum: 50), [100, 80])
        XCTAssertEqual(TableLayout.columnWidths(natural: [10, 80], available: 400, minimum: 50), [50, 80])
        XCTAssertEqual(TableLayout.columnWidths(natural: [100, 500, 100], available: 400, minimum: 50), [100, 200, 100])
        XCTAssertEqual(TableLayout.columnWidths(natural: [500, 500], available: 400, minimum: 50), [200, 200])
        XCTAssertEqual(TableLayout.columnWidths(natural: [100, 100, 100], available: 120, minimum: 50), [50, 50, 50])
        XCTAssertEqual(TableLayout.columnWidths(natural: [], available: 100, minimum: 50), [])
        let w = TableLayout.columnWidths(natural: [300, 120, 900, 60], available: 500, minimum: 40)
        XCTAssertEqual(w.reduce(0, +), 500, accuracy: 0.001)
        XCTAssertTrue(w[3] == 60 && w[1] == 120, "short columns keep their natural width: \(w)")
    }

    // MARK: Analyzer integration

    func testAnalyzerExposesModelAndCellRanges() throws {
        let s = "intro\n\n| 名 | **b** |\n| :-: | --- |\n| 😀 | x\\|y |\n\nafter\n"
        let a = MarkdownAnalyzer.analyze(s)
        let t = try XCTUnwrap(a.tables.first)
        let m = try XCTUnwrap(t.model)
        XCTAssertTrue(t.isGrid)
        XCTAssertEqual(m.rows, [["名", "**b**"], ["😀", "x\\|y"]])
        XCTAssertEqual(m.alignments, [.center, .none])
        for r in 0..<m.rowCount {
            for c in 0..<m.columnCount {
                XCTAssertEqual(sub(s, t.cellRanges[r][c]), m.rows[r][c], "cell \(r),\(c)")
            }
        }
        XCTAssertEqual(t.line(forRow: 0), 2)
        XCTAssertEqual(t.line(forRow: 1), 4)
        XCTAssertEqual(a.gridTableIndex(containing: t.range.location), 0)
        XCTAssertEqual(a.gridTableIndex(containing: NSMaxRange(t.range)), 0)
        XCTAssertNil(a.gridTableIndex(containing: 1))
    }

    func testQuotedAndListedTablesStayRawSource() {
        let quoted = MarkdownAnalyzer.analyze("> | a | b |\n> | - | - |\n> | 1 | 2 |\n")
        XCTAssertTrue(quoted.tables.allSatisfy { !$0.isGrid })
        let listed = MarkdownAnalyzer.analyze("- item\n\n  | a | b |\n  | - | - |\n  | 1 | 2 |\n")
        XCTAssertTrue(listed.tables.allSatisfy { !$0.isGrid })
    }

    func testNearestCellAndLocalOffset() throws {
        let s = "| ab | cd |\n| -- | -- |\n| ef | gh |\n"
        let t = try XCTUnwrap(MarkdownAnalyzer.analyze(s).tables.first)
        let inFirst = try XCTUnwrap(t.cell(nearest: 3))
        XCTAssertEqual(inFirst.position, .init(row: 0, column: 0))
        XCTAssertEqual(inFirst.local, 1)
        let inLast = try XCTUnwrap(t.cell(nearest: NSMaxRange(t.range)))
        XCTAssertEqual(inLast.position, .init(row: 1, column: 1))
        XCTAssertEqual(inLast.local, 2)
        let atPipe = try XCTUnwrap(t.cell(nearest: 6))     // the pipe between the header cells
        XCTAssertEqual(atPipe.position.row, 0)
    }

    func testCollapsibleExtentCoversGridTablesAndPreviews() {
        let s = "text\n\n| a |\n| - |\n| 1 |\n\n```mermaid\ngraph TD\n A-->B\n```\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.collapsibleExtent(containingLine: 3)?.first, 2)
        XCTAssertEqual(a.collapsibleExtent(containingLine: 4)?.last, 4)
        XCTAssertEqual(a.collapsibleExtent(containingLine: 8)?.first, 6)
        XCTAssertNil(a.collapsibleExtent(containingLine: 0))
    }

    func testPreviewBlocksDoNotIncludeTables() {
        let a = MarkdownAnalyzer.analyze("| a |\n| - |\n| 1 |\n")
        XCTAssertTrue(a.previewBlocks.isEmpty)
    }

    // MARK: Cell analysis

    func testCellAnalysisHidesAndRevealsInlineMarkers() {
        let text = "a **bold** and `c|d`"
        let a = MarkdownAnalyzer.analyzeTableCell(text)
        XCTAssertEqual(a.length, text.utf16.count)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.bold) && $0.range == NSRange(location: 2, length: 8) })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.code) })
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: 0, length: 0)).count, 4)
        XCTAssertEqual(a.hiddenMarkerIndices(selection: NSRange(location: 6, length: 0)).count, 2, "caret inside the bold pair reveals it")
    }

    func testCellAnalysisIgnoresBlockSyntaxAndBarePipes() {
        let a = MarkdownAnalyzer.analyzeTableCell("# not | a heading")
        XCTAssertTrue(a.markers.isEmpty)
        XCTAssertEqual(a.lines[0].kind, .body)
        XCTAssertTrue(MarkdownAnalyzer.analyzeTableCell("- x").spans.allSatisfy { !$0.flags.contains(.listMarker) })
        XCTAssertEqual(MarkdownAnalyzer.analyzeTableCell("").length, 0)
    }

    func testCellAnalysisOffsetsAreUTF16() {
        let a = MarkdownAnalyzer.analyzeTableCell("名😀 *x* [l](https://x.y)")
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.italic) && $0.range == NSRange(location: 4, length: 3) }, "\(a.spans)")
        XCTAssertEqual(a.links.first?.destination, "https://x.y")
        XCTAssertEqual(a.links.first?.range.location, 8)
    }

    // MARK: Leaving and removing tables

    func testExitAfterAddsTheBlankLineATableNeeds() throws {
        let table = "| a |\n| - |\n| 1 |"
        func edit(_ text: String) throws -> TextEdit {
            let t = try XCTUnwrap(MarkdownAnalyzer.analyze(text).tables.first)
            return TableEditing.exitAfter(in: text, table: t)
        }
        let n = table.utf16.count
        let endOfDoc = try edit(table)
        XCTAssertEqual(endOfDoc.apply(to: table), table + "\n\n")
        XCTAssertEqual(endOfDoc.selection, NSRange(location: n + 2, length: 0))
        let newline = try edit(table + "\n")
        XCTAssertEqual(newline.apply(to: table + "\n"), table + "\n\n")
        XCTAssertEqual(newline.selection, NSRange(location: n + 2, length: 0))
        let blank = try edit(table + "\n\nNext\n")
        XCTAssertEqual(blank.replacement, "")
        XCTAssertEqual(blank.selection, NSRange(location: n + 2, length: 0), "lands at the start of the next paragraph")
        let tight = try edit(table + "\n# Heading\n")
        XCTAssertEqual(tight.replacement, "")
        XCTAssertEqual(tight.selection.location, n + 1)
    }

    func testExitBefore() throws {
        let s = "intro\n\n| a |\n| - |\n| 1 |\n"
        let t = try XCTUnwrap(MarkdownAnalyzer.analyze(s).tables.first)
        let e = TableEditing.exitBefore(in: s, table: t)
        XCTAssertEqual(e.replacement, "")
        XCTAssertEqual(e.selection, NSRange(location: 6, length: 0), "the blank line above the table")
        let top = "| a |\n| - |\n| 1 |\n"
        let tt = try XCTUnwrap(MarkdownAnalyzer.analyze(top).tables.first)
        let ee = TableEditing.exitBefore(in: top, table: tt)
        XCTAssertEqual(ee.apply(to: top), "\n\n" + top)
        XCTAssertEqual(ee.selection, NSRange(location: 0, length: 0))
    }

    func testDeleteTable() throws {
        func run(_ s: String) throws -> String {
            let t = try XCTUnwrap(MarkdownAnalyzer.analyze(s).tables.first)
            return TableEditing.deleteTable(in: s, table: t).apply(to: s)
        }
        XCTAssertEqual(try run("A\n\n| a |\n| - |\n| 1 |\n\nB\n"), "A\n\nB\n")
        XCTAssertEqual(try run("A\n\n| a |\n| - |\n| 1 |\n"), "A\n\n")
        XCTAssertEqual(try run("| a |\n| - |\n| 1 |\n\nB\n"), "\nB\n")
        XCTAssertEqual(try run("| a |\n| - |\n| 1 |"), "")
    }

    func testReplaceTableWritesModelMarkdown() throws {
        let s = "x\n\n|a|b|\n|-|-|\n|1|2|\n\ny\n"
        let t = try XCTUnwrap(MarkdownAnalyzer.analyze(s).tables.first)
        var m = try XCTUnwrap(t.model)
        m.setCell("changed", at: .init(row: 1, column: 0))
        let out = TableEditing.replace(table: t, with: m).apply(to: s)
        XCTAssertEqual(out, "x\n\n| a       | b   |\n| ------- | --- |\n| changed | 2   |\n\ny\n")
        XCTAssertEqual(MarkdownAnalyzer.analyze(out).tables.first?.model?.rows[1], ["changed", "2"])
    }
}
