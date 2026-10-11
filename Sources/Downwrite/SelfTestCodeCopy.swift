import AppKit
import DownwriteCore

/// The copy control on code cards, end to end (DW-012): the real app, a real `NSDocument` on disk, real mouse and key events through
/// the window and the real menu bar, the clipboard read back (a private pasteboard, so the person's own is never touched) and
/// screenshots of the control in both themes. Nothing here needs a fixture file; the document is written by the step itself.
extension SelfTest {
    private static let codeCopyDocument = """
    # Copying code

    A paragraph before the code.

    ```sh
    brew install downwrite
    downwrite --version
    ```

    > ```json
    > { "quoted": true }
    > ```

    A paragraph after.

    """

    /// `--selftest-codecopy-only`: run only this step (for development; `--selftest-input` is still required and opened).
    static var codeCopyOnly: Bool { CommandLine.arguments.contains("--selftest-codecopy-only") }

    /// Runs in the run's first editor window (the one SwiftUI resolves the menu bar against), which it reloads the way an external change is,
    /// so the document is still real, unedited and on disk.
    static func codeCopyWalkthrough(outDir: URL, reusing tv: EditorTextView) async {
        func fail(_ what: String, _ detail: String = "") { check(false, "codecopy: " + what, detail: detail) }
        guard let window = tv.window, let url = window.representedURL, let document = NSDocumentController.shared.document(for: url),
              let coordinator = tv.coordinator, let layout = tv.layoutManager as? DWLayoutManager else { return fail("the editor window is available") }
        do {
            try codeCopyDocument.write(to: url, atomically: true, encoding: .utf8)
            try document.revert(toContentsOf: url, ofType: document.fileType ?? "")
        } catch { return fail("the document reloads", "\(error)") }
        guard await waitUntil(timeout: 10, { tv.string == codeCopyDocument }) else { return fail("the window shows the document", "\(tv.string.count) characters") }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("downwrite.selftest.codecopy"))
        defer { pasteboard.releaseGlobally() }
        coordinator.codeCopyPasteboard = pasteboard
        NSApp.activate(ignoringOtherApps: true)
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        window.acceptsMouseMovedEvents = true
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        try? await Task.sleep(nanoseconds: 800_000_000)

