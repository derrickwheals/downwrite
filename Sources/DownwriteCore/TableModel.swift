import Foundation

/// A cell address inside a table. Row 0 is the header row.
public struct TableCellPosition: Hashable, Sendable {
    public var row: Int
    public var column: Int
    public init(row: Int, column: Int) { self.row = row; self.column = column }
}

/// Everything the grid editor can do to a table that is expressible on the model alone.
public enum TableCommand: Equatable, Sendable {
    case insertRowAbove, insertRowBelow
    case insertColumnLeft, insertColumnRight
    case deleteRow, deleteColumn
    case moveRowUp, moveRowDown
    case moveColumnLeft, moveColumnRight
    case duplicateRow, duplicateColumn
    case clearRow, clearColumn
    case align(TableModel.Alignment)
    case sortAscending, sortDescending
    /// Not a model change: handled by the editor (swap grid for Markdown source / remove the whole table).
    case editAsMarkdown, deleteTable
}

/// The content of a GitHub-flavoured Markdown table, independent of how it is laid out in the source.
///
/// Cells hold *source text* — inline Markdown exactly as it appears between the pipes, with `\|` escapes intact — so
/// that editing a table never rewrites anything the user did not touch. Cells never contain line breaks or bare pipes
/// (`normalize` enforces both) which is what lets `markdownLines()` always produce a table cmark parses back to the
/// same cells.
public struct TableModel: Equatable, Sendable {
    public enum Alignment: String, Sendable { case none, left, center, right }

    /// `rows[0]` is the header row; every row has exactly `columnCount` cells.
    public private(set) var rows: [[String]]
    public private(set) var alignments: [Alignment]

    public var columnCount: Int { alignments.count }
    public var rowCount: Int { rows.count }

    public init(rows: [[String]], alignments: [Alignment]) {
        var cols = alignments.count
        if cols == 0 { cols = max(1, rows.first?.count ?? 1) }
        var normalized = rows.map { row in
            (0..<cols).map { $0 < row.count ? Self.normalize(row[$0]) : "" }
        }
        if normalized.isEmpty { normalized = [[String](repeating: "", count: cols)] }
        self.rows = normalized
        self.alignments = (0..<cols).map { $0 < alignments.count ? alignments[$0] : .none }
    }

    /// A fresh table: header + `bodyRows` empty rows.
    public static func blank(columns: Int = 3, bodyRows: Int = 1) -> TableModel {
        let cols = max(1, columns)
        var rows = [(1...cols).map { "Column \($0)" }]
        for _ in 0..<max(0, bodyRows) { rows.append([String](repeating: "", count: cols)) }
        return TableModel(rows: rows, alignments: [Alignment](repeating: .none, count: cols))
    }

    public func cell(_ row: Int, _ column: Int) -> String {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
        return rows[row][column]
    }

    public func contains(_ p: TableCellPosition) -> Bool {
        rows.indices.contains(p.row) && p.column >= 0 && p.column < columnCount
    }

    // MARK: Cell text

