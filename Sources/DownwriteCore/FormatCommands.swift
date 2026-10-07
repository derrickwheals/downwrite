import Foundation

/// A single replacement to apply to the document, plus where the selection should end up afterwards.
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    /// Selection in the document *after* the edit.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range; self.replacement = replacement; self.selection = selection
    }

    public func apply(to text: String) -> String {
        let ns = NSMutableString(string: text)
        ns.replaceCharacters(in: range, with: replacement)
        return ns as String
    }
}

public enum FormatCommand: Equatable, Sendable {
    case bold, italic, strikethrough, highlight, inlineCode
    case link
    case heading(Int)           // 1...6; applying the current level again removes it
    case body                   // removes heading markers
    case bulletList, numberedList, taskList
    case blockQuote
    case codeBlock
    case horizontalRule
    case formatTable
    case insertTable
}

public enum Formatter {
    public static func apply(_ command: FormatCommand, to text: String, selection: NSRange) -> TextEdit? {
        let sel = clamp(selection, in: text)
        switch command {
        case .bold: return toggleInline(["**", "__"], in: text, selection: sel)
        case .italic: return toggleInline(["*", "_"], in: text, selection: sel)
        case .strikethrough: return toggleInline(["~~"], in: text, selection: sel)
        case .highlight: return toggleInline(["=="], in: text, selection: sel)
        case .inlineCode: return toggleInline(["`"], in: text, selection: sel)
        case .link: return link(in: text, selection: sel)
        case .heading(let n): return heading(n, in: text, selection: sel)
        case .body: return heading(0, in: text, selection: sel)
        case .bulletList: return list(.bullet, in: text, selection: sel)
        case .numberedList: return list(.numbered, in: text, selection: sel)
        case .taskList: return list(.task, in: text, selection: sel)
        case .blockQuote: return blockQuote(in: text, selection: sel)
        case .codeBlock: return codeBlock(in: text, selection: sel)
        case .horizontalRule: return horizontalRule(in: text, selection: sel)
        case .formatTable: return TableFormatter.formatEdit(in: text, selection: sel)
        case .insertTable: return TableFormatter.insertEdit(in: text, selection: sel)
        }
    }

    static func clamp(_ r: NSRange, in text: String) -> NSRange {
        let n = text.utf16.count
        let loc = min(max(0, r.location), n)
        return NSRange(location: loc, length: min(max(0, r.length), n - loc))
    }

    // MARK: Inline toggles

    /// `markers[0]` is the canonical marker used when wrapping; the others are recognised when unwrapping.
    static func toggleInline(_ markers: [String], in text: String, selection: NSRange) -> TextEdit {
        let ns = NSString(string: text)
        var sel = selection
        let marker = markers[0]

        if sel.length == 0, let word = wordRange(ns, at: sel.location) { sel = word }

        // Trim whitespace off the selection so we never produce `** bold**`.
        var core = sel
        while core.length > 0, isWhitespace(ns.character(at: core.location)) { core.location += 1; core.length -= 1 }
        while core.length > 0, isWhitespace(ns.character(at: NSMaxRange(core) - 1)) { core.length -= 1 }

        // 1. Already wrapped just outside the selection?
        for m in markers {
            let ch = (m as NSString).character(at: 0)
            let need = m.utf16.count
            let before = run(of: ch, before: core.location, in: ns)
            let after = run(of: ch, after: NSMaxRange(core), in: ns)
            let n = min(before, after)
            if isWrapped(runLength: n, need: need, char: ch) {
                let range = NSRange(location: core.location - need, length: core.length + 2 * need)
                let inner = ns.substring(with: core)
                return TextEdit(range: range, replacement: inner, selection: NSRange(location: range.location, length: core.length))
            }
        }
        // 2. Selection itself includes the markers (`**bold**` selected)?
        if core.length >= 2 * marker.utf16.count + 1 {
            for m in markers {
                let s = ns.substring(with: core)
                let need = m.utf16.count
                if s.hasPrefix(m), s.hasSuffix(m) {
                    let ch = (m as NSString).character(at: 0)
                    // For single-char markers, ensure we aren't looking at `**x**` when toggling italic.
                    let inner = (s as NSString).substring(with: NSRange(location: need, length: s.utf16.count - 2 * need))
                    if need == 1 && inner.utf16.first == ch && inner.utf16.last == ch { continue }
                    return TextEdit(range: core, replacement: inner, selection: NSRange(location: core.location, length: inner.utf16.count))
                }
            }
        }
        // 3. Wrap.
        if core.length == 0 {
            let at = selection.length == 0 ? selection.location : core.location
            return TextEdit(range: NSRange(location: at, length: 0), replacement: marker + marker,
                            selection: NSRange(location: at + marker.utf16.count, length: 0))
        }
        let inner = ns.substring(with: core)
        return TextEdit(range: core, replacement: marker + inner + marker,
                        selection: NSRange(location: core.location + marker.utf16.count, length: core.length))
    }

