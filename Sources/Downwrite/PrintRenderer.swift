import AppKit
import WebKit

/// Prints a document page through a hidden web view and WebKit's own print engine, so the pages are paginated text, not a picture.
///
/// Found by the change's spike (see the plan): a web view's print operation never returns from `run()`, so every run here goes through
/// `runModal(for:delegate:didRun:contextInfo:)`; the web view can stay hidden, in no window, and the window passed in only hosts the
/// sheet; and `didRun` can say `true` when nothing was written, so a PDF is checked before it is moved into place.
///
/// The web view is locked down like the editor's HTML cards: page JavaScript is off, every navigation but our own load is cancelled, and
/// it has no base URL, so a `file:` image does not load. The page's own policy lets only `https:` and `data:` images in.
@MainActor
final class PrintRenderer: NSObject, WKNavigationDelegate {
    enum RenderError: LocalizedError {
        case loadFailed(String)
        case printFailed
        case notWritten

        var errorDescription: String? {
            switch self {
            case .loadFailed(let why): return "The page could not be loaded (\(why))."
            case .printFailed: return "The print system reported an error."
            case .notWritten: return "The print system did not produce a PDF."
            }
        }
    }

    /// The hidden web view (visible to tests).
    let webView: WKWebView
    private var waiter: CheckedContinuation<Bool, Never>?
    private var loadError: String?
    private var generation = 0
    private var runDelegate: PrintRunDelegate?

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: Loading

    /// Loads `html` and waits until it has finished (R25). Remote `https:` images get `imageTimeout` seconds; those that have not
    /// arrived by then are given up and show their alt text.
    func load(_ html: String, imageTimeout: TimeInterval = 8) async throws {
        waiter?.resume(returning: false)
        waiter = nil
        loadError = nil
        generation += 1
        let mine = generation
        let ok: Bool = await withCheckedContinuation { continuation in
            waiter = continuation
            webView.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + imageTimeout) { [weak self] in
                guard let self, self.generation == mine, self.waiter != nil else { return }
                self.webView.stopLoading()
                self.finishLoad(true)
            }
        }
        if !ok { throw RenderError.loadFailed(loadError ?? "unknown error") }
        // A remote image that failed (or that is still unanswered after the time limit) is its alt text (R25), not a broken-image icon. Only
        // images that are not embedded are looked at: a `data:` image is always meant to be there, whatever size the engine reports for it.
        _ = try? await webView.evaluateJavaScript(Self.swapBrokenImages)
    }

    private static let swapBrokenImages = """
    (function () {
      document.querySelectorAll('img').forEach(function (i) {
        var src = i.currentSrc || i.getAttribute('src') || '';
        if (src.indexOf('data:') === 0) return;
        if (i.complete && i.naturalWidth > 0) return;
        var s = document.createElement('span');
        s.className = 'dw-missing';
        s.textContent = i.getAttribute('alt') || (src.split('?')[0].split('#')[0].split('/').pop() || 'image');
        i.replaceWith(s);
      });
    })()
    """

    private func finishLoad(_ ok: Bool) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: ok)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoad(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.loadError = message
            self.finishLoad(false)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.loadError = message
            self.finishLoad(false)
        }
    }

    /// The document's HTML is untrusted: nothing may navigate away from the page we loaded (links, `<meta http-equiv="refresh">`,
    /// frames, scripted navigation). Only our own `loadHTMLString` (a main-frame load of `about:blank`) is allowed.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let isOurLoad = navigationAction.navigationType == .other && (navigationAction.targetFrame?.isMainFrame ?? true)
        return isOurLoad && (scheme == nil || scheme == "about") ? .allow : .cancel
    }

    // MARK: Printing

    /// The system default paper (or what the person last chose) with 20 mm margins on every side (R19).
    static func makePrintInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let margin = 20.0 / 25.4 * 72
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// Runs `operation` as a sheet on `window` and says whether it went through. Cancel and a failure both come back `false`.
    private func run(_ operation: NSPrintOperation, in window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            let delegate = PrintRunDelegate { success in continuation.resume(returning: success) }
            runDelegate = delegate
            operation.runModal(for: window, delegate: delegate, didRun: #selector(PrintRunDelegate.didRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    /// Print…: the standard print panel as a sheet on `window` with the paginated preview. True if the job was sent or saved from the
    /// panel; false if the person cancelled (the panel cannot tell that from a failure, so a failure is not reported separately).
    func runPrintPanel(in window: NSWindow, jobTitle: String) async -> Bool {
        let operation = webView.printOperation(with: Self.makePrintInfo())
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return await run(operation, in: window)
    }

    /// Export as PDF…: the same pages with no panel. The PDF is printed to a temporary file, checked, and only then moved to
    /// `destination` in one atomic step, so a failure leaves no partial file and leaves an existing file of that name alone.
    func writePDF(to destination: URL, in window: NSWindow, jobTitle: String) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Downwrite-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let info = Self.makePrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporary
        let operation = webView.printOperation(with: info)
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard await run(operation, in: window) else { throw RenderError.printFailed }
        // `didRun` can say true with nothing written (the spike saw that for a destination that does not exist).
        guard let data = try? Data(contentsOf: temporary), data.count > 8, data.starts(with: Data("%PDF-".utf8)) else { throw RenderError.notWritten }
        try data.write(to: destination, options: .atomic)
    }
}

/// Receives the end of a print operation run as a sheet.
private final class PrintRunDelegate: NSObject {
    private var done: ((Bool) -> Void)?
    init(_ done: @escaping (Bool) -> Void) { self.done = done }

    @objc func didRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        done?(success)
        done = nil
    }
}
