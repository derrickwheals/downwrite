import XCTest
import AppKit
import PDFKit
import WebKit
@testable import Downwrite
import DownwriteCore

/// Print and PDF output on real WebKit and real PDFs (R19 to R22, R28). The page is Fixture P, rendered by the same Core code the app
/// uses, with real image files on disk.
@MainActor
final class PrintRendererTests: XCTestCase {
    // MARK: Helpers

    /// A folder with the fixture document, its two small images and an image of 8,000,001 bytes (not committed; made here).
    static func makeFixtureFolder() throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["export-demo.md", "local.png", "local.svg"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        try Data(count: 8_000_001).write(to: dir.appendingPathComponent("big.png"))
        return dir
    }

    /// The same resolution the app does: files through `ImageLoader`, one stand-in drawing for each diagram.
    static func page(of markdown: String, folder: URL?, target: DocumentHTML.Target) -> (html: String, omissions: [DocumentHTML.Omission]) {
        let p = DocumentHTML.prepare(markdown, options: .init(target: target, documentName: "export-demo.md"))
        let images = DocumentHTML.resolveImages(p.imageSources, documentHasFolder: folder != nil) { source in
            ImageLoader.fileURL(for: source, base: folder).map(ImageLoader.embed(at:)) ?? .notFound
        }
        let drawing = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"260\" height=\"110\" viewBox=\"0 0 260 110\"><rect x=\"2\" y=\"2\" width=\"256\" height=\"106\" fill=\"#eef\" stroke=\"#336\"/><text x=\"20\" y=\"60\" font-size=\"16\">Diagram stand-in</text></svg>"
        return DocumentHTML.assemble(p, images: images, diagrams: p.diagrams.map { _ in .svg(drawing) })
    }

