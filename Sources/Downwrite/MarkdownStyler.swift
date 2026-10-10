import AppKit
import DownwriteCore

/// Extra, non-textual state the styler needs: how tall each preview card is and which source blocks are collapsed.
struct PreviewState {
    /// Reserved height below a preview block (diagram or image), keyed by the block's first line.
    var heights: [Int: CGFloat] = [:]
    /// Preview blocks whose source is collapsed (caret outside), keyed by first line.
    var collapsed: Set<Int> = []
    /// Source lines hidden by folds.
    var folded = FoldedLines()
    /// The foldable headers that are on screen (not hidden by another fold), keyed by *every* line of the header: the chevron
    /// goes on its first line and the chip on its last.
    var foldHeaders: [Int: FoldHeader] = [:]
}

/// Source lines hidden by folds, as sorted, merged ranges, so "is this line hidden?" is a binary search.
struct FoldedLines: Equatable {
    private(set) var ranges: [ClosedRange<Int>] = []

    init(_ ranges: [ClosedRange<Int>] = []) { self.ranges = ranges }

    var isEmpty: Bool { ranges.isEmpty }

    func contains(_ line: Int) -> Bool {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound < line { lo = mid + 1 } else { hi = mid }
        }
        return lo < ranges.count && ranges[lo].lowerBound <= line
    }

    /// The lines hidden in exactly one of the two sets, as sorted ranges: what a fold change has to restyle. Each set is a
    /// list of disjoint ranges, so every range edge is a point where membership flips; edges both sets share cancel out, and
    /// what is left alternates between entering and leaving the difference.
    func symmetricDifference(_ other: FoldedLines) -> [ClosedRange<Int>] {
        var edges: [Int] = []
        for r in ranges + other.ranges { edges.append(r.lowerBound); edges.append(r.upperBound + 1) }
        edges.sort()
        var flips: [Int] = []
        var i = 0
        while i < edges.count {
            var j = i
            while j < edges.count, edges[j] == edges[i] { j += 1 }
            if (j - i) % 2 == 1 { flips.append(edges[i]) }
            i = j
        }
        return stride(from: 0, to: flips.count - 1, by: 2).map { flips[$0]...(flips[$0 + 1] - 1) }
    }
}

/// How one visible foldable header is drawn.
struct FoldHeader: Equatable {
    var firstLine: Int
    var lastLine: Int
    var folded: Bool
    /// The selection covers some of the hidden text (the chip shows it).
    var covered: Bool
}

extension PreviewState {
    /// Takes the folds into account: which lines are hidden and which headers show a chevron (and a chip). A foldable header
    /// that another fold hides shows neither.
    mutating func setFolds(_ state: FoldState, analysis: MarkdownAnalysis, selection: NSRange) {
        folded = FoldedLines(state.hiddenLineRanges(in: analysis))
        foldHeaders = [:]
        for region in analysis.foldRegions where !folded.contains(region.headerLines.lowerBound) {
            let isFolded = state.isFolded(region)
            let header = FoldHeader(firstLine: region.headerLines.lowerBound, lastLine: region.headerLines.upperBound, folded: isFolded,
                                    covered: isFolded && NSIntersectionRange(selection, region.hiddenRange).length > 0)
            for line in region.headerLines { foldHeaders[line] = header }
        }
    }
}

/// Applies a `MarkdownAnalysis` to an `NSTextStorage` as attributes. All hiding of Markdown syntax happens here:
/// a hidden marker gets a ~zero-size clear font, so its characters stay in the document (copy/paste, undo and
/// find keep working) but take no space.
final class MarkdownStyler {
    let typography: Typography
    var palette: Palette
    private let hiddenFont = NSFont.systemFont(ofSize: 0.1)

    /// Line height of the lines a fold hides. Only the line height decides how much room a collapsed line leaves (the font
    /// size makes no difference), and the 0.1 pt used for collapsed sources leaves 0.1 pt per line — 100 pt for a
    /// 1,000-line section. 0.001 pt leaves 1 pt per 1,000 lines, which is the limit of R5; `FoldTests` measure it in the editor.
    static let foldedLineHeight: CGFloat = 0.001

