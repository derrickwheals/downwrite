import AppKit
import DownwriteCore

/// Extra, non-textual state the styler needs: how tall each Mermaid preview is and which are collapsed.
struct PreviewState {
    /// Reserved height below a Mermaid block, keyed by the block's first line.
    var heights: [Int: CGFloat] = [:]
    /// Mermaid blocks whose source is collapsed (caret outside).
    var collapsed: Set<Int> = []
}

/// Applies a `MarkdownAnalysis` to an `NSTextStorage` as attributes. All hiding of Markdown syntax happens here:
/// a hidden marker gets a ~zero-size clear font, so its characters stay in the document (copy/paste, undo and
/// find keep working) but take no space.
final class MarkdownStyler {
    let typography: Typography
    var palette: Palette
    private let hiddenFont = NSFont.systemFont(ofSize: 0.1)

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

    /// Re-styles only the given lines (used when the caret moves and markers show/hide).
    func style(lines: Set<Int>, storage: NSTextStorage, analysis: MarkdownAnalysis, selection: NSRange, preview: PreviewState) {
        guard !lines.isEmpty, storage.length > 0 else { return }
        storage.beginEditing()
        for index in lines.sorted() where index < analysis.lines.count {
            let line = analysis.lines[index]
            guard line.range.length > 0, NSMaxRange(line.range) <= storage.length else { continue }
            let runs = analysis.runs(in: line.range, selection: selection)
            applyLine(index, analysis: analysis, runs: runs[...], storage: storage, preview: preview, selection: selection)
        }
        storage.endEditing()
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = typography.lineHeight
        return [.font: typography.font(), .foregroundColor: palette.text.nsColor, .paragraphStyle: p]
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
        var look = lineLook(line, index: index, analysis: analysis, storage: storage, preview: preview)

        // Whole-line collapsing: hidden fences, collapsed Mermaid sources.
        let hiddenFence = line.kind == .fence && runs.contains { $0.flags.contains(.hidden) }
        let mermaid = analysis.mermaid.first { index >= $0.firstLine && index <= $0.lastLine }
        let collapseMermaid = mermaid.map { preview.collapsed.contains($0.firstLine) } ?? false
        if hiddenFence || collapseMermaid {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = 0.1
            p.maximumLineHeight = 0.1
            if let m = mermaid, index == m.lastLine, let h = preview.heights[m.firstLine] { p.paragraphSpacing = h }
            storage.setAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: p], range: r)
            return
        }
        if let m = mermaid, index == m.lastLine, let h = preview.heights[m.firstLine] {
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
    }

    private func lineLook(_ line: LineStyle, index: Int, analysis: MarkdownAnalysis, storage: NSTextStorage, preview: PreviewState) -> LineLook {
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
            let prefixRange = NSRange(location: line.range.location, length: min(line.listPrefixLength, line.contentEnd - line.range.location))
            let prefix = storage.attributedSubstring(from: prefixRange).string.replacingOccurrences(of: "\t", with: "    ")
            let width = (prefix as NSString).size(withAttributes: [.font: typography.font(size: look.size, bold: look.bold)]).width
            p.headIndent += width
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
        let size = f.contains(.code) && !look.mono ? look.size * 0.9 : look.size
        if mono != look.mono || bold != look.bold || italic || size != look.size {
            attrs[.font] = typography.font(size: size, bold: bold, italic: italic, mono: mono)
        }

        if f.contains(.marker) {
            attrs[.foregroundColor] = palette.marker.nsColor
        } else if f.contains(.listMarker) {
            attrs[.foregroundColor] = palette.accent.nsColor
            attrs[.font] = typography.font(size: look.size, bold: true, mono: look.mono)
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
