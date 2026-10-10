import Foundation
import Markdown

/// Turns Markdown text into a `MarkdownAnalysis`.
///
/// CommonMark + GFM structure (tables, strikethrough, task lists, autolinks) comes from swift-markdown (cmark-gfm).
/// Extensions cmark does not know — `==highlight==`, `[^footnotes]`, `$math$`, YAML front matter and
/// Mermaid fences — are handled here.
public enum MarkdownAnalyzer {
    public static func analyze(_ text: String) -> MarkdownAnalysis {
        var b = Builder(text)
        b.run()
        return b.finish()
    }

    /// Inline analysis of one table cell's source text, as if it were rendered inside a table: spans, markers (which
    /// hide and reveal like anywhere else) and links, all relative to `text`. Block syntax (`#`, `-`, `>`) is not
    /// interpreted, and a bare `|` cannot split the cell (it is masked before parsing; offsets are unchanged).
    public static func analyzeTableCell(_ text: String) -> MarkdownAnalysis {
        let masked = String(String.UnicodeScalarView(text.unicodeScalars.map { s -> Unicode.Scalar in
            (s == "\n" || s == "\r" || s == "\t" || s == "\u{2028}" || s == "\u{2029}") ? " " : s
        }))
        var units = Array(masked.utf16)
        var i = 0
        while i < units.count {                       // mask unescaped pipes, keeping UTF-16 length
            if units[i] == 92, i + 1 < units.count { i += 2; continue }
            if units[i] == 124 { units[i] = 0x00A6 }  // ¦
            i += 1
        }
        let cell = String(decoding: units, as: UTF16.self)
        let prefix = "| x |\n| - |\n| "
        let shift = prefix.utf16.count
        var b = Builder(prefix + cell + " |")
        b.cellMode = true
        b.run()
        let whole = b.finish()
        let window = NSRange(location: shift, length: units.count)
        func inside(_ r: NSRange) -> Bool { r.location >= window.location && NSMaxRange(r) <= NSMaxRange(window) }
        func moved(_ r: NSRange) -> NSRange { NSRange(location: r.location - shift, length: r.length) }
        let spans = whole.spans.filter { inside($0.range) && !$0.flags.contains(.table) && !$0.flags.contains(.dim) }
            .map { FormatSpan(range: moved($0.range), flags: $0.flags) }
        let markers = whole.markers.filter { inside($0.range) }
            .map { Marker(range: moved($0.range), reveal: moved($0.reveal), flags: $0.flags) }
        let links = whole.links.filter { inside($0.range) }
            .map { LinkSpan(range: moved($0.range), textRange: moved($0.textRange), destination: $0.destination) }
        let line = LineStyle(range: NSRange(location: 0, length: units.count), contentEnd: units.count)
        return MarkdownAnalysis(length: units.count, spans: spans, markers: markers, lines: [line], links: links, images: [],
                                taskBoxes: [], mermaid: [], tables: [], headings: [], imageBlocks: [], htmlBlocks: [], foldRegions: [])
    }
}

// MARK: - Builder

private struct Context {
    var quoteDepth = 0
    var listDepth = 0
}

private struct Builder {
    let src: SourceText
    let original: String
    var spans: [FormatSpan] = []
    var markers: [Marker] = []
    var lines: [LineStyle] = []
    var links: [LinkSpan] = []
    var images: [ImageSpan] = []
    var taskBoxes: [TaskBox] = []
    var mermaid: [MermaidBlock] = []
    var tables: [TableBlock] = []
    var headings: [HeadingInfo] = []
    var htmlBlocks: [RawHTMLBlock] = []
    /// Top-level headings in document order, with every line each one occupies (`finish` turns them into fold regions).
    var foldHeadings: [(level: Int, lines: ClosedRange<Int>)] = []
    /// List items with content after their first paragraph: the header lines (the paragraph) and the item's last line.
    var foldItems: [(header: ClosedRange<Int>, last: Int)] = []
    /// Analysing a single table cell: inline markers keep their real reveal ranges instead of staying visible.
    var cellMode = false

    init(_ text: String) {
        original = text
        src = SourceText(text)
        lines = (0..<src.lineCount).map { i in
            LineStyle(range: NSRange(location: src.lineStarts[i], length: src.lineEnds[i] - src.lineStarts[i]),
                      contentEnd: src.lineContentEnds[i])
        }
    }

    // MARK: Driver

    mutating func run() {
        let masked = maskFrontMatter()
        let doc = Document(parsing: masked)
        for child in doc.children { walk(child, Context()) }
    }

