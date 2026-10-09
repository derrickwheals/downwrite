import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// HTML blocks in a document are drawn as cards under their (collapsed) source: a locked-down web view that cannot run
/// scripts or navigate, sized to its content.
@MainActor
final class HTMLCardTests: XCTestCase {
    private func cards(_ h: EditorHarness) -> [DiagramView] { h.textView.subviews.compactMap { $0 as? DiagramView } }

    private func reserved(_ h: EditorHarness, _ line: Int) -> CGFloat { h.coordinator.overlay.reservedHeights[line] ?? 0 }

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
        h.select(h.index(of: "after"))
        let ok = await waitUntil { self.reserved(h, 0) > 40 }
        XCTAssertTrue(ok)
        let wide = reserved(h, 0)
        h.window.setContentSize(NSSize(width: 500, height: 760))
        h.textView.setFrameSize(NSSize(width: 500, height: h.textView.frame.height))      // (schedules the reposition that measures again)
        let again = await waitUntil { self.reserved(h, 0) > wide + 20 }
        XCTAssertTrue(again, "a narrower column wraps more: \(wide) → \(reserved(h, 0))")
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
