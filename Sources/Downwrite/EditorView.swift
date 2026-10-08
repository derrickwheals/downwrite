import SwiftUI
import AppKit
import DownwriteCore

struct EditorSettings: Equatable {
    var font: FontChoice
    var size: Double
    var lineHeight: Double
    var width: Double
    var spellCheck: Bool = false
    /// Colour themes (`ThemeCatalog` ids) used while the editor is light / dark.
    var lightTheme: String = ThemeCatalog.defaultLightID
    var darkTheme: String = ThemeCatalog.defaultDarkID
}

/// SwiftUI wrapper around the AppKit editor.
struct EditorView: NSViewRepresentable {
    @Binding var text: String
    var settings: EditorSettings
    var fileURL: URL?
    /// Feeds the table-of-contents sidebar.
    var toc: TOCModel?
    /// Shows the raw Markdown like a plain text editor (nothing hidden, no tables, diagrams or checkboxes drawn).
    var sourceMode = false

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, textView) = EditorTextView.make()
        context.coordinator.toc = toc
        context.coordinator.attach(scroll: scroll, textView: textView, settings: settings, initialText: text, sourceMode: sourceMode)
        context.coordinator.fileURL = fileURL
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.fileURL = fileURL
        context.coordinator.toc = toc
        context.coordinator.update(text: text, settings: settings, sourceMode: sourceMode)
    }
}

