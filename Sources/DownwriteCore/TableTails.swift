import Foundation
import Markdown

/// Where a table ends (DW-025). GFM ends a table only at a blank line or the start of another block, so text typed straight under the
/// last row becomes more rows. Downwrite ends it at the last line that is a row: that line and everything after it read as if a blank
/// line separated them from the table. This type holds the one rule; the analyzer and the export both apply it, so the editor and the
/// paper agree.
enum TableTails {
    private static let space: UInt16 = 32, tab: UInt16 = 9, quote: UInt16 = 62, pipe: UInt16 = 124, backslash: UInt16 = 92

    /// The offset of the first character of `u[from..<end]` that is not part of a container prefix: the leading run of spaces, tabs and `>`.
    static func contentStart(_ u: [UInt16], from: Int, end: Int) -> Int {
        var i = from
        while i < end, u[i] == space || u[i] == tab || u[i] == quote { i += 1 }
        return i
    }

    /// Whether a delimiter row starts with a pipe (after any container prefix). It decides how strict the rows under it must be.
    static func isPipeLed(_ u: [UInt16], from: Int, end: Int) -> Bool {
        let i = contentStart(u, from: from, end: end)
        return i < end && u[i] == pipe
    }

    /// Whether the line `u[from..<end]` (no terminator) is a row of a table under a delimiter row that is `pipeLed` or not.
    ///
    /// Under a pipe-led delimiter row a row starts with a pipe, as every table Downwrite writes does. A table whose delimiter row has no
    /// leading pipe (`a | b` / `- | -`) is written without outer pipes, so its rows are the lines with at least one pipe that is not
    /// escaped (a backslash escapes the next character, as in `TableModel.cellSlices`). Anything else is text.
    static func isRow(_ u: [UInt16], from: Int, end: Int, pipeLed: Bool) -> Bool {
        var i = contentStart(u, from: from, end: end)
        if pipeLed { return i < end && u[i] == pipe }
        while i < end {
            if u[i] == backslash { i += 2; continue }
            if u[i] == pipe { return true }
            i += 1
        }
        return false
    }

    static func isPipeLed(delimiter line: String) -> Bool {
        let u = Array(line.utf16)
        return isPipeLed(u, from: 0, end: u.count)
    }

    static func isRow(_ line: String, pipeLed: Bool) -> Bool {
        let u = Array(line.utf16)
        return isRow(u, from: 0, end: u.count, pipeLed: pipeLed)
    }

    /// How many of `lines` (a header, a delimiter row and what follows, none of them blank) belong to the table. Fewer than two lines
    /// are all kept: there is no delimiter row to judge by.
    static func tableLength(of lines: [String]) -> Int {
        guard lines.count >= 2 else { return lines.count }
        let pipeLed = isPipeLed(delimiter: lines[1])
        var n = 2
        while n < lines.count, isRow(lines[n], pipeLed: pipeLed) { n += 1 }
        return n
    }
}

// MARK: - Parsing

extension TableTails {
    /// A document parsed so that every table ends at its last row.
    struct Parsed {
        let document: Document
        /// The text that was parsed: the input with a blank line inserted before each line that is not a row of the table above it.
        let text: String
        /// The lines of `text` (0-based, ascending) that were inserted. Empty when no table has a tail, which is nearly always.
        let inserted: [Int]
        /// How many times the text was parsed (1 when nothing had to be inserted).
        let passes: Int

        func isInserted(_ parsedLine: Int) -> Bool {
            let i = firstIndex(notBelow: parsedLine)
            return i < inserted.count && inserted[i] == parsedLine
        }

        /// The line of the input that a line of `text` is. An inserted line has no counterpart: it answers with the input line that follows it.
        func originalLine(ofParsed parsedLine: Int) -> Int { parsedLine - firstIndex(notBelow: parsedLine) }

