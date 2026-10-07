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