    private static func isWrapped(runLength n: Int, need: Int, char: UInt16) -> Bool {
        guard n >= need else { return false }
        if need == 1 { return n % 2 == 1 }          // `*` run of 1 or 3 contains italic; 2 is bold only
        if need == 2 && char == 42 { return n >= 2 } // `**` bold is in runs of 2 or 3
        return n >= need
    }

    private static func run(of ch: UInt16, before loc: Int, in ns: NSString) -> Int {
        var n = 0, p = loc
        while p > 0, ns.character(at: p - 1) == ch { n += 1; p -= 1 }
        return n
    }

    private static func run(of ch: UInt16, after loc: Int, in ns: NSString) -> Int {
        var n = 0, p = loc
        while p < ns.length, ns.character(at: p) == ch { n += 1; p += 1 }
        return n
    }

    static func isWhitespace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    static func isWordChar(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }   // surrogates: treat as word chars
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Word surrounding (or adjacent to) a caret; nil if the caret is in whitespace/punctuation.
    static func wordRange(_ ns: NSString, at loc: Int) -> NSRange? {
        var a = loc, b = loc
        while a > 0, isWordChar(ns.character(at: a - 1)) { a -= 1 }
        while b < ns.length, isWordChar(ns.character(at: b)) { b += 1 }
        return b > a ? NSRange(location: a, length: b - a) : nil
    }

    // MARK: Link

    static func link(in text: String, selection: NSRange) -> TextEdit {
        let ns = NSString(string: text)
        var sel = selection
        if sel.length == 0, let w = wordRange(ns, at: sel.location) { sel = w }
        let s = ns.substring(with: sel)
        if sel.length == 0 {
            let url = "url"
            return TextEdit(range: sel, replacement: "[text](\(url))", selection: NSRange(location: sel.location + 1, length: 4))
        }
        if looksLikeURL(s) {
            return TextEdit(range: sel, replacement: "[](\(s))", selection: NSRange(location: sel.location + 1, length: 0))
        }
        let url = "url"
        let prefix = "[\(s)]("
        return TextEdit(range: sel, replacement: prefix + url + ")",
                        selection: NSRange(location: sel.location + prefix.utf16.count, length: url.utf16.count))
    }