        /// The number of inserted lines before `parsedLine`.
        private func firstIndex(notBelow parsedLine: Int) -> Int {
            var lo = 0, hi = inserted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if inserted[mid] < parsedLine { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    /// The most times a text is parsed. Tables stacked without a blank line between them are swallowed whole by cmark, so each pass
    /// can only show the next one's tail (a chain of N costs N parses of the whole text); no real document comes near this, and
    /// past it the rest of such a chain keeps GFM's reading rather than costing every keystroke more.
    static let maxPasses = 16

    /// Parses `text` as cmark does and, for every table whose last lines are not rows (see `isRow`), parses it again with a blank line
    /// before each such line, as if one had been typed there: cmark then ends the table and reads what follows as ordinary blocks (a
    /// paragraph, a setext heading over `---`, a second table headed by the last pipeless line). The inserted line carries the break
    /// line's own prefix of spaces, tabs and `>`, so inside a quote or a list item it stays in the container. A second parse can reveal
    /// another table with a tail (the one that now starts), so this repeats until no table has one; each pass adds at least one line, up to `maxPasses`.
    static func parse(_ text: String, options: ParseOptions = []) -> Parsed {
        var current = text
        var inserted: [Int] = []
        var document = Document(parsing: current, options: options)
        var passes = 1
        guard text.utf8.contains(124) else { return Parsed(document: document, text: current, inserted: inserted, passes: passes) }
        while true {
            var tables: [Table] = []
            collectTables(in: document, into: &tables)
            if tables.isEmpty { break }
            let source = SourceText(current)
            let known = Set(inserted)
            let breaks = Set(tables.compactMap { breakLine(of: $0, in: source) }).filter { !known.contains($0 - 1) }.sorted()
            if breaks.isEmpty || passes >= maxPasses { break }

            var units: [UInt16] = []
            units.reserveCapacity(source.units.count + 4 * breaks.count)
            var copied = 0
            for line in breaks {
                let start = source.lineStarts[line]
                units += source.units[copied..<start]
                let prefixEnd = contentStart(source.units, from: start, end: source.lineContentEnds[line])
                units += source.units[start..<prefixEnd]
                units.append(10)
                copied = start
            }
            units += source.units[copied...]
            current = String(decoding: units, as: UTF16.self)
            // Earlier insertions move down by the lines now inserted above them; the new ones sit at their break line plus those before it.
            inserted = (inserted.map { old in old + breaks.lazy.filter { $0 <= old }.count }
                        + breaks.enumerated().map { $0.element + $0.offset }).sorted()
            document = Document(parsing: current, options: options)
            passes += 1
        }
        return Parsed(document: document, text: current, inserted: inserted, passes: passes)
    }

    /// Every table in the block containers, at any depth. Paragraphs, headings, code and HTML hold none, so they are not entered.
    private static func collectTables(in node: Markup, into out: inout [Table]) {
        for child in node.children {
            switch child {
            case let table as Table: out.append(table)
            case is BlockQuote, is ListItem, is UnorderedList, is OrderedList: collectTables(in: child, into: &out)
            default: break
            }
        }
    }

    /// The first line (0-based) of `table`'s range, under its delimiter row, that is not a row, or nil when every line is.
    private static func breakLine(of table: Table, in source: SourceText) -> Int? {
        guard let range = table.range else { return nil }
        let first = range.lowerBound.line - 1
        let last = (range.upperBound.column == 1 && range.upperBound.line > range.lowerBound.line ? range.upperBound.line - 1 : range.upperBound.line) - 1
        guard first >= 0, last >= first + 2, last < source.lineCount else { return nil }
        let delimiter = first + 1
        let pipeLed = isPipeLed(source.units, from: source.lineStarts[delimiter], end: source.lineContentEnds[delimiter])
        for line in (first + 2)...last
        where !isRow(source.units, from: source.lineStarts[line], end: source.lineContentEnds[line], pipeLed: pipeLed) {
            return line
        }
        return nil
    }
}