    init(typography: Typography, palette: Palette) {
        self.typography = typography
        self.palette = palette
    }

    // MARK: Entry points

    func styleAll(storage: NSTextStorage, analysis: MarkdownAnalysis, selection: NSRange, preview: PreviewState) {
        guard storage.length > 0 else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        // Reset to the base look first so characters outside any line (e.g. a trailing empty line) are sane.
        storage.setAttributes(baseAttributes(), range: all)
        let runs = analysis.runs(in: all, selection: selection)
        var cursor = 0
        for index in analysis.lines.indices {
            let line = analysis.lines[index]
            guard line.range.length > 0 else { continue }
            // Advance past runs that end before this line.
            while cursor < runs.count, NSMaxRange(runs[cursor].range) <= line.range.location { cursor += 1 }
            var end = cursor
            while end < runs.count, runs[end].range.location < NSMaxRange(line.range) { end += 1 }
            applyLine(index, analysis: analysis, runs: runs[cursor..<end], storage: storage, preview: preview, selection: selection)
        }
        storage.endEditing()
    }

    /// Re-styles only the given lines (used when the caret moves and markers show/hide, and when a fold opens or closes).
    /// Consecutive lines are styled together: `runs` scans every span and marker, so doing it per line would make a section of
    /// a few thousand lines quadratic. Lines that a fold hides need no runs at all, and when many separate visible lines are
    /// restyled at once (Fold All leaves a header per section) one `runs` computation serves them all.
    func style(lines: Set<Int>, storage: NSTextStorage, analysis: MarkdownAnalysis, selection: NSRange, preview: PreviewState) {
        guard !lines.isEmpty, storage.length > 0 else { return }
        let sorted = lines.sorted().filter { $0 < analysis.lines.count }
        var shared: [StyleRun]?
        let visible = sorted.filter { !preview.folded.contains($0) }
        if visible.count > 8, let first = visible.first, let last = visible.last {
            let from = analysis.lines[first].range.location, to = min(storage.length, NSMaxRange(analysis.lines[last].range))
            if to > from { shared = analysis.runs(in: NSRange(location: from, length: to - from), selection: selection) }
        }
        storage.beginEditing()
        var i = 0
        while i < sorted.count {
            let hidden = preview.folded.contains(sorted[i])
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1, preview.folded.contains(sorted[j + 1]) == hidden { j += 1 }
            styleGroup(sorted[i...j], hidden: hidden, shared: shared, storage: storage, analysis: analysis, selection: selection, preview: preview)
            i = j + 1
        }
        storage.endEditing()
    }

