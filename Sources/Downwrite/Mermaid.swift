import AppKit
import WebKit
import DownwriteCore

// MARK: - Rendering service

enum MermaidError: Error { case unavailable, failed(String) }

/// Renders Mermaid source to SVG using a single hidden WKWebView that has Mermaid loaded once.
@MainActor
final class MermaidService: NSObject, WKNavigationDelegate {
    static let shared = MermaidService()

    private enum LoadState { case idle, loading, ready, failed }
    private var state: LoadState = .idle
    private var web: WKWebView?
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var counter = 0
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var cache: [String: String] = [:]

    private func ensureLoaded() async -> Bool {
        switch state {
        case .ready: return true
        case .failed: return false
        case .loading: return await withCheckedContinuation { loadWaiters.append($0) }
        case .idle:
            guard let url = AppResources.url("mermaid-renderer", "html") else { state = .failed; return false }
            state = .loading
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: WKWebViewConfiguration())
            w.navigationDelegate = self
            web = w
            w.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return await withCheckedContinuation { loadWaiters.append($0) }
        }
    }

    private func finishLoading(_ ok: Bool) {
        state = ok ? .ready : .failed
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume(returning: ok) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoading(true) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading(false) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading(false) }
    }

    private func acquire() async {
        if busy { await withCheckedContinuation { queue.append($0) } } else { busy = true }
    }
    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }

    func render(_ source: String, dark: Bool) async -> Result<String, MermaidError> {
        let key = (dark ? "d:" : "l:") + source
        if let hit = cache[key] { return .success(hit) }
        guard await ensureLoaded(), let web else { return .failure(.unavailable) }
        await acquire()
        defer { release() }
        counter += 1
        let js = """
        mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default',
                             fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif' });
        try {
          const r = await mermaid.render('dwm' + n, source);
          return r.svg;
        } finally {
          document.querySelectorAll('[id^="dwm"],[id^="ddwm"]').forEach(e => e.remove());
        }
        """
        do {
            let value = try await web.callAsyncJavaScript(js, arguments: ["source": source, "dark": dark, "n": counter],
                                                          in: nil, contentWorld: .page)
            guard let svg = value as? String, !svg.isEmpty else { return .failure(.failed("Empty result")) }
            if cache.count > 64 { cache.removeAll() }
            cache[key] = svg
            return .success(svg)
        } catch {
            let ns = error as NSError
            let message = (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription
            return .failure(.failed(MermaidSupport.friendlyError(message)))
        }
    }
}

// MARK: - Diagram card view

/// A rounded card showing one rendered diagram. It never takes mouse events, so clicks and scrolling fall through
/// to the text view underneath.
final class DiagramView: NSView {
    private let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let errorLabel = NSTextField(labelWithString: "")
    private(set) var naturalSize: MermaidSupport.Size?
    private var lastSVG: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityLabel("Mermaid diagram")
        addSubview(web)
        errorLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true
        addSubview(errorLabel)
        setAccessibilityIdentifier("mermaid-diagram")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var padding: CGFloat { 16 }

    override func layout() {
        super.layout()
        web.frame = bounds.insetBy(dx: padding, dy: padding)
        errorLabel.frame = bounds.insetBy(dx: padding, dy: 10)
    }

    func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.codeBackground.nsColor.cgColor
        errorLabel.textColor = NSColor.systemRed
    }

    func show(svg: String) {
        errorLabel.isHidden = true
        web.isHidden = false
        naturalSize = MermaidSupport.intrinsicSize(ofSVG: svg)
        if lastSVG != svg {
            lastSVG = svg
            web.loadHTMLString(MermaidSupport.page(wrapping: svg), baseURL: nil)
        }
    }

    /// Bitmap of the web content (WebKit renders out of process, so view caching cannot see it).
    func webSnapshot() async -> NSImage? {
        guard !web.isHidden else { return nil }
        return await withCheckedContinuation { cont in
            web.takeSnapshot(with: nil) { image, _ in cont.resume(returning: image) }
        }
    }

    func showError(_ message: String) {
        web.isHidden = true
        lastSVG = nil
        naturalSize = nil
        errorLabel.stringValue = "Diagram error — " + message
        errorLabel.isHidden = false
    }

    func showLoading() {
        web.isHidden = true
        errorLabel.isHidden = false
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.stringValue = "Rendering diagram…"
        naturalSize = nil
    }
}

// MARK: - Overlay controller

/// Keeps one `DiagramView` per Mermaid block, positions it under the block's last line, and tells the editor how
/// much vertical room to reserve there.
@MainActor
final class DiagramOverlay {
    private struct Entry {
        var source: String
        var dark: Bool
        var view: DiagramView
        var reserved: CGFloat
        var failed = false
        var task: Task<Void, Never>?
    }

    private weak var textView: EditorTextView?
    private var entries: [Int: Entry] = [:]
    var onReservedHeightsChanged: (() -> Void)?
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

    func sync(blocks: [MermaidBlock], dark: Bool) {
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
                if e.source == block.source && e.dark == dark { continue }
                e.task?.cancel()
                e.source = block.source; e.dark = dark
                entries[block.firstLine] = e
                start(block.firstLine)
            } else {
                let v = DiagramView(frame: NSRect(x: 0, y: 0, width: availableWidth, height: 100))
                v.applyPalette(palette)
                v.showLoading()
                tv.addSubview(v)
                entries[block.firstLine] = Entry(source: block.source, dark: dark, view: v, reserved: 72)
                changed = true
                start(block.firstLine)
            }
        }
        if changed { onReservedHeightsChanged?() }
    }

    private func start(_ key: Int) {
        guard let entry = entries[key] else { return }
        let source = entry.source, dark = entry.dark
        entries[key]?.task = Task { [weak self] in
            let result = await MermaidService.shared.render(source, dark: dark)
            guard !Task.isCancelled, let self, var e = self.entries[key], e.source == source, e.dark == dark else { return }
            switch result {
            case .success(let svg):
                e.view.show(svg: svg)
                let natural = e.view.naturalSize ?? .init(width: 400, height: 240)
                let fit = MermaidSupport.fittedSize(natural, maxWidth: Double(self.availableWidth - 2 * e.view.padding))
                e.reserved = CGFloat(fit.height) + 2 * e.view.padding + 14
                e.failed = false
            case .failure(let error):
                switch error {
                case .failed(let msg): e.view.showError(msg)
                case .unavailable: e.view.showError("Mermaid renderer unavailable")
                }
                e.reserved = 56
                e.failed = true
            }
            let old = self.entries[key]?.reserved
            self.entries[key] = e
            if old != e.reserved { self.onReservedHeightsChanged?() }
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
        for block in analysis.mermaid {
            guard let e = entries[block.firstLine], block.lastLine < analysis.lines.count else { continue }
            let line = analysis.lines[block.lastLine]
            let charRange = line.range.length > 0 ? NSRange(location: line.range.location, length: 1)
                                                   : NSRange(location: max(0, tv.string.utf16.count - 1), length: 0)
            guard tv.string.utf16.count > 0 else { continue }
            let glyph = lm.glyphIndexForCharacter(at: min(charRange.location, tv.string.utf16.count - 1))
            let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let height = max(40, e.reserved - 14)
            let frame = NSRect(x: origin.x, y: frag.maxY + origin.y + 4, width: width, height: height)
            if e.view.frame != frame { e.view.frame = frame; e.view.needsLayout = true }
        }
    }
}