    func finish() -> MarkdownAnalysis {
        // An image that is the whole content of its line gets a preview.
        var blocks: [ImageBlock] = []
        for img in images {
            let l = src.lineIndex(containing: img.range.location)
            guard lines[l].kind == .body, lines[l].quoteDepth == 0 else { continue }
            let content = lines[l].contentRange
            let before = src.string(NSRange(location: content.location, length: img.range.location - content.location))
            let after = src.string(NSRange(location: NSMaxRange(img.range), length: NSMaxRange(content) - NSMaxRange(img.range)))
            if before.allSatisfy({ $0 == " " || $0 == "\t" }) && after.allSatisfy({ $0 == " " || $0 == "\t" }) && !img.source.isEmpty {
                blocks.append(ImageBlock(line: l, range: img.range, alt: img.alt, source: img.source))
            }
        }
        return MarkdownAnalysis(
            length: src.length, spans: spans, markers: markers, lines: lines, links: links, images: images,
            taskBoxes: taskBoxes, mermaid: mermaid, tables: tables, headings: withPlainTitles(headings), imageBlocks: blocks,
            htmlBlocks: htmlBlocks, foldRegions: cellMode ? [] : foldRegions()
        )
    }

    /// The regions that can fold. A top-level heading hides everything up to the next top-level heading of the same or a
    /// higher level (or the end of the document); an item hides what follows its first paragraph. A region needs at least
    /// one non-blank hidden line. Two items that start on the same line (`- - a`) share an anchor, which is a fold's identity,
    /// so only the outer one is kept.
    private func foldRegions() -> [FoldRegion] {
        guard !foldHeadings.isEmpty || !foldItems.isEmpty else { return [] }
        // nonBlank[i] = number of non-blank lines before line i, so "any content in a..b" is two lookups.
        var nonBlank = [Int](repeating: 0, count: lines.count + 1)
        for i in lines.indices {
            var blank = true
            var p = src.lineStarts[i]
            while blank, p < src.lineContentEnds[i] { blank = src.isSpaceOrTab(p); p += 1 }
            nonBlank[i + 1] = nonBlank[i] + (blank ? 0 : 1)
        }
        var out: [FoldRegion] = []
        func add(_ kind: FoldRegion.Kind, header: ClosedRange<Int>, through last: Int) {
            guard header.upperBound < last, nonBlank[last + 1] - nonBlank[header.upperBound + 1] > 0 else { return }
            let hidden = (header.upperBound + 1)...last
            let first = lines[hidden.lowerBound].range, end = lines[hidden.upperBound].range
            out.append(FoldRegion(kind: kind, headerLines: header, hiddenLines: hidden, anchor: lines[header.lowerBound].range.location,
                                  hiddenRange: NSRange(location: first.location, length: NSMaxRange(end) - first.location)))
        }

        // Sections: a stack of open headings with strictly rising levels; a heading closes every open one that is as shallow or deeper.
        var open: [Int] = []
        for (i, h) in foldHeadings.enumerated() {
            while let top = open.last, foldHeadings[top].level >= h.level {
                add(.heading(level: foldHeadings[top].level), header: foldHeadings[top].lines, through: h.lines.lowerBound - 1)
                open.removeLast()
            }
            open.append(i)
        }
        for top in open.reversed() {
            add(.heading(level: foldHeadings[top].level), header: foldHeadings[top].lines, through: lines.count - 1)
        }
        for item in foldItems { add(.item, header: item.header, through: item.last) }

        out.sort { $0.anchor != $1.anchor ? $0.anchor < $1.anchor : $0.hiddenRange.length > $1.hiddenRange.length }
        var unique: [FoldRegion] = []
        for r in out where unique.last?.anchor != r.anchor { unique.append(r) }
        return unique
    }

