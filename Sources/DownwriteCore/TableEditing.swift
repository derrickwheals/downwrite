import Foundation

/// Text-level edits around a grid table: leaving it with the keyboard and removing it. (Cell and row/column edits go
/// through `TableModel`; the app writes the model back with `TableModel.markdown`.)
public enum TableEditing {
    /// Caret position for leaving the grid downwards. A table must be followed by a blank line before ordinary text
    /// (otherwise the next line would become one of its rows), so this adds the missing blank line when the document
    /// ends right at the table. When nothing needs adding the returned edit is an empty insertion and only the
    /// selection matters.
    public static func exitAfter(in text: String, table: TableBlock) -> TextEdit {
        let ns = NSString(string: text)
        let end = NSMaxRange(table.range)
        func insert(_ s: String, at p: Int, caret: Int) -> TextEdit {
            TextEdit(range: NSRange(location: p, length: 0), replacement: s, selection: NSRange(location: caret, length: 0))
        }
        if end >= ns.length { return insert("\n\n", at: end, caret: end + 2) }      // no newline after the table at all
        let next = end + 1                                                           // start of the line after the table
        if next >= ns.length { return insert("\n", at: next, caret: next + 1) }     // document ends with the table's newline
        let line = ns.lineRange(for: NSRange(location: next, length: 0))
        let isBlank = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isBlank else { return insert("", at: next, caret: next) }             // another block starts right away
        let after = NSMaxRange(line)
        if after >= ns.length, ns.substring(with: line).hasSuffix("\n") == false {   // blank last line without a newline
            return insert("\n", at: after, caret: after + 1)
        }
        return insert("", at: after, caret: after)
    }

    /// Caret position for leaving the grid upwards: the end of the line above. A table at the very top of the
    /// document gets an empty line above it to land on.
    public static func exitBefore(in text: String, table: TableBlock) -> TextEdit {
        let start = table.range.location
        if start == 0 {
            return TextEdit(range: NSRange(location: 0, length: 0), replacement: "\n\n", selection: NSRange(location: 0, length: 0))
        }
        return TextEdit(range: NSRange(location: start, length: 0), replacement: "", selection: NSRange(location: start - 1, length: 0))
    }

    /// Removes the table and its line terminator (and one of the blank lines around it, so no double gap is left).
    public static func deleteTable(in text: String, table: TableBlock) -> TextEdit {
        let ns = NSString(string: text)
        var start = table.range.location
        let stop = min(ns.length, NSMaxRange(table.range) + 1)
        let prevBlank = start >= 1 && ns.character(at: start - 1) == 10 && (start == 1 || ns.character(at: start - 2) == 10)
        let nextBlank = stop < ns.length && ns.character(at: stop) == 10
        if prevBlank && nextBlank { start -= 1 }
        return TextEdit(range: NSRange(location: start, length: stop - start), replacement: "",
                        selection: NSRange(location: start, length: 0))
    }

    /// Replaces the table's source with the model's Markdown.
    public static func replace(table: TableBlock, with model: TableModel) -> TextEdit {
        let md = model.markdown
        return TextEdit(range: table.range, replacement: md, selection: NSRange(location: table.range.location, length: 0))
    }
}
