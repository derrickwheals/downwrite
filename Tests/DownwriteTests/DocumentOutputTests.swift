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
