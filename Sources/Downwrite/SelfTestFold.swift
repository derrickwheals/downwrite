import AppKit
import DownwriteCore

/// The folding walkthrough of the end-to-end run (`SelfTest`, step 6j): the spec's verification steps against the real app —
/// real menu shortcuts, real mouse and key events, a real document saved to disk, Find, and screenshots of a folded document.
extension SelfTest {
    /// `--selftest-fold=<file>`: the shared Fixture F (`Tests/Fixtures/fold-demo.md`). Without it the step is skipped.
    static var foldFixture: URL? {
        CommandLine.arguments.first { $0.hasPrefix("--selftest-fold=") }.map { URL(fileURLWithPath: String($0.dropFirst("--selftest-fold=".count))) }
    }

    /// `--selftest-fold-only`: run only this step (for development; `--selftest-input` is still required but unused).
    static var foldOnly: Bool { CommandLine.arguments.contains("--selftest-fold-only") }

    /// With `reusing`, the walkthrough runs in that (the run's first) editor window: Fixture F is written to its file and reloaded the way an
    /// external change is (`revert`), so it is still a real, unedited document on disk. That window is the one SwiftUI resolves focused-value
    /// menu items (⌘/, View ▸ Show Markdown Source) against; a second document window opened later never takes that focus in a scripted run.
    /// Without it (`--selftest-fold-only`) the fixture opens in a window of its own.
    static func foldWalkthrough(outDir: URL, fixture: URL, reusing existing: EditorTextView? = nil) async {
        func fail(_ what: String, _ detail: String = "") { check(false, "fold: " + what, detail: detail) }
        var work = outDir.appendingPathComponent("fold-demo.md")
        if let url = existing?.window?.representedURL { work = url }
        try? FileManager.default.removeItem(at: work)
        guard (try? FileManager.default.copyItem(at: fixture, to: work)) != nil,
              let text = try? String(contentsOf: work, encoding: .utf8), let bytes = try? Data(contentsOf: work) else { return fail("the fixture can be copied") }
        let tv: EditorTextView
        if let existing, let document = NSDocumentController.shared.document(for: work) {
            do { try document.revert(toContentsOf: work, ofType: document.fileType ?? "") } catch { return fail("the window reloads the fixture", "\(error)") }
            guard await waitUntil(timeout: 10, { existing.string == text }) else { return fail("the window shows the fixture", "\(existing.string.count) vs \(text.count) characters") }
            tv = existing
        } else {
            do { _ = try await NSDocumentController.shared.openDocument(withContentsOf: work, display: true) } catch { return fail("the fixture opens", "\(error)") }
            guard let opened = await waitForEditor(file: work.lastPathComponent) else { return fail("the fixture's editor appears") }
            tv = opened
        }
        guard let coordinator = tv.coordinator, let window = tv.window, let document = NSDocumentController.shared.document(for: work) else { return fail("the fixture's editor appears") }
        // Alone: any other document window (restored from an earlier session, say) would compete for focus.
        for other in NSApp.windows where other !== window && other.representedURL != nil {
            (other.windowController?.document as? NSDocument)?.updateChangeCount(.changeCleared)       // (no "save changes?" sheet)
            other.close()
        }
        _ = await waitUntil(timeout: 5) { !NSApp.windows.contains { $0 !== window && $0.representedURL != nil && $0.isVisible } }
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.activate(ignoringOtherApps: true)
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        try? await Task.sleep(nanoseconds: 500_000_000)

        // MARK: helpers
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        func keyEvent(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        /// A key equivalent through the real menu bar.
        func shortcut(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) { _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent(chars, code, flags)) }
        /// A key typed into the window's first responder.
        func type(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) { window.sendEvent(keyEvent(chars, code, flags)) }
        let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
        let opt: NSEvent.ModifierFlags = [.command, .option], optShift: NSEvent.ModifierFlags = [.command, .option, .shift]
        func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func headers() -> [String] {
            let a = coordinator.analysis, ns = tv.string as NSString
            return a.foldRegions.filter(coordinator.foldState.isFolded).map { ns.substring(with: a.lines[$0.headerLines.lowerBound].contentRange) }
        }
        func offset(_ needle: String) -> Int { (tv.string as NSString).range(of: needle).location }
        func lineEnd(_ needle: String) -> Int { coordinator.analysis.lines[coordinator.analysis.lineIndex(at: offset(needle))].contentEnd }
        func isHidden(_ needle: String) -> Bool { coordinator.foldState.foldHiding(offset: offset(needle), in: coordinator.analysis) != nil }
        func viewMenu() -> NSMenu? { NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu }
        func item(_ title: String) -> NSMenuItem? { viewMenu()?.items.first { $0.title == title } }
        func click(_ point: NSPoint) {
            let p = tv.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(e)
                }
            }
        }
        func viewPoint(of rect: NSRect) -> NSPoint { NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y) }
        let layout = tv.layoutManager as! DWLayoutManager

        // MARK: menu (R10)
        check(true, "fold: the fixture opens in its own window")
        // The mouse, key and menu checks need this window to be the key window of the frontmost app; the menu checks also need SwiftUI to
        // have resolved the window's focused scene (the View menu's items are disabled until it has). Say so once, with a control, instead of
        // letting a dozen steps fail for one reason: the existing "Show Markdown Source" item is built the same way as the fold items, so if
        // it is disabled too the environment is at fault, and if only the fold items are, they are.
        let keyed = await waitUntil(timeout: 8) { window.isKeyWindow && NSApp.isActive }
        check(keyed, "fold: the editor window is key and the app is frontmost (the mouse, key and menu checks need that)",
              detail: "active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "nil") windows=\(NSApp.windows.map { $0.title })")
        var menusLive = false
        if keyed {
            menusLive = await waitUntil(timeout: 8) { NSApp.mainMenu?.update(); return item("Fold")?.isEnabled == true }
            check(menusLive, "fold: the fold commands are enabled while an editor is frontmost",
                  detail: "control: Show Markdown Source enabled=\(String(describing: item("Show Markdown Source")?.isEnabled)) (if that is false too, SwiftUI has not resolved the focused window)")
        }
        let wanted: [(String, String, NSEvent.ModifierFlags)] = [("Fold", left, [.command, .option]), ("Unfold", right, [.command, .option]),
                                                                 ("Fold All", left, [.command, .option, .shift]), ("Unfold All", right, [.command, .option, .shift])]
        for (title, key, flags) in wanted {
            let found = item(title)
            check(found != nil && found?.keyEquivalent == key && found?.keyEquivalentModifierMask.intersection([.command, .option, .shift]) == flags,
                  "fold: View ▸ \(title) has its shortcut", detail: "\(String(describing: found?.keyEquivalent.unicodeScalars.first?.value)) \(String(describing: found?.keyEquivalentModifierMask))")
        }
        let levels = item("Fold to Level")?.submenu?.items.map(\.title) ?? []
        check(levels == (1...6).map { "Heading \($0)" }, "fold: View ▸ Fold to Level lists Heading 1…6", detail: "\(levels)")

        // MARK: starting state (verification 1, R4, R20)
        check(coordinator.foldState.isEmpty && headers().isEmpty, "fold: every file opens fully unfolded")
        check(!document.isDocumentEdited, "fold: no edited mark to begin with")
        check(tv.undoManager?.canUndo == false, "fold: nothing to undo to begin with")

        if menusLive {
            // MARK: fold at the caret, outwards (verification 5, R11)
            tv.setSelectedRange(NSRange(location: offset("Review") + 3, length: 0))
            shortcut(left, 123, opt.union(arrowFlags))
            check(headers() == ["- [ ] Write spec"], "fold: ⌥⌘← folds the item holding the caret", detail: "\(headers())")
            check(tv.selectedRange() == NSRange(location: lineEnd("Write spec"), length: 0), "fold: and the caret goes to the end of its header")
            for _ in 0..<3 { shortcut(left, 123, opt.union(arrowFlags)) }
            check(headers() == ["# Project", "## Plan", "### Tasks", "- [ ] Write spec"], "fold: three more presses fold outwards: Tasks, Plan, Project", detail: "\(headers())")
            check(coordinator.foldState.hiddenLineRanges(in: coordinator.analysis) == [1...35], "fold: only `# Project` is left on screen")
            shortcut(right, 124, opt.union(arrowFlags))
            check(headers() == ["## Plan", "### Tasks", "- [ ] Write spec"], "fold: ⌥⌘→ opens Project and Plan stays folded inside it", detail: "\(headers())")

            // MARK: fold all, unfold all, fold to level (verification 6, R12)
            shortcut(left, 123, optShift.union(arrowFlags))
            check(headers().count == 8, "fold: ⌥⌘⇧← folds every heading and item", detail: "\(headers().count)")
            shortcut(right, 124, optShift.union(arrowFlags))
            check(headers().isEmpty, "fold: ⌥⌘⇧→ opens everything")
            if let menu = item("Fold to Level")?.submenu, let two = menu.items.first(where: { $0.title == "Heading 2" }) { menu.performActionForItem(at: menu.index(of: two)) }
            check(headers() == ["## Plan", "### Tasks", "## Notes", "## Last"], "fold: Fold to Level ▸ Heading 2 leaves Project and the list items alone", detail: "\(headers())")
            shortcut(right, 124, optShift.union(arrowFlags))
        }

        if keyed {
            // MARK: the mouse (verification 2 and 3, R8, R9)
            await settle()
            tv.scrollToBeginningOfDocument(nil)
            if let chevron = layout.foldChevronRect(forCharacterAt: offset("Plan")) {
                check(chevron.width >= 16 && chevron.height >= 16, "fold: the chevron's click target is at least 16 pt square", detail: "\(chevron)")
                click(viewPoint(of: chevron))
                check(headers() == ["## Plan"], "fold: clicking the chevron folds the section", detail: "\(headers())")
                check(isHidden("Plan text.") && !isHidden("## Notes"), "fold: the section's lines are gone and Notes follows it")
                await settle()
                if let chip = layout.foldChipRect(forCharacterAt: lineEnd("Plan") - 1) {
                    click(viewPoint(of: chip))
                    check(headers().isEmpty, "fold: clicking the ⋯ chip unfolds it")
                } else {
                    fail("a folded header has a ⋯ chip")
                }
            } else {
                fail("a foldable header has a chevron")
            }
        }

        // MARK: nothing is written, nothing to undo (verification 3, 15, R4)
        _ = layout
        coordinator.setFoldState(FoldState())
        check(!document.isDocumentEdited, "fold: the title bar shows no edited mark after all that folding")
        check(tv.undoManager?.canUndo == false, "fold: Edit ▸ Undo was never available")
        check(tv.string == text, "fold: the text is exactly the file's")
        document.save(nil)
        await settle(0.5)
        check((try? Data(contentsOf: work)) == bytes, "fold: saving after folding leaves the file byte-identical")

        // MARK: screenshots of a folded document (R9: legible in light and dark)
        coordinator.setFoldState(FoldState().foldingAll(in: coordinator.analysis).unfoldingAll())
        let a = coordinator.analysis
        let some = [a.foldRegions[1], a.foldRegions[4], a.foldRegions[5]]                // Plan, Notes, Groceries
        coordinator.setFoldState(some.reduce(FoldState()) { $0.toggled($1) })
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.scrollToBeginningOfDocument(nil)
        for theme in [ThemeChoice.light, .dark] {
            UserDefaults.standard.set(theme.rawValue, forKey: Prefs.theme)
            ThemeChoice.applyCurrent()
            await settle(0.8)
            check(capture(window: window, to: outDir.appendingPathComponent("window-\(theme.rawValue)-folded.png")), "fold: a \(theme.rawValue) screenshot of the folded document is not blank")
        }
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        coordinator.setFoldState(FoldState())

        if menusLive {
            // MARK: the source view (verification 13, R21)
            coordinator.setFoldState(FoldState().toggled(a.foldRegions[1]))
            // The theme was just flipped back, and SwiftUI re-resolves the focused window after that: wait until the menu is live again
            // instead of pressing at once (the standard ⌘/ step sleeps for the same reason).
            func markdownSourceItem() -> NSMenuItem? { viewMenu()?.items.first { $0.title.hasSuffix("Markdown Source") } }
            func menuReady() async -> Bool { await waitUntil(timeout: 8) { NSApp.mainMenu?.update(); return markdownSourceItem()?.isEnabled == true } }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(tv)
            func editorStates() -> String { editors().map { "\($0.window?.title ?? "?")=\($0.coordinator?.sourceMode == true ? "source" : "formatted")" }.joined(separator: ", ") }
            /// Switches this window's source view with ⌘/ and, if that does nothing, with the same menu item chosen directly. (The ⌘/ key
            /// route is covered by the standard source-view step; what matters here is that the command acts on *this* window.) Returns how.
            func toggleSource(wanting on: Bool) async -> String? {
                _ = await menuReady()
                shortcut("/", 44, .command)
                if await waitUntil(timeout: 4, { coordinator.sourceMode == on }) { return "⌘/" }
                if let menu = viewMenu(), let it = markdownSourceItem() {
                    menu.performActionForItem(at: menu.index(of: it))
                    if await waitUntil(timeout: 4, { coordinator.sourceMode == on }) { return "the menu item (⌘/ itself did nothing in this window)" }
                }
                return nil
            }
            let how = await toggleSource(wanting: true)
            var source = how != nil
            check(source, "fold: View ▸ Show Markdown Source switches this window to the source view",
                  detail: how ?? "neither ⌘/ nor the menu item did: \(editorStates()); key=\(NSApp.keyWindow?.title ?? "nil") item=\(markdownSourceItem()?.title ?? "nil") enabled=\(String(describing: markdownSourceItem()?.isEnabled))")
            if !source { coordinator.setSourceMode(true); source = true }          // carry on checking the rest either way
            // R10 says the fold commands are disabled in the source view. The menu items' enabled flag is SwiftUI's and is only refreshed when the menu
            // opens or a key equivalent is matched (the title above still reads "Show" after the switch for the same reason), so a scripted run
            // cannot assert it. What it can assert is the guarantee behind it: the commands do nothing there. The flags are reported for information.
            let flags = ["Fold", "Unfold", "Fold All", "Unfold All", "Fold to Level"].map { "\($0)=\(item($0)?.isEnabled == true ? "on" : "off")" }.joined(separator: " ")
            var beeps = 0
            coordinator.beep = { beeps += 1 }
            let before = coordinator.foldState
            Responder.fold(); Responder.unfold(); Responder.foldAll(); Responder.unfoldAll(); Responder.fold(toLevel: 1)
            check(coordinator.foldState == before && beeps == 5, "fold: the fold commands do nothing in the source view (they beep)",
                  detail: "beeps=\(beeps) state unchanged=\(coordinator.foldState == before) | menu flags (SwiftUI refreshes them lazily): \(flags)")
            coordinator.beep = { NSSound.beep() }
            check(tv.textStorage.map { ($0.attribute(.font, at: offset("Plan text."), effectiveRange: nil) as? NSFont)?.pointSize ?? 0 > 10 } == true,
                  "fold: the source view shows the folded lines")
            var back = await toggleSource(wanting: false) != nil
            if !back { check(false, "fold: View ▸ Hide Markdown Source brings the formatted editor back", detail: editorStates()); coordinator.setSourceMode(false); back = true }
            check(back && headers() == ["## Plan"], "fold: leaving the source view brings the fold back", detail: "\(headers())")
            coordinator.setFoldState(FoldState())
        }

        // MARK: Find (verification 8, R15)
        coordinator.setFoldState([a.foldRegions[4], a.foldRegions[5], a.foldRegions[1]].reduce(FoldState()) { $0.toggled($1) })   // Notes, Groceries, Plan
        let board = NSPasteboard(name: .find)
        let savedFind = board.string(forType: .string)
        board.clearContents(); board.setString("Milk", forType: .string)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)     // (the finder re-reads its string then)
        await settle()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(tv)
        let next = NSMenuItem(); next.tag = NSTextFinder.Action.nextMatch.rawValue
        tv.performTextFinderAction(next)
        let found = await waitUntil(timeout: 4) { (tv.string as NSString).substring(with: tv.selectedRange()) == "Milk" }
        if let savedFind { board.clearContents(); board.setString(savedFind, forType: .string) }
        check(found, "fold: Find selects the match inside the folded text")
        check(!isHidden("Milk") && headers() == ["## Plan"], "fold: and opens the folds that hid it, leaving the others", detail: "\(headers())")
        let matchRect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: tv.selectedRange(), actualCharacterRange: nil), in: tv.textContainer!)
        check(tv.visibleRect.intersects(matchRect.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)), "fold: the match is scrolled into view")
        coordinator.setFoldState(FoldState())

        if keyed {
            // MARK: Return and Delete at a fold's edge (verification 10, 11, R16)
            window.makeFirstResponder(tv)
            coordinator.setFoldState(FoldState().toggled(a.foldRegions[1]))
            tv.setSelectedRange(NSRange(location: lineEnd("## Plan"), length: 0))
            type("\r", 36)
            check(headers().isEmpty && tv.string != text, "fold: Return at the end of a folded header opens it and adds a line")
            tv.undoManager?.undo()
            check(tv.string == text, "fold: undo takes the Return back")
            coordinator.setFoldState(FoldState().toggled(coordinator.analysis.foldRegions[1]))
            tv.setSelectedRange(NSRange(location: offset("## Notes"), length: 0))
            type("\u{7F}", 51)
            check(tv.string == text && headers().isEmpty, "fold: Delete at the start of the line below a fold opens it and deletes nothing", detail: "\(headers())")
            document.updateChangeCount(.changeCleared)
        }

        // MARK: staying attached to a changed file, and a new window (verification 14, R18, R20)
        coordinator.setFoldState(FoldState().toggled(coordinator.analysis.foldRegions[1]))
        try? "\ntail\n".data(using: .utf8).flatMap { data in
            let h = try FileHandle(forWritingTo: work)
            defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: data)
        }
        let reloaded = await waitUntil(timeout: 8) { tv.string.contains("tail") }
        check(reloaded, "fold: an external change to the file is picked up")
        check(headers() == ["## Plan"], "fold: and the fold is still in place", detail: "\(headers())")
        window.close()
        _ = await waitUntil(timeout: 5) { !window.isVisible }
        _ = try? await NSDocumentController.shared.openDocument(withContentsOf: work, display: true)
        var reopened: EditorTextView?
        _ = await waitUntil(timeout: 10) {
            reopened = editors().first { $0.window?.representedURL?.lastPathComponent == work.lastPathComponent && $0.coordinator !== coordinator }
            return reopened != nil
        }
        if let again = reopened, let c = again.coordinator {
            check(c.foldState.isEmpty, "fold: a reopened file is fully unfolded again (nothing was stored)")
            again.window?.close()
        } else {
            fail("the file reopens")
        }
    }
}
