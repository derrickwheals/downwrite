import Foundation

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
