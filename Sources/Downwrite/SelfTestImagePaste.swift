import AppKit
import DownwriteCore

/// Pasting and dropping images, end to end (DW-002): the real app, a real `NSDocument` on disk, the real Edit ▸ Paste menu item and its
/// validation, the real undo manager, a fold, a drop with its marker on screen, and an untitled window's save-first sheet. The images
/// are generated here and the pasteboard is a private one, so the person's clipboard is never touched. Nothing needs a fixture file.
///
/// Not driven here, on purpose: a drag from another app (a drag session cannot be made without a mouse and a source app: the drop is
/// handed to the editor the way AppKit hands it, and a file promise needs a live session, so Photos and Safari are on the by-hand list),
/// the system save panel behind Save… (it runs out of process), and VoiceOver speaking the announcement.
extension SelfTest {
    private static let imagePasteDocument = """
    # Images

    Before the image.

    ## Folded section

    Hidden body of the folded section.

    ## After

    End.

    """

    /// `--selftest-imagepaste-only`: run only this step (for development).
    static var imagePasteOnly: Bool { CommandLine.arguments.contains("--selftest-imagepaste-only") }

    static func imagePasteWalkthrough(outDir: URL, reusing tv: EditorTextView) async {
        func fail(_ what: String, _ detail: String = "") { check(false, "imagepaste: " + what, detail: detail) }
        guard let window = tv.window, let url = window.representedURL, let document = NSDocumentController.shared.document(for: url),
              let coordinator = tv.coordinator else { return fail("the editor window is available") }
        let folder = url.deletingLastPathComponent()
        let assets = folder.appendingPathComponent("assets")
        try? FileManager.default.removeItem(at: assets)
        do {
            try imagePasteDocument.write(to: url, atomically: true, encoding: .utf8)
            try document.revert(toContentsOf: url, ofType: document.fileType ?? "")
        } catch { return fail("the document reloads", "\(error)") }
        guard await waitUntil(timeout: 10, { tv.string == imagePasteDocument }) else { return fail("the window shows the document", "\(tv.string.count) characters") }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("downwrite.selftest.imagepaste"))
        defer { pasteboard.releaseGlobally() }
        var said: [String] = []
        var notices: [String] = []
        coordinator.imagePasteboard = pasteboard
        coordinator.onAnnouncement = { said.append($0) }
        coordinator.onImageNotice = { notices.append($0 + ": " + $1) }
        defer { coordinator.onAnnouncement = nil; coordinator.onImageNotice = nil; coordinator.imagePasteboard = .general }
        NSApp.activate(ignoringOtherApps: true)
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        try? await Task.sleep(nanoseconds: 800_000_000)

