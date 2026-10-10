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

    // MARK: ImageLoader.embed: why a file is not embedded (export and print, R14)

    private func scratchFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testEmbedReturnsTheDataURIAndTheFileSize() throws {
        let dir = try makeFolder(withImageNamed: "pic.png", size: NSSize(width: 20, height: 20))
        let url = dir.appendingPathComponent("pic.png")
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        guard case .image(let uri, let bytes) = ImageLoader.embed(at: url) else { return XCTFail("not embedded") }
        XCTAssertTrue(uri.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(bytes, size)
        XCTAssertEqual(ImageLoader.dataURI(at: url), uri, "the editor's cards get the same bytes as before")
    }

    func testEmbedHandlesAnSVGAndAnUpperCaseExtension() throws {
        let dir = try scratchFolder()
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>".write(to: dir.appendingPathComponent("a.svg"), atomically: true, encoding: .utf8)
        guard case .image(let uri, _) = ImageLoader.embed(at: dir.appendingPathComponent("a.svg")) else { return XCTFail("svg not embedded") }
        XCTAssertTrue(uri.hasPrefix("data:image/svg+xml;base64,"), uri)
        let png = try makeFolder(withImageNamed: "SHOUT.PNG", size: NSSize(width: 8, height: 8))
        guard case .image(let upper, _) = ImageLoader.embed(at: png.appendingPathComponent("SHOUT.PNG")) else { return XCTFail("upper-case extension") }
        XCTAssertTrue(upper.hasPrefix("data:image/png;base64,"))
    }

    func testEmbedSaysWhyAFileIsNotUsed() throws {
        let dir = try scratchFolder()
        XCTAssertEqual(ImageLoader.embed(at: dir.appendingPathComponent("missing.png")), .notFound)
        try "words".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ImageLoader.embed(at: dir.appendingPathComponent("notes.txt")), .notAnImage)
        try "x".write(to: dir.appendingPathComponent("noextension"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ImageLoader.embed(at: dir.appendingPathComponent("noextension")), .notAnImage)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.png"), withIntermediateDirectories: false)
        XCTAssertEqual(ImageLoader.embed(at: dir.appendingPathComponent("folder.png")), .notAnImage, "a folder is not an image even if it is named like one")
        XCTAssertNil(ImageLoader.dataURI(at: dir.appendingPathComponent("notes.txt")))
    }

    func testTheEightMegabyteLimitIsExactlyEightMillionBytes() throws {
        let dir = try scratchFolder()
        let atLimit = dir.appendingPathComponent("at.png"), over = dir.appendingPathComponent("over.png")
        try Data(count: 8_000_000).write(to: atLimit)
        try Data(count: 8_000_001).write(to: over)
        guard case .image(_, let bytes) = ImageLoader.embed(at: atLimit) else { return XCTFail("8,000,000 bytes should be embedded") }
        XCTAssertEqual(bytes, 8_000_000)
        XCTAssertEqual(ImageLoader.embed(at: over), .tooLarge)
        XCTAssertNil(ImageLoader.dataURI(at: over))
    }

    func testABigFileThatIsNotAnImageIsNotAnImageFirst() throws {
        let dir = try scratchFolder()
        try Data(count: 9_000_000).write(to: dir.appendingPathComponent("huge.bin"))
        XCTAssertEqual(ImageLoader.embed(at: dir.appendingPathComponent("huge.bin")), .notAnImage)
    }
}
