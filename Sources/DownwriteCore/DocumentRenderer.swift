import Foundation
import Markdown

/// Writes the body of the page from a swift-markdown tree (the library's own `HTMLFormatter` is not used: it writes text, code and `href`
/// unescaped and passes raw HTML through).
///
/// Everything the document says is escaped here. Raw HTML from the document is passed through untouched, to be locked down by
/// ``HTMLSanitizer`` afterwards, together with the markup written here. After each block the renderer writes a block boundary (see
/// ``HTMLSanitizer/blockBoundary``) so that a broken tag in one block cannot swallow the next. A diagram is a slot, `U+E000 D<n> U+E001`;
/// the document cannot forge one because every use of these three characters in its text is written as a numeric reference.
final class DocumentRenderer {
    private(set) var html = ""
    private(set) var diagrams: [String] = []
    private let headingIDs: [String?]
    private var nextHeading = 0

    static let boundary = "\u{E002}"
    static func slot(_ number: Int) -> String { "\u{E000}D\(number)\u{E001}" }

    init(headingIDs: [String?]) { self.headingIDs = headingIDs }

    func render(_ document: Document) { blocks(of: document) }

    // MARK: Escaping

    private static func isSentinel(_ c: Unicode.Scalar) -> Bool { c.value >= 0xE000 && c.value <= 0xE002 }