        // MARK: helpers
        func settle(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func offset(_ needle: String) -> Int { (tv.string as NSString).range(of: needle).location }
        func png(_ width: Int, _ height: Int) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 35)
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }
        func files() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []).sorted() }
        func shot(_ name: String) { check(capture(window: window, to: outDir.appendingPathComponent(name)), "imagepaste: the screenshot \(name) is not blank") }
        func menuItem(_ top: String, _ title: String) -> NSMenuItem? {
            NSApp.mainMenu?.update()
            return NSApp.mainMenu?.items.first { $0.title == top }?.submenu?.items.first { $0.title == title }
        }
        func choose(_ item: NSMenuItem?) {
            guard let item, let menu = item.menu else { return }
            menu.performActionForItem(at: menu.index(of: item))
        }

        let original = tv.string
        check(!document.isDocumentEdited, "imagepaste: the document starts unedited")

        // The reload above, through the document system, leaves the NSDocument deaf to the next edit until SwiftUI has updated once more:
        // found while writing this step, a typed character stays "unedited" for 5 s and the paste right after it was too. It is not
        // specific to images (typing does it), so one typed-and-undone character settles the document first, and the check below is
        // about the paste. The observation is kept in the report.
        do {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            let heard = await waitUntil(timeout: 2) { document.isDocumentEdited }
            tv.undoManager?.undo()
            document.updateChangeCount(.changeCleared)
            check(tv.string == original && !document.isDocumentEdited, "imagepaste: the document is settled and unedited again",
                  detail: "the first typed character after the reload was \(heard ? "" : "not ")recorded by the NSDocument")
        }

        // MARK: Edit ▸ Paste with a screenshot on the clipboard
        pasteboard.clearContents()
        pasteboard.setData(png(640, 360), forType: .png)
        tv.setSelectedRange(NSRange(location: offset("Before the image.") + "Before the image.".utf16.count, length: 0))
        await settle(0.2)
        let paste = menuItem("Edit", "Paste")
        check(paste != nil, "imagepaste: Edit has Paste")
        check(paste?.isEnabled == true, "imagepaste: Edit ▸ Paste is available for an image-only clipboard (the text view alone disables it)")
        choose(paste)
        await coordinator.waitForImageWork()
        let name = files().first
        check(files().count == 1 && name?.hasPrefix("image-") == true && name?.hasSuffix(".png") == true, "imagepaste: the screenshot is saved as assets/image-….png", detail: "\(files())")
        check(name.map { tv.string.contains("\n\n![](assets/\($0))\n\n## Folded section") } == true, "imagepaste: its link is a paragraph of its own at the caret", detail: tv.string)
        // SwiftUI marks the document edited a turn after the text changes (through the binding), so wait for it.
        let edited = await waitUntil(timeout: 5) { document.isDocumentEdited }
        check(edited, "imagepaste: the paste is an edit of the document")
        check(said == [name.map { "Image inserted: \($0)" } ?? ""], "imagepaste: the paste is announced", detail: "\(said)")
        check(notices.isEmpty, "imagepaste: a plain success shows no sheet", detail: "\(notices)")
        let carded = await waitUntil(timeout: 15) { coordinator.overlay.reservedHeights.values.contains { $0 > 100 } }
        check(carded, "imagepaste: the image previews as a card with no further step")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await settle(0.4)
        shot("window-light-imagepaste.png")

        // MARK: Undo, redo
        let pasted = tv.string
        check(tv.undoManager?.undoMenuItemTitle == "Undo Paste Image", "imagepaste: Edit ▸ Undo is \"Undo Paste Image\"", detail: "\(String(describing: tv.undoManager?.undoMenuItemTitle))")
        tv.undoManager?.undo()
        check(tv.string == original, "imagepaste: one undo removes the whole insertion")
        check(files().count == 1, "imagepaste: and never deletes the file")
        tv.undoManager?.redo()
        check(tv.string == pasted, "imagepaste: redo puts the link back")

        // MARK: A drop onto a folded heading
        let photos = folder.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let sunset = photos.appendingPathComponent("sunset.png")
        try? png(300, 200).write(to: sunset)
        if let region = coordinator.analysis.foldRegions.first(where: { $0.kind == .heading(level: 2) }) {
            coordinator.setFoldState(coordinator.foldState.toggled(region))
            await settle(0.4)
        } else { fail("the document has a fold") }
        check(!coordinator.foldState.isEmpty, "imagepaste: the second section is folded before the drop")
        let board = NSPasteboard(name: NSPasteboard.Name("downwrite.selftest.imagedrop"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([sunset as NSURL])
        let end = offset("Folded section") + "Folded section".utf16.count
        let lm = tv.layoutManager!
        let line = lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: end - 1), effectiveRange: nil)
        let atEnd = NSPoint(x: tv.textContainerOrigin.x + line.maxX + 2, y: tv.textContainerOrigin.y + line.midY)
        let drag = SelfTestDraggingInfo(pasteboard: board, window: window, location: tv.convert(atEnd, to: nil))
        let operation = tv.draggingEntered(drag)
        check(operation == .copy, "imagepaste: an image file dragged over the text shows the copy badge", detail: "\(operation)")
        await settle(0.3)
        check((tv.layoutManager as? DWLayoutManager)?.dropMarkerIndex == end, "imagepaste: and the drop point is marked", detail: "\(String(describing: (tv.layoutManager as? DWLayoutManager)?.dropMarkerIndex))")
        shot("window-light-imagedrop-marker.png")
        check(tv.prepareForDragOperation(drag) && tv.performDragOperation(drag), "imagepaste: the drop is accepted")
        tv.concludeDragOperation(drag)
        await coordinator.waitForImageWork()
        check((tv.layoutManager as? DWLayoutManager)?.dropMarkerIndex == nil, "imagepaste: the marker is gone after the drop")
        check(tv.string.contains("## Folded section\n\n![](photos/sunset.png)\n\n"), "imagepaste: the dropped file in the document's folder is linked where it is", detail: tv.string)
        check(files().count == 1, "imagepaste: and nothing was copied for it", detail: "\(files())")
        check(coordinator.foldState.isEmpty, "imagepaste: the fold that would have hidden the link opened")
        check(tv.undoManager?.undoMenuItemTitle == "Undo Drop Image", "imagepaste: Edit ▸ Undo is \"Undo Drop Image\"", detail: "\(String(describing: tv.undoManager?.undoMenuItemTitle))")
        shot("window-light-imagedrop.png")

        // MARK: An untitled document asks to save first
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSDocumentController.shared.newDocument(nil)
        let opened = await waitUntil(timeout: 10) { editors().contains { $0 !== tv && $0.window != nil && !windowsBefore.contains(ObjectIdentifier($0.window!)) } }
        guard opened, let other = editors().first(where: { $0 !== tv && $0.window != nil && !windowsBefore.contains(ObjectIdentifier($0.window!)) }),
              let otherWindow = other.window, let otherCoordinator = other.coordinator else { return fail("a new untitled window opens") }
        otherCoordinator.imagePasteboard = pasteboard
        otherCoordinator.onImageNotice = { notices.append($0 + ": " + $1) }
        otherWindow.makeKeyAndOrderFront(nil)
        otherWindow.makeFirstResponder(other)
        pasteboard.clearContents()
        pasteboard.setData(png(200, 100), forType: .png)
        let filesBefore = files()
        choose(menuItem("Edit", "Paste"))
        let sheetUp = await waitUntil(timeout: 10) { otherWindow.attachedSheet != nil }
        check(sheetUp, "imagepaste: pasting into an untitled document shows the save-first sheet")
        if let sheet = otherWindow.attachedSheet {
            func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
            func texts(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts) }
            let found = sheet.contentView.map(texts) ?? []
            check(found.contains("Save the document first"), "imagepaste: the sheet says \"Save the document first\"", detail: "\(found)")
            check(sheet.defaultButtonCell?.title == "Save…", "imagepaste: Save… is its default button")
            shot("window-light-imagepaste-untitled.png")
            sheet.contentView.flatMap { buttons($0).first { $0.title == "Cancel" } }?.performClick(nil)
        }
        await otherCoordinator.waitForImageWork()
        check(otherWindow.attachedSheet == nil, "imagepaste: Cancel closes the sheet")
        check(other.string.isEmpty, "imagepaste: and inserts nothing")
        check(files() == filesBefore, "imagepaste: and writes nothing", detail: "\(files())")
        otherCoordinator.onImageNotice = nil
        otherCoordinator.imagePasteboard = .general
        otherWindow.close()

        // Back to the original window and the starting theme, for the walkthroughs that follow.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
    }
}

/// A drag session as AppKit hands one to a drag destination, made by hand (no mouse and no source app are involved).
private final class SelfTestDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let window: NSWindow?
    let location: NSPoint
    init(pasteboard: NSPasteboard, window: NSWindow?, location: NSPoint) { self.pasteboard = pasteboard; self.window = window; self.location = location }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .move, .link] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
