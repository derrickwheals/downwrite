import Foundation

/// Smart editing behaviours for the Return and Tab keys: continue/exit lists and block quotes, indent/outdent items.
public enum ListEditing {
    private static let itemRE = try! NSRegularExpression(
        pattern: "^(\\s*)((?:>\\s?)*)(\\s*)([-+*]|\\d+[.)])(\\s+)(\\[[ xX]\\]\\s+)?")
    private static let quoteOnlyRE = try! NSRegularExpression(pattern: "^(\\s*)((?:>\\s?)+)")
    public static let indentUnit = "    "

    /// Edit for pressing Return with an empty selection, or nil to let the text view insert a plain newline.
    public static func returnKey(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let ns = NSString(string: text)
        let line = ns.lineRange(for: selection)
        var lineEnd = NSMaxRange(line)
        if lineEnd > line.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        if lineEnd > line.location, ns.character(at: lineEnd - 1) == 13 { lineEnd -= 1 }
        let content = NSRange(location: line.location, length: lineEnd - line.location)
        let lineText = ns.substring(with: content)
        let full = NSRange(location: 0, length: lineText.utf16.count)

        if let m = itemRE.firstMatch(in: lineText, range: full) {
            let prefixLen = m.range.length
            // Caret inside the marker: behave like a normal newline.
            if selection.location - line.location < prefixLen { return nil }
            let rest = (lineText as NSString).substring(from: prefixLen)
            let indent = (lineText as NSString).substring(with: m.range(at: 1))
            let quote = (lineText as NSString).substring(with: m.range(at: 2))
            let inner = (lineText as NSString).substring(with: m.range(at: 3))
            let marker = (lineText as NSString).substring(with: m.range(at: 4))
            let spacing = (lineText as NSString).substring(with: m.range(at: 5))
            let hasTask = m.range(at: 6).location != NSNotFound

            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item: outdent one level, or leave the list.
                if indent.count + inner.count >= indentUnit.count || (indent + inner).contains("\t") {
                    var shorter = indent + inner
                    shorter = removeOneIndent(shorter)
                    let newLine = shorter + marker + spacing + (hasTask ? "[ ] " : "")
                    let edit = NSRange(location: content.location, length: content.length)
                    return TextEdit(range: edit, replacement: newLine,
                                    selection: NSRange(location: content.location + newLine.utf16.count, length: 0))
                }
                return TextEdit(range: content, replacement: quote,
                                selection: NSRange(location: content.location + quote.utf16.count, length: 0))
            }
            let next = nextMarker(marker)
            let insertion = "\n" + indent + quote + inner + next + spacing + (hasTask ? "[ ] " : "")
            return TextEdit(range: selection, replacement: insertion,
                            selection: NSRange(location: selection.location + insertion.utf16.count, length: 0))
        }

        if let m = quoteOnlyRE.firstMatch(in: lineText, range: full) {
            let prefixLen = m.range.length
            if selection.location - line.location < prefixLen { return nil }
            let rest = (lineText as NSString).substring(from: prefixLen)
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return TextEdit(range: content, replacement: "",
                                selection: NSRange(location: content.location, length: 0))
            }
            let prefix = (lineText as NSString).substring(to: prefixLen)
            let normalized = prefix.hasSuffix(" ") ? prefix : prefix + " "
            let insertion = "\n" + normalized
            return TextEdit(range: selection, replacement: insertion,
                            selection: NSRange(location: selection.location + insertion.utf16.count, length: 0))
        }
        return nil
    }

    private static func nextMarker(_ marker: String) -> String {
        guard let last = marker.last, last == "." || last == ")", let n = Int(marker.dropLast()) else { return marker }
        return "\(n + 1)\(last)"
    }

    private static func removeOneIndent(_ s: String) -> String {
        if s.hasSuffix("\t") { return String(s.dropLast()) }
        let spaces = s.reversed().prefix(while: { $0 == " " }).count
        return String(s.dropLast(min(spaces, indentUnit.count)))
    }

    public static func isListLine(in text: String, selection: NSRange) -> Bool {
        let ns = NSString(string: text)
        let line = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        let s = ns.substring(with: line)
        return itemRE.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }

    /// Indent or outdent every line touched by the selection.
    public static func indent(in text: String, selection: NSRange, outdent: Bool) -> TextEdit {
        let ns = NSString(string: text)
        let block = Formatter.lineBlock(ns, selection)
        var body = ns.substring(with: block)
        let trailing = body.hasSuffix("\n")
        if trailing { body.removeLast() }
        let lines = body.components(separatedBy: "\n")
        var firstDelta = 0
        let out = lines.enumerated().map { (i, l) -> String in
            var result = l
            if outdent {
                if l.hasPrefix("\t") { result = String(l.dropFirst()) }
                else {
                    let n = min(l.prefix(while: { $0 == " " }).count, indentUnit.count)
                    result = String(l.dropFirst(n))
                }
            } else if !l.isEmpty {
                result = indentUnit + l
            }
            if i == 0 { firstDelta = result.utf16.count - l.utf16.count }
            return result
        }
        let joined = out.joined(separator: "\n") + (trailing ? "\n" : "")
        if selection.length == 0 {
            let caret = max(block.location, selection.location + firstDelta)
            return TextEdit(range: block, replacement: joined, selection: NSRange(location: caret, length: 0))
        }
        return TextEdit(range: block, replacement: joined,
                        selection: NSRange(location: block.location, length: joined.utf16.count - (trailing ? 1 : 0)))
    }

    /// Flip `[ ]` ↔ `[x]` at the given range (the three-character checkbox).
    public static func toggleTask(in text: String, box: NSRange) -> TextEdit {
        let ns = NSString(string: text)
        let current = ns.substring(with: box)
        let replacement = current == "[ ]" ? "[x]" : "[ ]"
        return TextEdit(range: box, replacement: replacement, selection: NSRange(location: NSMaxRange(box), length: 0))
    }
}
