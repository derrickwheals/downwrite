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

// MARK: - Pasting into a saved document (step 9)

@MainActor
final class ImagePasteFlowTests: ImageRigTestCase {
    // MARK: The happy path (R1, R10, R11, R24)

    func testAPastedScreenshotIsSavedLinkedAndPreviewed() async throws {
        let r = try rig("Hello world\n")
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(files(r), [pastedName])
        XCTAssertEqual(r.text, "Hello world\n\n\(link(pastedName))\n\n")
        XCTAssertEqual(r.h.textView.selectedRange(), NSRange(location: r.text.utf16.count, length: 0), "the caret is right after the inserted text")
        XCTAssertEqual(r.h.coordinator.analysis.imageBlocks.map(\.source), ["assets/\(pastedName)"])
        let carded = await waitUntil { (r.h.coordinator.overlay.reservedHeights[2] ?? 0) > 20 }
        XCTAssertTrue(carded, "the preview card appears with no further step")
        XCTAssertTrue(r.rec.notices.isEmpty, "a plain success shows no sheet")
        XCTAssertEqual(r.rec.announcements, ["Image inserted: \(pastedName)"])
    }

    func testTheSelectionIsReplaced() async throws {
        let r = try rig("Hello world", selection: NSRange(location: 6, length: 5))
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "Hello \n\n\(link(pastedName))\n\n")
    }

    func testAnImageWithItsURLIsAnImagePasteEvenOverASelection() async throws {
        let r = try rig("Hello world", selection: NSRange(location: 6, length: 5))
        r.pb.clearContents()
        r.pb.declareTypes([.png, .string], owner: nil)
        r.pb.setData(ImageFixtures.png(), forType: .png)
        r.pb.setString("https://example.com/cat.png", forType: .string)
        XCTAssertTrue(r.h.coordinator.pasteImages(), "Safari's Copy Image: the image wins over making a link")
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(files(r), [pastedName])
        XCTAssertFalse(r.text.contains("example.com"))
    }

    func testOneUndoRemovesTheLinkAndLeavesTheFileAndRedoBringsItBack() async throws {
        let r = try rig("Hello world\n")
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        let pasted = r.text
        let undo = try XCTUnwrap(r.h.textView.undoManager)
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Paste Image")
        undo.undo()
        XCTAssertEqual(r.text, "Hello world\n", "one undo removes the whole insertion")
        XCTAssertEqual(files(r), [pastedName], "undo never deletes a file")
        XCTAssertEqual(undo.redoMenuItemTitle, "Redo Paste Image")
        undo.redo()
        XCTAssertEqual(r.text, pasted, "redo uses the same link; the file is still there")
        XCTAssertEqual(files(r), [pastedName])
    }

    func testSeveralFilesGiveOneParagraphEachInOrder() async throws {
        let r = try rig("")
        let outside = r.folder.deletingLastPathComponent().appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let a = outside.appendingPathComponent("a.png"), b = outside.appendingPathComponent("b.jpg"), c = outside.appendingPathComponent("c.gif")
        try ImageFixtures.png().write(to: a)
        try ImageFixtures.jpeg().write(to: b)
        try ImageFixtures.gif().write(to: c)
        r.pb.clearContents()
        r.pb.writeObjects([a as NSURL, b as NSURL, c as NSURL])
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "\(link("a.png"))\n\n\(link("b.jpg"))\n\n\(link("c.gif"))\n\n")
        XCTAssertEqual(r.h.textView.selectedRange().location, r.text.utf16.count)
        XCTAssertEqual(files(r), ["a.png", "b.jpg", "c.gif"])
        XCTAssertEqual(r.rec.announcements, ["3 images inserted"])
        XCTAssertEqual(r.h.textView.undoManager?.undoMenuItemTitle, "Undo Paste Images")
    }

    func testAFinderCopyOfAFileUsesItsName() async throws {
        let r = try rig("")
        let outside = r.folder.deletingLastPathComponent().appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let photo = outside.appendingPathComponent("photo one.png")
        try ImageFixtures.png().write(to: photo)
        r.pb.clearContents()
        r.pb.declareTypes([.fileURL, .string], owner: nil)
        r.pb.setString(photo.absoluteString, forType: .fileURL)
        r.pb.setString("photo one.png", forType: .string)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(files(r), ["photo-one.png"])
        XCTAssertEqual(r.text, "\(link("photo-one.png"))\n\n")
    }

    // MARK: What is and is not an image paste (R3, R4)

    func testTextThatWinsLeavesThePasteToTheTextView() throws {
        let r = try rig("Hello\n")
        r.pb.clearContents()
        r.pb.declareTypes([.png, .string], owner: nil)
        r.pb.setData(ImageFixtures.png(), forType: .png)
        r.pb.setString("Name\tQty\nApples\t3", forType: .string)
        XCTAssertFalse(r.h.coordinator.pasteImages(), "spreadsheet text with an image preview is text")
        XCTAssertEqual(r.text, "Hello\n")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }

    func testPlainTextAndNonImageFilesAreNotImagePastes() throws {
        let r = try rig("Hello\n")
        r.pb.clearContents()
        r.pb.setString("just text", forType: .string)
        XCTAssertFalse(r.h.coordinator.pasteImages())
        let pdf = r.folder.appendingPathComponent("notes.pdf")
        try ImageFixtures.pdf().write(to: pdf)
        r.pb.clearContents()
        r.pb.writeObjects([pdf as NSURL])
        XCTAssertFalse(r.h.coordinator.pasteImages(), "a PDF is not an image here")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }

    func testAnEmptyPasteboardIsNotAnImagePaste() throws {
        let r = try rig("Hello\n")
        XCTAssertFalse(r.h.coordinator.pasteImages())
    }

    func testIMEMarkedTextIsLeftAlone() throws {
        let r = try rig("Hello\n")
        r.h.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 6, length: 0))
        XCTAssertTrue(r.h.textView.hasMarkedText())
        putPNG(r.pb)
        XCTAssertFalse(r.h.coordinator.pasteImages())
    }

    // MARK: Where it applies (R5)

    func testItGoesIntoListsQuotesAndHeadings() async throws {
        let cases: [(String, Int, String)] = [
            ("- item", 6, "- item \(link(pastedName))"),
            ("> quoted", 8, "> quoted \(link(pastedName))"),
            ("# Title\nText", 3, "# Title\n\n\(link(pastedName))\n\nText"),
            ("Title\n=====\nText", 2, "Title\n=====\n\n\(link(pastedName))\n\nText"),
        ]
        for (text, caret, expected) in cases {
            let r = try rig(text, selection: NSRange(location: caret, length: 0))
            putPNG(r.pb)
            XCTAssertTrue(r.h.coordinator.pasteImages(), text)
            await r.h.coordinator.waitForImageWork()
            XCTAssertEqual(r.text, expected, text)
        }
    }

    func testRefusedContextsLeaveTheTextAndTheFolderUntouched() throws {
        let cases: [(String, Int)] = [
            ("```swift\nlet x = 1\n```", 14),
            ("---\ntitle: x\n---\nBody", 8),
            ("| a | b |\n|---|---|\n| 1 | 2 |", 28),
            ("<div>\nhi\n</div>", 8),
            ("A\n\n---\n\nB", 5),
        ]
        for (text, caret) in cases {
            let r = try rig(text, selection: NSRange(location: caret, length: 0))
            putPNG(r.pb)
            XCTAssertFalse(r.h.coordinator.pasteImages(), text)
            XCTAssertEqual(r.text, text)
            XCTAssertFalse(fm.fileExists(atPath: r.assets.path), "\(text): nothing was written")
        }
    }

    // MARK: Folds, source view, other state (R6, R19)

    func testAFoldedHeadingOpensForTheInsertion() async throws {
        let r = try rig("# One\n\nfirst\n\n# Two\n\nsecond\n", selection: NSRange(location: 5, length: 0))
        let region = try XCTUnwrap(r.h.coordinator.analysis.foldRegions.first)
        r.h.coordinator.setFoldState(r.h.coordinator.foldState.toggled(region))
        XCTAssertFalse(r.h.coordinator.foldState.isEmpty)
        r.h.select(5)
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertTrue(r.h.coordinator.foldState.isEmpty, "the fold that would have hidden the image opened")
        XCTAssertTrue(r.text.hasPrefix("# One\n\n\(link(pastedName))\n\nfirst"))
    }

    func testOtherFoldsAreCarriedThroughTheInsertion() async throws {
        let r = try rig("# One\n\nfirst\n\n# Two\n\nsecond\n", selection: NSRange(location: 12, length: 0))
        let two = try XCTUnwrap(r.h.coordinator.analysis.foldRegions.last)
        r.h.coordinator.setFoldState(r.h.coordinator.foldState.toggled(two))
        r.h.select(12)
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.h.coordinator.foldState.anchors.count, 1)
        XCTAssertEqual(r.h.coordinator.foldState.anchors.first, r.h.index(of: "# Two"), "the fold still sits on its heading")
    }

    func testItWorksInTheSourceViewAndTheCardAppearsOnLeaving() async throws {
        let r = try rig("Hello world\n")
        r.h.coordinator.setSourceMode(true)
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "Hello world\n\n\(link(pastedName))\n\n")
        r.h.coordinator.setSourceMode(false)
        let carded = await waitUntil { (r.h.coordinator.overlay.reservedHeights[2] ?? 0) > 20 }
        XCTAssertTrue(carded)
    }

    func testTheDocumentFileIsNotTouchedAndTheWatcherDoesNotReload() async throws {
        let r = try rig("Hello world\n")
        let before = try fm.attributesOfItem(atPath: r.doc.path)[.modificationDate] as? Date
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(try fm.attributesOfItem(atPath: r.doc.path)[.modificationDate] as? Date, before, "the .md file was not written")
        XCTAssertFalse(r.h.coordinator.checkForExternalChange())
        XCTAssertEqual(try String(contentsOf: r.doc, encoding: .utf8), "Hello world\n")
    }

    // MARK: Responsiveness (R20)

    /// Makes `prepare` wait on `gate` so a test can act while the work is under way.
    private func slow(_ r: Rig, gate: DispatchSemaphore) {
        r.h.coordinator.imagePrepare = { source, folder, now, zone, cap in
            gate.wait()
            return try ImageIntake.prepare(source, documentFolder: folder, now: now, timeZone: zone, maxBytes: cap)
        }
    }

    func testTypingDuringTheWorkIsKeptAndTheLinkLandsAtTheMovedPlace() async throws {
        let r = try rig("Hello world\n")
        let gate = DispatchSemaphore(value: 0)
        slow(r, gate: gate)
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        r.h.select(0)
        r.h.textView.insertText("XYZ ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(r.text, "XYZ Hello world\n", "the editor takes input while the image is being made")
        gate.signal()
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "XYZ Hello world\n\n\(link(pastedName))\n\n")
    }

    func testClosingTheWindowMeansNothingIsInserted() async throws {
        let r = try rig("Hello world\n")
        let gate = DispatchSemaphore(value: 0)
        slow(r, gate: gate)
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        r.h.window.isReleasedWhenClosed = false                    // the test owns the window; closing must not release it again
        r.h.window.close()
        let seen = await waitUntil { r.h.coordinator.imageWindowClosed }
        XCTAssertTrue(seen)
        gate.signal()
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "Hello world\n")
        XCTAssertTrue(r.rec.announcements.isEmpty)
    }

    func testASecondPasteWaitsItsTurnAndKeepsOrder() async throws {
        let r = try rig("Hello world\n")
        let gate = DispatchSemaphore(value: 0)
        slow(r, gate: gate)
        putPNG(r.pb, ImageFixtures.png(width: 20, height: 20))
        XCTAssertTrue(r.h.coordinator.pasteImages())
        putPNG(r.pb, ImageFixtures.png(width: 30, height: 30))                    // the clipboard changes under the first job
        XCTAssertTrue(r.h.coordinator.pasteImages())
        gate.signal(); gate.signal()
        await r.h.coordinator.waitForImageWork()
        let second = "image-20261013-094112-2.png"
        XCTAssertEqual(Set(files(r)), [pastedName, second], "two distinct names")
        XCTAssertEqual(r.text, "Hello world\n\n\(link(pastedName))\n\n\(link(second))\n\n", "links in paste order")
        let first = try Data(contentsOf: r.assets.appendingPathComponent(pastedName))
        XCTAssertEqual(ImageFixtures.properties(of: first)[kCGImagePropertyPixelWidth] as? Int, 20, "each job kept its own bytes")
    }

    // MARK: Failure and alteration (R21, R22)

    func testAnAlteredImageIsInsertedAndExplained() async throws {
        let r = try rig("")
        r.h.coordinator.imageMaxBytes = 1_000_000
        let big = ImageFixtures.png(width: 800, height: 800, noise: true)
        XCTAssertGreaterThan(big.count, 1_000_000)
        putPNG(r.pb, big)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.rec.notices.count, 1)
        XCTAssertEqual(r.rec.notices.first?.title, "The image was added with changes")
        XCTAssertTrue(r.rec.notices.first?.message.contains("800 × 800") == true, r.rec.notices.first?.message ?? "")
        XCTAssertTrue(r.text.contains(link(pastedName)), "it was inserted")
    }

    func testAnImageTooBigToPreviewIsSaidSo() async throws {
        let r = try rig("")
        let gif = ImageFixtures.gif(frames: 4)
        r.h.coordinator.imageMaxBytes = gif.count / 2
        putPNG(r.pb)
        r.pb.clearContents()
        r.pb.setData(gif, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertTrue(r.rec.notices.first?.message.contains("too big to preview") == true)
        XCTAssertEqual(files(r).count, 1)
        XCTAssertTrue(files(r)[0].hasSuffix(".gif"))
    }

    func testNonImageFilesInAMixedPasteAreSkippedAndNamed() async throws {
        let r = try rig("")
        let png = r.folder.deletingLastPathComponent().appendingPathComponent("pic.png")
        let pdf = r.folder.deletingLastPathComponent().appendingPathComponent("notes.pdf")
        try ImageFixtures.png().write(to: png)
        try ImageFixtures.pdf().write(to: pdf)
        r.pb.clearContents()
        r.pb.writeObjects([png as NSURL, pdf as NSURL])
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "\(link("pic.png"))\n\n")
        XCTAssertTrue(r.rec.notices.first?.message.contains("notes.pdf") == true, r.rec.notices.first?.message ?? "no notice")
    }

    func testTheSuccessesOfAMixedBatchAreInsertedAndTheFailuresListed() async throws {
        let r = try rig("")
        let dir = r.folder.deletingLastPathComponent()
        let good = dir.appendingPathComponent("good.png"), bad = dir.appendingPathComponent("bad.png")
        try ImageFixtures.png().write(to: good)
        try Data("not an image at all".utf8).write(to: bad)
        r.pb.clearContents()
        r.pb.writeObjects([bad as NSURL, good as NSURL])
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "\(link("good.png"))\n\n")
        XCTAssertEqual(r.rec.notices.first?.title, "Not every image was added")
        XCTAssertTrue(r.rec.notices.first?.message.contains("“bad.png” isn't an image Downwrite can read.") == true)
        XCTAssertEqual(files(r), ["good.png"], "no partial file for the failure")
        XCTAssertEqual(r.rec.announcements, ["Image inserted: good.png"])
    }

    func testWhenNothingSucceedsNothingIsInserted() async throws {
        let r = try rig("Keep\n")
        let bad = r.folder.deletingLastPathComponent().appendingPathComponent("bad.png")
        try Data("nope".utf8).write(to: bad)
        r.pb.clearContents()
        r.pb.writeObjects([bad as NSURL])
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "Keep\n")
        XCTAssertEqual(r.rec.notices.first?.title, "The image was not added")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
        XCTAssertTrue(r.rec.announcements.isEmpty)
    }

    func testAnUnwritableFolderShowsTheSheetAndInsertsNothing() async throws {
        let r = try rig("Keep\n")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: r.folder.path)
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "Keep\n")
        XCTAssertEqual(r.rec.notices.first?.message, "“assets” in “Notes” can't be created: the folder is read-only.")
    }

    func testThePlaceTurningIntoCodeWhileTheWorkRunsInsertsNothingAndSaysSo() async throws {
        let r = try rig("Hello\n", selection: NSRange(location: 5, length: 0))
        let gate = DispatchSemaphore(value: 0)
        slow(r, gate: gate)
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        // The person wraps the line in a code fence while the image is being made.
        r.h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        r.h.textView.insertText("```\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        gate.signal()
        await r.h.coordinator.waitForImageWork()
        XCTAssertFalse(r.text.contains("!["), "no link in code")
        XCTAssertEqual(files(r), [pastedName], "the file stays in assets")
        XCTAssertEqual(r.rec.notices.first?.title, "The link was not added")
        XCTAssertTrue(r.rec.notices.first?.message.contains(pastedName) == true)
    }

    // MARK: Reading a pasteboard

    func testTheSummaryOfAScreenshotAFinderCopyAndMixedFiles() throws {
        let r = try rig("")
        putPNG(r.pb)
        var read = ImageIntake.read(r.pb)
        XCTAssertEqual(read.content, PasteboardImageContent(plainText: nil, hasImageData: true, imageFileNames: [], hasOtherFiles: false))
        XCTAssertEqual(read.sources.count, 1)

        let png = r.folder.appendingPathComponent("a.png"), pdf = r.folder.appendingPathComponent("b.pdf")
        r.pb.clearContents()
        r.pb.writeObjects([png as NSURL, pdf as NSURL])
        read = ImageIntake.read(r.pb)
        XCTAssertEqual(read.content.imageFileNames, ["a.png"])
        XCTAssertTrue(read.content.hasOtherFiles)
        XCTAssertEqual(read.skippedFiles, ["b.pdf"])
        XCTAssertEqual(read.sources.map(\.displayName), ["a.png"])
    }

    func testDataIsTakenInTheOrderOfR12() throws {
        let r = try rig("")
        r.pb.clearContents()
        r.pb.declareTypes([.tiff, .png], owner: nil)
        let tiff = ImageFixtures.tiff(), png = ImageFixtures.png()
        r.pb.setData(tiff, forType: .tiff)
        r.pb.setData(png, forType: .png)
        guard case .bytes(let data)? = ImageIntake.read(r.pb).sources.first?.origin else { return XCTFail("bytes expected") }
        XCTAssertEqual(data, png, "PNG comes before TIFF")
    }
}

