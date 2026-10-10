import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DownwriteCore

/// Print…, Export as PDF… and Export as HTML… for one window.
///
/// Each command works in two phases (R25). First it *prepares*: it takes the text as the editor holds it at that moment (R3), has Core
/// render it off the main thread, reads the images (also off the main thread), renders the Mermaid diagrams one at a time with a time
/// limit, assembles the page and, for the paginated path, loads it into the hidden web view. Only when all that is done does the panel
/// appear: the print panel, or a save panel for the file. It never touches the editor, its text, its undo history or its folds (R5): all
/// it is given is a closure that returns a snapshot.
///
/// Everything that needs a person or a window is a property with a real default, so tests and the self-test drive the same code through
/// `makeHTML`, `writeHTML(to:)` and `writePDF(to:)`.
@MainActor
final class DocumentOutputController: ObservableObject {
    enum Kind { case print, pdf, html }

    /// What a command works from, taken when the command is chosen.
    struct Snapshot {
        var text: String
        /// The document's file, nil for an untitled document.
        var fileURL: URL?
        var displayName: String
    }

    struct Output {
        var html: String
        var omissions: [DocumentHTML.Omission]
    }

    /// True from the moment a command is chosen until it has finished, including while its panel is open (R2: the three menu items are
    /// disabled for this window meanwhile).
    @Published private(set) var isPreparing = false

    // MARK: Seams

    var snapshot: () -> Snapshot = { Snapshot(text: "", fileURL: nil, displayName: "Untitled") }
    /// The window that hosts the sheets, set by the scene.
    var hostWindow: () -> NSWindow? = { nil }
    var renderDiagram: @MainActor (String) async -> Result<String, MermaidError> = { await MermaidService.shared.render($0, dark: false) }
    /// A diagram that takes longer than this is given up on, and the rest of the export does not try again (R15).
    var diagramTimeout: TimeInterval = 20
    var remoteImageTimeout: TimeInterval = 8
    var makeRenderer: @MainActor () -> PrintRenderer = { PrintRenderer() }
    /// Asks where to save (R24); nil if the person cancelled.
    var chooseDestination: @MainActor (_ kind: Kind, _ suggestedName: String, _ directory: URL?) async -> URL? = { _, _, _ in nil }
    var runPrintPanel: @MainActor (_ renderer: PrintRenderer, _ window: NSWindow, _ jobTitle: String) async -> Bool = { await $0.runPrintPanel(in: $1, jobTitle: $2) }
    var presentError: @MainActor (_ title: String, _ message: String) -> Void = { _, _ in }
    var presentOmissions: @MainActor (_ lines: [String]) -> Void = { _ in }

    /// Which controller serves which window, for the end-to-end run (SwiftUI owns the controller; the window is what a script can find).
    private static let registry = NSMapTable<NSWindow, DocumentOutputController>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    static func controller(for window: NSWindow) -> DocumentOutputController? { registry.object(forKey: window) }

    private weak var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private(set) var windowClosed = false

    init() {
        chooseDestination = { [weak self] kind, name, directory in await self?.showSavePanel(kind: kind, suggestedName: name, directory: directory) }
        presentError = { [weak self] title, message in self?.showAlert(title: title, message: message) }
        presentOmissions = { [weak self] lines in self?.showAlert(title: "Some images could not be included", message: lines.joined(separator: "\n"), style: .informational) }
    }