    static func hostWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        return w
    }

    struct Output {
        var url: URL
        var document: PDFDocument
        var pageTexts: [String]
        var omissions: [DocumentHTML.Omission]
    }

    private static var cachedFixtureOutput: Output?

    /// Fixture P as a PDF, made once for the tests that read it.
    static func fixtureOutput() async throws -> Output {
        if let cached = cachedFixtureOutput { return cached }
        let folder = try makeFixtureFolder()
        let markdown = try String(contentsOf: folder.appendingPathComponent("export-demo.md"), encoding: .utf8)
        let (html, omissions) = page(of: markdown, folder: folder, target: .print)
        let renderer = PrintRenderer()
        try await renderer.load(html)
        let window = hostWindow()
        defer { window.close() }
        let url = folder.appendingPathComponent("out.pdf")
        try await renderer.writePDF(to: url, in: window, jobTitle: "export-demo")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let texts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        let output = Output(url: url, document: document, pageTexts: texts, omissions: omissions)
        cachedFixtureOutput = output
        return output
    }

    private func pageIndex(of marker: String, in texts: [String]) -> Int? { texts.firstIndex { $0.contains(marker) } }

    // MARK: R22, R19: the PDF

    func testTheFixtureMakesAValidMultiPagePDFWithSelectableText() async throws {
        let out = try await Self.fixtureOutput()
        XCTAssertGreaterThan(out.document.pageCount, 1)
        XCTAssertTrue(try Data(contentsOf: out.url).starts(with: Data("%PDF-".utf8)))
        XCTAssertTrue(out.pageTexts[0].contains("Fixture P with bold"), "the text is text, not a picture")
        XCTAssertTrue(out.pageTexts.joined().contains("Text inside the details."), "a <details> is open on paper (R20)")
    }

    func testNoPageIsBlank() async throws {
        let out = try await Self.fixtureOutput()
        for (i, text) in out.pageTexts.enumerated() { XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "page \(i + 1) is blank") }
    }

    func testThePageSizeIsTheSystemDefaultPaper() async throws {
        let out = try await Self.fixtureOutput()
        let box = try XCTUnwrap(out.document.page(at: 0)).bounds(for: .mediaBox)
        let paper = NSPrintInfo.shared.paperSize
        XCTAssertEqual(box.width.rounded(), paper.width.rounded())
        XCTAssertEqual(box.height.rounded(), paper.height.rounded())
    }

    func testTextStaysInsideTwentyMillimetreMargins() async throws {
        let out = try await Self.fixtureOutput()
        let margin = 20.0 / 25.4 * 72
        for i in 0..<out.document.pageCount {
            let page = try XCTUnwrap(out.document.page(at: i))
            let box = page.bounds(for: .mediaBox)
            let lines = page.selection(for: box)?.selectionsByLine() ?? []
            let bounds = lines.filter { !($0.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.bounds(for: page) }
            XCTAssertFalse(bounds.isEmpty, "page \(i + 1)")
            XCTAssertGreaterThanOrEqual(bounds.map(\.minX).min() ?? 0, margin - 4, "left, page \(i + 1)")
            XCTAssertLessThanOrEqual(bounds.map(\.maxX).max() ?? 0, box.width - margin + 4, "right, page \(i + 1): code wraps instead of running off")
            XCTAssertGreaterThanOrEqual(bounds.map(\.minY).min() ?? 0, margin - 6, "bottom, page \(i + 1)")
            XCTAssertLessThanOrEqual(bounds.map(\.maxY).max() ?? 0, box.height - margin + 6, "top, page \(i + 1)")
        }
    }

    func testNoTableRowIsSplitAcrossPages() async throws {
        let out = try await Self.fixtureOutput()
        for i in 1...120 {
            let first = pageIndex(of: String(format: "Row %03d", i), in: out.pageTexts)
            let last = pageIndex(of: String(format: "end of row %03d", i), in: out.pageTexts)
            XCTAssertNotNil(first, "row \(i)")
            XCTAssertEqual(first, last, "row \(i) is cut between two pages")
        }
        let tablePages = Set((1...120).compactMap { pageIndex(of: String(format: "Row %03d", $0), in: out.pageTexts) })
        XCTAssertGreaterThan(tablePages.count, 1, "the 120-row table needs more than a page")
    }

    func testPageOneIsWhiteWithDarkText() async throws {
        let out = try await Self.fixtureOutput()
        let page = try XCTUnwrap(out.document.page(at: 0))
        let image = page.thumbnail(of: NSSize(width: 400, height: 560), for: .mediaBox)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        func luminance(_ x: Int, _ y: Int) -> Double {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            return Double(0.2126 * (c?.redComponent ?? 0) + 0.7152 * (c?.greenComponent ?? 0) + 0.0722 * (c?.blueComponent ?? 0))
        }
        XCTAssertGreaterThan(luminance(2, 2), 0.99, "the corner is paper white")
        XCTAssertGreaterThan(luminance(rep.pixelsWide - 3, rep.pixelsHigh - 3), 0.99)
        var darkest = 1.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) { darkest = min(darkest, luminance(x, y)) } }
        XCTAssertLessThan(darkest, 0.35, "the text is dark")
    }

    func testCodeCardsAndTaskBoxesAreDrawnWithTheirColoursOnPaper() async throws {
        let out = try await Self.fixtureOutput()
        // Backgrounds are printed (print-color-adjust): some pixel somewhere is the code card's light grey and some is the task accent.
        var sawCard = false, sawAccent = false
        for i in 0..<out.document.pageCount {
            let page = try XCTUnwrap(out.document.page(at: i))
            let image = page.thumbnail(of: NSSize(width: 300, height: 420), for: .mediaBox)
            guard let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else { continue }
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let (r, g, b) = (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                    if abs(r - 0xF3) <= 2, abs(g - 0xF3) <= 2, abs(b - 0xF6) <= 2 { sawCard = true }
                    if abs(r - 0x40) <= 14, abs(g - 0x54) <= 14, abs(b - 0xD6) <= 14 { sawAccent = true }
                }
            }
        }
        XCTAssertTrue(sawCard, "the code card's grey was not printed")
        XCTAssertTrue(sawAccent, "the task box's accent colour was not printed")
    }


    /// A row with a tall cell must stay whole wherever the page break falls: the same table is printed at four vertical offsets.
    func testNoMultiLineTableRowIsCutWhereverThePageBreakFalls() async throws {
        func row(_ i: Int) -> String { String(format: "| Row %03d | code %d | %d<br>middle %03d<br>end of row %03d |\n", i, i, i * 7 % 101, i, i) }
        var table = "| Row | Code | Value |\n|:--|:--:|--:|\n"
        for i in 1...150 { table += row(i) }
        for filler in [3, 9, 15, 21] {
            let md = (0..<filler).map { "Filler paragraph \($0)." }.joined(separator: "\n\n") + "\n\n" + table
            let (html, _) = Self.page(of: md, folder: nil, target: .print)
            let renderer = PrintRenderer()
            try await renderer.load(html)
            let window = Self.hostWindow()
            defer { window.close() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dw-rows-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            try await renderer.writePDF(to: url, in: window, jobTitle: "rows")
            let doc = try XCTUnwrap(PDFDocument(url: url))
            let texts = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
            XCTAssertGreaterThan(doc.pageCount, 3)
            for i in 1...150 {
                let markers = [String(format: "Row %03d", i), String(format: "middle %03d", i), String(format: "end of row %03d", i)]
                let pages = Set(markers.map { m in texts.firstIndex { $0.contains(m) } ?? -1 })
                XCTAssertEqual(pages.count, 1, "row \(i) is cut across pages (offset \(filler)): \(pages)")
            }
        }
    }

    // MARK: R19: headings (as amended: kept with the next block when both fit a page)

    func testNoPageEndsOnAHeadingWhenEachSectionFitsAPage() async throws {
        var md = ""
        for n in 1...150 {
            md += "## Section \(String(format: "%03d", n)) heading\n\n"
            for k in 0..<(1 + (n * 7) % 4) {
                md += "Section \(n) paragraph \(k). " + String(repeating: "Lorem ipsum dolor sit amet. ", count: 3 + (n + k * 5) % 9) + "\n\n"
            }
        }
        let (html, _) = Self.page(of: md, folder: nil, target: .print)
        let renderer = PrintRenderer()
        try await renderer.load(html)
        let window = Self.hostWindow()
        defer { window.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dw-headings-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await renderer.writePDF(to: url, in: window, jobTitle: "headings")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(doc.pageCount, 10)
        var endings = 0
        for i in 0..<doc.pageCount {
            let lines = (doc.page(at: i)?.string ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let last = lines.last, last.range(of: #"^Section \d{3} heading$"#, options: .regularExpression) != nil { endings += 1 }
            XCTAssertFalse(lines.isEmpty, "page \(i + 1) is blank")
        }
        XCTAssertEqual(endings, 0, "a heading is the last thing on \(endings) page(s)")
    }

    // MARK: R28: the web view is locked down

    func testAScriptInThePageDoesNotRun() async throws {
        let renderer = PrintRenderer()
        try await renderer.load("<!doctype html><title>before</title><script>document.title = 'ran'</script><p id=\"x\">hi</p>")
        let title = try await renderer.webView.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "before")
    }

    func testAMetaRefreshAndALinkClickDoNotNavigate() async throws {
        let renderer = PrintRenderer()
        try await renderer.load("<!doctype html><meta http-equiv=\"refresh\" content=\"0;url=https://example.com/\"><a id=\"a\" href=\"https://example.com/other\">go</a>")
        _ = try? await renderer.webView.evaluateJavaScript("document.getElementById('a').click()")
        try await Task.sleep(nanoseconds: 800_000_000)
        let scheme = renderer.webView.url?.scheme
        XCTAssertTrue(scheme == nil || scheme == "about", "navigated to \(String(describing: renderer.webView.url))")
        let text = try await renderer.webView.evaluateJavaScript("document.getElementById('a') ? document.getElementById('a').textContent : 'gone'") as? String
        XCTAssertEqual(text, "go", "the page was not replaced")
    }

    func testThePageCannotReadLocalFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-secret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!.write(to: dir.appendingPathComponent("s.png"))
        let renderer = PrintRenderer()
        try await renderer.load("<!doctype html><img id=\"i\" src=\"file://\(dir.path)/s.png\"><p>x</p>")
        let width = try await renderer.webView.evaluateJavaScript("document.getElementById('i').naturalWidth") as? Int
        XCTAssertEqual(width, 0, "a file: image is not loaded by the print web view")
    }
}


/// The controller: phases, the preparing flag, the text it works from, failure and the left-out sheet (R2 to R5, R15, R16, R24 to R26).
@MainActor
final class DocumentOutputControllerTests: XCTestCase {
    /// A controller wired to recorders instead of panels.
    @MainActor final class Rig {
        let controller = DocumentOutputController()
        var text = "# Title\n\nBody text.\n"
        var fileURL: URL?
        var displayName = "Untitled"
        var events: [String] = []
        var destination: URL?
        var asked: [(kind: DocumentOutputController.Kind, name: String, directory: URL?)] = []
        var errors: [(String, String)] = []
        var sheets: [[String]] = []
        var diagramCalls: [String] = []
        var window: NSWindow?

        init() {
            controller.snapshot = { [unowned self] in .init(text: text, fileURL: fileURL, displayName: displayName) }
            controller.hostWindow = { [unowned self] in window }
            controller.chooseDestination = { [unowned self] kind, name, directory in
                events.append("panel:\(kind)")
                asked.append((kind, name, directory))
                return destination
            }
            controller.presentError = { [unowned self] title, message in events.append("error"); errors.append((title, message)) }
            controller.presentOmissions = { [unowned self] lines in events.append("sheet"); sheets.append(lines) }
            controller.renderDiagram = { [unowned self] source in
                diagramCalls.append(source)
                return .success("<svg xmlns=\"http://www.w3.org/2000/svg\" id=\"dwm\(diagramCalls.count)\" width=\"40\" height=\"20\" viewBox=\"0 0 40 20\"><rect width=\"40\" height=\"20\"/></svg>")
            }
            controller.diagramTimeout = 2
        }

        /// Waits until the command that was started has finished.
        func finish() async { _ = await waitUntil(timeout: 20) { !controller.isPreparing } }
    }

    private func temporaryFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-ctl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: R3: the text the editor holds

    func testTheOutputIsMadeFromTheTextAsItIsAndNotFromTheFileOnDisk() async throws {
        let dir = try temporaryFolder()
        let file = dir.appendingPathComponent("notes.md")
        try "# From disk\n\nDISK TEXT\n".write(to: file, atomically: true, encoding: .utf8)
        let rig = Rig()
        rig.fileURL = file
        rig.displayName = "notes.md"
        rig.text = "# Unsaved edit\n\nUNSAVED TEXT\n"
        let made = try await rig.controller.makeHTML()
        let html = try XCTUnwrap(made)
        XCTAssertTrue(html.html.contains("UNSAVED TEXT"))
        XCTAssertFalse(html.html.contains("DISK TEXT"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# From disk\n\nDISK TEXT\n", "the file on disk is untouched")
    }

    func testAnUntitledDocumentIsOutputAsItStands() async throws {
        let rig = Rig()
        rig.text = "Just typed.\n"
        let made = try await rig.controller.makeHTML()
        let html = try XCTUnwrap(made)
        XCTAssertTrue(html.html.contains("<p>Just typed.</p>"))
        XCTAssertTrue(html.html.contains("<title>Untitled</title>"))
    }

    func testAnEditMadeAfterTheCommandWasChosenIsNotInTheFile() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.destination = dir.appendingPathComponent("out.html")
        rig.text = "BEFORE\n"
        rig.controller.exportHTML()
        rig.text = "AFTER\n"        // typed while it prepares
        await rig.finish()
        let written = try String(contentsOf: dir.appendingPathComponent("out.html"), encoding: .utf8)
        XCTAssertTrue(written.contains("BEFORE"))
        XCTAssertFalse(written.contains("AFTER"))
    }

    // MARK: R25: phases and the preparing flag

    func testThePanelComesOnlyAfterPreparingAndTheFlagIsHeldUntilTheEnd() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.destination = dir.appendingPathComponent("a.html")
        rig.text = "```mermaid\ngraph TD\n```\n"
        var flagWhenAsked: Bool?
        rig.controller.chooseDestination = { [unowned rig] kind, name, directory in
            flagWhenAsked = rig.controller.isPreparing
            rig.events.append("panel")
            return rig.destination
        }
        XCTAssertFalse(rig.controller.isPreparing)
        rig.controller.exportHTML()
        XCTAssertTrue(rig.controller.isPreparing, "disabled from the moment it is chosen")
        await rig.finish()
        XCTAssertEqual(rig.diagramCalls.count, 1, "the diagram was rendered before the panel")
        XCTAssertEqual(flagWhenAsked, true)
        XCTAssertFalse(rig.controller.isPreparing)
        XCTAssertEqual(rig.events, ["panel"])
    }

    func testASecondCommandIsRefusedWhilePreparing() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.destination = dir.appendingPathComponent("a.html")
        rig.controller.exportHTML()
        rig.controller.exportHTML()
        rig.controller.exportPDF()
        rig.controller.printDocument()
        await rig.finish()
        XCTAssertEqual(rig.events, ["panel:html"], "one command ran")
        XCTAssertEqual(rig.asked.count, 1)
    }

    func testAnotherCommandCanStartOnceTheFirstHasFinished() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.destination = dir.appendingPathComponent("a.html")
        rig.controller.exportHTML()
        await rig.finish()
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertEqual(rig.asked.count, 2)
    }

    func testControllersAreIndependentPerWindow() async throws {
        let a = Rig(), b = Rig()
        a.controller.exportHTML()
        XCTAssertTrue(a.controller.isPreparing)
        XCTAssertFalse(b.controller.isPreparing, "another window is unaffected")
        await a.finish()
    }

    func testClosingTheWindowWhilePreparingDropsTheWork() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.destination = dir.appendingPathComponent("never.html")
        rig.controller.exportHTML()
        rig.controller.markWindowClosed()
        await rig.finish()
        XCTAssertEqual(rig.events, [], "no panel, no error, no sheet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("never.html").path))
    }

    // MARK: R24: the save panel

    func testTheSavePanelIsAskedForTheRightNameTypeAndFolder() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.fileURL = dir.appendingPathComponent("My Notes.md")
        rig.displayName = "My Notes.md"
        rig.destination = dir.appendingPathComponent("o.html")
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertEqual(rig.asked.first?.kind, .html)
        XCTAssertEqual(rig.asked.first?.name, "My Notes.html")
        XCTAssertEqual(rig.asked.first?.directory?.standardizedFileURL.path, dir.standardizedFileURL.path)
    }

    func testAnUntitledDocumentIsCalledUntitledAndHasNoFolder() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.destination = dir.appendingPathComponent("o.html")
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertEqual(rig.asked.first?.name, "Untitled.html")
        XCTAssertNil(rig.asked.first?.directory)
    }

    func testCancellingTheSavePanelWritesNothingAndShowsNothing() async throws {
        let rig = Rig()
        rig.destination = nil
        rig.text = "![gone](missing.png)\n"
        rig.fileURL = URL(fileURLWithPath: "/tmp/x/doc.md")
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertEqual(rig.events, ["panel:html"])
        XCTAssertEqual(rig.sheets.count, 0, "no sheet when the person cancelled")
    }

    // MARK: R26: failure

    func testAnUnwritableDestinationGivesAnAlertAndLeavesNoFile() async throws {
        let rig = Rig()
        rig.destination = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/out.html")
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertEqual(rig.errors.count, 1)
        XCTAssertEqual(rig.errors.first?.0, "Couldn't export")
        XCTAssertFalse((rig.errors.first?.1 ?? "").isEmpty, "the system's reason is shown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.destination!.path))
        XCTAssertEqual(rig.sheets.count, 0)
    }

    func testAFailedWriteLeavesAnExistingFileAlone() async throws {
        let dir = try temporaryFolder()
        let existing = dir.appendingPathComponent("keep.html")
        try "ORIGINAL".write(to: existing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let rig = Rig()
        rig.destination = existing
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertEqual(rig.errors.first?.0, "Couldn't export")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "ORIGINAL")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["keep.html"], "no partial file beside it")
    }

    // MARK: R16: the sheet

    func testTheSheetListsWhatWasLeftOutAfterTheFileIsWritten() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.fileURL = dir.appendingPathComponent("doc.md")
        rig.destination = dir.appendingPathComponent("out.html")
        rig.text = "![a](missing.png) ![b](http://example.com/a.png) ![c](https://example.com/c.png)\n"
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertEqual(rig.events, ["panel:html", "sheet"], "the sheet comes after the panel, once")
        XCTAssertEqual(rig.sheets, [["missing.png (file not found)", "http://example.com/a.png (http images are not allowed)"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out.html").path))
    }

    func testNoSheetWhenNothingWasLeftOut() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.destination = dir.appendingPathComponent("out.html")
        rig.text = "![c](https://example.com/c.png)\n"
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertEqual(rig.events, ["panel:html"])
    }

    // MARK: R15: diagrams and the time limit

    func testADiagramThatFailsIsANoteAndTheExportSucceeds() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.controller.renderDiagram = { _ in .failure(.failed("Parse error on line 2")) }
        rig.text = "```mermaid\ngraph TD\n  A --> ((\n```\n"
        rig.destination = dir.appendingPathComponent("o.html")
        rig.controller.exportHTML()
        await rig.finish()
        let html = try String(contentsOf: rig.destination!, encoding: .utf8)
        XCTAssertTrue(html.contains("Diagram could not be rendered: Parse error on line 2"))
        XCTAssertTrue(html.contains("A --&gt; (("))
        XCTAssertEqual(rig.errors.count, 0)
    }

    func testARendererThatNeverAnswersTimesOutAndTheRestAreNotAttempted() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        var calls = 0
        rig.controller.renderDiagram = { _ in
            calls += 1
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)   // an hour: it never returns in this test
            return .success("<svg/>")
        }
        rig.controller.diagramTimeout = 0.4
        rig.text = "```mermaid\nA\n```\n\n```mermaid\nB\n```\n\n```mermaid\nC\n```\n"
        rig.destination = dir.appendingPathComponent("o.html")
        let started = Date()
        rig.controller.exportHTML()
        await rig.finish()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "it did not wait for the stuck renderer")
        XCTAssertEqual(calls, 1, "after the first timeout the others are not attempted")
        let html = try String(contentsOf: rig.destination!, encoding: .utf8)
        XCTAssertTrue(html.contains("Diagram could not be rendered: timed out"))
        XCTAssertEqual(html.components(separatedBy: "Diagram could not be rendered: renderer not responding").count - 1, 2)
        XCTAssertTrue(html.contains("<pre><code>B</code></pre>") && html.contains("<pre><code>C</code></pre>"))
    }

    // MARK: R4, R5: the editor is not involved

    func testOutputIsByteIdenticalWhateverTheWindowLooksLikeAndTheDocumentIsNotTouched() async throws {
        let text = "# Title\n\n## Section\n\nBody with **bold** and ==mark==.\n\n- [x] done\n- [ ] todo\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let plain = EditorHarness(text: text, dark: false)
        let styled = EditorHarness(text: text, dark: true)
        let mocha = EditorSettings(font: .avenirNext, size: 21, lineHeight: 1.8, width: 560, spellCheck: true, lightTheme: ThemeCatalog.defaultLightID, darkTheme: "catppuccin-mocha")
        styled.coordinator.update(text: text, settings: mocha)
        styled.coordinator.setSourceMode(true)
        styled.coordinator.foldAll()
        styled.select(3, 4)

        func make(_ h: EditorHarness) async throws -> String {
            let rig = Rig()
            rig.controller.snapshot = { .init(text: h.textView.string, fileURL: nil, displayName: "doc.md") }
            let made = try await rig.controller.makeHTML()
            return try XCTUnwrap(made).html
        }
        let before = (string: styled.textView.string, selection: styled.textView.selectedRange(), canUndo: styled.textView.undoManager?.canUndo,
                      folds: styled.coordinator.foldState, source: styled.coordinator.sourceMode)
        let a = try await make(plain)
        let b = try await make(styled)
        XCTAssertEqual(a, b, "byte for byte")
        XCTAssertEqual(styled.textView.string, before.string)
        XCTAssertEqual(styled.textView.selectedRange(), before.selection)
        XCTAssertEqual(styled.textView.undoManager?.canUndo, before.canUndo)
        XCTAssertEqual(styled.coordinator.foldState, before.folds)
        XCTAssertEqual(styled.coordinator.sourceMode, before.source)
        XCTAssertEqual(styled.box.value, text)
    }

    // MARK: The three real outputs through the controller

    func testExportAsPDFThroughTheControllerWritesAValidFile() async throws {
        let dir = try temporaryFolder()
        let rig = Rig()
        rig.window = PrintRendererTests.hostWindow()
        defer { rig.window?.close() }
        rig.displayName = "doc.md"
        rig.text = "# Title\n\nSome text in a PDF.\n"
        rig.destination = dir.appendingPathComponent("doc.pdf")
        rig.controller.exportPDF()
        await rig.finish()
        XCTAssertEqual(rig.events, ["panel:pdf"])
        XCTAssertEqual(rig.asked.first?.name, "doc.pdf")
        XCTAssertTrue(try Data(contentsOf: rig.destination!).starts(with: Data("%PDF-".utf8)))
        XCTAssertEqual(rig.errors.count, 0)
    }

    func testAnUnwritablePDFDestinationGivesAnAlertAndLeavesNoFile() async throws {
        let rig = Rig()
        rig.window = PrintRendererTests.hostWindow()
        defer { rig.window?.close() }
        rig.destination = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/out.pdf")
        rig.controller.exportPDF()
        await rig.finish()
        XCTAssertEqual(rig.errors.first?.0, "Couldn't export")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.destination!.path))
    }

    func testPrintShowsThePanelOnceAndTheSheetOnlyIfThePrintWentThrough() async throws {
        for succeeds in [true, false] {
            let rig = Rig()
            rig.window = PrintRendererTests.hostWindow()
            defer { rig.window?.close() }
            rig.fileURL = URL(fileURLWithPath: "/tmp/nowhere/doc.md")
            rig.text = "![x](missing.png)\n"
            var panels = 0
            rig.controller.runPrintPanel = { _, _, _ in panels += 1; return succeeds }
            rig.controller.printDocument()
            await rig.finish()
            XCTAssertEqual(panels, 1)
            XCTAssertEqual(rig.sheets.count, succeeds ? 1 : 0, succeeds ? "sent: the sheet shows" : "cancelled: nothing shows")
            XCTAssertEqual(rig.errors.count, 0)
        }
    }

    func testTheHTMLFileLoadsInAFreshWebViewWithEveryImageAndDiagram() async throws {
        let folder = try PrintRendererTests.makeFixtureFolder()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let rig = Rig()
        rig.controller.renderDiagram = { source in await MermaidService.shared.render(source, dark: false) }
        rig.controller.diagramTimeout = 30
        rig.fileURL = folder.appendingPathComponent("export-demo.md")
        rig.displayName = "export-demo.md"
        rig.text = try String(contentsOf: folder.appendingPathComponent("export-demo.md"), encoding: .utf8)
        let out = folder.appendingPathComponent("export-demo.html")
        let omissions = try await rig.controller.writeHTML(to: out)
        XCTAssertEqual(Set(omissions.map(\.source)), ["missing.png", "big.png", "http://example.com/a.png"], "exactly the three images Fixture P cannot include")
        XCTAssertEqual(omissions.first { $0.source == "big.png" }?.reason, .tooLarge)

        let html = try String(contentsOf: out, encoding: .utf8)
        for forbidden in ["<script", "onerror", "javascript:", "Secret front matter"] { XCTAssertFalse(html.lowercased().contains(forbidden.lowercased()), forbidden) }
        XCTAssertTrue(html.hasPrefix("<!doctype html>\n<html>\n<head>\n<meta http-equiv=\"Content-Security-Policy\""))

        // A new web view with no base URL, the way a browser on another Mac would open it: nothing refers to this Mac.
        let loader = PrintRenderer()
        try await loader.load(html)
        let script = "JSON.stringify({embedded: Array.from(document.images).filter(i => i.src.startsWith('data:')).map(i => i.naturalWidth), diagrams: document.querySelectorAll('.dw-diagram svg').length, notes: document.querySelectorAll('.dw-note').length})"
        let reply = try await loader.webView.evaluateJavaScript(script) as? String
        let result = try XCTUnwrap(reply).data(using: .utf8).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let embedded = try XCTUnwrap(result?["embedded"] as? [Int])
        XCTAssertEqual(embedded.count, 4, "local.png (three times) and local.svg, all as data URIs")
        XCTAssertTrue(embedded.allSatisfy { $0 > 0 }, "every embedded image decodes: \(embedded)")
        XCTAssertEqual(result?["diagrams"] as? Int, 2, "the two good diagrams are inline SVG")
        XCTAssertEqual(result?["notes"] as? Int, 1, "the broken one is a note above its source")
    }

    // MARK: R27: the window stays responsive while preparing

    func testPreparingALargeDocumentNeverStallsTheMainThreadForLong() async throws {
        let folder = try temporaryFolder()
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        for n in 0..<20 { try FileManager.default.copyItem(at: fixtures.appendingPathComponent("local.png"), to: folder.appendingPathComponent("pic\(n).png")) }
        var lines: [String] = []
        for i in 0..<930 {
            lines += ["## Section \(i % 50)", "",
                      "A paragraph with **bold**, *italic*, `code`, a [link](https://example.com/\(i)), ==highlight== and https://example.org/page\(i) in it. "
                          + String(repeating: "Some more words to make the line a realistic length. ", count: 10), "",
                      "- item one", "  - nested [ ] text", "- [x] done task", "1. first", "2. second", "",
                      "> quote with ==mark== text", "", "| a | b |", "|---|--:|", "| 1 | `x` |", "",
                      "```swift", "let x = \(i) // </pre><script>", "```", "", i < 20 ? "![img](pic\(i).png)" : "", ""]
        }
        lines += ["```mermaid", "graph TD", "  A --> B", "```", "", "```mermaid", "graph TD", "  B --> C", "```", "", "```mermaid", "graph TD", "  C --> D", "```"]
        XCTAssertGreaterThanOrEqual(lines.count, 20_000)

        let rig = Rig()
        rig.fileURL = folder.appendingPathComponent("big.md")
        rig.displayName = "big.md"
        rig.text = lines.joined(separator: "\n")
        rig.destination = folder.appendingPathComponent("big.html")
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" id=\"dwm\" viewBox=\"0 0 400 300\">" + String(repeating: "<rect x=\"1\" y=\"1\" width=\"30\" height=\"20\"/>", count: 600) + "</svg>"
        rig.controller.renderDiagram = { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .success(svg)
        }

        var running = true
        var longestStall = 0.0
        let heartbeat = Task { @MainActor in
            var last = Date()
            while running {
                try? await Task.sleep(nanoseconds: 5_000_000)
                let now = Date()
                longestStall = max(longestStall, now.timeIntervalSince(last) - 0.005)
                last = now
            }
        }
        let started = Date()
        rig.controller.exportHTML()
        await rig.finish()
        running = false
        await heartbeat.value
        let took = Date().timeIntervalSince(started)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.destination!.path), "the file was written")
        XCTAssertEqual(rig.errors.count, 0)
        print("MAIN-THREAD STALL while preparing \(lines.count) lines: longest \(Int(longestStall * 1000)) ms, whole export \(String(format: "%.2f", took)) s")
        XCTAssertLessThan(longestStall, 0.25, "the main thread was blocked for \(longestStall) s")
    }

    /// The same large document through the paginated path: loading the page into the web view is part of preparing; the printing that
    /// follows is reported but is not what R27 limits.
    func testPreparingALargeDocumentForPDFNeverStallsTheMainThreadForLong() async throws {
        let folder = try temporaryFolder()
        var lines: [String] = []
        for i in 0..<930 {
            lines += ["## Section \(i % 50)", "",
                      "A paragraph with **bold**, *italic*, `code`, a [link](https://example.com/\(i)), ==highlight== and https://example.org/page\(i) in it. "
                          + String(repeating: "Some more words to make the line a realistic length. ", count: 10), "",
                      "- item one", "  - nested [ ] text", "- [x] done task", "1. first", "2. second", "",
                      "> quote with ==mark== text", "", "| a | b |", "|---|--:|", "| 1 | `x` |", "",
                      "```swift", "let x = \(i) // </pre><script>", "```", "", ""]
        }
        let rig = Rig()
        rig.window = PrintRendererTests.hostWindow()
        defer { rig.window?.close() }
        rig.text = lines.joined(separator: "\n")
        rig.destination = folder.appendingPathComponent("big.pdf")
        var running = true
        var longestStall = 0.0
        var stallAtPanel = -1.0
        let heartbeat = Task { @MainActor in
            var last = Date()
            while running {
                try? await Task.sleep(nanoseconds: 5_000_000)
                let now = Date()
                longestStall = max(longestStall, now.timeIntervalSince(last) - 0.005)
                last = now
            }
        }
        rig.controller.chooseDestination = { [unowned rig] _, _, _ in stallAtPanel = longestStall; return rig.destination }
        let started = Date()
        rig.controller.exportPDF()
        await rig.finish()
        running = false
        await heartbeat.value
        print("MAIN-THREAD STALL (PDF) \(lines.count) lines: while preparing \(Int(stallAtPanel * 1000)) ms, while printing \(Int(longestStall * 1000)) ms, whole export \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.destination!.path), "errors: \(rig.errors)")
        XCTAssertGreaterThanOrEqual(stallAtPanel, 0, "the panel was reached")
        XCTAssertLessThan(stallAtPanel, 0.25, "preparing blocked the main thread for \(stallAtPanel) s")
    }
}
