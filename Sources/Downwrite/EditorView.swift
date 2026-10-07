import SwiftUI
import AppKit
import DownwriteCore

struct EditorSettings: Equatable {
    var font: FontChoice
    var size: Double
    var lineHeight: Double
    var width: Double
    var spellCheck: Bool = false
}

/// SwiftUI wrapper around the AppKit editor.
struct EditorView: NSViewRepresentable {
    @Binding var text: String
    var settings: EditorSettings
    var fileURL: URL?
    /// Feeds the table-of-contents sidebar.
    var toc: TOCModel?

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, textView) = EditorTextView.make()
        context.coordinator.toc = toc
        context.coordinator.attach(scroll: scroll, textView: textView, settings: settings, initialText: text)
        context.coordinator.fileURL = fileURL
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.fileURL = fileURL
        context.coordinator.toc = toc
        context.coordinator.update(text: text, settings: settings)
    }
}

/// Owns the analysis → styling → overlay pipeline for one editor.
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
    var text: Binding<String>
    var fileURL: URL?
    private(set) weak var textView: EditorTextView?
    private weak var scroll: NSScrollView?
    private(set) var analysis = MarkdownAnalyzer.analyze("")
    private(set) var styler: MarkdownStyler!
    private(set) var overlay: DiagramOverlay!
    private(set) var tableOverlay: TableOverlay!
    /// First line of the grid table that is currently shown as Markdown source (chosen with "Edit as Markdown").
    /// Ends as soon as the caret leaves the table.
    private(set) var sourceTableFirstLine: Int?
    let typography = Typography()
    /// The table-of-contents sidebar's model; nil when no sidebar is attached.
    var toc: TOCModel? {
        didSet {
            guard toc !== oldValue else { return }
            oldValue?.onSelect = nil
            toc?.onSelect = { [weak self] id in self?.revealHeading(at: id) }
            scheduleTOCPublish()
        }
    }

    private var settings: EditorSettings?
    private var preview = PreviewState()
    private var lastHidden = Set<Int>()
    private var isStyling = false
    private var repositionScheduled = false
    private var tocPublishScheduled = false
    private var tableOfContents = TableOfContents(headings: [])
    private var debounce: DispatchWorkItem?

    init(text: Binding<String>) {
        self.text = text
        super.init()
    }

    // MARK: Setup

    func attach(scroll: NSScrollView, textView tv: EditorTextView, settings s: EditorSettings, initialText: String) {
        self.scroll = scroll
        textView = tv
        tv.coordinator = self
        tv.delegate = self
        tv.layoutManager?.delegate = self
        tv.layoutManager?.allowsNonContiguousLayout = true
        applySettings(s)
        styler = MarkdownStyler(typography: typography, palette: AppearanceResolver.palette(for: tv.effectiveAppearance))
        overlay = DiagramOverlay(textView: tv, palette: styler.palette)
        overlay.onReservedHeightsChanged = { [weak self] in self?.reservedHeightsChanged() }
        tableOverlay = TableOverlay(coordinator: self, textView: tv)
        tableOverlay.onReservedHeightsChanged = { [weak self] in self?.reservedHeightsChanged() }
        tv.string = initialText
        applyChrome()
        reanalyze()
    }

    private func applySettings(_ s: EditorSettings) {
        settings = s
        typography.update(choice: s.font, size: CGFloat(s.size), lineHeight: CGFloat(s.lineHeight), readableWidth: CGFloat(s.width))
        textView?.maxContentWidth = CGFloat(s.width)
        textView?.isContinuousSpellCheckingEnabled = s.spellCheck
    }

    func update(text newText: String, settings s: EditorSettings) {
        guard let tv = textView else { return }
        var reanalyzeNeeded = false
        if tv.string != newText {
            let sel = tv.selectedRange()
            tv.string = newText
            let loc = min(sel.location, (newText as NSString).length)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            reanalyzeNeeded = true
        }
        if s != settings {
            applySettings(s)
            reanalyzeNeeded = true
        }
        if reanalyzeNeeded { reanalyze() }
    }

    // MARK: Pipeline

    private var isDark: Bool { styler.palette == Palette.palette(for: .dark) }

    func reanalyze() {
        guard let tv = textView else { return }
        analysis = MarkdownAnalyzer.analyze(tv.string)
        tableOfContents = analysis.tableOfContents
        scheduleTOCPublish()
        if let first = sourceTableFirstLine, !analysis.tables.contains(where: { $0.isGrid && $0.firstLine == first }) {
            sourceTableFirstLine = nil
        }
        overlay.baseURL = fileURL?.deletingLastPathComponent()
        overlay.sync(blocks: analysis.previewBlocks, dark: isDark)
        tableOverlay.sync()
        preview.heights = combinedHeights()
        preview.collapsed = collapsedBlocks(selection: tv.selectedRange())
        restyleAll()
    }

    private func combinedHeights() -> [Int: CGFloat] {
        overlay.reservedHeights.merging(tableOverlay.reservedHeights()) { a, _ in a }
    }

    /// Blocks whose source is hidden behind a card or grid: Mermaid/image previews while the caret is outside, and
    /// every grid table except the one being edited as Markdown. Keyed by first line.
    private func collapsedBlocks(selection: NSRange) -> Set<Int> {
        var set = Set(analysis.previewBlocks.filter { !MarkdownAnalysis.isRevealed($0.reveal, by: selection) }.map(\.firstLine))
        for t in analysis.tables where t.isGrid && t.firstLine != sourceTableFirstLine { set.insert(t.firstLine) }
        return set
    }

    /// Shows the grid again for a table that was being edited as Markdown (unless the caret is still inside it).
    func endTableSource() {
        guard let first = sourceTableFirstLine, let tv = textView else { return }
        if let t = analysis.tables.first(where: { $0.isGrid && $0.firstLine == first }),
           tableOverlay.hasFocus || !MarkdownAnalysis.isRevealed(t.range, by: tv.selectedRange()) {
            sourceTableFirstLine = nil
            reanalyze()
        }
    }

    /// "Edit as Markdown": shows one table as source until the caret leaves it.
    func showTableSource(order: Int, at pos: TableCellPosition) {
        let blocks = analysis.tables.filter(\.isGrid)
        guard let tv = textView, order < blocks.count else { return }
        let block = blocks[order]
        sourceTableFirstLine = block.firstLine
        let caret = NSRange(location: block.range(of: pos)?.location ?? block.range.location, length: 0)
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(caret)
        reanalyze()
        tv.setSelectedRange(caret)
        tv.scrollRangeToVisible(caret)
    }

    func restyleAll() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        isStyling = true
        defer { isStyling = false }
        let sel = tv.selectedRange()
        styler.styleAll(storage: storage, analysis: analysis, selection: sel, preview: preview)
        lastHidden = analysis.hiddenMarkerIndices(selection: sel)
        tv.typingAttributes = styler.baseAttributes()
        scheduleReposition()
    }

    func applyChrome() {
        guard let tv = textView else { return }
        let p = styler.palette
        tv.backgroundColor = p.background.nsColor
        tv.insertionPointColor = p.accent.nsColor
        tv.selectedTextAttributes = [.backgroundColor: p.selection.nsColor]
        tv.linkTextAttributes = [:]
        scroll?.backgroundColor = p.background.nsColor
        scroll?.drawsBackground = true
    }

    func appearanceDidChange() {
        guard let tv = textView, styler != nil else { return }
        let palette = AppearanceResolver.palette(for: tv.effectiveAppearance)
        guard palette != styler.palette else { return }
        styler.palette = palette
        overlay.setPalette(palette)
        tableOverlay.setPalette()
        applyChrome()
        reanalyze()
    }

    private func reservedHeightsChanged() {
        guard let tv = textView, let storage = tv.textStorage, analysis.length == storage.length else { return }
        preview.heights = combinedHeights()
        let lines = Set(analysis.previewBlocks.map(\.lastLine)).union(analysis.tables.filter(\.isGrid).map(\.lastLine))
        isStyling = true
        styler.style(lines: lines, storage: storage, analysis: analysis, selection: tv.selectedRange(), preview: preview)
        isStyling = false
        scheduleReposition()
    }

    func scheduleReposition() {
        guard !repositionScheduled else { return }
        repositionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.repositionScheduled = false
            self.overlay.reposition(analysis: self.analysis)
            self.tableOverlay.reposition()
        }
    }

    // MARK: Table of contents

    /// Hands the sidebar its rows and active heading. Deferred one turn of the run loop: `reanalyze` also runs from
    /// `updateNSView`, where SwiftUI forbids publishing changes.
    private func scheduleTOCPublish() {
        guard toc != nil, !tocPublishScheduled else { return }
        tocPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tocPublishScheduled = false
            guard let toc = self.toc, let tv = self.textView else { return }
            toc.update(rows: self.tableOfContents.rows, activeID: self.analysis.headingIndex(at: tv.selectedRange().location))
        }
    }

    /// Sidebar click: puts the caret at the end of heading `index` (a `TOCRow.id`), gives the editor the keyboard so
    /// typing carries on there, and scrolls the heading to the top of the window.
    func revealHeading(at index: Int, animated: Bool = true) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        if analysis.length != storage.length { reanalyze() }
        guard analysis.headings.indices.contains(index) else { return }
        let heading = analysis.headings[index]
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: NSMaxRange(heading.range), length: 0))
        tv.scrollToTop(of: heading.range, animated: animated)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isStyling, let tv = textView else { return }
        let s = tv.string
        if text.wrappedValue != s { text.wrappedValue = s }
        if tv.hasMarkedText() { return }
        debounce?.cancel()
        if s.utf16.count > 400_000 {
            let work = DispatchWorkItem { [weak self] in self?.reanalyze() }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            reanalyze()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isStyling, let tv = textView, let storage = tv.textStorage,
              analysis.length == storage.length, !tv.hasMarkedText() else { return }
        let sel = tv.selectedRange()
        scheduleTOCPublish()
        // Markdown source of a table is only shown while the caret is in it.
        if let first = sourceTableFirstLine,
           let t = analysis.tables.first(where: { $0.isGrid && $0.firstLine == first }),
           !MarkdownAnalysis.isRevealed(t.range, by: sel) {
            sourceTableFirstLine = nil
            reanalyze()
            tableOverlay.scheduleHandOff()
            return
        }
        let hidden = analysis.hiddenMarkerIndices(selection: sel)
        var dirty = Set<Int>()
        for i in hidden.symmetricDifference(lastHidden) where i < analysis.markers.count {
            dirty.insert(analysis.lineIndex(at: analysis.markers[i].range.location))
        }
        let collapsed = collapsedBlocks(selection: sel)
        let collapseChanged = collapsed != preview.collapsed
        for first in collapsed.symmetricDifference(preview.collapsed) {
            if let e = analysis.collapsibleExtent(containingLine: first) { for l in e.first...e.last { dirty.insert(l) } }
        }
        preview.collapsed = collapsed
        lastHidden = hidden
        if !dirty.isEmpty {
            isStyling = true
            styler.style(lines: dirty, storage: storage, analysis: analysis, selection: sel, preview: preview)
            isStyling = false
        }
        tv.typingAttributes = styler.baseAttributes()
        if collapseChanged { scheduleReposition() }
        tableOverlay.highlightSelection()
        tableOverlay.scheduleHandOff()
    }

    // MARK: NSLayoutManagerDelegate

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        Task { @MainActor in self.scheduleReposition() }
    }

    /// Draws `-`/`*`/`+` list markers as a real bullet glyph while the Markdown character stays in the text.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                                   properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                                   characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                                   forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var changed = false
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            guard ci < storage.length, storage.attribute(.dwBullet, at: ci, effectiveRange: nil) != nil else { continue }
            var ch: UniChar = 0x2022
            var glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(aFont, &ch, &glyph, 1) { newGlyphs[i] = glyph; changed = true }
        }
        guard changed else { return 0 }
        let properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        let indexes = Array(UnsafeBufferPointer(start: charIndexes, count: glyphRange.length))
        layoutManager.setGlyphs(newGlyphs, properties: properties, characterIndexes: indexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // MARK: Links

    func open(destination: String) {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return }
        if dest.hasPrefix("#") { scrollToHeading(slug: String(dest.dropFirst())); return }
        if let url = URL(string: dest), let scheme = url.scheme, !scheme.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        let base = fileURL?.deletingLastPathComponent() ?? textView?.window?.representedURL?.deletingLastPathComponent()
        let path = dest.removingPercentEncoding ?? dest
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: base)
        NSWorkspace.shared.open(url)
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        let allowed = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
        return String(String.UnicodeScalarView(allowed)).replacingOccurrences(of: " ", with: "-")
    }

    private func scrollToHeading(slug: String) {
        guard let tv = textView, let h = analysis.headings.first(where: { Self.slug($0.title) == slug.lowercased() }) else { return }
        tv.setSelectedRange(NSRange(location: h.range.location, length: 0))
        tv.scrollRangeToVisible(h.range)
    }
}