// MARK: - The paste command (step 10)

extension ImagePasteFlowTests {
    func testThePasteCommandTakesAnImagePaste() async throws {
        let r = try rig("Hello world\n")
        putPNG(r.pb)
        r.h.textView.paste(nil)
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "Hello world\n\n\(link(pastedName))\n\n")
        XCTAssertEqual(files(r), [pastedName])
    }

    func testAnImageWithItsURLBeatsMakingALinkThroughThePasteCommand() async throws {
        let r = try rig("Hello world", selection: NSRange(location: 6, length: 5))
        r.pb.clearContents()
        r.pb.declareTypes([.png, .string], owner: nil)
        r.pb.setData(ImageFixtures.png(), forType: .png)
        r.pb.setString("https://example.com/cat.png", forType: .string)
        r.h.textView.paste(nil)
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "Hello \n\n\(link(pastedName))\n\n")
    }

    func testAURLAloneOverASelectionStillMakesALinkAndWritesNothing() async throws {
        let r = try rig("Hello world\n", selection: NSRange(location: 6, length: 5))
        r.pb.clearContents()
        r.pb.setString("https://example.com/page", forType: .string)
        r.h.textView.paste(nil)
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(r.text, "Hello [world](https://example.com/page)\n")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }

    func testThePasteMenuItemIsAvailableForAnImagePasteboardOnly() throws {
        let r = try rig("Hello\n")
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        putPNG(r.pb)
        XCTAssertTrue(r.h.textView.validateUserInterfaceItem(item), "an image-only pasteboard: the text view alone would disable Paste")
        XCTAssertTrue(r.h.coordinator.canPasteImages())
        r.pb.clearContents()
        r.pb.setString("just text", forType: .string)
        XCTAssertFalse(r.h.coordinator.canPasteImages())
        r.pb.clearContents()
        r.pb.declareTypes([.png, .string], owner: nil)
        r.pb.setData(ImageFixtures.png(), forType: .png)
        r.pb.setString("Name\tQty\n1\t2", forType: .string)
        XCTAssertFalse(r.h.coordinator.canPasteImages(), "spreadsheet text wins")
    }

    func testThePasteMenuItemIsNotOfferedWhereImagesCannotGo() throws {
        let r = try rig("```\ncode\n```\n", selection: NSRange(location: 6, length: 0))
        putPNG(r.pb)
        XCTAssertFalse(r.h.coordinator.canPasteImages())
    }

    func testLookingAtThePasteboardForTheMenuCopiesNoData() throws {
        let r = try rig("")
        putPNG(r.pb, ImageFixtures.png(width: 200, height: 200, noise: true))
        let cheap = ImageIntake.read(r.pb, copyingData: false)
        let full = ImageIntake.read(r.pb)
        XCTAssertEqual(cheap.content, full.content)
        guard case .bytes(let placeholder)? = cheap.sources.first?.origin else { return XCTFail("bytes expected") }
        XCTAssertTrue(placeholder.isEmpty, "the menu check never holds the image")
    }

    func testPasteAndMatchStyleAndTheOtherPastesAreStillAppKits() {
        for selector in [#selector(NSTextView.pasteAsPlainText(_:)), #selector(NSTextView.pasteAsRichText(_:)),
                         #selector(NSTextView.pasteFont(_:)), #selector(NSTextView.pasteRuler(_:))] {
            let ours = method_getImplementation(class_getInstanceMethod(EditorTextView.self, selector)!)
            let appkits = method_getImplementation(class_getInstanceMethod(NSTextView.self, selector)!)
            XCTAssertEqual(ours, appkits, "\(selector) is not overridden, so it never inserts an image (R1)")
        }
    }

    func testATableCellIsNotTheEditorAndSoNeverTakesAnImagePaste() {
        XCTAssertFalse(TableCellView.self.isSubclass(of: EditorTextView.self), "its paste (R4) is its own and untouched")
        XCTAssertNotEqual(method_getImplementation(class_getInstanceMethod(TableCellView.self, #selector(NSText.paste(_:)))!),
                          method_getImplementation(class_getInstanceMethod(EditorTextView.self, #selector(NSText.paste(_:)))!))
    }
}

// MARK: - Untitled documents (step 11)

extension ImagePasteFlowTests {
    /// A rig whose document has no file yet. `save` stands in for the Save… button and the save panel: it is told the rig and
    /// answers with the file the person "saved" (or nil for a cancelled panel).
    private func untitled(_ text: String = "Hello world\n", save: @escaping (Rig) async -> URL?) throws -> (Rig, SaveCounter) {
        let r = try rig(text, saved: false)
        let counter = SaveCounter()
        r.h.coordinator.requestSave = {
            counter.asked += 1
            return await save(r)
        }
        addTeardownBlock { r.h.coordinator.requestSave = nil }       // the closure holds the rig, which holds the coordinator
        return (r, counter)
    }

    final class SaveCounter { var asked = 0 }

    func testAnUntitledDocumentAsksToSaveThenCompletesThePasteAtTheRememberedPlace() async throws {
        let (r, counter) = try untitled { rig in rig.doc }
        r.h.select(5)                                             // between "Hello" and " world"
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(counter.asked, 1)
        XCTAssertEqual(r.text, "Hello\n\n\(link(pastedName))\n\n world\n")
        XCTAssertEqual(files(r), [pastedName], "written next to the file that was saved")
    }

    func testCancellingTheSaveWritesAndInsertsNothing() async throws {
        let (r, counter) = try untitled { _ in nil }
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(counter.asked, 1)
        XCTAssertEqual(r.text, "Hello world\n")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
        XCTAssertTrue(r.rec.announcements.isEmpty)
        XCTAssertTrue(r.rec.notices.isEmpty, "a cancel is a choice, not an error")
    }

    func testTheFolderComesFromTheSavedFileNotFromAnythingElse() async throws {
        let elsewhere = fm.temporaryDirectory.appendingPathComponent("downwrite-saved-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        addTeardownBlock { [fm] in try? fm.removeItem(at: elsewhere) }
        let (r, _) = try untitled { _ in elsewhere.appendingPathComponent("saved.md") }
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        await r.h.coordinator.waitForImageWork()
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.appendingPathComponent("assets/\(pastedName)").path))
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }

    func testASecondPasteQueuedBehindTheSheetWaitsAndIsAskedAboutOnce() async throws {
        var release: CheckedContinuation<Void, Never>?
        let (r, counter) = try untitled { rig in
            await withCheckedContinuation { release = $0 }             // the sheet is up
            rig.h.coordinator.fileURL = rig.doc                         // the save completed: SwiftUI hands the new URL over
            return rig.doc
        }
        putPNG(r.pb, ImageFixtures.png(width: 20, height: 20))
        XCTAssertTrue(r.h.coordinator.pasteImages())
        putPNG(r.pb, ImageFixtures.png(width: 30, height: 30))
        XCTAssertTrue(r.h.coordinator.pasteImages(), "a second paste while the sheet is up is queued")
        let up = await waitUntil { release != nil }
        XCTAssertTrue(up)
        XCTAssertEqual(r.text, "Hello world\n", "nothing yet")
        release?.resume()
        await r.h.coordinator.waitForImageWork()
        XCTAssertEqual(counter.asked, 1, "the second paste finds the saved document")
        XCTAssertEqual(r.text, "Hello world\n\n\(link(pastedName))\n\n\(link("image-20261013-094112-2.png"))\n\n")
    }

    // The sheet itself (the Save… path needs a real NSDocument and is checked in the real app)

    func testTheSheetSaysWhatItIsAndCancelEndsIt() async throws {
        let r = try rig("Hello world\n", saved: false)
        putPNG(r.pb)
        XCTAssertTrue(r.h.coordinator.pasteImages())
        let shown = await waitUntil { r.h.window.attachedSheet != nil }
        XCTAssertTrue(shown, "the save-first sheet appears on the window")
        let sheet = try XCTUnwrap(r.h.window.attachedSheet)
        func buttons(in view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        func labels(in view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels) }
        let all = buttons(in: sheet.contentView!)
        XCTAssertEqual(all.map(\.title).sorted(), ["Cancel", "Save…"])
        let text = labels(in: sheet.contentView!)
        XCTAssertTrue(text.contains("Save the document first"), "\(text)")
        XCTAssertTrue(text.contains { $0.contains("“assets” folder next to the document") && $0.contains("the image will be added") }, "\(text)")
        XCTAssertEqual(sheet.defaultButtonCell?.title, "Save…", "Save… is the default")
        try XCTUnwrap(all.first { $0.title == "Cancel" }).performClick(nil)
        await r.h.coordinator.waitForImageWork()
        XCTAssertNil(r.h.window.attachedSheet)
        XCTAssertEqual(r.text, "Hello world\n")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }
}
