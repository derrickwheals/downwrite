import Foundation

/// Aligns GitHub-flavoured Markdown tables.
public enum TableFormatter {
    enum Alignment { case left, center, right, none }

    /// Splits a table row into trimmed cells, honouring `\|` and code spans.
    static func cells(of line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var prevBackslash = false
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        for ch in trimmed {
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !prevBackslash && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            prevBackslash = (ch == "\\" && !prevBackslash)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !trimmed.hasSuffix("|") { cells.append(last) }
        return cells
    }

    static func isDelimiterRow(_ line: String) -> Bool {
        let c = cells(of: line)
        guard !c.isEmpty else { return false }
        return c.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            return t.count >= 1 && t.allSatisfy { $0 == "-" || $0 == ":" } && t.contains("-")
        }
    }

    static func alignment(of cell: String) -> Alignment {
        let t = cell.trimmingCharacters(in: .whitespaces)
        switch (t.hasPrefix(":"), t.hasSuffix(":")) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        default: return .none
        }
    }

    /// Display width: wide (CJK / emoji) characters count as two columns.
    static func width(_ s: String) -> Int {
        s.reduce(0) { acc, ch in
            guard let v = ch.unicodeScalars.first?.value else { return acc + 1 }
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0x1F300...0x1FAFF).contains(v)
            return acc + (wide ? 2 : 1)
        }
    }

    public static func format(_ lines: [String]) -> [String] {
        guard lines.count >= 2, isDelimiterRow(lines[1]) else { return lines }
        let rows = lines.map { cells(of: $0) }
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return lines }
        let aligns: [Alignment] = (0..<cols).map { $0 < rows[1].count ? alignment(of: rows[1][$0]) : .none }
        var widths = [Int](repeating: 3, count: cols)
        for (r, row) in rows.enumerated() where r != 1 {
            for (c, cell) in row.enumerated() { widths[c] = max(widths[c], width(cell)) }
        }
        func pad(_ s: String, _ w: Int, _ a: Alignment) -> String {
            let gap = max(0, w - width(s))
            switch a {
            case .right: return String(repeating: " ", count: gap) + s
            case .center:
                let l = gap / 2
                return String(repeating: " ", count: l) + s + String(repeating: " ", count: gap - l)
            default: return s + String(repeating: " ", count: gap)
            }
        }
        return rows.enumerated().map { (r, row) -> String in
            let parts = (0..<cols).map { c -> String in
                if r == 1 {
                    let w = widths[c]
                    switch aligns[c] {
                    case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
                    case .left: return ":" + String(repeating: "-", count: w - 1)
                    case .right: return String(repeating: "-", count: w - 1) + ":"
                    case .none: return String(repeating: "-", count: w)
                    }
                }
                return pad(c < row.count ? row[c] : "", widths[c], aligns[c])
            }
            return "| " + parts.joined(separator: " | ") + " |"
        }
    }

    /// Line range of the table containing the caret, if the caret is inside one.
    static func tableLines(in text: String, selection: NSRange) -> (range: NSRange, lines: [String])? {
        let ns = NSString(string: text)
        let caretLine = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        func lineText(_ r: NSRange) -> String { ns.substring(with: r).trimmingCharacters(in: .newlines) }
        func isRow(_ s: String) -> Bool { s.contains("|") && !s.trimmingCharacters(in: .whitespaces).isEmpty }
        guard isRow(lineText(caretLine)) else { return nil }
        var start = caretLine
        while start.location > 0 {
            let prev = ns.lineRange(for: NSRange(location: start.location - 1, length: 0))
            if isRow(lineText(prev)) { start = prev } else { break }
        }
        var end = caretLine
        while NSMaxRange(end) < ns.length {
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(end), length: 0))
            if isRow(lineText(next)) { end = next } else { break }
        }
        let range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        let lines = lineText(range).components(separatedBy: "\n")
        guard lines.count >= 2, isDelimiterRow(lines[1]) else { return nil }
        return (range, lines)
    }

    public static func formatEdit(in text: String, selection: NSRange) -> TextEdit? {
        guard let (range, lines) = tableLines(in: text, selection: selection) else { return nil }
        let ns = NSString(string: text)
        let hadTrailing = ns.substring(with: range).hasSuffix("\n")
        let formatted = format(lines).joined(separator: "\n") + (hadTrailing ? "\n" : "")
        return TextEdit(range: range, replacement: formatted, selection: NSRange(location: range.location + 2, length: 0))
    }

    public static func insertEdit(in text: String, selection: NSRange) -> TextEdit {
        let table = format(["| Column 1 | Column 2 | Column 3 |", "| --- | --- | --- |", "| | | |"]).joined(separator: "\n")
        let ns = NSString(string: text)
        let line = ns.lineRange(for: selection)
        let atLineStart = selection.location == line.location
        let prefix = atLineStart ? "" : "\n\n"
        let rep = prefix + table + "\n"
        return TextEdit(range: selection, replacement: rep,
                        selection: NSRange(location: selection.location + prefix.utf16.count + 2, length: 8))
    }
}