    /// Follows `window` so that closing it drops any work in flight (R25).
    func attach(window newWindow: NSWindow?) {
        guard newWindow !== window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        window = newWindow
        windowClosed = false
        hostWindow = { [weak self] in self?.window }
        guard let newWindow else { return }
        Self.registry.setObject(self, forKey: newWindow)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowClosed = true }
        }
    }

    /// For tests: the window went away.
    func markWindowClosed() { windowClosed = true }

    // MARK: The three commands

    func printDocument() { start(.print) }
    func exportPDF() { start(.pdf) }
    func exportHTML() { start(.html) }

    private func start(_ kind: Kind) {
        guard !isPreparing else { return }
        isPreparing = true
        let taken = snapshot()      // R3: the text now; later edits do not reach this output
        Task { [weak self] in
            await self?.run(kind, taken)
            self?.isPreparing = false
        }
    }

    private func run(_ kind: Kind, _ taken: Snapshot) async {
        guard let output = await prepare(taken, target: kind == .html ? .screen : .print) else { return }
        let folder = taken.fileURL?.deletingLastPathComponent()
        do {
            switch kind {
            case .html:
                guard let url = await chooseDestination(.html, OutputNaming.defaultFileName(forDisplayName: taken.displayName, extension: "html"), folder),
                      !windowClosed else { return }
                try Data(output.html.utf8).write(to: url, options: .atomic)
                report(output.omissions)
            case .pdf:
                let renderer = makeRenderer()
                try await renderer.load(output.html, imageTimeout: remoteImageTimeout)
                guard !windowClosed, let window = hostWindow(),
                      let url = await chooseDestination(.pdf, OutputNaming.defaultFileName(forDisplayName: taken.displayName, extension: "pdf"), folder),
                      !windowClosed else { return }
                try await renderer.writePDF(to: url, in: window, jobTitle: taken.displayName)
                report(output.omissions)
            case .print:
                let renderer = makeRenderer()
                try await renderer.load(output.html, imageTimeout: remoteImageTimeout)
                guard !windowClosed, let window = hostWindow() else { return }
                if await runPrintPanel(renderer, window, taken.displayName) { report(output.omissions) }
            }
        } catch {
            presentError(kind == .print ? "Couldn't print" : "Couldn't export", error.localizedDescription)
        }
    }

    /// The sheet that lists what was left out, after the operation has finished (R16).
    private func report(_ omissions: [DocumentHTML.Omission]) {
        guard !omissions.isEmpty, !windowClosed else { return }
        presentOmissions(DocumentHTML.summaryLines(of: omissions))
    }

    // MARK: Without a person: for tests and the self-test

    struct Busy: Error {}

    /// The page for the text as it is now. Nil if the window was closed meanwhile.
    func makeHTML(target: DocumentHTML.Target = .screen) async throws -> Output? {
        guard !isPreparing else { throw Busy() }
        isPreparing = true
        defer { isPreparing = false }
        return await prepare(snapshot(), target: target)
    }

    /// Export as HTML… without the panel: the same file, written atomically. Returns what was left out.
    @discardableResult
    func writeHTML(to url: URL) async throws -> [DocumentHTML.Omission] {
        guard !isPreparing else { throw Busy() }
        isPreparing = true
        defer { isPreparing = false }
        guard let output = await prepare(snapshot(), target: .screen) else { throw CancellationError() }
        try Data(output.html.utf8).write(to: url, options: .atomic)
        return output.omissions
    }

    /// Export as PDF… without the panel.
    @discardableResult
    func writePDF(to url: URL) async throws -> [DocumentHTML.Omission] {
        guard !isPreparing else { throw Busy() }
        isPreparing = true
        defer { isPreparing = false }
        let taken = snapshot()
        guard let output = await prepare(taken, target: .print), let window = hostWindow() else { throw CancellationError() }
        let renderer = makeRenderer()
        try await renderer.load(output.html, imageTimeout: remoteImageTimeout)
        try await renderer.writePDF(to: url, in: window, jobTitle: taken.displayName)
        return output.omissions
    }

    /// The print operation a Print… would run, for the self-test to read the paper size and page count from (the panel itself is modal).
    func makePrintOperation() async throws -> (operation: NSPrintOperation, renderer: PrintRenderer)? {
        guard !isPreparing else { throw Busy() }
        isPreparing = true
        defer { isPreparing = false }
        guard let output = await prepare(snapshot(), target: .print) else { return nil }
        let renderer = makeRenderer()
        try await renderer.load(output.html, imageTimeout: remoteImageTimeout)
        return (renderer.webView.printOperation(with: PrintRenderer.makePrintInfo()), renderer)
    }

    // MARK: Preparing

    /// Phases one to four: render, read images, render diagrams, assemble. Nil if the window closed on the way (nothing more is done).
    private func prepare(_ taken: Snapshot, target: DocumentHTML.Target) async -> Output? {
        let options = DocumentHTML.Options(target: target, documentName: taken.displayName)
        let text = taken.text
        let prepared = await Task.detached(priority: .userInitiated) { DocumentHTML.prepare(text, options: options) }.value
        guard !windowClosed else { return nil }

        let folder = taken.fileURL?.deletingLastPathComponent()
        let sources = prepared.imageSources
        let images = await Task.detached(priority: .userInitiated) {
            DocumentHTML.resolveImages(sources, documentHasFolder: folder != nil) { source in
                ImageLoader.fileURL(for: source, base: folder).map { ImageLoader.embed(at: $0) } ?? .notFound
            }
        }.value
        guard !windowClosed else { return nil }

        let outcomes = await renderDiagrams(prepared.diagrams)
        guard !windowClosed else { return nil }

        let assembled = await Task.detached(priority: .userInitiated) { DocumentHTML.assemble(prepared, images: images, diagrams: outcomes) }.value
        return windowClosed ? nil : Output(html: assembled.html, omissions: assembled.omissions)
    }

    private enum Race {
        case rendered(Result<String, MermaidError>)
        case timedOut
    }

    /// Hands a continuation back at most once, whichever of two unstructured tasks gets there first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Race, Never>?
        init(_ continuation: CheckedContinuation<Race, Never>) { self.continuation = continuation }
        func resume(_ value: Race) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// One diagram against the clock. `MermaidService.render` ignores cancellation, so this is not a task group (which would wait for it
    /// for ever): two plain tasks race, and the loser's result is dropped.
    private func race(_ source: String) async -> Race {
        let limit = diagramTimeout
        let render = renderDiagram
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { @MainActor in once.resume(.rendered(await render(source))) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(limit, 0) * 1_000_000_000))
                once.resume(.timedOut)
            }
        }
    }

    /// Diagrams in order. After the first timeout the shared renderer may be stuck, so the others are not attempted (R15).
    private func renderDiagrams(_ sources: [String]) async -> [DocumentHTML.DiagramOutcome] {
        var outcomes: [DocumentHTML.DiagramOutcome] = []
        var stuck = false
        for source in sources {
            if stuck || windowClosed {
                outcomes.append(.failed(reason: "renderer not responding"))
                continue
            }
            switch await race(source) {
            case .rendered(.success(let svg)): outcomes.append(.svg(svg))
            case .rendered(.failure(.unavailable)): outcomes.append(.failed(reason: "the diagram renderer is not available"))
            case .rendered(.failure(.failed(let why))): outcomes.append(.failed(reason: why))
            case .timedOut:
                stuck = true
                outcomes.append(.failed(reason: "timed out"))
            }
        }
        return outcomes
    }

    // MARK: Panels and alerts

    private func showSavePanel(kind: Kind, suggestedName: String, directory: URL?) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind == .pdf ? .pdf : .html]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = directory
        if let window = hostWindow() {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK ? panel.url : nil) }
            }
        }
        return await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0 == .OK ? panel.url : nil) }
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = hostWindow() { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// Reports the window a view lives in, for the controller (it hosts the sheets and tells it when to give up).
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onWindow(nsView?.window) }
    }
}