    /// Consecutive lines that are all hidden by folds, or all visible; the visible ones share one `runs` computation.
    private func styleGroup(_ group: ArraySlice<Int>, hidden: Bool, shared: [StyleRun]?, storage: NSTextStorage, analysis: MarkdownAnalysis,
                            selection: NSRange, preview: PreviewState) {
        // Every hidden line gets the same look, so a stretch of them is set in one go (with one shared paragraph style).
        if hidden, let first = group.first, let last = group.last {
            let from = analysis.lines[first].range.location
            let to = min(storage.length, NSMaxRange(analysis.lines[last].range))
            if to > from { storage.setAttributes(collapsedAttributes(), range: NSRange(location: from, length: to - from)) }
            return
        }
        var runs: [StyleRun] = shared ?? []
        if shared == nil, let first = group.first, let last = group.last {
            let from = analysis.lines[first].range.location
            let to = min(storage.length, NSMaxRange(analysis.lines[last].range))
            if to > from { runs = analysis.runs(in: NSRange(location: from, length: to - from), selection: selection) }
        }
        // Runs are sorted and do not overlap: find the first one that reaches this group (a binary search in the shared list).
        var cursor = 0
        if shared != nil, let first = group.first {
            let start = analysis.lines[first].range.location
            var lo = 0, hi = runs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(runs[mid].range) <= start { lo = mid + 1 } else { hi = mid }
            }
            cursor = lo
        }
        for index in group {
            let line = analysis.lines[index]
            guard line.range.length > 0, NSMaxRange(line.range) <= storage.length else { continue }
            while cursor < runs.count, NSMaxRange(runs[cursor].range) <= line.range.location { cursor += 1 }
            var end = cursor
            while end < runs.count, runs[end].range.location < NSMaxRange(line.range) { end += 1 }
            applyLine(index, analysis: analysis, runs: runs[cursor..<end], storage: storage, preview: preview, selection: selection)
        }
    }

    // MARK: Table cells

    /// Font size of grid-table cell text (a little under body text so tables stay compact).
    var cellFontSize: CGFloat { typography.size * 0.94 }

    /// Height of one line of cell text, used for empty cells and as the minimum row height.
    var cellLineHeight: CGFloat {
        let f = typography.font(size: cellFontSize)
        return ceil((f.ascender - f.descender + f.leading) * 1.25)
    }

    func cellBaseAttributes(header: Bool, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.25
        p.alignment = alignment
        p.lineBreakMode = .byWordWrapping
        return [.font: typography.font(size: cellFontSize, bold: header), .foregroundColor: palette.text.nsColor, .paragraphStyle: p]
    }

    /// Styles the text storage of one grid cell from the cell's own inline analysis (`MarkdownAnalyzer.analyzeTableCell`).
    /// Markers hide and reveal exactly like in the main editor.
    func styleCell(storage: NSTextStorage, analysis: MarkdownAnalysis, selection: NSRange, header: Bool, alignment: NSTextAlignment) {
        let all = NSRange(location: 0, length: storage.length)
        guard all.length > 0, analysis.length == all.length, let line = analysis.lines.first else { return }
        let base = cellBaseAttributes(header: header, alignment: alignment)
        var look = LineLook(size: cellFontSize, color: palette.text.nsColor)
        look.bold = header
        storage.beginEditing()
        storage.setAttributes(base, range: all)
        for run in analysis.runs(in: all, selection: selection) {
            let attrs = runAttributes(run.flags, line: line, look: look)
            if !attrs.isEmpty { storage.addAttributes(attrs, range: run.range) }
        }
        storage.endEditing()
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = typography.lineHeight
        return [.font: typography.font(), .foregroundColor: palette.text.nsColor, .paragraphStyle: p]
    }

    // MARK: Source view

    /// The source view's look: the whole document in one plain monospaced style — nothing hidden, no cards, pills, bars,
    /// rules or checkboxes.
    func sourceAttributes() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = typography.lineHeight
        return [.font: typography.font(size: (typography.size * 0.92).rounded(), mono: true), .foregroundColor: palette.text.nsColor, .paragraphStyle: p]
    }

    func styleSource(storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(sourceAttributes(), range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    // MARK: Per-line styling

    private struct LineLook {
        var size: CGFloat
        var bold = false
        var mono = false
        var color: NSColor
        var paragraph = NSMutableParagraphStyle()
        var extra: [NSAttributedString.Key: Any] = [:]
    }

    private func applyLine(_ index: Int, analysis: MarkdownAnalysis, runs: ArraySlice<StyleRun>,
                           storage: NSTextStorage, preview: PreviewState, selection: NSRange) {
        let line = analysis.lines[index]
        let r = line.range
        // A line a fold hides shows nothing (no text, checkbox, pill, bar or card) and takes next to no room.
        if preview.folded.contains(index) {
            storage.setAttributes(collapsedAttributes(), range: r)
            return
        }
        // A bulleted task whose `- [ ] ` source is hidden is drawn as a checkbox instead.
        let task = hiddenTask(onLine: index, analysis: analysis, runs: runs)
        var look = lineLook(line, index: index, analysis: analysis, storage: storage, preview: preview, hiddenTask: task)

        // Whole-line collapsing: hidden fences, collapsed Mermaid sources and grid tables (their cards/grids are overlays).
        let hiddenFence = line.kind == .fence && runs.contains { $0.flags.contains(.hidden) }
        let extent = analysis.collapsibleExtent(containingLine: index)
        let collapsePreview = extent.map { preview.collapsed.contains($0.first) } ?? false
        if hiddenFence || collapsePreview {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = 0.1
            p.maximumLineHeight = 0.1
            if let e = extent, index == e.last, let h = preview.heights[e.first] { p.paragraphSpacing = h }
            storage.setAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: p], range: r)
            return
        }
        if let e = extent, index == e.last, let h = preview.heights[e.first] {
            look.paragraph.paragraphSpacing = h
        }
        if line.kind == .hr, runs.contains(where: { $0.flags.contains(.hidden) }) {
            look.extra[.dwRule] = palette.rule.nsColor
        }

        var base: [NSAttributedString.Key: Any] = [
            .font: typography.font(size: look.size, bold: look.bold, mono: look.mono),
            .foregroundColor: look.color,
            .paragraphStyle: look.paragraph,
        ]
        for (k, v) in look.extra { base[k] = v }
        storage.setAttributes(base, range: r)

        for run in runs {
            let rr = NSIntersectionRange(run.range, r)
            guard rr.length > 0 else { continue }
            let attrs = runAttributes(run.flags, line: line, look: look)
            if !attrs.isEmpty { storage.addAttributes(attrs, range: rr) }
        }

        let font = (base[.font] as? NSFont) ?? typography.font()
        if let task, let prefix = task.prefix, prefix.length > 0, NSMaxRange(prefix) <= storage.length {
            let mark = CheckboxMark(checked: task.checked, side: checkboxSide(look.size), centerAboveBaseline: (font.capHeight + font.xHeight) / 4,
                                    accent: palette.accent.nsColor, outline: palette.marker.nsColor, tick: palette.background.nsColor)
            // The first character (the bullet) carries the box and keeps the line's font (see `keepLineMetrics`). Its own width
            // is taken out of the kern, which keeps the item's text exactly one `checkboxColumn` clear of the box.
            storage.addAttribute(.dwCheckbox, value: mark, range: NSRange(location: prefix.location, length: 1))
            keepLineMetrics(storage, at: prefix.location, font: font, advance: checkboxColumn(look.size))
        } else if line.contentEnd > r.location, NSMaxRange(line.contentRange) <= storage.length {
            // A line whose every character is hidden — an empty heading (`# `), a bare quote marker (`>`) — would otherwise shrink
            // to a sliver as well.
            switch line.kind {
            case .heading, .body:
                let hidden = runs.reduce(0) { $0 + ($1.flags.contains(.hidden) ? NSIntersectionRange($1.range, line.contentRange).length : 0) }
                if hidden == line.contentRange.length { keepLineMetrics(storage, at: line.contentRange.location, font: font, advance: 0) }
            default: break
            }
        }

        if let header = preview.foldHeaders[index] {
            applyFoldMarks(header, line: line, index: index, runs: runs, storage: storage, task: task)
        }
    }

    /// The look of a line a fold hides: no ink, and a line height so small it takes next to no room.
    private func collapsedAttributes() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = Self.foldedLineHeight
        p.maximumLineHeight = Self.foldedLineHeight
        return [.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: p]
    }

    /// The chevron goes on the header's first visible character and the chip on the last character of its last line.
    private func applyFoldMarks(_ header: FoldHeader, line: LineStyle, index: Int, runs: ArraySlice<StyleRun>,
                                storage: NSTextStorage, task: TaskBox?) {
        let mark = FoldMark(folded: header.folded, covered: header.covered, chevron: palette.marker.nsColor,
                            chipFill: (header.covered ? palette.selection : palette.inlineCodeBackground).nsColor, chipInk: palette.text.nsColor)
        if index == header.firstLine, let at = firstVisibleCharacter(of: line, runs: runs, storage: storage, task: task) {
            storage.addAttribute(.dwFold, value: mark, range: NSRange(location: at, length: 1))
        }
        if header.folded, index == header.lastLine, line.contentEnd > line.range.location {
            storage.addAttribute(.dwFoldChip, value: mark, range: NSRange(location: line.contentEnd - 1, length: 1))
        }
    }

    /// The first character of the line that shows: past the indentation and past hidden syntax (`## `), except that a hidden
    /// `- [ ] ` task prefix shows its checkbox on its first character.
    private func firstVisibleCharacter(of line: LineStyle, runs: ArraySlice<StyleRun>, storage: NSTextStorage, task: TaskBox?) -> Int? {
        let content = line.contentRange
        guard content.length > 0 else { return nil }
        if let prefix = task?.prefix, prefix.length > 0 { return prefix.location }
        let string = storage.mutableString
        var p = content.location
        while p < NSMaxRange(content) {
            if let run = runs.first(where: { NSLocationInRange(p, $0.range) }), run.flags.contains(.hidden) {
                p = NSMaxRange(run.range)
                continue
            }
            let c = string.character(at: p)
            if c == 32 || c == 9 { p += 1; continue }
            return p
        }
        return content.location
    }

    /// Hidden characters are ~zero-size, so a line that holds nothing else (an empty task item, an empty heading, a bare `>`)
    /// would collapse to a sliver with no baseline of its own, and anything drawn relative to it (a task's checkbox) would spill
    /// into the line above. Giving one hidden character the line's real font (it stays clear, so invisible) gives the line
    /// exactly the height and baseline of a line with text; a kern then makes the character advance by `advance` points.
    private func keepLineMetrics(_ storage: NSTextStorage, at index: Int, font: NSFont, advance: CGFloat) {
        guard index >= 0, index < storage.length else { return }
        let range = NSRange(location: index, length: 1)
        let width = (storage.attributedSubstring(from: range).string as NSString).size(withAttributes: [.font: font]).width
        storage.addAttributes([.font: font, .kern: advance - width], range: range)
    }

    /// Edge length of a task checkbox for body text of `size`.
    private func checkboxSide(_ size: CGFloat) -> CGFloat { (size * 0.82).rounded() }

    /// Horizontal room a drawn checkbox takes: the box plus the gap before the item's text.
    func checkboxColumn(_ size: CGFloat) -> CGFloat { checkboxSide(size) + (size * 0.5).rounded() }

    /// The task on line `index` if its `- [ ] ` prefix is currently hidden (so a checkbox is drawn for it).
    private func hiddenTask(onLine index: Int, analysis: MarkdownAnalysis, runs: ArraySlice<StyleRun>) -> TaskBox? {
        guard let box = analysis.taskBox(onLine: index), let prefix = box.prefix else { return nil }
        let hidden = runs.contains { $0.flags.contains(.taskPrefix) && $0.flags.contains(.hidden) && NSLocationInRange(prefix.location, $0.range) }
        return hidden ? box : nil
    }

    private func lineLook(_ line: LineStyle, index: Int, analysis: MarkdownAnalysis, storage: NSTextStorage, preview: PreviewState,
                          hiddenTask: TaskBox? = nil) -> LineLook {
        var look = LineLook(size: typography.size, color: palette.text.nsColor)
        let p = look.paragraph
        p.lineHeightMultiple = typography.lineHeight

        switch line.kind {
        case .heading(let level):
            look.size = typography.headingSize(level)
            look.bold = true
            p.lineHeightMultiple = 1.18
            p.paragraphSpacingBefore = typography.size * (level <= 2 ? 0.7 : 0.45)
            p.paragraphSpacing = typography.size * 0.1
            if level == 6 { look.color = palette.secondaryText.nsColor }
        case .setextUnderline:
            look.color = palette.marker.nsColor
        case .codeBlock, .fence, .frontMatter:
            look.mono = true
            look.size = typography.size * 0.88
            look.color = (line.kind == .codeBlock) ? palette.codeText.nsColor : palette.secondaryText.nsColor
            p.lineHeightMultiple = 1.3
            p.headIndent = 14; p.firstLineHeadIndent = 14; p.tailIndent = -14
            look.extra[.dwBlockBackground] = palette.codeBackground.nsColor
        case .tableHeader, .tableRow, .tableDelimiter:
            look.mono = true
            look.size = typography.size * 0.88
            look.bold = line.kind == .tableHeader
            look.color = line.kind == .tableDelimiter ? palette.marker.nsColor : palette.text.nsColor
            p.lineHeightMultiple = 1.3
            p.headIndent = 14; p.firstLineHeadIndent = 14; p.tailIndent = -14
            look.extra[.dwBlockBackground] = palette.codeBackground.nsColor
        case .html:
            look.mono = true
            look.size = typography.size * 0.88
            look.color = palette.secondaryText.nsColor
        case .hr, .body:
            break
        }

        if line.quoteDepth > 0 {
            let indent = CGFloat(line.quoteDepth) * 16
            p.firstLineHeadIndent += indent
            p.headIndent += indent
            look.extra[.dwQuoteDepth] = line.quoteDepth
            look.extra[.dwQuoteBarColor] = palette.quoteBar.nsColor
            if case .body = line.kind { look.color = palette.text.nsColor.withAlphaComponent(0.82) }
        }
        if line.listPrefixLength > 0, case .body = line.kind {
            var prefixRange = NSRange(location: line.range.location, length: min(line.listPrefixLength, line.contentEnd - line.range.location))
            var extra: CGFloat = 0
            if let task = hiddenTask, let tp = task.prefix {
                // The hidden `- [ ] ` takes no room itself: wrapped lines line up with the text after the drawn checkbox.
                prefixRange.length = max(0, min(prefixRange.length, tp.location - line.range.location))
                extra = checkboxColumn(look.size)
            }
            let prefix = storage.attributedSubstring(from: prefixRange).string.replacingOccurrences(of: "\t", with: "    ")
            let width = (prefix as NSString).size(withAttributes: [.font: typography.font(size: look.size, bold: look.bold)]).width
            p.headIndent += width + extra
            p.paragraphSpacing = typography.size * 0.12
        }
        return look
    }

    private func runAttributes(_ f: StyleFlags, line: LineStyle, look: LineLook) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]

        if f.contains(.hidden) {
            return [.font: hiddenFont, .foregroundColor: NSColor.clear]
        }

        let mono = look.mono || f.contains(.code) || f.contains(.math) || f.contains(.html)
        let bold = look.bold || f.contains(.bold)
        let italic = f.contains(.italic)
        var size = f.contains(.code) && !look.mono ? look.size * 0.9 : look.size
        if f.contains(.sub) || f.contains(.sup) { size = look.size * 0.75 }
        if mono != look.mono || bold != look.bold || italic || size != look.size {
            attrs[.font] = typography.font(size: size, bold: bold, italic: italic, mono: mono)
        }

        if f.contains(.marker) {
            attrs[.foregroundColor] = palette.marker.nsColor
        } else if f.contains(.listMarker) {
            attrs[.foregroundColor] = palette.accent.nsColor
            attrs[.font] = typography.font(size: look.size, bold: true, mono: look.mono)
            if f.contains(.bullet) { attrs[.dwBullet] = true }
        } else if f.contains(.task) {
            attrs[.foregroundColor] = palette.accent.nsColor
            attrs[.font] = typography.font(size: look.size, bold: true, mono: true)
        } else if f.contains(.link) {
            attrs[.foregroundColor] = palette.link.nsColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = palette.link.nsColor.withAlphaComponent(0.35)
        } else if f.contains(.footnote) || f.contains(.math) {
            attrs[.foregroundColor] = palette.accent.nsColor
        } else if f.contains(.dim) {
            attrs[.foregroundColor] = palette.marker.nsColor
        } else if f.contains(.taskDone) {
            attrs[.foregroundColor] = palette.secondaryText.nsColor
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = palette.marker.nsColor
        } else if f.contains(.html) {
            attrs[.foregroundColor] = palette.secondaryText.nsColor
        }

        if f.contains(.strike) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if f.contains(.underline) {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if f.contains(.sup) {
            attrs[.baselineOffset] = look.size * 0.33
        } else if f.contains(.sub) {
            attrs[.baselineOffset] = -look.size * 0.14
        }
        if f.contains(.highlight), !f.contains(.marker) {
            attrs[.dwPill] = palette.highlightBackground.nsColor
        }
        if f.contains(.code), !f.contains(.marker), !f.contains(.codeBlock) {
            attrs[.dwPill] = palette.inlineCodeBackground.nsColor
            attrs[.foregroundColor] = palette.text.nsColor
        }
        if f.contains(.hr) {
            if f.contains(.marker) {
                attrs[.foregroundColor] = palette.marker.nsColor
            }
        }
        return attrs
    }
}
