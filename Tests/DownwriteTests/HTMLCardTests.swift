import XCTest
import AppKit
import WebKit
@testable import Downwrite
import DownwriteCore

/// HTML blocks in a document are drawn as cards under their (collapsed) source: a locked-down web view that cannot run
/// scripts or navigate, sized to its content.
@MainActor
final class HTMLCardTests: XCTestCase {
    private func cards(_ h: EditorHarness) -> [DiagramView] { h.textView.subviews.compactMap { $0 as? DiagramView } }

    private func reserved(_ h: EditorHarness, _ line: Int) -> CGFloat { h.coordinator.overlay.reservedHeights[line] ?? 0 }

    /// What the first card's page says about itself: the width it was laid out at and the height of its content. For the message of a failed
    /// wait, so that the next failure says whether the card never rendered again or measured at the old width. Bounded to 5 s, because a web
    /// view that does not answer must not hold the failure back.
    private func pageReport(_ h: EditorHarness) async -> String {
        guard let web = cards(h).first?.subviews.compactMap({ $0 as? WKWebView }).first else { return "no card web view" }
        let answer = TextBox("")
        Task { @MainActor in
            do { answer.value = "\(try await web.evaluateJavaScript("window.innerWidth + ' × ' + Math.ceil(document.getElementById('dw-root').getBoundingClientRect().height)") ?? "no value")" }
            catch { answer.value = "error \(error.localizedDescription)" }
        }
        let answered = await waitUntil(timeout: 5) { !answer.value.isEmpty }
        return "page \(answered ? answer.value : "did not answer within 5 s") (web view frame \(web.frame))"
    }