    public static func looksLikeURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.contains(" ") && (t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("mailto:") || t.hasPrefix("www."))
    }

    // MARK: Line-based block commands

    /// Range covering whole lines touched by `selection` (excluding the final terminator when the selection ends at a line start).
    static func lineBlock(_ ns: NSString, _ selection: NSRange) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, ns.character(at: end - 1) == 10 { end -= 1 }
        return ns.lineRange(for: NSRange(location: selection.location, length: max(0, end - selection.location)))
    }

    private static func splitLines(_ block: String) -> (lines: [String], trailingNewline: Bool) {
        var lines = block.components(separatedBy: "\n")
        var trailing = false
        if lines.last == "" && lines.count > 1 { lines.removeLast(); trailing = true }
        return (lines, trailing)
    }

    private static func join(_ lines: [String], trailing: Bool) -> String {
        lines.joined(separator: "\n") + (trailing ? "\n" : "")
    }

    static let headingRE = try! NSRegularExpression(pattern: "^(\\s{0,3})(#{1,6})(?:\\s+|$)")

    static func heading(_ level: Int, in text: String, selection: NSRange) -> TextEdit {
        let ns = NSString(string: text)
        let block = lineBlock(ns, selection)
        let (lines, trailing) = splitLines(ns.substring(with: block))
        func currentLevel(_ l: String) -> Int {
            guard let m = headingRE.firstMatch(in: l, range: NSRange(location: 0, length: l.utf16.count)) else { return 0 }
            return m.range(at: 2).length
        }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allAtLevel = !nonEmpty.isEmpty && nonEmpty.allSatisfy { currentLevel($0) == level }
        let target = (level == 0 || allAtLevel) ? 0 : level
        let out = lines.map { l -> String in
            var body = l
            if let m = headingRE.firstMatch(in: l, range: NSRange(location: 0, length: l.utf16.count)) {
                body = (l as NSString).substring(from: m.range.length)
            }
            if target == 0 { return body }
            if body.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return l }
            return String(repeating: "#", count: target) + " " + body
        }
        let joined = join(out, trailing: trailing)
        // Keep the caret where the user was relative to the text when it's a single line.
        if selection.length == 0, lines.count == 1 {
            let oldPrefix = lines[0].utf16.count - (out[0].utf16.count - (target == 0 ? 0 : target + 1))
            let delta = out[0].utf16.count - lines[0].utf16.count
            _ = oldPrefix
            let caret = max(block.location, selection.location + delta)
            return TextEdit(range: block, replacement: joined, selection: NSRange(location: min(caret, block.location + out[0].utf16.count), length: 0))
        }
        let contentLen = joined.utf16.count - (trailing ? 1 : 0)
        return TextEdit(range: block, replacement: joined, selection: NSRange(location: block.location, length: contentLen))
    }

    enum ListKind { case bullet, numbered, task }

    static let listMarkerRE = try! NSRegularExpression(pattern: "^(\\s*)(?:[-+*]|\\d+[.)])\\s+(?:\\[[ xX]\\]\\s+)?")
    static let bulletRE = try! NSRegularExpression(pattern: "^(\\s*)[-+*]\\s+(?!\\[[ xX]\\])")
    static let numberRE = try! NSRegularExpression(pattern: "^(\\s*)\\d+[.)]\\s+")
    static let taskRE = try! NSRegularExpression(pattern: "^(\\s*)[-+*]\\s+\\[[ xX]\\]\\s+")

    static func list(_ kind: ListKind, in text: String, selection: NSRange) -> TextEdit {
        let ns = NSString(string: text)
        let block = lineBlock(ns, selection)
        let (lines, trailing) = splitLines(ns.substring(with: block))
        func matches(_ re: NSRegularExpression, _ l: String) -> Bool {
            re.firstMatch(in: l, range: NSRange(location: 0, length: l.utf16.count)) != nil
        }
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let re: NSRegularExpression = kind == .bullet ? bulletRE : (kind == .numbered ? numberRE : taskRE)
        let remove = !content.isEmpty && content.allSatisfy { matches(re, $0) }
        var counter = 0
        let out = lines.map { l -> String in
            if l.trimmingCharacters(in: .whitespaces).isEmpty && (lines.count > 1 || !remove && false) { return l }
            var indent = ""
            var body = l
            if let m = listMarkerRE.firstMatch(in: l, range: NSRange(location: 0, length: l.utf16.count)) {
                indent = (l as NSString).substring(with: m.range(at: 1))
                body = (l as NSString).substring(from: m.range.length)
            } else {
                let ws = l.prefix(while: { $0 == " " || $0 == "\t" })
                indent = String(ws)
                body = String(l.dropFirst(ws.count))
            }
            if remove { return indent + body }
            counter += 1
            switch kind {
            case .bullet: return indent + "- " + body
            case .numbered: return indent + "\(counter). " + body
            case .task: return indent + "- [ ] " + body
            }
        }
        let joined = join(out, trailing: trailing)
        let contentLen = joined.utf16.count - (trailing ? 1 : 0)
        if selection.length == 0, lines.count == 1 {
            let delta = out[0].utf16.count - lines[0].utf16.count
            let caret = max(block.location, min(selection.location + delta, block.location + contentLen))
            return TextEdit(range: block, replacement: joined, selection: NSRange(location: caret, length: 0))
        }
        return TextEdit(range: block, replacement: joined, selection: NSRange(location: block.location, length: contentLen))
    }

    static let quoteRE = try! NSRegularExpression(pattern: "^(\\s{0,3})>\\s?")

    static func blockQuote(in text: String, selection: NSRange) -> TextEdit {
        let ns = NSString(string: text)
        let block = lineBlock(ns, selection)
        let (lines, trailing) = splitLines(ns.substring(with: block))
        func isQuoted(_ l: String) -> Bool {
            quoteRE.firstMatch(in: l, range: NSRange(location: 0, length: l.utf16.count)) != nil
        }
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let remove = !content.isEmpty && content.allSatisfy(isQuoted)
        let out = lines.map { l -> String in
            if remove, let m = quoteRE.firstMatch(in: l, range: NSRange(location: 0, length: l.utf16.count)) {
                return (l as NSString).substring(from: m.range.length)
            }
            return remove ? l : "> " + l
        }
        let joined = join(out, trailing: trailing)
        let contentLen = joined.utf16.count - (trailing ? 1 : 0)
        if selection.length == 0, lines.count == 1 {
            let delta = out[0].utf16.count - lines[0].utf16.count
            let caret = max(block.location, min(selection.location + delta, block.location + contentLen))
            return TextEdit(range: block, replacement: joined, selection: NSRange(location: caret, length: 0))
        }
        return TextEdit(range: block, replacement: joined, selection: NSRange(location: block.location, length: contentLen))
    }

    static func codeBlock(in text: String, selection: NSRange) -> TextEdit {
        let ns = NSString(string: text)
        if selection.length == 0 {
            let line = ns.lineRange(for: selection)
            let lineText = ns.substring(with: line).trimmingCharacters(in: .newlines)
            if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
                let at = NSRange(location: line.location, length: lineText.utf16.count)
                return TextEdit(range: at, replacement: "```\n\n```", selection: NSRange(location: line.location + 4, length: 0))
            }
        }
        let block = lineBlock(ns, selection)
        var body = ns.substring(with: block)
        let hadTrailing = body.hasSuffix("\n")
        if hadTrailing { body.removeLast() }
        let replacement = "```\n" + body + "\n```" + (hadTrailing ? "\n" : "")
        return TextEdit(range: block, replacement: replacement,
                        selection: NSRange(location: block.location + 4, length: body.utf16.count))
    }

    static func horizontalRule(in text: String, selection: NSRange) -> TextEdit {
        let ns = NSString(string: text)
        let line = ns.lineRange(for: NSRange(location: NSMaxRange(selection), length: 0))
        var insertAt = NSMaxRange(line)
        var prefix = ""
        let lineText = ns.substring(with: line)
        if !lineText.hasSuffix("\n") && lineText.utf16.count > 0 { prefix = "\n" }
        if lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertAt = line.location
        } else {
            prefix += "\n"
        }
        let rep = prefix + "---\n\n"
        return TextEdit(range: NSRange(location: insertAt, length: 0), replacement: rep,
                        selection: NSRange(location: insertAt + rep.utf16.count, length: 0))
    }
}
