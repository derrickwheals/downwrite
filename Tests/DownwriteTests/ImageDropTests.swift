import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Dropping images (DW-002). The first group pins what the editor does *today* with the drags an image drop involves (R2, R4);
/// they were written before `EditorTextView` was changed.
@MainActor
final class ImageDropTests: XCTestCase {
    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("downwrite.test.imagedrop.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        pb.clearContents()
        return pb
    }

    private func editor(_ text: String = "Hello world\n\nSecond line\n") -> EditorHarness {
        let h = EditorHarness(text: text)
        h.window.makeKeyAndOrderFront(nil)
        h.window.makeFirstResponder(h.textView)
        return h
    }

    /// A drag session over `h`'s text, `x`/`y` points into the text view.
    private func drag(_ pb: NSPasteboard, over h: EditorHarness, x: CGFloat = 120, y: CGFloat = 30) -> FakeDraggingInfo {
        FakeDraggingInfo(pasteboard: pb, window: h.window, location: h.textView.convert(NSPoint(x: x, y: y), to: nil))
    }

    /// Runs the four destination calls in the order AppKit makes them and reports each answer.
    private func dropAnswers(_ info: FakeDraggingInfo, on tv: EditorTextView) -> (entered: NSDragOperation, updated: NSDragOperation, prepared: Bool, performed: Bool) {
        let entered = tv.draggingEntered(info)
        let updated = tv.draggingUpdated(info)
        let prepared = tv.prepareForDragOperation(info)
        let performed = prepared ? tv.performDragOperation(info) : false
        return (entered, updated, prepared, performed)
    }

    // MARK: Baseline: what a drop does today

    func testBaselineTheTypesAreRegisteredOnlyOnceTheViewIsInAWindow() {
        let (_, bare) = EditorTextView.make()
        XCTAssertTrue(bare.registeredDraggedTypes.isEmpty, "no window yet: nothing is delivered to it")
        let h = editor()
        // AppKit registers the legacy names; it maps the modern ones (public.png, public.utf8-plain-text …) onto them.
        let registered = Set(h.textView.registeredDraggedTypes.map(\.rawValue))
        for name in ["Apple PNG pasteboard type", "NeXT TIFF v4.0 pasteboard type", "NSStringPboardType", "NSFilenamesPboardType",
                     "com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type"] {
            XCTAssertTrue(registered.contains(name), "\(name) is delivered to the editor once it is in a window")
        }
    }

    func testBaselineADroppedStringIsInserted() {
        let h = editor()
        let pb = board()
        pb.setString("DROPPED", forType: .string)
        let answers = dropAnswers(drag(pb, over: h), on: h.textView)
        XCTAssertEqual(answers.entered, .copy)
        XCTAssertTrue(answers.performed)
        XCTAssertTrue(h.textView.string.contains("DROPPED"))
    }

    func testBaselineADroppedFileInsertsItsPathAsText() {
        let h = editor()
        let pb = board()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/probe image.png") as NSURL])
        let answers = dropAnswers(drag(pb, over: h), on: h.textView)
        XCTAssertEqual(answers.entered, .copy)
        XCTAssertTrue(answers.performed)
        XCTAssertTrue(h.textView.string.contains("/tmp/probe image.png"))
    }

    func testBaselineRawImageDataIsNotAcceptedAtAll() {
        let h = editor()
        let before = h.textView.string
        let pb = board()
        pb.setData(ImageFixtures.png(), forType: .png)
        let answers = dropAnswers(drag(pb, over: h), on: h.textView)
        XCTAssertEqual(answers.entered, [], "AppKit refuses image data because the editor does not import graphics")
        XCTAssertEqual(answers.updated, [])
        XCTAssertFalse(answers.prepared)
        XCTAssertFalse(answers.performed)
        XCTAssertEqual(h.textView.string, before)
    }
}
