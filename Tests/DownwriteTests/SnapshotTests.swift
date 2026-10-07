import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Renders the editor to PNGs for the visual pass (collected by CI as artifacts) and sanity-checks that the output
/// is a real, non-blank image.
@MainActor
final class SnapshotTests: XCTestCase {
    static var outputDir: URL = {
        let base = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory() + "downwrite-snapshots"
        let url = URL(fileURLWithPath: base, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func render(_ h: EditorHarness, name: String) async throws -> NSImage {
        h.window.displayIfNeeded()
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        h.coordinator.overlay.reposition(analysis: h.coordinator.analysis)
        try await Task.sleep(nanoseconds: 700_000_000)   // let web views paint
        let view = h.window.contentView!
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        // WKWebView content is composited out of process; overlay each diagram's snapshot.
        for card in h.textView.subviews.compactMap({ $0 as? DiagramView }) {
            if let snap = await card.webSnapshot() {
                let rect = card.convert(card.bounds, to: view)
                let inner = rect.insetBy(dx: card.padding, dy: card.padding)
                image.lockFocus()
                snap.draw(in: inner, from: .zero, operation: .sourceOver, fraction: 1)
                image.unlockFocus()
            }
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: Self.outputDir.appendingPathComponent("\(name).png"))
        return image
    }

    private func assertNotBlank(_ image: NSImage, _ name: String) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var values = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 60)
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    values.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
                }
            }
        }
        XCTAssertGreaterThan(values.count, 6, "\(name) looks blank (\(values.count) distinct colours)")
    }

    private func welcome() throws -> String {
        try String(contentsOf: try XCTUnwrap(AppResources.url("Welcome", "md")), encoding: .utf8)
    }

    func testSnapshotWelcomeLight() async throws {
        let text = try welcome()
        let h = EditorHarness(text: text, dark: false)
        _ = await waitUntil { (h.coordinator.overlay.reservedHeights.values.first ?? 0) > 100 }
        h.select(h.index(of: "comes back") + 3)   // reveal inline markers
        try assertNotBlank(try await render(h, name: "welcome-light"), "welcome-light")
    }

    func testSnapshotWelcomeDark() async throws {
        let text = try welcome()
        let h = EditorHarness(text: text, dark: true)
        _ = await waitUntil { (h.coordinator.overlay.reservedHeights.values.first ?? 0) > 100 }
        h.select(h.index(of: "Press Return") + 2)
        try assertNotBlank(try await render(h, name: "welcome-dark"), "welcome-dark")
    }

    func testSnapshotScrolledToDiagramAndCode() async throws {
        let text = try welcome()
        let h = EditorHarness(text: text, dark: false, size: NSSize(width: 960, height: 760))
        _ = await waitUntil { (h.coordinator.overlay.reservedHeights.values.first ?? 0) > 100 }
        h.select(0)
        let loc = h.index(of: "## Code and tables")
        h.textView.scrollRangeToVisible(NSRange(location: loc + 900, length: 10))
        h.textView.scroll(NSPoint(x: 0, y: max(0, h.textView.layoutManager!.boundingRect(forGlyphRange: NSRange(location: loc, length: 1), in: h.textView.textContainer!).minY - 20)))
        try assertNotBlank(try await render(h, name: "code-table-diagram-light"), "code-table-diagram-light")
    }

    func testSnapshotEmptyDocumentShowsPlaceholder() async throws {
        let h = EditorHarness(text: "", dark: false, size: NSSize(width: 760, height: 300))
        h.window.makeFirstResponder(h.textView)
        let image = try await render(h, name: "empty-light")
        try assertNotBlank(image, "empty") // background + placeholder text
    }

    func testSnapshotEditingStates() async throws {
        let h = EditorHarness(text: "# Notes\n\nThis has **bold**, *italic*, `code` and a [link](https://example.com).\n\n> A quote\n\n- [ ] one\n- [x] two\n", dark: true, size: NSSize(width: 760, height: 420))
        h.select(h.index(of: "bold") + 1)
        try assertNotBlank(try await render(h, name: "editing-caret-in-bold-dark"), "editing")
        h.select(0)
        try assertNotBlank(try await render(h, name: "editing-caret-at-start-dark"), "editing2")
    }
}
