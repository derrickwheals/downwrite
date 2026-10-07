import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

@MainActor
final class ImagePreviewTests: XCTestCase {
    private func makeFolder(withImageNamed name: String, size: NSSize) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-img-\(UUID().uuidString)", isDirectory: true)
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

    func testStandaloneImageShowsCardAndCollapsesSource() async throws {
        let dir = try makeFolder(withImageNamed: "pic.png", size: NSSize(width: 300, height: 150))
        let h = EditorHarness(text: "intro\n\n![pic](pic.png)\n\nafter\n", fileURL: dir.appendingPathComponent("doc.md"))
        h.select(0)
        let ok = await waitUntil { (h.coordinator.overlay.reservedHeights[2] ?? 0) > 100 }
        XCTAssertTrue(ok, "image never loaded")
        let card = try XCTUnwrap(h.textView.subviews.compactMap { $0 as? DiagramView }.first)
        XCTAssertTrue(card.isImage)
        XCTAssertEqual(h.coordinator.overlay.reservedHeights[2] ?? 0, 150 + 14, accuracy: 20)   // 1x or 2x pixel density
        XCTAssertTrue(h.isHidden(at: h.index(of: "![pic]")), "markdown source collapses while the caret is elsewhere")
        h.select(h.index(of: "pic.png") + 2)
        XCTAssertFalse(h.isHidden(at: h.index(of: "![pic]")), "source returns when the caret is on the line")
        try? FileManager.default.removeItem(at: dir)
    }

    func testWideImageIsScaledToColumn() async throws {
        let dir = try makeFolder(withImageNamed: "wide.png", size: NSSize(width: 3000, height: 1500))
        let h = EditorHarness(text: "![wide](wide.png)\n", fileURL: dir.appendingPathComponent("doc.md"))
        let ok = await waitUntil { (h.coordinator.overlay.reservedHeights[0] ?? 0) > 100 }
        XCTAssertTrue(ok)
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        h.coordinator.overlay.reposition(analysis: h.coordinator.analysis)
        let card = try XCTUnwrap(h.textView.subviews.compactMap { $0 as? DiagramView }.first)
        XCTAssertLessThanOrEqual(card.frame.width, 720.5)
        XCTAssertEqual(card.frame.width / card.frame.height, 2, accuracy: 0.05, "aspect ratio preserved")
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingImageShowsErrorCardWithoutBreakingText() async {
        let h = EditorHarness(text: "![nope](does-not-exist.png)\n\ntext\n", fileURL: URL(fileURLWithPath: "/tmp/none/doc.md"))
        let ok = await waitUntil { h.coordinator.overlay.reservedHeights[0] == 56 }
        XCTAssertTrue(ok)
        XCTAssertEqual(h.textView.string, "![nope](does-not-exist.png)\n\ntext\n")
    }

    func testInlineImageInsideParagraphGetsNoCard() {
        let h = EditorHarness(text: "some ![x](y.png) inline\n")
        XCTAssertTrue(h.coordinator.analysis.previewBlocks.isEmpty)
        XCTAssertEqual(h.textView.subviews.compactMap { $0 as? DiagramView }.count, 0)
    }
}