/// Owns the analysis → styling → overlay pipeline for one editor.
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
    var text: Binding<String>
    var fileURL: URL? {
        didSet { if fileURL != oldValue { watchedDate = Self.modificationDate(of: fileURL) } }
    }
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

    /// The source view: raw Markdown in a plain monospaced style, nothing hidden and no overlays (see `setSourceMode`).
    private(set) var sourceMode = false

    private var settings: EditorSettings?
    private var preview = PreviewState()
    private var lastHidden = Set<Int>()
    private var isStyling = false
    private var repositionScheduled = false
    private var tocPublishScheduled = false
    private var tableOfContents = TableOfContents(headings: [])
    private var debounce: DispatchWorkItem?
    /// Modification date of the file on disk as last seen by `checkForExternalChange`.
    private var watchedDate: Date?
    private var fileTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init(text: Binding<String>) {
        self.text = text
        super.init()
    }

    // MARK: Setup

    func attach(scroll: NSScrollView, textView tv: EditorTextView, settings s: EditorSettings, initialText: String, sourceMode: Bool = false) {
        self.sourceMode = sourceMode
        self.scroll = scroll
        textView = tv
        tv.coordinator = self
        tv.delegate = self
        tv.layoutManager?.delegate = self
        tv.layoutManager?.allowsNonContiguousLayout = true
        applySettings(s)
        styler = MarkdownStyler(typography: typography, palette: currentPalette(for: tv.effectiveAppearance))
        overlay = DiagramOverlay(textView: tv, palette: styler.palette)
        overlay.onReservedHeightsChanged = { [weak self] in self?.reservedHeightsChanged() }
        tableOverlay = TableOverlay(coordinator: self, textView: tv)
        tableOverlay.onReservedHeightsChanged = { [weak self] in self?.reservedHeightsChanged() }
        tv.string = initialText
        applyChrome()
        reanalyze()
        startWatchingFile()
    }

    private func applySettings(_ s: EditorSettings) {
        settings = s
        typography.update(choice: s.font, size: CGFloat(s.size), lineHeight: CGFloat(s.lineHeight), readableWidth: CGFloat(s.width))
        textView?.maxContentWidth = CGFloat(s.width)
        textView?.isContinuousSpellCheckingEnabled = s.spellCheck
    }

    func update(text newText: String, settings s: EditorSettings, sourceMode wanted: Bool? = nil) {
        guard let tv = textView else { return }
        if let wanted, wanted != sourceMode { setSourceMode(wanted) }
        var reanalyzeNeeded = false
        if tv.string != newText {
            applyExternalText(newText)
            reanalyzeNeeded = true
        }
        if s != settings {
            applySettings(s)
            _ = refreshPalette()                      // a different light/dark theme may have been chosen
            reanalyzeNeeded = true
        }
        if reanalyzeNeeded { reanalyze() }
    }

    /// Switches between the formatted editor and the source view. The text, the caret and undo are untouched; only what
    /// is drawn changes: the source view restyles everything plain and removes the table grids and diagram/image cards.
    func setSourceMode(_ on: Bool) {
        guard on != sourceMode, let tv = textView else { return }
        sourceMode = on
        let selection = tv.selectedRange()
        // A grid cell that has the keyboard goes away with the grids (its text is already in the document).
        if tableOverlay.hasFocus { tv.window?.makeFirstResponder(tv) }
        sourceTableFirstLine = nil
        reanalyze()
        tv.setSelectedRange(selection)
        tv.scrollRangeToVisible(selection)
    }

    // MARK: Changes from outside

    /// The document's text changed underneath the editor (the file was reloaded after another app rewrote it). Applies the
    /// smallest replacement instead of resetting the whole text, so the scroll position and the caret stay where they were.
    /// The undo history is dropped: its entries refer to offsets in text that no longer exists.
    private func applyExternalText(_ newText: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard let edit = TextDiff.replacement(from: tv.string, to: newText) else { return }
        let selection = tv.selectedRange()
        isStyling = true
        tv.undoManager?.disableUndoRegistration()
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        tv.undoManager?.enableUndoRegistration()
        tv.undoManager?.removeAllActions()
        tv.setSelectedRange(TextDiff.map(selection, through: edit))
        isStyling = false
    }

    private static func modificationDate(of url: URL?) -> Date? {
        guard let url else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Looks for the file being changed by another process (an editor, a sync client, `git checkout`…) once a second and
    /// whenever the app comes back to the front, and reloads it.
    private func startWatchingFile() {
        guard fileTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.textView != nil else { timer.invalidate(); return }
                self.checkForExternalChange()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fileTimer = timer
        let token = ObserverToken()
        token.observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.textView != nil else {                // the window is gone: stop listening
                    if let o = token.observer { NotificationCenter.default.removeObserver(o) }
                    return
                }
                self.checkForExternalChange()
            }
        }
        activationObserver = token.observer
    }

    /// Lets a notification block remove its own observer.
    private final class ObserverToken { var observer: NSObjectProtocol? }

    /// If the file on disk was modified by someone else and the document has no unsaved edits, asks the document to revert to
    /// the file (SwiftUI then hands the new text to `update(text:settings:)`). With unsaved edits nothing happens here: the
    /// document system's own "changed by another application" alert handles that when it is next saved.
    /// Returns whether a reload was started.
    @discardableResult
    func checkForExternalChange() -> Bool {
        guard let url = fileURL, let tv = textView, !tv.hasMarkedText() else { return false }
        guard let date = Self.modificationDate(of: url) else { return false }
        guard date != watchedDate else { return false }
        watchedDate = date
        guard let document = NSDocumentController.shared.document(for: url), !document.isDocumentEdited,
              let data = try? Data(contentsOf: url) else { return false }
        guard TextCoding.decode(data).text != tv.string else { return false }      // our own save, or a touch: nothing to show
        do {
            try document.revert(toContentsOf: url, ofType: document.fileType ?? "")
            return true
        } catch {
            return false
        }
    }

    // MARK: Pipeline

    private var isDark: Bool { styler.palette.isDark }

    /// The palette for the appearance the editor is showing in, from the light/dark themes chosen in Settings.
    private func currentPalette(for appearance: NSAppearance) -> Palette {
        AppearanceResolver.palette(for: appearance, lightTheme: settings?.lightTheme ?? ThemeCatalog.defaultLightID,
                                   darkTheme: settings?.darkTheme ?? ThemeCatalog.defaultDarkID)
    }

    /// Re-reads the palette (appearance or chosen theme changed) and applies it to the styler, overlays and window chrome.
    /// Returns whether it changed; the caller re-analyses and restyles.
    private func refreshPalette() -> Bool {
        guard let tv = textView, styler != nil else { return false }
        let palette = currentPalette(for: tv.effectiveAppearance)
        guard palette != styler.palette else { return false }
        styler.palette = palette
        overlay.setPalette(palette)
        tableOverlay.setPalette()
        applyChrome()
        return true
    }

    func reanalyze() {
        guard let tv = textView else { return }
        analysis = MarkdownAnalyzer.analyze(tv.string)
        tableOfContents = analysis.tableOfContents
        scheduleTOCPublish()
        if let first = sourceTableFirstLine, !analysis.tables.contains(where: { $0.isGrid && $0.firstLine == first }) {
            sourceTableFirstLine = nil
        }
        overlay.baseURL = fileURL?.deletingLastPathComponent()
        overlay.sync(blocks: sourceMode ? [] : analysis.previewBlocks, dark: isDark)
        tableOverlay.sync()                       // (no grids in the source view: `gridBlocks` is empty then)
        preview.heights = sourceMode ? [:] : combinedHeights()
        preview.collapsed = sourceMode ? [] : collapsedBlocks(selection: tv.selectedRange())
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
        if sourceMode {
            styler.styleSource(storage: storage)
            lastHidden = []
            tv.typingAttributes = styler.sourceAttributes()
            scheduleReposition()
            return
        }
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
        // The strip behind the toolbar shows the window's own colour: keep it the page colour so there is no band at the top.
        tv.window?.backgroundColor = p.background.nsColor
        tv.window?.titlebarAppearsTransparent = true
    }

    func appearanceDidChange() {
        if refreshPalette() { reanalyze() }
    }

    private func reservedHeightsChanged() {
        guard !sourceMode, let tv = textView, let storage = tv.textStorage, analysis.length == storage.length else { return }
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
        if sourceMode { return }                  // plain text: moving the caret changes nothing that is drawn
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