        // MARK: helpers
        func settle(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func offset(_ needle: String) -> Int { (tv.string as NSString).range(of: needle).location }
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: tv.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        func move(to point: NSPoint) { if let e = event(.mouseMoved, at: point) { window.sendEvent(e) } }
        /// A real click. The mouse-up is queued first: a click that is not swallowed would otherwise track the mouse for ever.
        func click(_ point: NSPoint) {
            if let up = event(.leftMouseUp, at: point) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown, at: point) { window.sendEvent(down) }
        }
        func point(onLineOf needle: String) -> NSPoint {
            let r = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset(needle)), effectiveRange: nil)
            return NSPoint(x: tv.textContainerOrigin.x + 120, y: tv.textContainerOrigin.y + r.midY)
        }
        func controlPoint(block i: Int) -> NSPoint? {
            coordinator.copyControlFrame(ofBlock: i, in: layout).map { NSPoint(x: $0.midX, y: $0.midY) }
        }
        func clipboard() -> String? { pasteboard.string(forType: .string) }
        func shot(_ name: String) { check(capture(window: window, to: outDir.appendingPathComponent(name)), "codecopy: the screenshot \(name) is not blank") }

        // MARK: the starting point
        check(coordinator.analysis.codeBlocks.map(\.text) == ["brew install downwrite\ndownwrite --version", "{ \"quoted\": true }"], "codecopy: both blocks are recorded",
              detail: "\(coordinator.analysis.codeBlocks.map(\.text))")
        check(!document.isDocumentEdited, "codecopy: the document starts unedited")
        check(tv.undoManager?.canUndo == false, "codecopy: and with nothing to undo")
        let text = tv.string
        tv.setSelectedRange(NSRange(location: offset("A paragraph before"), length: 0))
        await settle()
        check(layout.activeCodeBlock == nil && layout.hoveredCodeBlock == nil, "codecopy: no control shows with the pointer and the caret elsewhere")

        // MARK: hover, click, tick (light)
        for theme in [ThemeChoice.light, .dark] {
            UserDefaults.standard.set(theme.rawValue, forKey: Prefs.theme)
            ThemeChoice.applyCurrent()
            await settle(1.0)
            tv.setSelectedRange(NSRange(location: offset("A paragraph before"), length: 0))
            pasteboard.clearContents()
            let caret = tv.selectedRange()
            move(to: point(onLineOf: "brew install"))
            await settle()
            check(layout.hoveredCodeBlock == 0, "codecopy: the control shows while the pointer is over the block (\(theme.rawValue))", detail: "hovered=\(String(describing: layout.hoveredCodeBlock))")
            guard let target = controlPoint(block: 0) else { fail("the control has a place on the card (\(theme.rawValue))"); continue }
            move(to: target)
            await settle(0.2)
            shot("window-\(theme.rawValue)-codecopy-hover.png")
            click(target)
            await settle(0.3)
            check(clipboard() == "brew install downwrite\ndownwrite --version", "codecopy: a click puts exactly the code on the clipboard (\(theme.rawValue))", detail: "\(String(describing: clipboard()))")
            check(layout.copiedCodeBlock == 0, "codecopy: the control shows a tick (\(theme.rawValue))")
            shot("window-\(theme.rawValue)-codecopy-ticked.png")
            check(tv.selectedRange() == caret, "codecopy: the caret did not move (\(theme.rawValue))", detail: "\(tv.selectedRange())")
            check(window.firstResponder === tv, "codecopy: the editor has the keyboard (\(theme.rawValue))")
            let gone = await waitUntil(timeout: 5) { layout.copiedCodeBlock == nil }
            check(gone, "codecopy: the tick goes after a moment (\(theme.rawValue))")
        }
        check(tv.string == text, "codecopy: the text is unchanged")
        check(!document.isDocumentEdited, "codecopy: the document is still not marked as edited")
        check(tv.undoManager?.canUndo == false, "codecopy: and there is still nothing to undo")

        // MARK: the caret inside a block (revealed), a block in a quote
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        await settle(1.0)
        let inside = NSRange(location: offset("quoted") + 2, length: 0)
        tv.setSelectedRange(inside)
        pasteboard.clearContents()
        await settle()
        check(layout.activeCodeBlock == 1, "codecopy: the control shows while the caret is in the block", detail: "active=\(String(describing: layout.activeCodeBlock))")
        if let target = controlPoint(block: 1) {
            click(target)
            await settle(0.3)
            check(clipboard() == "{ \"quoted\": true }", "codecopy: a block in a quote copies without its quote marks", detail: "\(String(describing: clipboard()))")
            check(tv.selectedRange() == inside, "codecopy: and the caret stays inside it")
        } else { fail("the quoted block's control has a place") }

        // MARK: Edit ▸ Copy Code Block
        NSApp.mainMenu?.update()
        func allItems(_ menu: NSMenu?) -> [(top: String, item: NSMenuItem)] {
            (menu?.items ?? []).flatMap { top -> [(String, NSMenuItem)] in
                func walk(_ m: NSMenu?) -> [(String, NSMenuItem)] { (m?.items ?? []).flatMap { [(top.title, $0)] + walk($0.submenu) } }
                return walk(top.submenu)
            }.map { (top: $0.0, item: $0.1) }
        }
        let shortcut = allItems(NSApp.mainMenu).filter { $0.item.keyEquivalent.lowercased() == "c" && $0.item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .shift] }
        let copyItem = allItems(NSApp.mainMenu).first { $0.top == "Edit" && $0.item.title == "Copy Code Block" }?.item
        check(copyItem != nil, "codecopy: Edit has Copy Code Block", detail: "\(allItems(NSApp.mainMenu).filter { $0.top == "Edit" }.map(\.item.title))")
        check(shortcut.count == 1 && shortcut.first?.item.title == "Copy Code Block", "codecopy: ⇧⌘C is Copy Code Block and nothing else in the menu bar",
              detail: "\(shortcut.map { "\($0.top) ▸ \($0.item.title)" })")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: offset("brew install") + 4, length: 0))
        await settle()
        let blockText = "brew install downwrite\ndownwrite --version"
        // The menu item itself, as a click on it would run it.
        if let menu = copyItem?.menu, let index = copyItem.map({ menu.index(of: $0) }), index >= 0 {
            pasteboard.clearContents()
            menu.performActionForItem(at: index)
            await settle(0.3)
            check(clipboard() == blockText, "codecopy: choosing Edit ▸ Copy Code Block copies the block the caret is in",
                  detail: "\(String(describing: clipboard())); enabled=\(copyItem?.isEnabled == true) key=\(NSApp.keyWindow?.title ?? "nil") firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
        }
        // Pressing ⇧⌘C is not driven here, on purpose. A synthesised shifted-letter key event is matched by the unshifted item with the same
        // letter, whichever way it is built or sent (the menu bar's performKeyEquivalent, NSApp.sendEvent, with or without a real keyboard's
        // device-level modifier bits): a synthetic ⇧⌘X cut the selection instead of reaching Format ▸ Strikethrough, and ⇧⌘C is swallowed by
        // the disabled Copy item. So the shortcut is checked by what AppKit dispatches on, the item's key and modifiers and that no other
        // item has them (above), and the item's action by choosing it (above); pressing the keys is on the by-hand list in the plan.
        check(!document.isDocumentEdited && tv.undoManager?.canUndo == false && tv.string == text, "codecopy: the command leaves the document alone too")
        tv.setSelectedRange(NSRange(location: offset("A paragraph after"), length: 0))
        await settle(0.2)
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
    }
}
