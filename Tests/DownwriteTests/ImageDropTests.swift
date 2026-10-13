import XCTest
import AppKit
import UniformTypeIdentifiers
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

    func testBaselineADroppedNonImageFileInsertsItsPathAsText() {
        let h = editor()
        let pb = board()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/probe notes.txt") as NSURL])
        let answers = dropAnswers(drag(pb, over: h), on: h.textView)
        XCTAssertEqual(answers.entered, .copy)
        XCTAssertTrue(answers.performed)
        XCTAssertTrue(h.textView.string.contains("/tmp/probe notes.txt"), "R4: unchanged by the image drop")
    }

    /// What a plain text view set up like the editor does with raw image data: it refuses it. This is why the editor claims image
    /// drags itself (R2): before the change the editor behaved exactly like this.
    func testBaselineAPlainTextViewRefusesRawImageData() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tv = NSTextView(frame: scroll.bounds)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.string = "Hello\n"
        scroll.documentView = tv
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let pb = board()
        pb.setData(ImageFixtures.png(), forType: .png)
        let info = FakeDraggingInfo(pasteboard: pb, window: window, location: tv.convert(NSPoint(x: 40, y: 10), to: nil))
        XCTAssertEqual(tv.draggingEntered(info), [], "AppKit refuses image data because graphics are not imported")
        XCTAssertFalse(tv.prepareForDragOperation(info))
        XCTAssertEqual(tv.string, "Hello\n")
        window.close()
    }
}

// MARK: - Dropping images (step 12)

/// Writes a promised file when the drag's destination asks for it, as Photos and some browsers do.
final class PromiseSource: NSObject, NSFilePromiseProviderDelegate {
    let name: String
    let data: Data
    init(name: String, data: Data) { self.name = name; self.data = data }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try data.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

@MainActor
final class ImageDropFlowTests: ImageRigTestCase {
    /// A drag over the character at `index` (window coordinates, just to the right of its left edge, so that is the nearest boundary).
    private func info(_ r: Rig, at index: Int, source: Any? = nil, mask: NSDragOperation? = nil) -> FakeDraggingInfo {
        let tv = r.h.textView
        let lm = tv.layoutManager!
        lm.ensureLayout(for: tv.textContainer!)
        let origin = tv.textContainerOrigin
        var point: NSPoint
        if index < tv.string.utf16.count {
            let glyph = lm.glyphIndexForCharacter(at: index)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            point = NSPoint(x: line.minX + lm.location(forGlyphAt: glyph).x + 0.5, y: line.midY)
        } else {
            let last = lm.lineFragmentUsedRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil)
            point = NSPoint(x: last.maxX + 4, y: last.midY)
        }
        point = NSPoint(x: point.x + origin.x, y: point.y + origin.y)
        let drag = FakeDraggingInfo(pasteboard: r.pb, window: r.h.window, location: tv.convert(point, to: nil))
        drag.source = source
        if let mask { drag.operationMask = mask }
        return drag
    }

    /// The four destination calls in AppKit's order, then the queued work.
    @discardableResult
    private func drop(_ r: Rig, at index: Int, source: Any? = nil) async -> (entered: NSDragOperation, updated: NSDragOperation, prepared: Bool, performed: Bool) {
        let drag = info(r, at: index, source: source)
        let tv = r.h.textView
        let entered = tv.draggingEntered(drag)
        let updated = tv.draggingUpdated(drag)
        let prepared = tv.prepareForDragOperation(drag)
        let performed = prepared ? tv.performDragOperation(drag) : false
        if performed { tv.concludeDragOperation(drag) }
        await r.h.coordinator.waitForImageWork()
        return (entered, updated, prepared, performed)
    }