    private func makeFolder(withImageNamed name: String, size: NSSize) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-html-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent(name))
        return dir
    }

    // MARK: Card and layout

    func testHTMLBlockShowsACardAsTallAsItsContent() async throws {
        let h = EditorHarness(text: "intro\n\n<div style=\"height:120px\">box</div>\n\nafter\n")
        h.select(0)
        let ok = await waitUntil { self.reserved(h, 2) > 100 }
        XCTAssertTrue(ok, "the HTML card never reported a height")
        XCTAssertEqual(reserved(h, 2), 120 + 14, accuracy: 1.5)
        let card = try XCTUnwrap(cards(h).first)
        XCTAssertTrue(card.isHTML)
        XCTAssertEqual(cards(h).count, 1)
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        h.coordinator.overlay.reposition(analysis: h.coordinator.analysis)
        XCTAssertEqual(card.frame.height, 120, accuracy: 1.5)
        XCTAssertEqual(h.coordinator.overlay.layoutProblems(analysis: h.coordinator.analysis), [])
    }

    func testSourceCollapsesWhileTheCaretIsOutsideAndReturnsInside() async {
        let h = EditorHarness(text: "intro\n\n<div style=\"height:60px\">box</div>\n\nafter\n")
        h.select(0)
        let ok = await waitUntil { self.reserved(h, 2) > 40 }
        XCTAssertTrue(ok)
        let source = h.index(of: "<div")
        XCTAssertTrue(h.isHidden(at: source), "the source takes no room while the card shows it")
        XCTAssertEqual(h.paragraph(at: source).paragraphSpacing, reserved(h, 2), accuracy: 0.5)
        h.select(source + 3)
        XCTAssertFalse(h.isHidden(at: source), "the source comes back when the caret is in the block")
        XCTAssertEqual(cards(h).count, 1, "…and the card stays below it")
        h.select(h.index(of: "after"))
        XCTAssertTrue(h.isHidden(at: source))
    }

    func testBlocksThatDrawNothingKeepTheirSourceAndGetNoCard() {
        let h = EditorHarness(text: "<!-- a comment -->\n\ntext\n\n<div align=\"center\">\n\nmore\n\n</div>\n")
        h.select(0)
        XCTAssertTrue(cards(h).isEmpty)
        XCTAssertFalse(h.isHidden(at: h.index(of: "<!--")))
        XCTAssertFalse(h.isHidden(at: h.index(of: "</div>")))
    }

    func testHTMLThatDrawsNothingShowsAnErrorCardInsteadOfVanishing() async throws {
        let h = EditorHarness(text: "<div style=\"display:none\">hidden</div>\n\nafter\n")
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 0) == 56 && !(self.cards(h).first?.isHTML ?? true) }
        XCTAssertTrue(ok, "reserved \(reserved(h, 0))")
        XCTAssertEqual(h.textView.string, "<div style=\"display:none\">hidden</div>\n\nafter\n")
    }

    // MARK: Safety

    func testScriptsInTheDocumentNeverRun() async throws {
        let html = "<div id=\"a\">no</div><script>document.getElementById('a').textContent = 'yes'</script><img src=\"x\" onerror=\"document.getElementById('a').textContent = 'yes'\">"
        let h = EditorHarness(text: html + "\n\nafter\n")
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 0) > 14 }
        XCTAssertTrue(ok)
        try await Task.sleep(nanoseconds: 500_000_000)
        let card = try XCTUnwrap(cards(h).first)
        let text = await card.evaluate("document.getElementById('a').textContent") as? String
        XCTAssertEqual(text, "no", "the page's own scripts must not run")
    }

    func testThePageCannotNavigateAway() async throws {
        let html = "<div><meta http-equiv=\"refresh\" content=\"0;url=https://example.invalid/\"><p>stays</p></div>"
        let h = EditorHarness(text: html + "\n\nafter\n")
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 0) > 14 }
        XCTAssertTrue(ok)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let card = try XCTUnwrap(cards(h).first)
        let href = await card.evaluate("location.href") as? String
        XCTAssertEqual(href, "about:blank", "a meta refresh must not take the card anywhere")
        let text = await card.evaluate("document.body.textContent") as? String
        XCTAssertTrue(text?.contains("stays") == true)
    }

    // MARK: Images

    func testLocalImageIsEmbeddedAndMeasured() async throws {
        let dir = try makeFolder(withImageNamed: "pic.png", size: NSSize(width: 300, height: 150))
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = EditorHarness(text: "<p><img src=\"pic.png\" width=\"200\"></p>\n\nafter\n", fileURL: dir.appendingPathComponent("doc.md"))
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 0) > 60 }
        XCTAssertTrue(ok, "image never loaded (reserved \(reserved(h, 0)))")
        // 200 pt wide at the image's 2:1 shape is 100 pt tall, plus the line box and paragraph margin around it and the gap below the
        // card. A picture that was not embedded would be a broken-image icon of a line or so.
        XCTAssertGreaterThan(reserved(h, 0), 100 + 14)
        XCTAssertLessThan(reserved(h, 0), 100 + 14 + 40)
    }

    func testMissingImageStillGetsACard() async throws {
        let h = EditorHarness(text: "<p><img src=\"nope.png\" alt=\"missing picture\" width=\"100\" height=\"40\"></p>\n\nafter\n",
                              fileURL: URL(fileURLWithPath: "/tmp/none/doc.md"))
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 0) > 14 }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.textView.string.hasPrefix("<p><img src=\"nope.png\""), true)
    }

    // MARK: Reflow, themes, source view

    func testCardIsMeasuredAgainWhenTheColumnGetsNarrower() async throws {
        let words = Array(repeating: "wrapping words", count: 60).joined(separator: " ")
        let h = EditorHarness(text: "<p>\(words)</p>\n\nafter\n")
        h.pinColumnWidth()                // (without it a scroller appears once the narrower card has grown the document, and takes 17 pt from the column again: 500 → 483)
        h.select(h.index(of: "after"))
        // (A web view on a shared CI runner can need a good deal longer than the 25 s default for its first load, so wait up to a minute.)
        let ok = await waitUntil(timeout: 60) { self.reserved(h, 0) > 40 }
        XCTAssertTrue(ok, "the HTML card never reported a height: reserved \(h.coordinator.overlay.reservedHeights), \(cards(h).count) card view(s), column \(h.textView.frame.width) pt")
        let wide = reserved(h, 0)
        h.window.setContentSize(NSSize(width: 500, height: 760))
        h.textView.setFrameSize(NSSize(width: 500, height: h.textView.frame.height))      // (schedules the reposition that measures again)
        XCTAssertEqual(h.textView.frame.width, 500, accuracy: 1, "the column should be 500 pt wide now\n\(h.geometryReport())")
        let again = await waitUntil(timeout: 60) { self.reserved(h, 0) > wide + 20 }
        let diagnosis = again ? "" : "\n\(h.geometryReport())\n\(await pageReport(h))"
        XCTAssertTrue(again, "a narrower column wraps more: \(wide) → \(reserved(h, 0))\(diagnosis)")
        let settled = await waitUntil { h.coordinator.overlay.layoutProblems(analysis: h.coordinator.analysis).isEmpty }
        XCTAssertTrue(settled, "\(h.coordinator.overlay.layoutProblems(analysis: h.coordinator.analysis))")
    }

    func testCardMovesWithItsBlockWhenLinesAreInsertedAbove() async throws {
        let h = EditorHarness(text: "intro\n\n<div style=\"height:80px\">box</div>\n\nafter\n")
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 2) > 80 }
        XCTAssertTrue(ok)
        let card = try XCTUnwrap(cards(h).first)
        let before = reserved(h, 2)
        h.textView.insertText("one\n\ntwo\n\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(h.coordinator.analysis.htmlBlocks.first?.firstLine, 6)
        XCTAssertEqual(cards(h).count, 1)
        XCTAssertTrue(cards(h).first === card, "the same card, not a new web view")
        XCTAssertEqual(reserved(h, 6), before, accuracy: 0.5, "…with its height ready straight away")
        XCTAssertEqual(reserved(h, 2), 0, "nothing is left reserved under the old line")
        XCTAssertTrue(h.isHidden(at: h.index(of: "<div")))
        let settled = await waitUntil { h.coordinator.overlay.layoutProblems(analysis: h.coordinator.analysis).isEmpty }
        XCTAssertTrue(settled, "\(h.coordinator.overlay.layoutProblems(analysis: h.coordinator.analysis))")
    }

    func testTypingInTheBlockRendersTheNewContent() async throws {
        let h = EditorHarness(text: "<div style=\"height:50px\">box</div>\n\nafter\n")
        h.select(5)
        let ok = await waitUntil { self.reserved(h, 0) > 50 }
        XCTAssertTrue(ok)
        XCTAssertEqual(reserved(h, 0), 64, accuracy: 1.5)
        let at = h.index(of: "50px")
        h.textView.setSelectedRange(NSRange(location: at, length: 2))
        h.textView.insertText("90", replacementRange: NSRange(location: at, length: 2))
        let grew = await waitUntil { abs(self.reserved(h, 0) - 104) < 1.5 }
        XCTAssertTrue(grew, "reserved \(reserved(h, 0))")
    }

    func testDarkAndLightPalettesRenderTheCardAgain() async throws {
        let h = EditorHarness(text: "<p>themed</p>\n\nafter\n")
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 0) > 14 }
        XCTAssertTrue(ok)
        let card = try XCTUnwrap(cards(h).first)
        let light = await card.evaluate("getComputedStyle(document.body).color") as? String
        XCTAssertNotNil(light)
        h.window.appearance = NSAppearance(named: .darkAqua)
        h.coordinator.appearanceDidChange()
        var dark: String?
        for _ in 0..<80 {
            dark = await card.evaluate("getComputedStyle(document.body).color") as? String
            if dark != nil, dark != light { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotEqual(dark, light, "the card is rendered again in the dark palette")
    }

    func testNoCardsInTheSourceView() async {
        let h = EditorHarness(text: "<div style=\"height:40px\">box</div>\n\nafter\n")
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 0) > 40 }
        XCTAssertTrue(ok)
        h.coordinator.setSourceMode(true)
        XCTAssertTrue(cards(h).isEmpty)
        XCTAssertFalse(h.isHidden(at: h.index(of: "<div")))
        h.coordinator.setSourceMode(false)
        let back = await waitUntil { self.reserved(h, 0) > 40 }
        XCTAssertTrue(back)
        XCTAssertEqual(cards(h).count, 1)
    }

    func testMermaidAndImageCardsAreUnaffected() async {
        let h = EditorHarness(text: "```mermaid\ngraph TD\n  A --> B\n```\n\n<div style=\"height:30px\">box</div>\n")
        h.select(0)
        let ok = await waitUntil { self.reserved(h, 0) > 100 && self.reserved(h, 5) > 30 }
        XCTAssertTrue(ok, "mermaid \(reserved(h, 0)), html \(reserved(h, 5))")
        XCTAssertEqual(cards(h).filter(\.isHTML).count, 1)
        XCTAssertEqual(cards(h).filter { !$0.isHTML && !$0.isImage }.count, 1)
    }
}