    /// Fills in `HeadingInfo.plainTitle`: each heading line minus the marker ranges that fall on it.
    private func withPlainTitles(_ headings: [HeadingInfo]) -> [HeadingInfo] {
        guard !headings.isEmpty else { return headings }
        let sorted = markers.sorted { $0.range.location < $1.range.location }
        return headings.map { h in
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid].range.location < h.range.location { lo = mid + 1 } else { hi = mid }
            }
            let end = NSMaxRange(h.range)
            var visible: [UInt16] = []
            var p = h.range.location
            var i = lo
            var sawHeadingMarker = false
            while i < sorted.count, sorted[i].range.location < end {
                let m = sorted[i].range
                if sorted[i].flags.contains(.headingMarker) { sawHeadingMarker = true }
                if m.location > p { visible += src.units[p..<m.location] }
                p = max(p, min(NSMaxRange(m), end))
                i += 1
            }
            if p < end { visible += src.units[p..<end] }
            var title = String(decoding: visible, as: UTF16.self).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !sawHeadingMarker {
                // `# Title` inside a quote or list item is not marked up as an ATX heading; drop its syntax here.
                title = title.replacingOccurrences(of: "^(?:(?:[-*+]|[0-9]{1,9}[.)])\\s+)*(?:#{1,6}(?:\\s+|$))?", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+#+$", with: "", options: .regularExpression)
            }
            var out = h
            out.plainTitle = title
            return out
        }
    }

    /// YAML front matter (`---` … `---` at the very top) is blanked out before parsing so cmark does not
    /// see a thematic break / setext heading, while line numbers stay intact.
    private mutating func maskFrontMatter() -> String {
        guard let end = FrontMatter.endLine(in: src) else { return original }
        var units = src.units
        for l in 0...end {
            for p in src.lineStarts[l]..<src.lineContentEnds[l] { units[p] = 32 }
            lines[l].kind = .frontMatter
        }
        let r = NSRange(location: 0, length: src.lineContentEnds[end])
        spans.append(FormatSpan(range: r, flags: .frontMatter))
        return String(decoding: units, as: UTF16.self)
    }

    private func content(_ line: Int) -> String {
        src.string(NSRange(location: src.lineStarts[line], length: src.lineContentEnds[line] - src.lineStarts[line]))
    }

    // MARK: Helpers

    private func range(of node: Markup) -> NSRange? {
        guard let r = node.range else { return nil }
        let s = src.offset(line: r.lowerBound.line, column: r.lowerBound.column)
        let e = src.offset(line: r.upperBound.line, column: r.upperBound.column)
        return NSRange(location: s, length: max(0, e - s))
    }

    private func lineSpan(_ r: NSRange) -> ClosedRange<Int> {
        let a = src.lineIndex(containing: r.location)
        let b = src.lineIndex(containing: max(r.location, NSMaxRange(r) - 1))
        return a...max(a, b)
    }

    private func firstNonSpace(line: Int) -> Int {
        var p = src.lineStarts[line]
        let end = src.lineContentEnds[line]
        while p < end && src.isSpaceOrTab(p) { p += 1 }
        return p
    }

    private mutating func addMarker(_ r: NSRange, reveal: NSRange, flags: StyleFlags = []) {
        guard r.length > 0 else { return }
        markers.append(Marker(range: r, reveal: reveal, flags: flags))
    }

    private mutating func addSpan(_ r: NSRange, _ f: StyleFlags) {
        guard r.length > 0 else { return }
        spans.append(FormatSpan(range: r, flags: f))
    }

    private func lineReveal(_ line: Int) -> NSRange {
        NSRange(location: src.lineStarts[line], length: src.lineContentEnds[line] - src.lineStarts[line])
    }

    // MARK: Blocks

    private mutating func walk(_ node: Markup, _ ctx: Context) {
        switch node {
        case let h as Heading: heading(h, ctx)
        case let p as Paragraph: paragraph(p, ctx)
        case let q as BlockQuote: blockQuote(q, ctx)
        case let c as CodeBlock: codeBlock(c, ctx)
        case is ThematicBreak: thematicBreak(node)
        case let li as ListItem: listItem(li, ctx)
        case is UnorderedList, is OrderedList:
            var inner = ctx; inner.listDepth += 1
            for c in node.children { walk(c, inner) }
        case let t as Table: table(t, ctx)
        case is HTMLBlock: htmlBlock(node, ctx)
        default:
            for c in node.children { walk(c, ctx) }
        }
    }

    private mutating func heading(_ h: Heading, _ ctx: Context) {
        guard let r = range(of: h) else { return }
        let ls = lineSpan(r)
        let l0 = ls.lowerBound
        var p = firstNonSpace(line: l0)
        let end = src.lineContentEnds[l0]
        if p < end, src.units[p] == 35 {            // ATX
            let hashStart = p
            while p < end && src.units[p] == 35 { p += 1 }
            var q = p
            while q < end && src.isSpaceOrTab(q) { q += 1 }
            let reveal = lineReveal(l0)
            addMarker(NSRange(location: hashStart, length: q - hashStart), reveal: reveal, flags: .headingMarker)
            // Optional closing sequence: ` ###`
            var e = end
            while e > q && src.isSpaceOrTab(e - 1) { e -= 1 }
            var h0 = e
            while h0 > q && src.units[h0 - 1] == 35 { h0 -= 1 }
            if h0 < e, h0 > q, src.isSpaceOrTab(h0 - 1) {
                var s = h0 - 1
                while s > q && src.isSpaceOrTab(s - 1) { s -= 1 }
                addMarker(NSRange(location: s, length: end - s), reveal: reveal, flags: .headingMarker)
            }
            lines[l0].kind = .heading(h.level)
        } else {                                      // Setext
            for l in ls { lines[l].kind = .heading(h.level) }
            if ls.count > 1 {
                let u = ls.upperBound
                lines[u].kind = .setextUnderline
                addSpan(lines[u].contentRange, .dim)
            }
        }
        inlineContent(of: h)
        let titleRange = NSRange(location: src.lineStarts[l0], length: src.lineContentEnds[l0] - src.lineStarts[l0])
        let title = src.string(titleRange).replacingOccurrences(of: "^\\s*#{1,6}\\s*|\\s+#+\\s*$", with: "", options: .regularExpression)
        headings.append(HeadingInfo(level: h.level, title: title, range: titleRange))
        // Only top-level headings fold; one inside a quote or a list item neither folds nor ends the enclosing section.
        if ctx.quoteDepth == 0, ctx.listDepth == 0 { foldHeadings.append((h.level, headingLines(ls))) }
    }

    /// The lines a heading really occupies. For a setext heading directly followed by text, cmark's range runs over that next
    /// line as well, so its last line is taken to be the first line that is nothing but `=` or `-`.
    private func headingLines(_ ls: ClosedRange<Int>) -> ClosedRange<Int> {
        let first = firstNonSpace(line: ls.lowerBound)
        guard ls.count > 1, !(first < src.lineContentEnds[ls.lowerBound] && src.units[first] == 35) else { return ls }
        for l in (ls.lowerBound + 1)...ls.upperBound where isSetextUnderline(l) { return ls.lowerBound...l }
        return ls
    }

    private func isSetextUnderline(_ l: Int) -> Bool {
        var p = src.lineStarts[l]
        let end = src.lineContentEnds[l]
        var indent = 0
        while p < end, src.units[p] == 32, indent < 3 { p += 1; indent += 1 }
        guard p < end, src.units[p] == 61 || src.units[p] == 45 else { return false }
        let c = src.units[p]
        while p < end, src.units[p] == c { p += 1 }
        while p < end, src.isSpaceOrTab(p) { p += 1 }
        return p == end
    }

    private mutating func paragraph(_ p: Paragraph, _ ctx: Context) {
        inlineContent(of: p)
    }

    private mutating func blockQuote(_ q: BlockQuote, _ ctx: Context) {
        if let r = range(of: q) {
            for l in lineSpan(r) {
                lines[l].quoteDepth = ctx.quoteDepth + 1
                if ctx.quoteDepth == 0 { quoteMarkers(line: l) }
            }
            addSpan(r, .quote)
        }
        var inner = ctx; inner.quoteDepth += 1
        for c in q.children { walk(c, inner) }
    }

    private mutating func quoteMarkers(line l: Int) {
        var p = src.lineStarts[l]
        let end = src.lineContentEnds[l]
        let reveal = lineReveal(l)
        while true {
            var q = p, spaces = 0
            while q < end && src.units[q] == 32 && spaces < 3 { q += 1; spaces += 1 }
            guard q < end, src.units[q] == 62 else { break }
            var e = q + 1
            if e < end && src.units[e] == 32 { e += 1 }
            addMarker(NSRange(location: q, length: e - q), reveal: reveal, flags: .quote)
            p = e
        }
    }

    private mutating func codeBlock(_ c: CodeBlock, _ ctx: Context) {
        guard let r = range(of: c) else { return }
        let ls = lineSpan(r)
        let l0 = ls.lowerBound, l1 = ls.upperBound
        let first = firstNonSpace(line: l0)
        let end0 = src.lineContentEnds[l0]
        var fenceChar: UInt16 = 0, fenceLen = 0
        if first < end0, src.units[first] == 96 || src.units[first] == 126 {
            fenceChar = src.units[first]
            var q = first
            while q < end0 && src.units[q] == fenceChar { q += 1 }
            fenceLen = q - first
        }
        addSpan(NSRange(location: src.lineStarts[l0], length: src.lineContentEnds[l1] - src.lineStarts[l0]), .codeBlock)
        guard fenceLen >= 3 else {                      // indented code block
            for l in ls { lines[l].kind = .codeBlock }
            return
        }
        let reveal = NSRange(location: src.lineStarts[l0], length: src.lineContentEnds[l1] - src.lineStarts[l0])
        lines[l0].kind = .fence
        addMarker(NSRange(location: first, length: end0 - first), reveal: reveal, flags: .fence)
        var closed = false
        if l1 > l0 {
            let cf = firstNonSpace(line: l1), ce = src.lineContentEnds[l1]
            var q = cf
            while q < ce && src.units[q] == fenceChar { q += 1 }
            var t = q
            while t < ce && src.isSpaceOrTab(t) { t += 1 }
            if q - cf >= fenceLen && t == ce && cf < ce {
                closed = true
                lines[l1].kind = .fence
                addMarker(NSRange(location: cf, length: ce - cf), reveal: reveal, flags: .fence)
            }
        }
        let innerEnd = closed ? l1 - 1 : l1
        if innerEnd >= l0 + 1 { for l in (l0 + 1)...innerEnd { lines[l].kind = .codeBlock } }

        let lang = (c.language ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first.map(String.init) ?? ""
        if lang.lowercased() == "mermaid" {
            var codeLines: [String] = []
            if innerEnd >= l0 + 1 { for l in (l0 + 1)...innerEnd { codeLines.append(content(l)) } }
            mermaid.append(MermaidBlock(range: reveal, source: codeLines.joined(separator: "\n"),
                                        firstLine: l0, lastLine: closed ? l1 : l1))
        }
    }

    private mutating func thematicBreak(_ node: Markup) {
        guard let r = range(of: node) else { return }
        let l = lineSpan(r).lowerBound
        lines[l].kind = .hr
        let first = firstNonSpace(line: l)
        addSpan(lines[l].contentRange, .hr)
        addMarker(NSRange(location: first, length: src.lineContentEnds[l] - first), reveal: lineReveal(l), flags: .hr)
    }

    private mutating func htmlBlock(_ node: Markup, _ ctx: Context) {
        guard let r = range(of: node) else { return }
        let ls = lineSpan(r)
        for l in ls { lines[l].kind = .html }
        addSpan(NSRange(location: src.lineStarts[ls.lowerBound], length: NSMaxRange(r) - src.lineStarts[ls.lowerBound]), .html)
        // Top-level blocks that draw something are also rendered as a card (nested ones keep showing their source, like tables).
        guard !cellMode, ctx.quoteDepth == 0, ctx.listDepth == 0 else { return }
        let whole = NSRange(location: src.lineStarts[ls.lowerBound], length: src.lineContentEnds[ls.upperBound] - src.lineStarts[ls.lowerBound])
        let source = src.string(whole)
        guard HTMLSupport.isRenderable(source) else { return }
        htmlBlocks.append(RawHTMLBlock(range: whole, source: source, firstLine: ls.lowerBound, lastLine: ls.upperBound))
    }

    private mutating func listItem(_ li: ListItem, _ ctx: Context) {
        guard let r = range(of: li) else { for c in li.children { walk(c, ctx) }; return }
        let ls = lineSpan(r)
        let l0 = ls.lowerBound
        // The header of a fold is the item's first paragraph (every line it wraps over); the rest of the item hides.
        var headerLast = l0
        if let first = li.child(at: 0) as? Paragraph, let pr = range(of: first) { headerLast = min(max(l0, lineSpan(pr).upperBound), ls.upperBound) }
        if ls.upperBound > headerLast { foldItems.append((l0...headerLast, ls.upperBound)) }
        let start = src.lineStarts[l0], end = src.lineContentEnds[l0]
        var p = start
        while p < end && src.isSpaceOrTab(p) { p += 1 }
        let tokenStart = p
        if p < end, [42, 43, 45].contains(src.units[p]) {
            p += 1
        } else {
            var q = p
            while q < end && src.units[q] >= 48 && src.units[q] <= 57 && q - p < 9 { q += 1 }
            if q > p, q < end, src.units[q] == 46 || src.units[q] == 41 { p = q + 1 }
        }
        if p > tokenStart {
            let isBullet = p - tokenStart == 1 && [42, 43, 45].contains(src.units[tokenStart])
            addSpan(NSRange(location: tokenStart, length: p - tokenStart), isBullet ? [.listMarker, .bullet] : .listMarker)
            var q = p
            while q < end && src.isSpaceOrTab(q) { q += 1 }
            if q - p > 4 { q = p + 1 }
            var prefix = q - start
            if li.checkbox != nil, q + 2 < end, src.units[q] == 91, src.units[q + 2] == 93 {
                let checked = li.checkbox == .checked
                let box = NSRange(location: q, length: 3)
                addSpan(box, .task)
                var after = q + 3
                while after < end && src.isSpaceOrTab(after) { after += 1 }
                prefix = after - start
                // A bulleted task is drawn as a checkbox: its whole `- [ ] ` prefix hides as one marker, and shows its source
                // only while the caret is *inside* it (so a caret at the start of the item's text, where you type, never reveals it).
                var taskPrefix: NSRange?
                if isBullet {
                    let whole = NSRange(location: tokenStart, length: after - tokenStart)
                    taskPrefix = whole
                    addMarker(whole, reveal: NSRange(location: whole.location + 1, length: max(0, whole.length - 2)), flags: .taskPrefix)
                }
                taskBoxes.append(TaskBox(range: box, checked: checked, prefix: taskPrefix))
                if checked { addSpan(NSRange(location: after, length: end - after), .taskDone) }
            }
            for l in ls {
                lines[l].listDepth = ctx.listDepth
                if l == l0 {
                    lines[l].listPrefixLength = prefix
                    lines[l].isListStart = true
                } else {
                    var w = src.lineStarts[l]
                    while w < src.lineContentEnds[l] && src.isSpaceOrTab(w) { w += 1 }
                    lines[l].listPrefixLength = min(w - src.lineStarts[l], prefix)
                    lines[l].isListStart = false
                }
            }
        }
        for c in li.children { walk(c, ctx) }
    }

    private mutating func table(_ t: Table, _ ctx: Context) {
        guard let r = range(of: t) else { return }
        let ls = lineSpan(r)
        guard ls.count >= 2 else { return }
        for l in ls {
            lines[l].kind = l == ls.lowerBound ? .tableHeader : (l == ls.lowerBound + 1 ? .tableDelimiter : .tableRow)
            var f: StyleFlags = [.table]
            if l == ls.lowerBound { f.insert(.tableHeader) }
            if l == ls.lowerBound + 1 { f.insert(.tableDelimiter) }
            addSpan(lines[l].contentRange, f)
            var i = src.lineStarts[l]
            let e = src.lineContentEnds[l]
            while i < e {
                if src.units[i] == 124, i == src.lineStarts[l] || src.units[i - 1] != 92 {
                    addSpan(NSRange(location: i, length: 1), .dim)
                }
                i += 1
            }
        }
        var block = TableBlock(range: NSRange(location: src.lineStarts[ls.lowerBound],
                                              length: src.lineContentEnds[ls.upperBound] - src.lineStarts[ls.lowerBound]),
                               firstLine: ls.lowerBound, lastLine: ls.upperBound)
        // Top-level tables are edited as a grid; the model must agree with what cmark parsed, otherwise fall back to source.
        if !cellMode, ctx.quoteDepth == 0, ctx.listDepth == 0,
           let parsed = TableModel.parse(lines: ls.map { content($0) }),
           parsed.model.columnCount == t.head.childCount, parsed.model.rowCount == 1 + t.body.childCount {
            block.model = parsed.model
            block.cellRanges = parsed.cellRanges.enumerated().map { (r, row) in
                let start = src.lineStarts[ls.lowerBound + (r == 0 ? 0 : r + 1)]
                return row.map { NSRange(location: start + $0.lowerBound, length: $0.count) }
            }
        }
        tables.append(block)
        // Inline formatting inside cells. In the source view markers stay visible: hiding them would shift the
        // monospaced columns. (Cells of the grid are analysed on their own and do hide them.)
        let firstMarker = markers.count
        for cell in t.head.children { inlineContent(of: cell) }
        for row in t.body.children { for cell in row.children { inlineContent(of: cell) } }
        guard !cellMode else { return }
        let always = NSRange(location: 0, length: src.length)
        for i in firstMarker..<markers.count { markers[i].reveal = always }
    }

    // MARK: Inline

    private mutating func inlineContent(of container: Markup) {
        var protected: [NSRange] = []
        inline(container, &protected, parent: nil)
        guard let cr = range(of: container), cr.length > 0 else { return }
        extensions(in: cr, protected: protected)
    }

    /// A delimited parent (emphasis/strong/strike): cmark reports wrong ranges when nested nodes share a delimiter
    /// run (`***x***`), so children that share an edge are shifted inward by the parent's delimiter width.
    private struct Parent {
        var reported: NSRange
        var effective: NSRange
        var open: Int
    }

    private func effective(_ r: NSRange, in parent: Parent?) -> NSRange {
        guard let p = parent, p.open > 0 else { return r }
        var s = r.location, e = NSMaxRange(r)
        if r.location == p.reported.location { s = p.effective.location + p.open }
        if NSMaxRange(r) == NSMaxRange(p.reported) { e = NSMaxRange(p.effective) - p.open }
        return NSRange(location: s, length: max(0, e - s))
    }

    private mutating func inline(_ node: Markup, _ protected: inout [NSRange], parent: Parent?) {
        // Inline HTML tags that are open at this level, waiting for their closing tag (see `htmlTag`).
        var openTags: [(tag: HTMLSupport.Tag, range: NSRange)] = []
        for child in node.children {
            let reported = range(of: child)
            switch child {
            case is Emphasis, is Strong, is Strikethrough:
                guard let reported else { inline(child, &protected, parent: nil); continue }
                let eff = effective(reported, in: parent)
                var open = child is Strong ? 2 : 1
                var flags: StyleFlags = child is Strong ? .bold : .italic
                if child is Strikethrough {
                    flags = .strike
                    open = 0
                    while eff.location + open < NSMaxRange(eff), src.units[eff.location + open] == 126, open < 2 { open += 1 }
                    open = max(1, open)
                }
                delimited(eff, openLen: open, flags: flags, reveal: eff)
                inline(child, &protected, parent: Parent(reported: reported, effective: eff, open: open))
            case is InlineCode:
                if let r = reported {
                    var n = 0
                    while r.location + n < NSMaxRange(r), src.units[r.location + n] == 96 { n += 1 }
                    delimited(r, openLen: max(1, n), flags: .code, reveal: r)
                    protected.append(r)
                }
            case let l as Link:
                if let r = reported { link(l, r, &protected) } else { inline(child, &protected, parent: nil) }
            case let i as Image:
                if let r = reported {
                    let (head, tail) = linkDelimiters(child, r)
                    addSpan(r, .image)
                    addMarker(head, reveal: r, flags: .image)
                    addMarker(tail, reveal: r, flags: .image)
                    images.append(ImageSpan(range: r, alt: i.plainText, source: i.source ?? ""))
                    protected.append(tail)
                }
                inline(child, &protected, parent: nil)
            case is InlineHTML:
                if let r = reported { htmlTag(r, &openTags); protected.append(r) }
            default:
                inline(child, &protected, parent: nil)
            }
        }
        for open in openTags { addSpan(open.range, .html) }          // never closed: stays visible source
    }

    /// What an inline HTML tag pair means for the editor, for the tags that have a Markdown-style equivalent.
    private static func flags(forTag tag: HTMLSupport.Tag) -> StyleFlags? {
        switch tag.name {
        case "b", "strong": return .bold
        case "i", "em": return .italic
        case "s", "del", "strike": return .strike
        case "u", "ins": return .underline
        case "mark": return .highlight
        case "code", "kbd", "samp": return .code
        case "sub": return .sub
        case "sup": return .sup
        case "a": return (tag.attributes["href"] ?? "").isEmpty ? nil : .link
        default: return nil
        }
    }

    /// One `InlineHTML` node, which is a single tag. An opening tag of a supported element waits in `openTags` for the closing
    /// tag at the same level; the pair then styles the text between them and hides like `**` does — both tags are markers that
    /// show while the caret is anywhere in the pair. Everything else (other elements, `<br>`, strays, never-closed tags)
    /// stays visible source in the dim HTML style.
    private mutating func htmlTag(_ r: NSRange, _ openTags: inout [(tag: HTMLSupport.Tag, range: NSRange)]) {
        guard let tag = HTMLSupport.parseTag(src.string(r)), !tag.isSelfClosing, Self.flags(forTag: tag) != nil || tag.isClosing else {
            addSpan(r, .html)
            return
        }
        if !tag.isClosing {
            openTags.append((tag, r))
            return
        }
        guard let i = openTags.lastIndex(where: { $0.tag.name == tag.name }) else {
            addSpan(r, .html)
            return
        }
        let open = openTags[i]
        for later in openTags[(i + 1)...] { addSpan(later.range, .html) }       // opened inside the pair, never closed
        openTags.removeSubrange(i...)
        let whole = NSRange(location: open.range.location, length: NSMaxRange(r) - open.range.location)
        let content = NSRange(location: NSMaxRange(open.range), length: r.location - NSMaxRange(open.range))
        guard let flags = Self.flags(forTag: open.tag) else { return }
        addSpan(content, flags)
        addMarker(open.range, reveal: whole)
        addMarker(r, reveal: whole)
        if flags == .link, content.length > 0, let href = open.tag.attributes["href"] {
            links.append(LinkSpan(range: whole, textRange: content, destination: href))
        }
    }

    private mutating func delimited(_ r: NSRange, openLen: Int, flags: StyleFlags, reveal: NSRange) {
        guard r.length >= openLen * 2 else { return }
        addSpan(r, flags)
        // Closing delimiter can be shorter than the opening one for odd `***a***` nesting; use the symmetric length.
        addMarker(NSRange(location: r.location, length: openLen), reveal: reveal)
        addMarker(NSRange(location: NSMaxRange(r) - openLen, length: openLen), reveal: reveal)
    }

    /// Opening `[`/`![` and closing `](dest)` of a link or image, derived from its children.
    private func linkDelimiters(_ node: Markup, _ r: NSRange) -> (NSRange, NSRange) {
        var firstStart = r.location, lastEnd = NSMaxRange(r)
        let kids = Array(node.children)
        if let f = kids.first, let fr = range(of: f), let l = kids.last, let lr = range(of: l) {
            firstStart = fr.location; lastEnd = NSMaxRange(lr)
        } else {
            // Empty text: `[]( … )` — opening bracket is 1 (or 2 for images) chars.
            firstStart = r.location + (node is Image ? 2 : 1); lastEnd = firstStart
        }
        firstStart = max(r.location, min(firstStart, NSMaxRange(r)))
        lastEnd = max(firstStart, min(lastEnd, NSMaxRange(r)))
        return (NSRange(location: r.location, length: firstStart - r.location),
                NSRange(location: lastEnd, length: NSMaxRange(r) - lastEnd))
    }

    private mutating func link(_ l: Link, _ r: NSRange, _ protected: inout [NSRange]) {
        let (head, tail) = linkDelimiters(l, r)
        let textRange = NSRange(location: NSMaxRange(head), length: max(0, tail.location - NSMaxRange(head)))
        addSpan(textRange.length > 0 ? textRange : r, .link)
        if head.length > 0 || tail.length > 0 {
            addMarker(head, reveal: r, flags: .link)
            addMarker(tail, reveal: r, flags: .link)
            protected.append(tail)
        }
        links.append(LinkSpan(range: r, textRange: textRange.length > 0 ? textRange : r, destination: l.destination ?? ""))
        inline(l, &protected, parent: nil)
    }

    // MARK: Extensions (highlight, footnotes, math)

    private static let footnoteRE = try! NSRegularExpression(pattern: "\\[\\^[^\\]\\s]+\\]:?")
    private static let mathInlineRE = try! NSRegularExpression(pattern: "(?<![\\\\$])\\$(?![\\s$])([^$\\n]+?)(?<![\\s\\\\])\\$(?![\\d$])")
    private static let mathBlockRE = try! NSRegularExpression(pattern: "\\$\\$(.+?)\\$\\$", options: [.dotMatchesLineSeparators])

    private mutating func extensions(in container: NSRange, protected: [NSRange]) {
        var units = Array(src.units[container.location..<NSMaxRange(container)])
        for p in protected {
            let a = max(container.location, p.location), b = min(NSMaxRange(container), NSMaxRange(p))
            if b > a { for i in a..<b { units[i - container.location] = 1 } }
        }
        let s = String(decoding: units, as: UTF16.self)
        let whole = NSRange(location: 0, length: s.utf16.count)
        func shift(_ r: NSRange) -> NSRange { NSRange(location: r.location + container.location, length: r.length) }

        for m in InlineExtensions.highlight.matches(in: s, range: whole) {
            let r = shift(m.range)
            addSpan(r, .highlight)
            addMarker(NSRange(location: r.location, length: 2), reveal: r)
            addMarker(NSRange(location: NSMaxRange(r) - 2, length: 2), reveal: r)
        }
        for m in InlineExtensions.bareURL.matches(in: s, range: whole) {
            let r = shift(m.range)
            let overlapsLink = links.contains { NSIntersectionRange($0.range, r).length > 0 }
            let inProtected = protected.contains { NSIntersectionRange($0, r).length > 0 }
            guard !overlapsLink, !inProtected else { continue }
            let text = src.string(r)
            addSpan(r, .link)
            links.append(LinkSpan(range: r, textRange: r, destination: InlineExtensions.destination(forBareURL: text)))
        }
        for m in Self.footnoteRE.matches(in: s, range: whole) { addSpan(shift(m.range), .footnote) }
        for m in Self.mathBlockRE.matches(in: s, range: whole) { addSpan(shift(m.range), .math) }
        for m in Self.mathInlineRE.matches(in: s, range: whole) { addSpan(shift(m.range), .math) }
    }
}
