import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Pasting images (DW-002). The first group pins what the editor does *today* with the pasteboards an image paste involves
/// (R4), so the change can be shown to leave every other paste alone; they were written before `EditorTextView` was changed.
@MainActor
final class ImagePasteTests: XCTestCase {
    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("downwrite.test.imagepaste.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        pb.clearContents()
        return pb
    }

    // MARK: Baseline: what a paste does today

    func testBaselineAnImageOnlyPasteboardPastesNothing() {
        let h = EditorHarness(text: "Hello\n")
        let pb = board()
        pb.setData(ImageFixtures.png(), forType: .png)
        h.select(5)
        XCTAssertFalse(h.textView.readSelection(from: pb))
        XCTAssertEqual(h.textView.string, "Hello\n")
    }

    func testBaselineATIFFOnlyPasteboardPastesNothing() {
        let h = EditorHarness(text: "Hello\n")
        let pb = board()
        pb.setData(NSImage(data: ImageFixtures.png())!.tiffRepresentation!, forType: .tiff)
        h.select(5)
        XCTAssertFalse(h.textView.readSelection(from: pb))
        XCTAssertEqual(h.textView.string, "Hello\n")
    }

    func testBaselineAFileURLPastesItsPath() {
        let h = EditorHarness(text: "Hello\n")
        let pb = board()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/shot one.png") as NSURL])
        h.select(5)
        XCTAssertTrue(h.textView.readSelection(from: pb))
        XCTAssertEqual(h.textView.string, "Hello/tmp/shot one.png\n")
    }

    func testBaselineAFinderCopyPastesTheFileName() {
        let h = EditorHarness(text: "Hello\n")
        let pb = board()
        pb.declareTypes([.fileURL, .string], owner: nil)
        pb.setString(URL(fileURLWithPath: "/tmp/photo.png").absoluteString, forType: .fileURL)
        pb.setString("photo.png", forType: .string)
        h.select(5)
        XCTAssertTrue(h.textView.readSelection(from: pb))
        XCTAssertEqual(h.textView.string, "Hellophoto.png\n")
    }

    func testBaselineAnImageWithTextPastesTheText() {
        let h = EditorHarness(text: "Hello\n")
        let pb = board()
        pb.declareTypes([.png, .string], owner: nil)
        pb.setData(ImageFixtures.png(), forType: .png)
        pb.setString("a caption", forType: .string)
        h.select(5)
        XCTAssertTrue(h.textView.readSelection(from: pb))
        XCTAssertEqual(h.textView.string, "Helloa caption\n")
    }

    func testBaselineAURLPastedOverASelectionBecomesALink() {
        let h = EditorHarness(text: "Hello world\n")
        let pb = board()
        pb.setString("https://example.com/page", forType: .string)
        h.coordinator.imagePasteboard = pb
        h.select(6, 5)
        h.textView.paste(nil)
        XCTAssertEqual(h.textView.string, "Hello [world](https://example.com/page)\n")
    }

    func testBaselinePlainTextPastesAsItIsThroughTheTextViewsOwnPath() {
        let h = EditorHarness(text: "Hello\n")
        let pb = board()
        pb.setString("brave new world", forType: .string)
        h.select(5)
        XCTAssertTrue(h.textView.readSelection(from: pb))
        XCTAssertEqual(h.textView.string, "Hellobrave new world\n")
    }
}
