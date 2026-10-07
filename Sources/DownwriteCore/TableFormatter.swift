import Foundation

/// Aligns GitHub-flavoured Markdown tables (the "Format Table" command and the Markdown-source view).
/// Parsing and serialising live in `TableModel`; this type finds the table around the caret and swaps the text.
public enum TableFormatter {
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
        guard let model = TableModel(markdownLines: lines) else { return lines }
        return model.markdownLines()
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
        guard lines.count >= 2, TableModel.isDelimiterRow(lines[1]) else { return nil }
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
        let table = TableModel.blank().markdown
        let ns = NSString(string: text)
        let line = ns.lineRange(for: selection)
        let atLineStart = selection.location == line.location
        let prefix = atLineStart ? "" : "\n\n"
        let rep = prefix + table + "\n"
        return TextEdit(range: selection, replacement: rep,
                        selection: NSRange(location: selection.location + prefix.utf16.count + 2, length: 8))
    }
}
