import AppKit
import WebKit
import UniformTypeIdentifiers
import DownwriteCore

// MARK: - Card view

/// A card showing one rendered preview: a Mermaid diagram (WebKit), an image, or a block of the document's own HTML (WebKit,
/// locked down: see `HTMLSupport`). It never takes mouse events, so clicks and scrolling fall through to the text view
/// underneath.
final class DiagramView: NSView, WKNavigationDelegate {
    enum Mode { case svg, image, html }

    /// Display-only web view: the SVG is already rendered, so scripting is switched off entirely.
    private let web: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: config)
    }()
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var naturalSize: MermaidSupport.Size?
    private var lastSVG: String?
    private(set) var mode = Mode.svg
    var isImage: Bool { mode == .image }
    var isHTML: Bool { mode == .html }

    /// The navigation of the HTML page being loaded and who is waiting for it (see `showHTML`).
    private var htmlNavigation: WKNavigation?
    private var htmlWaiter: CheckedContinuation<Bool, Never>?
    private var htmlLoadGeneration = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityLabel("Mermaid diagram")
        web.navigationDelegate = self
        addSubview(web)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.isHidden = true
        addSubview(imageView)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 3
        label.isHidden = true
        addSubview(label)
        setAccessibilityIdentifier("preview-card")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Diagrams sit on a padded card; images and HTML are drawn straight onto the page.
    var padding: CGFloat { mode == .svg ? 16 : 0 }

    override func layout() {
        super.layout()
        web.frame = bounds.insetBy(dx: padding, dy: padding)
        imageView.frame = bounds
        label.frame = bounds.insetBy(dx: 16, dy: 10)
    }

    func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = mode == .svg ? palette.codeBackground.nsColor.cgColor : NSColor.clear.cgColor
        label.textColor = NSColor.systemRed
    }

    private func setMode(_ mode: Mode, palette: Palette? = nil) {
        self.mode = mode
        layer?.cornerRadius = mode == .svg ? 12 : 0
        layer?.backgroundColor = mode == .svg ? palette?.codeBackground.nsColor.cgColor : NSColor.clear.cgColor
        needsLayout = true
    }

    func show(svg: String, palette: Palette) {
        setMode(.svg, palette: palette)
        web.setAccessibilityLabel("Mermaid diagram")
        label.isHidden = true; imageView.isHidden = true; web.isHidden = false
        naturalSize = MermaidSupport.intrinsicSize(ofSVG: svg)
        if lastSVG != svg {
            lastSVG = svg
            web.loadHTMLString(MermaidSupport.page(wrapping: svg), baseURL: nil)
        }
    }

    func show(image: NSImage, palette: Palette) {
        setMode(.image, palette: palette)
        web.isHidden = true; label.isHidden = true; imageView.isHidden = false
        imageView.image = image
        lastSVG = nil
        naturalSize = MermaidSupport.Size(width: image.size.width, height: image.size.height)
    }

    // MARK: HTML

    /// Renders `page` (see `HTMLSupport.page`) at `width` points and returns the height of its content in points, or `nil`
    /// if it did not load. The page cannot run scripts, and the delegate below refuses every navigation but this load.
    func showHTML(page: String, width: CGFloat, palette: Palette) async -> CGFloat? {
        setMode(.html, palette: palette)
        web.setAccessibilityLabel("Rendered HTML")
        label.isHidden = true; imageView.isHidden = true; web.isHidden = false
        lastSVG = nil
        naturalSize = nil
        web.frame = NSRect(x: 0, y: 0, width: max(1, width), height: max(1, bounds.height))
        // Whoever was waiting for an earlier load is released; the navigation id keeps its late callbacks away from this one.
        htmlWaiter?.resume(returning: false)
        htmlWaiter = nil
        htmlLoadGeneration += 1
        let generation = htmlLoadGeneration
        let loaded: Bool = await withCheckedContinuation { cont in
            htmlWaiter = cont
            htmlNavigation = web.loadHTMLString(page, baseURL: nil)
            // A remote image that never answers must not hold the card back for ever: measure what is there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.htmlLoadGeneration == generation else { return }
                self.finishHTMLLoad(true)
            }
        }
        guard loaded, !Task.isCancelled, generation == htmlLoadGeneration else { return nil }
        guard let value = try? await web.evaluateJavaScript(HTMLSupport.heightScript) else { return nil }
        guard let n = value as? NSNumber else { return nil }
        return CGFloat(truncating: n)
    }

    private func finishHTMLLoad(_ ok: Bool) {
        guard let waiter = htmlWaiter else { return }
        htmlWaiter = nil
        waiter.resume(returning: ok)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let id = navigation.map { ObjectIdentifier($0) }
        Task { @MainActor in
            if let id, let current = self.htmlNavigation, id == ObjectIdentifier(current) { self.finishHTMLLoad(true) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let id = navigation.map { ObjectIdentifier($0) }
        Task { @MainActor in
            if let id, let current = self.htmlNavigation, id == ObjectIdentifier(current) { self.finishHTMLLoad(false) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let id = navigation.map { ObjectIdentifier($0) }
        Task { @MainActor in
            if let id, let current = self.htmlNavigation, id == ObjectIdentifier(current) { self.finishHTMLLoad(false) }
        }
    }

    /// The document's HTML is untrusted: while it is shown nothing may navigate away from the page we loaded (links,
    /// `<meta http-equiv="refresh">`, frames, scripted navigation). Only our own `loadHTMLString` — a main-frame load of
    /// `about:blank` — is allowed.
    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard mode == .html else { return .allow }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let isOurLoad = navigationAction.navigationType == .other && (navigationAction.targetFrame?.isMainFrame ?? true)
        return isOurLoad && (scheme == nil || scheme == "about") ? .allow : .cancel
    }

    /// Runs `script` in the page (for tests: the page itself cannot run scripts, the app can).
    func evaluate(_ script: String) async -> Any? {
        guard let value = try? await web.evaluateJavaScript(script) else { return nil }
        return value
    }

    /// Bitmap of the web content (WebKit renders out of process, so view caching cannot see it).
    func webSnapshot() async -> NSImage? {
        guard !web.isHidden else { return nil }
        return await withCheckedContinuation { cont in
            web.takeSnapshot(with: nil) { image, _ in cont.resume(returning: image) }
        }
    }

    func showError(_ message: String, palette: Palette) {
        setMode(.svg, palette: palette)
        web.isHidden = true; imageView.isHidden = true
        lastSVG = nil
        naturalSize = nil
        label.textColor = .systemRed
        label.stringValue = message
        label.isHidden = false
    }

    func showLoading(palette: Palette) {
        setMode(.svg, palette: palette)
        web.isHidden = true; imageView.isHidden = true
        label.textColor = .secondaryLabelColor
        label.stringValue = "Rendering…"
        label.isHidden = false
        naturalSize = nil
    }
}

// MARK: - Image loading

enum ImageLoader {
    /// The file `source` points to: an absolute or `~` path, a `file:` URL, or a path relative to the document's folder.
    /// `nil` for web URLs.
    static func fileURL(for source: String, base: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return nil }
        let path = trimmed.removingPercentEncoding ?? trimmed
        if let u = URL(string: trimmed), u.scheme == "file" { return u }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return URL(fileURLWithPath: path, relativeTo: base)
    }

    /// Resolves `source` against the document's folder (relative paths) or loads it from the network.
    static func load(source: String, base: URL?) async -> NSImage? {
        guard let url = fileURL(for: source, base: base) else {
            guard let url = URL(string: source.trimmingCharacters(in: .whitespaces)),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        return await Task.detached { NSImage(contentsOf: url) }.value
    }

    /// The largest image file that is embedded into an HTML card.
    static let maxEmbeddedBytes = 8_000_000

    /// The image file at `url` as a `data:` URI, or `nil` if it is missing, too big or not an image type WebKit shows.
    static func dataURI(at url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType,
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxEmbeddedBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

// MARK: - Overlay controller

/// Keeps one `DiagramView` per preview block, positions it under the block's last line, and tells the editor how
/// much vertical room to reserve there.
@MainActor
final class DiagramOverlay {
    private struct Entry {
        var kind: PreviewBlock.Kind
        var dark: Bool
        /// How an HTML card looks (palette, font); `nil` for the other kinds.
        var style: HTMLPageStyle?
        /// The width an HTML card was last rendered at: HTML reflows, so a different column width means a new height.
        var renderedWidth: CGFloat = 0
        var hasRendered = false
        /// A render is under way (its result is filed under the entry's current key, so a changed key restarts it).
        var rendering = false
        var view: DiagramView
        var reserved: CGFloat
        var task: Task<Void, Never>?
    }

    private weak var textView: EditorTextView?
    private var entries: [Int: Entry] = [:]
    /// Local images already turned into `data:` URIs for HTML cards, by file path; reused while the file is unchanged.
    private var embeddedImages: [String: (stamp: Date?, uri: String)] = [:]
    var onReservedHeightsChanged: (() -> Void)?
    var baseURL: URL?
    private(set) var palette: Palette

    init(textView: EditorTextView, palette: Palette) {
        self.textView = textView
        self.palette = palette
    }

    var reservedHeights: [Int: CGFloat] { entries.mapValues(\.reserved) }
    var diagramViews: [DiagramView] { entries.values.map(\.view) }

    func setPalette(_ p: Palette) {
        palette = p
        entries.values.forEach { $0.view.applyPalette(p) }
    }

    private var availableWidth: CGFloat {
        guard let tv = textView else { return 600 }
        return max(200, tv.bounds.width - tv.textContainerInset.width * 2)
    }

    /// Shows a card for each block and drops the cards of blocks that are gone. `style` is how HTML blocks are drawn: a
    /// different one (theme, font) renders them again.
    func sync(blocks: [PreviewBlock], dark: Bool, style: HTMLPageStyle) {
        guard let tv = textView else { return }
        // Cards are filed under their block's first line, which moves whenever a line is typed above them. A card whose block
        // has the same content at another line moves with it instead of being thrown away and rendered again.
        let keep = Set(blocks.map(\.firstLine))
        var orphans = entries.filter { !keep.contains($0.key) }
        for key in orphans.keys { entries[key] = nil }
        var changed = false
        for block in blocks {
            var blockStyle: HTMLPageStyle?
            if case .html = block.kind { blockStyle = style }
            if var e = entries[block.firstLine] {
                if e.kind == block.kind && e.dark == dark && e.style == blockStyle { continue }
                e.task?.cancel()
                e.kind = block.kind; e.dark = dark; e.style = blockStyle
                entries[block.firstLine] = e
                start(block.firstLine)
            } else if let moved = orphans.filter({ $0.value.kind == block.kind && $0.value.dark == dark && $0.value.style == blockStyle })
                        .min(by: { abs($0.key - block.firstLine) < abs($1.key - block.firstLine) }) {
                orphans[moved.key] = nil
                entries[block.firstLine] = moved.value
                if moved.value.rendering { start(block.firstLine) }          // (its result would be filed under the old line)
            } else {
                let v = DiagramView(frame: NSRect(x: 0, y: 0, width: availableWidth, height: 100))
                v.applyPalette(palette)
                // (An HTML card shows nothing, and keeps no room, until it knows how tall it is.)
                if blockStyle == nil { v.showLoading(palette: palette) }
                tv.addSubview(v)
                entries[block.firstLine] = Entry(kind: block.kind, dark: dark, style: blockStyle, view: v, reserved: blockStyle == nil ? 72 : 0)
                changed = true
                start(block.firstLine)
            }
        }
        for (_, gone) in orphans {
            gone.task?.cancel()
            gone.view.removeFromSuperview()
        }
        if changed { onReservedHeightsChanged?() }
    }

    /// `html` with its local images embedded as `data:` URIs, so the page never needs file access.
    private func inlineLocalImages(in html: String, base: URL?) async -> String {
        var map: [String: String] = [:]
        for source in HTMLSupport.imageSources(in: html) where HTMLSupport.isLocalSource(source) {
            guard let url = ImageLoader.fileURL(for: source, base: base) else { continue }
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let hit = embeddedImages[url.path], hit.stamp == stamp { map[source] = hit.uri; continue }
            let uri = await Task.detached(priority: .userInitiated) { ImageLoader.dataURI(at: url) }.value
            guard let uri else { continue }
            if embeddedImages.count > 64 { embeddedImages.removeAll() }
            embeddedImages[url.path] = (stamp, uri)
            map[source] = uri
        }
        return HTMLSupport.replacingImageSources(in: html, with: map)
    }

    /// How long typing in an HTML block waits before the card is rendered again.
    private static let htmlDebounce: UInt64 = 150_000_000

    private func start(_ key: Int) {
        guard let entry = entries[key] else { return }
        entry.task?.cancel()
        let kind = entry.kind, dark = entry.dark, style = entry.style
        let firstRender = !entry.hasRendered
        let width = availableWidth
        if case .html = kind { entries[key]?.renderedWidth = width }
        entries[key]?.rendering = true
        let base = baseURL ?? textView?.window?.representedURL?.deletingLastPathComponent()
        entries[key]?.task = Task { [weak self] in
            var reserved: CGFloat = 56
            var card: DiagramView?
            switch kind {
            case .mermaid(let source):
                let result = await MermaidService.shared.render(source, dark: dark)
                guard !Task.isCancelled, let self, let e = self.entries[key], e.kind == kind, e.dark == dark else { return }
                card = e.view
                switch result {
                case .success(let svg):
                    e.view.show(svg: svg, palette: self.palette)
                    let natural = e.view.naturalSize ?? .init(width: 400, height: 240)
                    let fit = MermaidSupport.fittedSize(natural, maxWidth: Double(self.availableWidth - 2 * e.view.padding))
                    reserved = CGFloat(fit.height) + 2 * e.view.padding + 14
                case .failure(let error):
                    switch error {
                    case .failed(let msg): e.view.showError("Diagram error — " + msg, palette: self.palette)
                    case .unavailable: e.view.showError("Mermaid renderer unavailable", palette: self.palette)
                    }
                }
            case .image(let source, _):
                let image = await ImageLoader.load(source: source, base: base)
                guard !Task.isCancelled, let self, let e = self.entries[key], e.kind == kind else { return }
                card = e.view
                if let image, image.size.width > 0, image.size.height > 0 {
                    e.view.show(image: image, palette: self.palette)
                    let fit = MermaidSupport.fittedSize(.init(width: image.size.width, height: image.size.height),
                                                        maxWidth: Double(self.availableWidth), maxHeight: 560)
                    reserved = CGFloat(fit.height) + 14
                } else {
                    e.view.showError("Image not found — " + source, palette: self.palette)
                }
            case .html(let source):
                if !firstRender { try? await Task.sleep(nanoseconds: Self.htmlDebounce) }      // typing in the block
                guard !Task.isCancelled, let self, let style, self.entries[key]?.kind == kind, self.entries[key]?.style == style else { return }
                let body = await self.inlineLocalImages(in: source, base: base)
                guard !Task.isCancelled, let view = self.entries[key]?.view, self.entries[key]?.kind == kind else { return }
                let height = await view.showHTML(page: HTMLSupport.page(body: body, style: style), width: width, palette: self.palette)
                guard !Task.isCancelled, let e = self.entries[key], e.kind == kind, e.style == style else { return }
                card = e.view
                if let height, height >= 2 {
                    reserved = min(height, 20_000) + 14
                } else {
                    e.view.showError(height == nil ? "Could not render this HTML" : "Nothing to show — this HTML draws no content", palette: self.palette)
                }
            }
            guard let self, var e = self.entries[key], let card, card === e.view else { return }
            let old = e.reserved
            e.reserved = reserved
            e.hasRendered = true
            e.rendering = false
            self.entries[key] = e
            if old != reserved { self.onReservedHeightsChanged?() }
            self.reposition(analysis: self.lastAnalysis)
        }
    }

    private var lastAnalysis: MarkdownAnalysis?

    /// Places every card just below its block. Call after layout changes.
    func reposition(analysis: MarkdownAnalysis?) {
        lastAnalysis = analysis
        guard let tv = textView, let lm = tv.layoutManager, let analysis else { return }
        let origin = tv.textContainerOrigin
        let width = availableWidth
        let total = tv.textStorage?.length ?? 0
        guard total > 0 else { return }
        for block in analysis.previewBlocks {
            guard let e = entries[block.firstLine], block.lastLine < analysis.lines.count else { continue }
            // HTML reflows with the column: after the sidebar opens or the window is resized, measure again.
            if case .html = e.kind, e.hasRendered, abs(e.renderedWidth - width) > 0.5 { start(block.firstLine) }
            let line = analysis.lines[block.lastLine]
            // Non-contiguous layout can report stale estimates for unlaid text; make everything above the card exact.
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(total, NSMaxRange(line.range))))
            let glyph = lm.glyphIndexForCharacter(at: min(max(0, line.range.location), total - 1))
            // The fragment rect of the block's last line includes the paragraph spacing we reserved for the card,
            // so anchor to the *used* rect (the text itself) and let the card fill the reserved space beneath it.
            let frag = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let height = max(24, e.reserved - 14)
            var w = width
            if e.view.isImage, let n = e.view.naturalSize {
                let fit = MermaidSupport.fittedSize(n, maxWidth: Double(width), maxHeight: 560)
                w = CGFloat(fit.width)
            }
            let frame = NSRect(x: origin.x, y: frag.maxY + origin.y + 4, width: w, height: height)
            if e.view.frame != frame { e.view.frame = frame; e.view.needsLayout = true }
        }
    }

    /// Disagreements between the cards and the text they belong to — a card that is not directly under its block's last line,
    /// an HTML card that is not as wide as the column, cards that overlap. Empty when everything is in place.
    func layoutProblems(analysis: MarkdownAnalysis) -> [String] {
        guard let tv = textView, let lm = tv.layoutManager, let storage = tv.textStorage, storage.length > 0,
              analysis.length == storage.length else { return [] }
        var out: [String] = []
        var previousBottom = -CGFloat.infinity
        for block in analysis.previewBlocks {
            guard let e = entries[block.firstLine], e.hasRendered, block.lastLine < analysis.lines.count else { continue }
            let line = analysis.lines[block.lastLine]
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, NSMaxRange(line.range))))
            let glyph = lm.glyphIndexForCharacter(at: min(max(0, line.range.location), storage.length - 1))
            let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let expectedY = used.maxY + tv.textContainerOrigin.y + 4
            let frame = e.view.frame
            if abs(frame.minY - expectedY) > 1 { out.append("card for line \(block.firstLine) is at y \(Int(frame.minY)), its text ends at \(Int(expectedY))") }
            if e.view.isHTML, abs(frame.width - availableWidth) > 1 { out.append("HTML card for line \(block.firstLine) is \(Int(frame.width)) pt wide, the column \(Int(availableWidth))") }
            if frame.minY < previousBottom - 0.5 { out.append("card for line \(block.firstLine) overlaps the one above it") }
            previousBottom = frame.maxY
        }
        return out
    }
}