    private func outside(_ r: Rig, _ name: String, _ data: Data) throws -> URL {
        let dir = r.folder.deletingLastPathComponent().appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func dropFiles(_ r: Rig, _ urls: [URL]) {
        r.pb.clearContents()
        r.pb.writeObjects(urls.map { $0 as NSURL })
    }

    // MARK: Files (R2)

    func testAnImageFileDroppedOnTheTextIsSavedLinkedAtTheDropPointAndPreviewed() async throws {
        let r = try rig("Hello world\n\nSecond paragraph\n")
        dropFiles(r, [try outside(r, "photo.png", ImageFixtures.png())])
        let answers = await drop(r, at: r.h.index(of: "Second"))
        XCTAssertEqual(answers.entered, .copy, "the pointer shows the copy badge")
        XCTAssertEqual(answers.updated, .copy)
        XCTAssertTrue(answers.prepared)
        XCTAssertTrue(answers.performed)
        XCTAssertEqual(r.text, "Hello world\n\n\(link("photo.png"))\n\nSecond paragraph\n")
        XCTAssertEqual(files(r), ["photo.png"])
        let carded = await waitUntil { (r.h.coordinator.overlay.reservedHeights[2] ?? 0) > 20 }
        XCTAssertTrue(carded)
        XCTAssertEqual(r.rec.announcements, ["Image inserted: photo.png"])
        XCTAssertEqual(r.h.textView.undoManager?.undoMenuItemTitle, "Undo Drop Image")
    }

    func testTwoFilesAreInsertedInDropOrder() async throws {
        let r = try rig("Hello world\n")
        dropFiles(r, [try outside(r, "b.jpg", ImageFixtures.jpeg()), try outside(r, "a.png", ImageFixtures.png())])
        await drop(r, at: 5)
        XCTAssertEqual(r.text, "Hello\n\n\(link("b.jpg"))\n\n\(link("a.png"))\n\n world\n")
        XCTAssertEqual(r.rec.announcements, ["2 images inserted"])
        XCTAssertEqual(r.h.textView.undoManager?.undoMenuItemTitle, "Undo Drop Images")
    }

    func testAFileAlreadyInTheFolderIsLinkedWhereItIsAndNothingIsWritten() async throws {
        let r = try rig("Intro\n")
        let url = r.folder.appendingPathComponent("pics/a b.png")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ImageFixtures.png().write(to: url)
        dropFiles(r, [url])
        await drop(r, at: 5)
        XCTAssertEqual(r.text, "Intro\n\n![](pics/a%20b.png)\n\n\n".replacingOccurrences(of: "\n\n\n", with: "\n\n"))
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path), "R15: nothing written")
    }

    func testAFileAlreadyInAssetsIsLinkedAndNotCopied() async throws {
        let r = try rig("Intro\n")
        let url = r.assets.appendingPathComponent("a.png")
        try fm.createDirectory(at: r.assets, withIntermediateDirectories: true)
        try ImageFixtures.png().write(to: url)
        dropFiles(r, [url])
        await drop(r, at: 5)
        XCTAssertTrue(r.text.contains(link("a.png")))
        XCTAssertEqual(files(r), ["a.png"])
    }

    func testASymbolicLinkInTheFolderThatLeavesItIsCopied() async throws {
        let r = try rig("Intro\n")
        let real = try outside(r, "real.png", ImageFixtures.png())
        let alias = r.folder.appendingPathComponent("alias.png")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        dropFiles(r, [alias])
        await drop(r, at: 5)
        XCTAssertTrue(r.text.contains(link("alias.png")), r.text)
        XCTAssertEqual(files(r), ["alias.png"], "copied into assets, not linked through the symbolic link")
    }

    func testASiblingFolderWithTheSamePrefixIsOutside() async throws {
        let r = try rig("Intro\n")
        let sibling = r.folder.deletingLastPathComponent().appendingPathComponent("Notes2", isDirectory: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let url = sibling.appendingPathComponent("a.png")
        try ImageFixtures.png().write(to: url)
        dropFiles(r, [url])
        await drop(r, at: 5)
        XCTAssertEqual(files(r), ["a.png"], "/Notes2 is not inside /Notes")
    }

    func testTIFFAndHEICFilesAreConverted() async throws {
        let r = try rig("")
        var urls = [try outside(r, "scan.tif", ImageFixtures.tiff())]
        if let heic = ImageFixtures.heic() { urls.append(try outside(r, "IMG_0001.HEIC", heic)) }
        dropFiles(r, urls)
        await drop(r, at: 0)
        XCTAssertTrue(r.text.contains(link("scan.png")))
        if urls.count == 2 { XCTAssertTrue(r.text.contains(link("IMG_0001.jpg")), "HEIC arrives as .jpg") }
    }

    func testMixedFilesInsertTheImagesAndNameTheOthers() async throws {
        let r = try rig("")
        dropFiles(r, [try outside(r, "a.png", ImageFixtures.png()), try outside(r, "notes.txt", Data("hi".utf8))])
        await drop(r, at: 0)
        XCTAssertEqual(r.text, "\(link("a.png"))\n\n")
        XCTAssertTrue(r.rec.notices.first?.message.contains("notes.txt") == true)
    }

    // MARK: What stays as it was (R4)

    func testADropWithNoImagesInsertsThePathAsTextAsBefore() async throws {
        let r = try rig("Hello\n")
        let pdf = try outside(r, "doc.pdf", ImageFixtures.pdf())
        dropFiles(r, [pdf])
        let answers = await drop(r, at: 0)
        XCTAssertEqual(answers.entered, .copy)
        XCTAssertTrue(answers.performed)
        XCTAssertTrue(r.text.contains(pdf.path), "the path is inserted as text, as it always was")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }

    func testTextDraggedWithinTheEditorIsNotAnImageDrag() async throws {
        let r = try rig("Hello\n")
        dropFiles(r, [try outside(r, "a.png", ImageFixtures.png())])
        let answers = await drop(r, at: 0, source: r.h.textView)
        XCTAssertTrue(answers.performed, "AppKit handles it")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path), "a drag that started in the editor never writes a file")
    }

    func testAStringDropIsAppKits() async throws {
        let r = try rig("Hello\n")
        r.pb.clearContents()
        r.pb.setString("DROPPED", forType: .string)
        await drop(r, at: 0)
        XCTAssertTrue(r.text.contains("DROPPED"))
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }

    func testACaptionBesideTheImageMakesItATextDrop() async throws {
        let r = try rig("Hello\n")
        r.pb.clearContents()
        r.pb.declareTypes([.png, .string], owner: nil)
        r.pb.setData(ImageFixtures.png(), forType: .png)
        r.pb.setString("Name\tQty\n1\t2", forType: .string)
        let answers = await drop(r, at: 0)
        XCTAssertTrue(answers.performed)
        XCTAssertTrue(r.text.contains("Name\tQty"), "the text wins, as in a paste")
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }

    func testAnImageDragInACodeBlockIsLeftToAppKit() async throws {
        let r = try rig("```\ncode\n```\n")
        r.pb.clearContents()
        r.pb.setData(ImageFixtures.png(), forType: .png)
        let before = r.text
        let answers = await drop(r, at: 5)
        XCTAssertEqual(answers.entered, [], "R5: not here (and AppKit refuses image data)")
        XCTAssertFalse(answers.performed)
        XCTAssertEqual(r.text, before)
        XCTAssertFalse(fm.fileExists(atPath: r.assets.path))
    }

    // MARK: Raw data and promised files (R2)

    func testRawImageDataIsAccepted() async throws {
        let r = try rig("Hello\n")
        r.pb.clearContents()
        let png = ImageFixtures.png()
        r.pb.setData(png, forType: .png)
        let answers = await drop(r, at: 5)
        XCTAssertEqual(answers.entered, .copy, "AppKit refuses this today; the editor accepts it")
        XCTAssertTrue(answers.performed)
        XCTAssertEqual(r.text, "Hello\n\n\(link(pastedName))\n\n\n".replacingOccurrences(of: "\n\n\n", with: "\n\n"))
        XCTAssertEqual(try Data(contentsOf: r.assets.appendingPathComponent(pastedName)), png)
    }

    /// Stands in for AppKit's `receivePromisedFiles`, which raises an exception outside a live drop: the provider's file is written to
    /// the destination on the queue, as the real call does.
    private func fakeAppKit(_ source: PromiseSource, failing: Bool = false) -> PromisedFiles.Starter {
        { _, destination, queue, reader in
            let url = destination.appendingPathComponent(source.name)
            queue.addOperation {
                if failing { reader(url, CocoaError(.fileReadUnknown)); return }
                do { try source.data.write(to: url); reader(url, nil) } catch { reader(url, error) }
            }
        }
    }

    private func promise(_ r: Rig, _ source: PromiseSource, type: UTType = .png) {
        r.pb.clearContents()
        r.pb.writeObjects([NSFilePromiseProvider(fileType: type.identifier, delegate: source)])
    }

    private func receivingFolders() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("downwrite-drop-") }
    }

    func testAPromisedFileIsReceivedAndAdded() async throws {
        let r = try rig("Hello\n")
        let source = PromiseSource(name: "Vacation.PNG", data: ImageFixtures.png())
        r.h.coordinator.promiseStarter = fakeAppKit(source)
        promise(r, source)
        let before = receivingFolders()
        let answers = await drop(r, at: 5)
        XCTAssertEqual(answers.entered, .copy, "a promise of an image is an image drag")
        XCTAssertTrue(answers.performed)
        XCTAssertEqual(files(r), ["Vacation.png"], "the promised file's own name, made safe")
        XCTAssertTrue(r.text.contains(link("Vacation.png")))
        XCTAssertEqual(receivingFolders(), before, "the receiving folder is removed")
    }

    func testAPromiseThatFailsIsCountedAndInsertsNothing() async throws {
        let r = try rig("Hello\n")
        let source = PromiseSource(name: "Broken.PNG", data: Data())
        r.h.coordinator.promiseStarter = fakeAppKit(source, failing: true)
        promise(r, source)
        let before = receivingFolders()
        await drop(r, at: 5)
        XCTAssertEqual(r.text, "Hello\n")
        XCTAssertEqual(r.rec.notices.first?.message, "A file could not be received from the app it was dragged from.")
        XCTAssertEqual(receivingFolders(), before)
    }

    func testAPromiseOfSomethingThatIsNotAnImageIsNotAnImageDrag() async throws {
        let r = try rig("Hello\n")
        let source = PromiseSource(name: "notes.pdf", data: ImageFixtures.pdf())
        r.h.coordinator.promiseStarter = fakeAppKit(source)
        promise(r, source, type: .pdf)
        XCTAssertNil(r.h.coordinator.imageDrag(from: info(r, at: 0), readData: false))
    }

    func testACancelledSaveRemovesTheReceivedFiles() async throws {
        let r = try rig("Hello\n", saved: false)
        r.h.coordinator.requestSave = { nil }
        addTeardownBlock { r.h.coordinator.requestSave = nil }
        let source = PromiseSource(name: "Vacation.PNG", data: ImageFixtures.png())
        r.h.coordinator.promiseStarter = fakeAppKit(source)
        promise(r, source)
        let before = receivingFolders()
        await drop(r, at: 5)
        XCTAssertEqual(r.text, "Hello\n")
        XCTAssertEqual(receivingFolders(), before, "nothing left in the temporary folder")
    }

    func testTheOperationFollowsWhatTheSourceAllows() async throws {
        let r = try rig("Hello\n")
        dropFiles(r, [try outside(r, "a.png", ImageFixtures.png())])
        XCTAssertEqual(r.h.textView.draggingEntered(info(r, at: 0, mask: [.copy])), .copy)
        XCTAssertEqual(r.h.textView.draggingEntered(info(r, at: 0, mask: [.generic])), .generic)
        XCTAssertEqual(r.h.textView.draggingEntered(info(r, at: 0, mask: [.link])), [])
    }

    // MARK: Where cards and cells are

    func testADropOverAPreviewCardReachesTheText() async throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("downwrite-card-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [fm] in try? fm.removeItem(at: dir) }
        try ImageFixtures.png(width: 300, height: 150).write(to: dir.appendingPathComponent("pic.png"))
        let h = EditorHarness(text: "intro\n\n![pic](pic.png)\n\nafter\n", fileURL: dir.appendingPathComponent("doc.md"))
        h.window.makeKeyAndOrderFront(nil)
        let carded = await waitUntil { (h.coordinator.overlay.reservedHeights[2] ?? 0) > 100 }
        XCTAssertTrue(carded)
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        h.coordinator.overlay.reposition(analysis: h.coordinator.analysis)
        let card = try XCTUnwrap(h.textView.subviews.compactMap { $0 as? DiagramView }.first)
        let inside = NSPoint(x: card.frame.midX, y: card.frame.midY)
        XCTAssertTrue(h.textView.hitTest(h.textView.convert(inside, to: h.textView.superview)) === h.textView,
                      "the card is click-through, so the text view is the drag destination")
    }

    // MARK: The drop marker

    func testAnImageDragMarksTheDropPointAndTheMarkerGoesAway() async throws {
        let r = try rig("Hello world\n\nSecond\n")
        dropFiles(r, [try outside(r, "a.png", ImageFixtures.png())])
        let layout = r.h.textView.layoutManager as! DWLayoutManager
        XCTAssertNil(layout.dropMarkerIndex)
        let drag = info(r, at: r.h.index(of: "world"))
        _ = r.h.textView.draggingEntered(drag)
        XCTAssertEqual(layout.dropMarkerIndex, r.h.index(of: "world"))
        let rect = try XCTUnwrap(layout.dropMarkerRect(forCharacterAt: r.h.index(of: "world")))
        XCTAssertEqual(rect.width, DWLayoutManager.dropMarkerWidth)
        let line = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: r.h.index(of: "world")), effectiveRange: nil)
        XCTAssertEqual(rect.minY, line.minY, accuracy: 0.5)
        XCTAssertEqual(rect.height, line.height, accuracy: 0.5, "as tall as the line")
        _ = r.h.textView.draggingUpdated(info(r, at: r.h.index(of: "Second")))
        XCTAssertEqual(layout.dropMarkerIndex, r.h.index(of: "Second"), "it follows the pointer")
        r.h.textView.draggingExited(drag)
        XCTAssertNil(layout.dropMarkerIndex)
    }

    func testTheMarkerIsDrawnInTheAccentColourAndOnlyWhileTheDragIsOver() async throws {
        let r = try rig("Hello world\n\nSecond\n")
        r.h.window.setContentSize(NSSize(width: 960, height: 760))
        dropFiles(r, [try outside(r, "a.png", ImageFixtures.png())])
        let tv = r.h.textView
        func pixels() -> NSBitmapImageRep {
            tv.displayIfNeeded()
            let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
            tv.cacheDisplay(in: tv.bounds, to: rep)
            return rep
        }
        let before = pixels()
        let layout = tv.layoutManager as! DWLayoutManager
        let at = r.h.index(of: "world")
        _ = tv.draggingEntered(info(r, at: at))
        let during = pixels()
        let rect = try XCTUnwrap(layout.dropMarkerRect(forCharacterAt: at))
        let origin = tv.textContainerOrigin
        let scale = CGFloat(during.pixelsWide) / tv.bounds.width
        let x = Int((rect.midX + origin.x) * scale), y = Int((rect.midY + origin.y) * scale)
        let beforeColour = before.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        let duringColour = during.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat { abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) }
        let accent = layout.dropMarkerColor.usingColorSpace(.sRGB)!
        XCTAssertLessThan(distance(duringColour, accent), distance(beforeColour, accent), "the pixel moved toward the accent colour")
        tv.draggingExited(info(r, at: at))
        let after = pixels()
        XCTAssertEqual(after.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent, beforeColour.redComponent, accuracy: 0.02, "gone again")
    }

    // MARK: Other states

    func testItWorksInTheSourceView() async throws {
        let r = try rig("Hello\n")
        r.h.coordinator.setSourceMode(true)
        dropFiles(r, [try outside(r, "a.png", ImageFixtures.png())])
        await drop(r, at: 5)
        XCTAssertTrue(r.text.contains(link("a.png")))
    }

    func testAnUntitledDocumentAsksToSaveBeforeADropToo() async throws {
        let r = try rig("Hello\n", saved: false)
        var asked = 0
        r.h.coordinator.requestSave = { asked += 1; return nil }
        addTeardownBlock { r.h.coordinator.requestSave = nil }
        dropFiles(r, [try outside(r, "a.png", ImageFixtures.png())])
        await drop(r, at: 5)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(r.text, "Hello\n")
    }
}
