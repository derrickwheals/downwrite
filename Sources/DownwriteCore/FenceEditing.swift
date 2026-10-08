import Foundation

/// Typing helpers for fenced code blocks.
///
/// - Typing the third backtick at the start of a line closes the fence for you.
/// - Return on such an opening line moves into the empty body instead of pushing the closing fence down.
public enum FenceEditing {
    private struct Fence { var char: UInt16; var length: Int }

    /// Fence characters at the start of `line` (after indentation): a run of 3+ backticks or tildes.
    private static func openingFence(of line: String) -> Fence? {
        let units = Array(line.utf16)
        var i = 0
        while i < units.count, units[i] == 32 || units[i] == 9 { i += 1 }
        guard i < units.count, units[i] == 96 || units[i] == 126 else { return nil }
        let ch = units[i]
        var n = 0
        while i + n < units.count, units[i + n] == ch { n += 1 }
        guard n >= 3 else { return nil }
        // An info string after a backtick fence may not contain backticks.
        if ch == 96, units[(i + n)...].contains(96) { return nil }
        return Fence(char: ch, length: n)
    }

    /// True when `line` is a closing fence for `fence` (only fence characters, at least as many, optional trailing spaces).
    private static func closes(_ line: String, _ fence: Fence) -> Bool {
        let units = Array(line.utf16)
        var i = 0
        while i < units.count, units[i] == 32 || units[i] == 9 { i += 1 }
        var n = 0
        while i + n < units.count, units[i + n] == fence.char { n += 1 }
        guard n >= fence.length else { return false }
        return units[(i + n)...].allSatisfy { $0 == 32 || $0 == 9 }
    }

    /// Whether the start of line `index` is inside a fenced code block that began on an earlier line.
    private static func isInsideFence(lines: [String], before index: Int) -> Bool {
        var open: Fence?
        for line in lines.prefix(index) {
            if let f = open {
                if closes(line, f) { open = nil }
            } else if let f = openingFence(of: line) {
                open = f
            }
        }
        return open != nil
    }

    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    // MARK: Typing the third backtick

    /// The edit for typing `typed` at an empty selection, or nil when the keystroke should be inserted normally.
    ///
    /// Fires only for a single backtick that completes a ``` at the start of a line (indentation allowed), with nothing
    /// but spaces after the caret, outside any code block. The result is the three backticks, an empty line and the
    /// closing fence, with the caret left after the opening fence so a language can be typed.
    public static func autoCloseEdit(typing typed: String, in text: String, selection: NSRange) -> TextEdit? {
        guard typed == "`", selection.length == 0 else { return nil }
        let ns = NSString(string: text)
        guard selection.location >= 0, selection.location <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: selection)
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location, [10, 13].contains(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        guard selection.location <= contentEnd else { return nil }

        let before = ns.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
        let after = ns.substring(with: NSRange(location: selection.location, length: contentEnd - selection.location))
        guard after.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }

        let indent = String(before.prefix(while: { $0 == " " || $0 == "\t" }))
        guard before.dropFirst(indent.count) == "``" else { return nil }

        let lines = splitLines(text)
        let lineIndex = ns.substring(to: lineRange.location).filter { $0 == "\n" }.count
        guard !isInsideFence(lines: lines, before: lineIndex) else { return nil }

        // Stray spaces after the caret are absorbed, so none dangle after the closing fence.
        let replacement = "`\n" + indent + "\n" + indent + "```"
        return TextEdit(range: NSRange(location: selection.location, length: after.utf16.count), replacement: replacement,
                        selection: NSRange(location: selection.location + 1, length: 0))
    }

    // MARK: Return on an opening fence

    /// When the caret sits at the end of an opening fence line whose body is a single empty line followed by the
    /// closing fence (exactly what `autoCloseEdit` produces), Return should step into that empty line. The edit changes
    /// no text; only `selection` matters.
    public static func returnEdit(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let ns = NSString(string: text)
        guard selection.location >= 0, selection.location <= ns.length else { return nil }
        let lines = splitLines(text)
        let lineIndex = ns.substring(to: selection.location).filter { $0 == "\n" }.count
        guard lineIndex + 2 < lines.count else { return nil }
        let current = lines[lineIndex]
        guard let fence = openingFence(of: current), !isInsideFence(lines: lines, before: lineIndex) else { return nil }
        // Caret must be at the end of the line (trailing spaces allowed).
        let lineStart = ns.lineRange(for: selection).location
        let column = selection.location - lineStart
        guard current.utf16.count >= column, current.utf16.dropFirst(column).allSatisfy({ $0 == 32 || $0 == 9 }) else { return nil }
        guard lines[lineIndex + 1].allSatisfy({ $0 == " " || $0 == "\t" }), closes(lines[lineIndex + 2], fence) else { return nil }

        let bodyStart = lineStart + current.utf16.count + 1
        let bodyEnd = bodyStart + lines[lineIndex + 1].utf16.count
        return TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "",
                        selection: NSRange(location: bodyEnd, length: 0))
    }
}