    /// Turns whatever a person typed or pasted into valid single-line cell source: line breaks and tabs become spaces,
    /// outer whitespace goes, and bare `|` is escaped. Idempotent.
    public static func normalize(_ text: String) -> String {
        var s = text
        for ws in ["\r\n", "\n", "\r", "\u{2028}", "\u{2029}", "\t"] where s.contains(ws) {
            s = s.replacingOccurrences(of: ws, with: " ")
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return escapePipes(s)
    }

    /// Escapes every `|` that is not already escaped. A backslash escapes the character after it, so `\\|` is an
    /// escaped backslash followed by a (bare) pipe.
    public static func escapePipes(_ s: String) -> String {
        let units = Array(s.utf16)
        guard units.contains(124) else { return s }
        var out: [UInt16] = []
        out.reserveCapacity(units.count + 4)
        var i = 0
        while i < units.count {
            let u = units[i]
            if u == 92, i + 1 < units.count {
                out.append(u); out.append(units[i + 1]); i += 2
            } else if u == 124 {
                out.append(92); out.append(124); i += 1
            } else {
                out.append(u); i += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: Parsing

    /// Splits one table row into cells. `content` ranges are UTF-16 offsets into `line`, trimmed of spaces and tabs.
    /// Escapes follow cmark-gfm: a backslash escapes the next character, and code spans do *not* shield pipes.
    static func cellSlices(of line: [UInt16]) -> [Range<Int>] {
        let n = line.count
        func isBlank(_ u: UInt16) -> Bool { u == 32 || u == 9 }
        var i = 0
        while i < n, isBlank(line[i]) { i += 1 }
        if i < n, line[i] == 124 { i += 1 }
        var slices: [Range<Int>] = []
        var start = i
        func trimmed(_ a: Int, _ b: Int) -> Range<Int> {
            var lo = a, hi = b
            while lo < hi, isBlank(line[lo]) { lo += 1 }
            while hi > lo, isBlank(line[hi - 1]) { hi -= 1 }
            return lo..<hi
        }
        var j = i
        while j < n {
            if line[j] == 92, j + 1 < n { j += 2; continue }
            if line[j] == 124 {
                slices.append(trimmed(start, j))
                start = j + 1
            }
            j += 1
        }
        let rest = trimmed(start, n)
        if !rest.isEmpty || slices.isEmpty { slices.append(rest) }
        return slices
    }

    static func cells(of line: String) -> [String] {
        let units = Array(line.utf16)
        return cellSlices(of: units).map { String(decoding: units[$0], as: UTF16.self) }
    }

    static func isDelimiterRow(_ line: String) -> Bool {
        let c = cells(of: line)
        guard !c.isEmpty else { return false }
        return c.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
    }

    static func alignment(ofDelimiter cell: String) -> Alignment {
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        default: return .none
        }
    }

    /// A parsed table plus where each cell sits in its source line.
    public struct Parsed: Equatable, Sendable {
        public var model: TableModel
        /// `cellRanges[row][column]`: UTF-16 range *within that row's source line* (row 0 = header; the delimiter
        /// line is skipped). Missing cells get an empty range at the end of the line's content.
        public var cellRanges: [[Range<Int>]]
    }

    /// Parses header, delimiter and body lines (no line terminators). Returns nil when the second line is not a delimiter row.
    public static func parse(lines: [String]) -> Parsed? {
        guard lines.count >= 2, isDelimiterRow(lines[1]) else { return nil }
        let units = lines.map { Array($0.utf16) }
        let delimiter = cells(of: lines[1])
        let headerSlices = cellSlices(of: units[0])
        let columns = max(headerSlices.count, delimiter.count)
        let aligns = (0..<columns).map { $0 < delimiter.count ? alignment(ofDelimiter: delimiter[$0]) : Alignment.none }

        var rows: [[String]] = []
        var ranges: [[Range<Int>]] = []
        for (index, line) in units.enumerated() where index != 1 {
            let slices = cellSlices(of: line)
            var end = line.count
            while end > 0, line[end - 1] == 32 || line[end - 1] == 9 { end -= 1 }
            var row: [String] = [], rowRanges: [Range<Int>] = []
            for c in 0..<columns {
                if c < slices.count {
                    row.append(String(decoding: line[slices[c]], as: UTF16.self))
                    rowRanges.append(slices[c])
                } else {
                    row.append("")
                    rowRanges.append(end..<end)
                }
            }
            rows.append(row)
            ranges.append(rowRanges)
        }
        return Parsed(model: TableModel(rows: rows, alignments: aligns), cellRanges: ranges)
    }

    public init?(markdownLines lines: [String]) {
        guard let p = Self.parse(lines: lines) else { return nil }
        self = p.model
    }

    // MARK: Serialising

    /// Column-aligned Markdown lines (header, delimiter, body…).
    public func markdownLines() -> [String] {
        let cols = columnCount
        var widths = [Int](repeating: 3, count: cols)
        for row in rows { for (c, cell) in row.enumerated() { widths[c] = max(widths[c], TableFormatter.width(cell)) } }
        func pad(_ s: String, _ w: Int, _ a: Alignment) -> String {
            let gap = max(0, w - TableFormatter.width(s))
            switch a {
            case .right: return String(repeating: " ", count: gap) + s
            case .center:
                let l = gap / 2
                return String(repeating: " ", count: l) + s + String(repeating: " ", count: gap - l)
            default: return s + String(repeating: " ", count: gap)
            }
        }
        func line(_ parts: [String]) -> String { "| " + parts.joined(separator: " | ") + " |" }
        var out: [String] = [line((0..<cols).map { pad(rows[0][$0], widths[$0], alignments[$0]) })]
        out.append(line((0..<cols).map { c in
            let w = widths[c]
            switch alignments[c] {
            case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
            case .left: return ":" + String(repeating: "-", count: w - 1)
            case .right: return String(repeating: "-", count: w - 1) + ":"
            case .none: return String(repeating: "-", count: w)
            }
        }))
        for r in 1..<max(1, rows.count) { out.append(line((0..<cols).map { pad(rows[r][$0], widths[$0], alignments[$0]) })) }
        return out
    }

    public var markdown: String { markdownLines().joined(separator: "\n") }

    // MARK: Editing

    public mutating func setCell(_ text: String, at p: TableCellPosition) {
        guard contains(p) else { return }
        rows[p.row][p.column] = Self.normalize(text)
    }

    private var emptyRow: [String] { [String](repeating: "", count: columnCount) }

    /// Inserts an empty body row so that it ends up at index `row` (1…rowCount).
    @discardableResult
    public mutating func insertRow(at row: Int) -> Bool {
        guard row >= 1, row <= rows.count else { return false }
        rows.insert(emptyRow, at: row)
        return true
    }

    @discardableResult
    public mutating func removeRow(at row: Int) -> Bool {
        guard row >= 1, row < rows.count else { return false }
        rows.remove(at: row)
        return true
    }

    @discardableResult
    public mutating func duplicateRow(at row: Int) -> Bool {
        guard row >= 1, row < rows.count else { return false }
        rows.insert(rows[row], at: row + 1)
        return true
    }

    /// Moves a body row so that it ends up at index `to`.
    @discardableResult
    public mutating func moveRow(from: Int, to: Int) -> Bool {
        guard from >= 1, from < rows.count, to >= 1, to < rows.count else { return false }
        guard from != to else { return true }
        rows.insert(rows.remove(at: from), at: to)
        return true
    }

    @discardableResult
    public mutating func insertColumn(at column: Int) -> Bool {
        guard column >= 0, column <= columnCount else { return false }
        for r in rows.indices { rows[r].insert("", at: column) }
        alignments.insert(.none, at: column)
        return true
    }

    @discardableResult
    public mutating func removeColumn(at column: Int) -> Bool {
        guard columnCount > 1, column >= 0, column < columnCount else { return false }
        for r in rows.indices { rows[r].remove(at: column) }
        alignments.remove(at: column)
        return true
    }

    @discardableResult
    public mutating func duplicateColumn(at column: Int) -> Bool {
        guard column >= 0, column < columnCount else { return false }
        for r in rows.indices { rows[r].insert(rows[r][column], at: column + 1) }
        alignments.insert(alignments[column], at: column + 1)
        return true
    }

    @discardableResult
    public mutating func moveColumn(from: Int, to: Int) -> Bool {
        guard from >= 0, from < columnCount, to >= 0, to < columnCount else { return false }
        guard from != to else { return true }
        for r in rows.indices { rows[r].insert(rows[r].remove(at: from), at: to) }
        alignments.insert(alignments.remove(at: from), at: to)
        return true
    }

    @discardableResult
    public mutating func setAlignment(_ a: Alignment, column: Int) -> Bool {
        guard column >= 0, column < columnCount else { return false }
        alignments[column] = a
        return true
    }

    @discardableResult
    public mutating func clearRow(_ row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        rows[row] = emptyRow
        return true
    }

    @discardableResult
    public mutating func clearColumn(_ column: Int) -> Bool {
        guard column >= 0, column < columnCount else { return false }
        for r in rows.indices { rows[r][column] = "" }
        return true
    }

    /// Stable sort of the body rows by one column: numbers by value, text case-insensitively, empty cells last.
    @discardableResult
    public mutating func sortBody(by column: Int, ascending: Bool) -> Bool {
        guard column >= 0, column < columnCount, rows.count > 2 else { return false }
        let body = Array(rows.dropFirst()).enumerated().map { (offset: $0.offset, row: $0.element) }
        let sorted = body.sorted { a, b in
            let x = a.row[column], y = b.row[column]
            if x.isEmpty != y.isEmpty { return y.isEmpty }
            if x.isEmpty { return a.offset < b.offset }
            let order = x.compare(y, options: [.numeric, .caseInsensitive])
            if order == .orderedSame { return a.offset < b.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        rows = [rows[0]] + sorted.map(\.row)
        return true
    }

    /// Writes a block of values with its top-left corner at `origin`, growing the table when it does not fit.
    /// Returns the position of the last cell written.
    @discardableResult
    public mutating func paste(_ values: [[String]], at origin: TableCellPosition) -> TableCellPosition {
        guard contains(origin), !values.isEmpty else { return origin }
        let width = values.map(\.count).max() ?? 1
        while origin.column + width > columnCount { insertColumn(at: columnCount) }
        while origin.row + values.count > rows.count { insertRow(at: rows.count) }
        for (dr, row) in values.enumerated() {
            for (dc, text) in row.enumerated() { rows[origin.row + dr][origin.column + dc] = Self.normalize(text) }
        }
        return TableCellPosition(row: origin.row + values.count - 1, column: origin.column + max(0, width - 1))
    }

    // MARK: Navigation

    public func nextCell(after p: TableCellPosition) -> TableCellPosition? {
        if p.column + 1 < columnCount { return TableCellPosition(row: p.row, column: p.column + 1) }
        if p.row + 1 < rowCount { return TableCellPosition(row: p.row + 1, column: 0) }
        return nil
    }

    public func previousCell(before p: TableCellPosition) -> TableCellPosition? {
        if p.column > 0 { return TableCellPosition(row: p.row, column: p.column - 1) }
        if p.row > 0 { return TableCellPosition(row: p.row - 1, column: columnCount - 1) }
        return nil
    }

    /// Tab / ⇧Tab. Tab out of the very last cell appends a row and lands in its first cell.
    public func tab(from p: TableCellPosition, backwards: Bool) -> (model: TableModel, focus: TableCellPosition)? {
        guard contains(p) else { return nil }
        if backwards { return previousCell(before: p).map { (self, $0) } }
        if let next = nextCell(after: p) { return (self, next) }
        var m = self
        m.insertRow(at: rowCount)
        return (m, TableCellPosition(row: rowCount, column: 0))
    }

    /// Return: down one row in the same column; on the last row, append one.
    public func returnKey(from p: TableCellPosition) -> (model: TableModel, focus: TableCellPosition)? {
        guard contains(p) else { return nil }
        if p.row + 1 < rowCount { return (self, TableCellPosition(row: p.row + 1, column: p.column)) }
        var m = self
        m.insertRow(at: rowCount)
        return (m, TableCellPosition(row: rowCount, column: p.column))
    }

    // MARK: Commands

    /// Applies `command` as if invoked on the cell at `p`. Returns the edited table and where focus should go, or nil
    /// when the command does not apply (e.g. deleting the header row, moving the first column left).
    public func applying(_ command: TableCommand, at p: TableCellPosition) -> (model: TableModel, focus: TableCellPosition)? {
        guard contains(p) else { return nil }
        var m = self
        var focus = p
        switch command {
        case .insertRowAbove:
            guard m.insertRow(at: p.row) else { return nil }
        case .insertRowBelow:
            guard m.insertRow(at: p.row + 1) else { return nil }
            focus.row = p.row + 1
        case .insertColumnLeft:
            guard m.insertColumn(at: p.column) else { return nil }
        case .insertColumnRight:
            guard m.insertColumn(at: p.column + 1) else { return nil }
            focus.column = p.column + 1
        case .deleteRow:
            guard m.removeRow(at: p.row) else { return nil }
            focus.row = min(p.row, m.rowCount - 1)
        case .deleteColumn:
            guard m.removeColumn(at: p.column) else { return nil }
            focus.column = min(p.column, m.columnCount - 1)
        case .moveRowUp:
            guard p.row >= 2, m.moveRow(from: p.row, to: p.row - 1) else { return nil }
            focus.row = p.row - 1
        case .moveRowDown:
            guard m.moveRow(from: p.row, to: p.row + 1), p.row + 1 < rowCount else { return nil }
            focus.row = p.row + 1
        case .moveColumnLeft:
            guard p.column >= 1, m.moveColumn(from: p.column, to: p.column - 1) else { return nil }
            focus.column = p.column - 1
        case .moveColumnRight:
            guard p.column + 1 < columnCount, m.moveColumn(from: p.column, to: p.column + 1) else { return nil }
            focus.column = p.column + 1
        case .duplicateRow:
            guard m.duplicateRow(at: p.row) else { return nil }
            focus.row = p.row + 1
        case .duplicateColumn:
            guard m.duplicateColumn(at: p.column) else { return nil }
            focus.column = p.column + 1
        case .clearRow:
            guard m.clearRow(p.row) else { return nil }
        case .clearColumn:
            guard m.clearColumn(p.column) else { return nil }
        case .align(let a):
            guard m.setAlignment(a, column: p.column) else { return nil }
        case .sortAscending:
            guard m.sortBody(by: p.column, ascending: true) else { return nil }
        case .sortDescending:
            guard m.sortBody(by: p.column, ascending: false) else { return nil }
        case .editAsMarkdown, .deleteTable:
            return nil
        }
        return (m, focus)
    }

    /// Pasted text that should fill several cells: tab-separated values (spreadsheets) or a Markdown table.
    /// Plain text without tabs returns nil so it is pasted into the one cell as usual.
    public static func pastedGrid(from text: String) -> [[String]]? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var trimmed = lines
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count >= 2, let p = parse(lines: trimmed) { return p.model.rows }
        guard trimmed.contains(where: { $0.contains("\t") }) else { return nil }
        return trimmed.map { $0.components(separatedBy: "\t") }
    }
}

/// Column widths for a table that has to fit a given space.
public enum TableLayout {
    /// Gives every column its natural width when they all fit; otherwise columns narrower than their fair share keep
    /// their width and the rest split what remains (so long text wraps instead of squeezing short columns).
    public static func columnWidths(natural: [Double], available: Double, minimum: Double) -> [Double] {
        var widths = natural.map { max($0, minimum) }
        guard !widths.isEmpty, widths.reduce(0, +) > available else { return widths }
        var fixed = [Bool](repeating: false, count: widths.count)
        var remaining = available
        var changed = true
        while changed {
            changed = false
            let free = widths.indices.filter { !fixed[$0] }
            guard !free.isEmpty else { break }
            let share = remaining / Double(free.count)
            for i in free where widths[i] <= share {
                fixed[i] = true
                remaining -= widths[i]
                changed = true
            }
        }
        let free = widths.indices.filter { !fixed[$0] }
        if !free.isEmpty {
            let share = max(minimum, remaining / Double(free.count))
            for i in free { widths[i] = share }
        }
        return widths
    }
}