    private static func escape(_ s: String, quotes: Bool) -> String {
        var needs = false
        for c in s.unicodeScalars where c == "&" || c == "<" || c == ">" || (quotes && c == "\"") || isSentinel(c) { needs = true; break }
        guard needs else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count + 16)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where quotes: out += "&quot;"
            default:
                if isSentinel(c) { out += "&#x" + String(c.value, radix: 16, uppercase: true) + ";" } else { out.unicodeScalars.append(c) }
            }
        }
        return out
    }

    static func escapeText(_ s: String) -> String { escape(s, quotes: false) }
    static func escapeAttribute(_ s: String) -> String { escape(s, quotes: true) }

    /// Raw HTML from the document, with the three sentinel characters made harmless.
    private static func raw(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isSentinel) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.map { isSentinel($0) ? "\u{FFFD}" : $0 }))
    }

    private func endBlock() { html += Self.boundary }

    // MARK: Blocks

    /// The children of a document, quote or list item. A run of headings is kept together with the block after it (R19), unless that
    /// block is raw HTML, which may open a tag that closes several blocks later.
    private func blocks(of parent: Markup) {
        let kids = Array(parent.children)
        var i = 0
        while i < kids.count {
            guard kids[i] is Heading else { block(kids[i]); i += 1; continue }
            var j = i
            while j < kids.count, kids[j] is Heading { j += 1 }
            let end = (j < kids.count && !(kids[j] is HTMLBlock)) ? j + 1 : j
            let wrap = end - i > 1
            if wrap { html += "<div class=\"keep\">\n" }
            for k in i..<end { block(kids[k]) }
            if wrap { html += "</div>\n"; endBlock() }
            i = end
        }
    }

    private func block(_ node: Markup) {
        switch node {
        case let h as Heading:
            let id = nextHeading < headingIDs.count ? headingIDs[nextHeading] : nil
            nextHeading += 1
            html += "<h\(h.level)" + (id.map { " id=\"\(Self.escapeAttribute($0))\"" } ?? "") + ">" + inlines(of: h) + "</h\(h.level)>\n"
            endBlock()
        case let p as Paragraph:
            html += "<p>" + inlines(of: p) + "</p>\n"
            endBlock()
        case is BlockQuote:
            html += "<blockquote>\n"
            blocks(of: node)
            html += "</blockquote>\n"
            endBlock()
        case is ThematicBreak:
            html += "<hr />\n"
            endBlock()
        case let l as UnorderedList:
            list(l, open: "<ul>\n", close: "</ul>\n")
        case let l as OrderedList:
            list(l, open: l.startIndex == 1 ? "<ol>\n" : "<ol start=\"\(l.startIndex)\">\n", close: "</ol>\n")
        case let c as CodeBlock:
            codeBlock(c)
        case let h as HTMLBlock:
            html += Self.raw(h.rawHTML.trimmingCharacters(in: .newlines)) + "\n"
            endBlock()
        case let t as Table:
            table(t)
        default:
            blocks(of: node)
        }
    }

    private func codeBlock(_ c: CodeBlock) {
        let language = (c.language ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first.map(String.init) ?? ""
        if language.lowercased() == "mermaid" {
            diagrams.append(c.code.hasSuffix("\n") ? String(c.code.dropLast()) : c.code)
            html += Self.slot(diagrams.count) + "\n"
        } else {
            html += "<pre><code>" + Self.escapeText(c.code) + "</code></pre>\n"
        }
        endBlock()
    }

    // MARK: Lists

    /// The last line of a node that has any content: cmark ends a node at column 1 of the following line when a blank line follows it.
    private func lastContentLine(_ range: SourceRange) -> Int {
        range.upperBound.column == 1 && range.upperBound.line > range.lowerBound.line ? range.upperBound.line - 1 : range.upperBound.line
    }

    /// CommonMark: a list is loose if two of its items, or two blocks directly inside one item, are separated by a blank line.
    private func isLoose(_ items: [ListItem]) -> Bool {
        func separated(_ blocks: [Markup]) -> Bool {
            for (a, b) in zip(blocks, blocks.dropFirst()) {
                if let ra = a.range, let rb = b.range, rb.lowerBound.line - lastContentLine(ra) > 1 { return true }
            }
            return false
        }
        return separated(items) || items.contains { separated(Array($0.children)) }
    }

    private func list(_ list: Markup, open: String, close: String) {
        let items = list.children.compactMap { $0 as? ListItem }
        let tight = !isLoose(items)
        html += open
        for item in items { listItem(item, tight: tight) }
        html += close
        endBlock()
    }

    private func listItem(_ item: ListItem, tight: Bool) {
        let kids = Array(item.children)
        let task = item.checkbox
        html += task == nil ? "<li>" : (task == .checked ? "<li class=\"task done\">" : "<li class=\"task\">")
        var rest = kids[...]
        if task != nil { html += "<span class=\"box\"></span>" }
        if let first = kids.first as? Paragraph, tight || task != nil {
            // The item's own text, without a paragraph around it: a tight list, or the line a task box belongs to.
            html += (task != nil ? "<span class=\"t\">" : "") + inlines(of: first) + (task != nil ? "</span>" : "")
            rest = kids.dropFirst()
        } else if !tight {
            html += "\n"
        }
        for child in rest {
            if tight || task != nil, !(child is Paragraph) { html += "\n" }
            block(child)
        }
        html += "</li>\n"
        endBlock()
    }

    // MARK: Tables

    private func table(_ t: Table) {
        let alignments = t.columnAlignments
        let headCells = Array(t.head.children)
        let rows = Array(t.body.children).map { Array($0.children) }
        // On paper a table is laid out as flex rows (see `PrintStyle`), which need to be told how wide each column is: in proportion to
        // its longest text, within limits. The markup stays an ordinary table.
        var longest = [Int](repeating: 0, count: max(headCells.count, rows.map(\.count).max() ?? 0))
        for cells in [headCells] + rows {
            for (i, cell) in cells.enumerated() where i < longest.count {
                for line in Self.plainText(of: cell).components(separatedBy: "\n") { longest[i] = max(longest[i], line.count) }
            }
        }
        let weights = longest.enumerated().map { "--w\($0.offset + 1):\(min(max($0.element, 4), 40))" }.joined(separator: ";")
        html += "<div class=\"dw-table\"><table style=\"\(weights)\">\n<thead>\n"
        tableRow(headCells, tag: "th", alignments: alignments)
        html += "</thead>\n"
        if !rows.isEmpty {
            html += "<tbody>\n"
            for cells in rows { tableRow(cells, tag: "td", alignments: alignments) }
            html += "</tbody>\n"
        }
        html += "</table></div>\n"
        endBlock()
    }

    /// The text of an inline container as a reader sees it: no markup, a line break as `\n`.
    private static func plainText(of node: Markup) -> String {
        var out = ""
        for child in node.children {
            switch child {
            case let t as Text: out += t.string
            case let c as InlineCode: out += c.code
            case is SoftBreak, is LineBreak: out += "\n"
            case is InlineHTML, is Image: break
            default: out += plainText(of: child)
            }
        }
        return out
    }

    private func tableRow(_ cells: [Markup], tag: String, alignments: [Table.ColumnAlignment?]) {
        html += "<tr>"
        for (i, cell) in cells.enumerated() {
            var style = ""
            if i < alignments.count, let a = alignments[i] {
                style = " style=\"text-align:" + (a == .left ? "left" : a == .center ? "center" : "right") + "\""
            }
            html += "<\(tag)\(style)>" + inlines(of: cell) + "</\(tag)>"
            endBlock()
        }
        html += "</tr>\n"
    }

    // MARK: Inline content

    /// The inline children of `container` as HTML. `==highlight==` is found on the container's text as a whole (so it may span emphasis
    /// and links, as in the editor) and written as `<mark>` around the text inside each element it touches, which keeps the markup
    /// well nested. A bare URL in a text run outside a link becomes a link.
    private func inlines(of container: Markup) -> String {
        var offsets: [Int] = []
        var marked: [Range<Int>] = []
        var delimiters: [Range<Int>] = []
        // The highlight pattern only matters where the text has `==`, so everything else skips the flattening.
        if Self.containsEquals(container) {
            var flat = ""
            Self.flatten(container, into: &flat, offsets: &offsets)
            for m in InlineExtensions.highlight.matches(in: flat, range: NSRange(location: 0, length: flat.utf16.count)) {
                let a = m.range.location, b = NSMaxRange(m.range)
                delimiters += [a..<(a + 2), (b - 2)..<b]
                marked.append((a + 2)..<(b - 2))
            }
        }
        var unit = 0
        return render(container, offsets: offsets, marked: marked, delimiters: delimiters, unit: &unit, inLink: false)
    }

    private static func containsEquals(_ node: Markup) -> Bool {
        node.children.contains { child in
            if let t = child as? Text { return t.string.contains("==") }
            return !(child is Image) && containsEquals(child)
        }
    }

    /// The container's text as the highlight pattern sees it: text as written, a line break as `\n`, and one placeholder for anything that
    /// is not text (code, an image, inline HTML). `offsets` has the UTF-16 offset of every such unit, in the order `render` meets them.
    private static func flatten(_ node: Markup, into flat: inout String, offsets: inout [Int]) {
        for child in node.children {
            switch child {
            case let t as Text: offsets.append(flat.utf16.count); flat += t.string
            case is SoftBreak, is LineBreak: offsets.append(flat.utf16.count); flat += "\n"
            case is InlineCode, is Image, is InlineHTML, is SymbolLink: offsets.append(flat.utf16.count); flat += "\u{1}"
            default: flatten(child, into: &flat, offsets: &offsets)
            }
        }
    }

    private func render(_ node: Markup, offsets: [Int], marked: [Range<Int>], delimiters: [Range<Int>], unit: inout Int, inLink: Bool) -> String {
        let tracking = !marked.isEmpty
        func isMarked(_ offset: Int) -> Bool { marked.contains { $0.contains(offset) } }
        var out = ""
        for child in node.children {
            switch child {
            case let t as Text:
                let start = tracking && unit < offsets.count ? offsets[unit] : 0
                unit += 1
                out += tracking ? highlightedRuns(t.string, start: start, marked: marked, delimiters: delimiters, linkify: !inLink) : Self.textRun(t.string, linkify: !inLink)
            case is SoftBreak:
                unit += 1
                out += "\n"
            case is LineBreak:
                unit += 1
                out += "<br />\n"
            case let c as InlineCode:
                let at = tracking && unit < offsets.count ? offsets[unit] : -1
                unit += 1
                let code = "<code>" + Self.escapeText(c.code) + "</code>"
                out += at >= 0 && isMarked(at) ? "<mark>" + code + "</mark>" : code
            case let s as SymbolLink:
                unit += 1
                out += "<code>" + Self.escapeText(s.destination ?? "") + "</code>"
            case let i as Image:
                let at = tracking && unit < offsets.count ? offsets[unit] : -1
                unit += 1
                let image = self.image(i)
                out += at >= 0 && isMarked(at) ? "<mark>" + image + "</mark>" : image
            case let h as InlineHTML:
                unit += 1
                out += Self.raw(h.rawHTML)
            case let l as Link:
                let inner = render(l, offsets: offsets, marked: marked, delimiters: delimiters, unit: &unit, inLink: true)
                let destination = l.destination ?? ""
                if !destination.isEmpty, LinkPolicy.isAllowedLinkDestination(destination) {
                    // The editor lower-cases a fragment before it looks the heading up, so the link says it in lower case.
                    let href = destination.hasPrefix("#") ? destination.lowercased() : destination
                    out += "<a href=\"" + Self.escapeAttribute(href) + "\"" + (l.title.map { $0.isEmpty ? "" : " title=\"" + Self.escapeAttribute($0) + "\"" } ?? "") + ">" + inner + "</a>"
                } else {
                    out += inner
                }
            case is Emphasis:
                out += "<em>" + render(child, offsets: offsets, marked: marked, delimiters: delimiters, unit: &unit, inLink: inLink) + "</em>"
            case is Strong:
                out += "<strong>" + render(child, offsets: offsets, marked: marked, delimiters: delimiters, unit: &unit, inLink: inLink) + "</strong>"
            case is Strikethrough:
                out += "<del>" + render(child, offsets: offsets, marked: marked, delimiters: delimiters, unit: &unit, inLink: inLink) + "</del>"
            default:
                out += render(child, offsets: offsets, marked: marked, delimiters: delimiters, unit: &unit, inLink: inLink)
            }
        }
        return out
    }

    /// One text node with the `==` delimiters taken out and `<mark>` around the parts inside a highlight.
    private func highlightedRuns(_ text: String, start: Int, marked: [Range<Int>], delimiters: [Range<Int>], linkify: Bool) -> String {
        let units = Array(text.utf16)
        enum Kind { case plain, mark, delimiter }
        func kind(at i: Int) -> Kind {
            let o = start + i
            if delimiters.contains(where: { $0.contains(o) }) { return .delimiter }
            return marked.contains(where: { $0.contains(o) }) ? .mark : .plain
        }
        var out = ""
        var i = 0
        while i < units.count {
            let k = kind(at: i)
            var j = i + 1
            while j < units.count, kind(at: j) == k { j += 1 }
            let run = String(decoding: units[i..<j], as: UTF16.self)
            switch k {
            case .plain: out += Self.textRun(run, linkify: linkify)
            case .mark: out += "<mark>" + Self.textRun(run, linkify: linkify) + "</mark>"
            case .delimiter: break
            }
            i = j
        }
        return out
    }

    /// Text, escaped, with each bare URL in it made a link (`https://…`, `www.…`).
    private static func textRun(_ s: String, linkify: Bool) -> String {
        guard linkify, s.contains("http") || s.contains("www.") else { return escapeText(s) }
        let ns = NSString(string: s)
        var out = ""
        var at = 0
        for m in InlineExtensions.bareURL.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: m.range)
            out += escapeText(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            out += "<a href=\"" + escapeAttribute(InlineExtensions.destination(forBareURL: url)) + "\">" + escapeText(url) + "</a>"
            at = NSMaxRange(m.range)
        }
        return out + escapeText(ns.substring(from: at))
    }

    /// An image whose source can never be loaded (empty, or a scheme the output does not allow) is shown as its alt text, muted.
    private func image(_ i: Image) -> String {
        let source = i.source ?? ""
        let alt = i.plainText
        guard !source.isEmpty, LinkPolicy.isCandidateImageSource(source) else {
            return "<span class=\"dw-missing\">" + Self.escapeText(alt.isEmpty ? "image" : alt) + "</span>"
        }
        let title = i.title.flatMap { $0.isEmpty ? nil : " title=\"" + Self.escapeAttribute($0) + "\"" } ?? ""
        return "<img src=\"" + Self.escapeAttribute(source) + "\" alt=\"" + Self.escapeAttribute(alt) + "\"" + title + ">"
    }
}
