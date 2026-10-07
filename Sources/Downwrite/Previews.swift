import AppKit
import WebKit
import DownwriteCore

// MARK: - Card view

/// A rounded card showing one rendered preview: a Mermaid diagram (WebKit) or an image. It never takes mouse
/// events, so clicks and scrolling fall through to the text view underneath.
final class DiagramView: NSView {
    private let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var naturalSize: MermaidSupport.Size?
    private var lastSVG: String?
    private(set) var isImage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityLabel("Mermaid diagram")
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

    var padding: CGFloat { isImage ? 0 : 16 }

    override func layout() {
        super.layout()
        web.frame = bounds.insetBy(dx: padding, dy: padding)
        imageView.frame = bounds
        label.frame = bounds.insetBy(dx: 16, dy: 10)
    }

    func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = isImage ? NSColor.clear.cgColor : palette.codeBackground.nsColor.cgColor
        label.textColor = NSColor.systemRed
    }

    private func setMode(image: Bool, palette: Palette? = nil) {
        isImage = image
        if let palette { layer?.backgroundColor = image ? NSColor.clear.cgColor : palette.codeBackground.nsColor.cgColor }
        needsLayout = true
    }

    func show(svg: String, palette: Palette) {
        setMode(image: false, palette: palette)
        label.isHidden = true; imageView.isHidden = true; web.isHidden = false
        naturalSize = MermaidSupport.intrinsicSize(ofSVG: svg)
        if lastSVG != svg {
            lastSVG = svg
            web.loadHTMLString(MermaidSupport.page(wrapping: svg), baseURL: nil)
        }
    }

    func show(image: NSImage, palette: Palette) {
        setMode(image: true, palette: palette)
        web.isHidden = true; label.isHidden = true; imageView.isHidden = false
        imageView.image = image
        lastSVG = nil
        naturalSize = MermaidSupport.Size(width: image.size.width, height: image.size.height)
    }

    /// Bitmap of the web content (WebKit renders out of process, so view caching cannot see it).
    func webSnapshot() async -> NSImage? {
        guard !web.isHidden else { return nil }
        return await withCheckedContinuation { cont in
            web.takeSnapshot(with: nil) { image, _ in cont.resume(returning: image) }
        }
    }

    func showError(_ message: String, palette: Palette) {
        setMode(image: false, palette: palette)
        web.isHidden = true; imageView.isHidden = true
        lastSVG = nil
        naturalSize = nil
        label.textColor = .systemRed
        label.stringValue = message
        label.isHidden = false
    }

    func showLoading(palette: Palette) {
        setMode(image: false, palette: palette)
        web.isHidden = true; imageView.isHidden = true
        label.textColor = .secondaryLabelColor
        label.stringValue = "Rendering…"
        label.isHidden = false
        naturalSize = nil
    }
}

// MARK: - Image loading

enum ImageLoader {
    /// Resolves `source` against the document's folder (relative paths) or loads it from the network.
    static func load(source: String, base: URL?) async -> NSImage? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        let path = trimmed.removingPercentEncoding ?? trimmed
        let url: URL
        if let u = URL(string: trimmed), u.scheme == "file" { url = u }
        else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else if path.hasPrefix("~") { url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        else { url = URL(fileURLWithPath: path, relativeTo: base) }
        return await Task.detached { NSImage(contentsOf: url) }.value
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
        var view: DiagramView
        var reserved: CGFloat
        var task: Task<Void, Never>?
    }

    private weak var textView: EditorTextView?
    private var entries: [Int: Entry] = [:]
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

    func sync(blocks: [PreviewBlock], dark: Bool) {
        guard let tv = textView else { return }
        let keep = Set(blocks.map(\.firstLine))
        for (key, entry) in entries where !keep.contains(key) {
            entry.task?.cancel()
            entry.view.removeFromSuperview()
            entries[key] = nil
        }
        var changed = false
        for block in blocks {
            if var e = entries[block.firstLine] {
                if e.kind == block.kind && e.dark == dark { continue }
                e.task?.cancel()
                e.kind = block.kind; e.dark = dark
                entries[block.firstLine] = e
                start(block.firstLine)
            } else {
                let v = DiagramView(frame: NSRect(x: 0, y: 0, width: availableWidth, height: 100))
                v.applyPalette(palette)
                v.showLoading(palette: palette)
                tv.addSubview(v)
                entries[block.firstLine] = Entry(kind: block.kind, dark: dark, view: v, reserved: 72)
                changed = true
                start(block.firstLine)
            }
        }
        if changed { onReservedHeightsChanged?() }
    }

    private func start(_ key: Int) {
        guard let entry = entries[key] else { return }
        let kind = entry.kind, dark = entry.dark
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
            }
            guard let self, var e = self.entries[key], let card, card === e.view else { return }
            let old = e.reserved
            e.reserved = reserved
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
            let line = analysis.lines[block.lastLine]
            let glyph = lm.glyphIndexForCharacter(at: min(max(0, line.range.location), total - 1))
            let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
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
}
