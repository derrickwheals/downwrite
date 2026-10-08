import AppKit
import DownwriteCore

/// End-to-end test mode, used by CI and available to anyone:
///
///     Downwrite.app/Contents/MacOS/Downwrite --selftest-out=<outputDir> --selftest-input=<markdownFile>
///
/// Launches the real app, opens the file through the document system, drives it with real key events through the real
/// menu bar, saves to disk, flips the theme, captures screenshots of the actual window and writes `selftest-report.txt`.
/// Exits 0 when every check passes.
@MainActor
enum SelfTest {
    static var arguments: (outDir: URL, input: URL)? {
        // Single `--key=value` tokens: bare paths on the command line would make Cocoa open them as documents.
        func value(_ key: String) -> String? {
            CommandLine.arguments.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        guard let out = value("--selftest-out"), let input = value("--selftest-input") else { return nil }
        return (URL(fileURLWithPath: out, isDirectory: true), URL(fileURLWithPath: input))
    }

    /// Optional extra Markdown file (CI passes the project README) used for the "tables vs. sidebar" scenario.
    private static var extraFile: URL? {
        CommandLine.arguments.first { $0.hasPrefix("--selftest-extra=") }.map { URL(fileURLWithPath: String($0.dropFirst("--selftest-extra=".count))) }
    }

    private static var report: [String] = []
    private static var reportURL: URL?

    /// Written after every check, so a crash part-way through still leaves everything that happened before it.
    private static func flush() {
        guard let url = reportURL else { return }
        try? (report + ["(in progress)"]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, detail: String = "") {
        report.append((ok ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : " — " + detail))
        if !ok { failures += 1 }
        flush()
    }

    static func run() async {
        guard let (outDir, input) = arguments else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        reportURL = outDir.appendingPathComponent("selftest-report.txt")
        let work = outDir.appendingPathComponent("work.md")
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.copyItem(at: input, to: work)
        let original = (try? String(contentsOf: work, encoding: .utf8)) ?? ""

        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()

        // 1. Open through the real document machinery.
        do {
            _ = try await NSDocumentController.shared.openDocument(withContentsOf: work, display: true)
        } catch {
            check(false, "open document", detail: "\(error)")
            return finish(outDir)
        }
        let found = await waitForEditor(file: work.lastPathComponent)
        guard let tv = found else {
            check(false, "editor window appears")
            return finish(outDir)
        }
        check(true, "editor window appears")
        check(tv.string == original, "document text loaded into editor", detail: "\(tv.string.count) vs \(original.count) chars")
        let window = tv.window!
        window.setContentSize(NSSize(width: 1000, height: 780))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 500_000_000)

        dumpMenus(outDir)
        check(NSApp.mainMenu?.items.contains { $0.title == "Format" } == true, "Format menu is installed")
        let viewMenu = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        check(viewMenu?.items.contains { $0.title.hasSuffix("Table of Contents") } == true, "View menu has the Table of Contents toggle")

        // 2. Hidden syntax + reveal on a live document.
        let coordinator = tv.coordinator!
        let boldRange = (tv.string as NSString).range(of: "**disappears**")
        check(boldRange.location != NSNotFound, "sample contains **disappears**")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let storage = tv.textStorage!
        let hiddenFont = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        check((hiddenFont?.pointSize ?? 99) < 1, "markers hidden when caret is elsewhere")
        tv.setSelectedRange(NSRange(location: boldRange.location + 4, length: 0))
        let shownFont = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        check((shownFont?.pointSize ?? 0) > 8, "markers revealed when caret enters the pair")

        // 3. Real key events through the real menu bar: ⌘B, ⌘I, ⌘K, ⌘E, ⌘2 + undo.
        let probe = "SELFTESTWORD"
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertText("\n\n\(probe) tail\n", replacementRange: tv.selectedRange())
        let word = (tv.string as NSString).range(of: probe)
        func press(_ chars: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: keyCode)!
            _ = NSApp.mainMenu?.performKeyEquivalent(with: e)
        }
        press("f", keyCode: 3, .command)
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(tv.enclosingScrollView?.isFindBarVisible == true, "⌘F opens the find bar")
        let hide = NSMenuItem()
        hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
        tv.performTextFinderAction(hide)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(tv.enclosingScrollView?.isFindBarVisible == false, "find bar closes again")
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(word)
        press("b", keyCode: 11, .command)
        check(tv.string.contains("**\(probe)**"), "⌘B wraps selection in **")
        press("b", keyCode: 11, .command)
        check(tv.string.contains(" \(probe) tail") || tv.string.contains("\n\(probe) tail"), "⌘B again unwraps")
        tv.setSelectedRange((tv.string as NSString).range(of: probe))
        press("i", keyCode: 34, .command)
        check(tv.string.contains("*\(probe)*"), "⌘I wraps selection in *")
        press("i", keyCode: 34, .command)
        tv.setSelectedRange((tv.string as NSString).range(of: probe))
        press("e", keyCode: 14, .command)
        check(tv.string.contains("`\(probe)`"), "⌘E wraps selection in backticks")
        press("e", keyCode: 14, .command)
        tv.setSelectedRange((tv.string as NSString).range(of: probe))
        press("2", keyCode: 19, .command)
        check(tv.string.contains("## \(probe)"), "⌘2 makes a level-2 heading")
        press("2", keyCode: 19, .command)
        check(!tv.string.contains("## \(probe)"), "⌘2 again removes the heading")
        tv.setSelectedRange((tv.string as NSString).range(of: probe))
        press("k", keyCode: 40, .command)
        check(tv.string.contains("[\(probe)](url)"), "⌘K inserts a link")
        tv.undoManager?.undo()
        check(!tv.string.contains("](url)"), "undo reverts the link")

        // 4. Typing + saving writes the file to disk.
        let marker = "Typed by the self-test."
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertText(marker, replacementRange: tv.selectedRange())
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
        let saved = await waitUntil(timeout: 8) { ((try? String(contentsOf: work, encoding: .utf8)) ?? "").contains(marker) }
        check(saved, "typed text is saved to disk by the document system")

        // 5. Mermaid renders as a card and the source collapses.
        let diagram = await waitUntil(timeout: 30) { tv.subviews.contains { ($0 as? DiagramView)?.naturalSize != nil } }
        check(diagram, "mermaid diagram rendered into a card")
        if let card = tv.subviews.compactMap({ $0 as? DiagramView }).first,
           let block = coordinator.analysis.previewBlocks.first(where: { if case .mermaid = $0.kind { return true } else { return false } }) {
            check(card.frame.height > 80 && card.frame.width > 200, "diagram card has a sensible frame", detail: "\(card.frame)")
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            try? await Task.sleep(nanoseconds: 600_000_000)
            let lm = tv.layoutManager!
            func lineRect(_ l: Int) -> NSRect {
                let loc = coordinator.analysis.lines[l].range.location
                return lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: loc), effectiveRange: nil)
            }
            let staleLast = lineRect(block.lastLine)
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(coordinator.analysis.lines[block.lastLine].range)))
            let first = lineRect(block.firstLine), last = lineRect(block.lastLine)
            let gap = card.frame.minY - (last.maxY + tv.textContainerOrigin.y)
            let tableLast = coordinator.analysis.tables.first(where: \.isGrid).map { $0.lastLine }
            let spacing = tableLast.flatMap { l -> CGFloat? in
                (storage.attribute(.paragraphStyle, at: coordinator.analysis.lines[l].range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing
            }
            report.append("DIAG gap before/after ensureLayout: last.y \(staleLast.minY) → \(last.minY); table spacing \(spacing ?? -1) vs grid \(coordinator.tableOverlay.grids.first?.totalHeight ?? -1) frame \(String(describing: coordinator.tableOverlay.grids.first?.frame))")
            report.append("DIAG mermaid lines \(block.firstLine)…\(block.lastLine): first y=\(first.minY) h=\(first.height), last y=\(last.minY) h=\(last.height), card y=\(card.frame.minY) h=\(card.frame.height), reserved=\(coordinator.overlay.reservedHeights[block.firstLine] ?? 0)")
            check(first.height < 2 && last.height < 2, "collapsed Mermaid source takes no vertical space", detail: "heights \(first.height)/\(last.height)")
            check(gap >= 0 && gap < 12, "diagram card sits directly under its collapsed source", detail: "gap \(gap)")
        }

        // 5b. Tables are an editable grid: real key events, the right-click menu and undo.
        let tables = coordinator.tableOverlay!
        let gridShown = await waitUntil(timeout: 10) { !tables.grids.isEmpty && tables.grids[0].tableSize.width > 0 }
        check(gridShown, "table is shown as an editable grid")
        if gridShown {
            let grid = tables.grids[0]
            func sendKey(_ chars: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: keyCode)!
                NSApp.sendEvent(e)
            }
            tv.scrollToVisible(grid.frame.insetBy(dx: 0, dy: -120))
            try? await Task.sleep(nanoseconds: 300_000_000)
            let rows = grid.model.rowCount, cols = grid.model.columnCount
            check(rows >= 3 && cols == 2, "grid has the Welcome table's shape", detail: "\(rows)×\(cols)")
            check(grid.frame.height > 100 && grid.frame.width > 300, "grid has a sensible frame", detail: "\(grid.frame)")
            grid.focus(TableCellPosition(row: 1, column: 0), atEnd: true)
            check(window.firstResponder is TableCellView, "clicking into a cell gives it the keyboard")
            sendKey("\t", keyCode: 48)
            check(grid.focusedPosition == TableCellPosition(row: 1, column: 1), "Tab jumps to the next cell", detail: "\(String(describing: grid.focusedPosition))")
            sendKey("\u{19}", keyCode: 48, [.shift])
            check(grid.focusedPosition == TableCellPosition(row: 1, column: 0), "⇧Tab jumps back", detail: "\(String(describing: grid.focusedPosition))")
            grid.focus(TableCellPosition(row: rows - 1, column: cols - 1), atEnd: true)
            sendKey("\t", keyCode: 48)
            check(grid.model.rowCount == rows + 1, "Tab in the last cell adds a row", detail: "\(grid.model.rowCount) rows")
            check(grid.focusedPosition == TableCellPosition(row: rows, column: 0), "focus lands in the new row", detail: "\(String(describing: grid.focusedPosition))")
            sendKey("Q", keyCode: 12, [.shift])
            sendKey("z", keyCode: 6)
            check(tv.string.contains("| Qz"), "typing in the new cell writes Markdown into the document")
            check(grid.model.cell(rows, 0) == "Qz", "model follows what was typed", detail: grid.model.cell(rows, 0))
            let menu = grid.makeMenu(at: TableCellPosition(row: 1, column: 0), includeEditing: true)
            let titles = menu.items.map(\.title).filter { !$0.isEmpty }
            report.append("DIAG table menu: " + titles.joined(separator: " | "))
            check(titles.contains("Insert Row Below") && titles.contains("Delete Column") && titles.contains("Column Alignment"), "right-click menu has the table actions")
            if let item = menu.items.first(where: { $0.title == "Insert Column Right" }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
                check(grid.model.columnCount == cols + 1, "menu: Insert Column Right adds a column", detail: "\(grid.model.columnCount) columns")
            } else {
                check(false, "menu has Insert Column Right")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            for _ in 0..<3 { window.undoManager?.undo(); try? await Task.sleep(nanoseconds: 60_000_000) }
            check(grid.model.rowCount == rows && grid.model.columnCount == cols, "undo walks the table back", detail: "\(grid.model.rowCount)×\(grid.model.columnCount)")
            window.makeFirstResponder(tv)
        }

        // 5c. Table of contents sidebar: toggled from the menu bar, lists the headings, a click scrolls the editor.
        if let scroll = tv.enclosingScrollView, let toc = coordinator.toc {
            let defaults = UserDefaults.standard
            let wide = tv.frame.width
            check(!defaults.bool(forKey: Prefs.showTOC), "table of contents sidebar starts hidden")
            press("o", keyCode: 31, [.command, .control])
            // The sidebar floats over the window (macOS 26): the scroll view keeps its frame and insets its content.
            let shown = await waitUntil(timeout: 10) { tv.frame.width < wide - 150 }
            check(defaults.bool(forKey: Prefs.showTOC), "⌃⌘O turns the sidebar on")
            check(shown, "the editor column narrows to make room for the sidebar", detail: "\(wide) → \(tv.frame.width)")
            let expected = coordinator.analysis.headings.map(\.plainTitle)
            let listed = await waitUntil(timeout: 10) { toc.rows.map(\.title) == expected }
            check(listed && expected.count >= 5, "sidebar lists every heading", detail: toc.rows.map(\.title).joined(separator: " | "))
            check(toc.rows.contains { $0.depth >= 2 }, "headings are nested by level", detail: toc.rows.map { String($0.depth) }.joined())
            if let target = toc.rows.last(where: { $0.depth == 1 }) {
                tv.scrollToBeginningOfDocument(nil)
                try? await Task.sleep(nanoseconds: 400_000_000)
                let before = scroll.contentView.bounds.origin.y
                toc.select(target.id)
                let heading = coordinator.analysis.headings[target.id]
                let lm = tv.layoutManager!
                func headingTop() -> CGFloat {
                    lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: heading.range.location), effectiveRange: nil).minY + tv.textContainerOrigin.y
                }
                let arrived = await waitUntil(timeout: 8) { scroll.contentView.bounds.origin.y > before + 100 }
                try? await Task.sleep(nanoseconds: 700_000_000)
                let visible = tv.visibleRect
                check(arrived, "clicking '\(target.title)' scrolls the editor", detail: "\(before) → \(scroll.contentView.bounds.origin.y)")
                check(headingTop() >= visible.minY && headingTop() <= visible.maxY, "the clicked heading is in view", detail: "y \(headingTop()) in \(visible)")
                check(tv.selectedRange() == NSRange(location: NSMaxRange(heading.range), length: 0), "the caret moves to the heading")
                check(window.firstResponder === tv, "the editor keeps the keyboard after a click in the sidebar")
                let active = await waitUntil(timeout: 5) { toc.activeID == target.id }
                check(active, "the clicked heading is highlighted in the sidebar")
            } else {
                check(false, "sample has a level-2 heading to click")
            }
            press("o", keyCode: 31, [.command, .control])
            let hidden = await waitUntil(timeout: 10) { abs(tv.frame.width - wide) < 2 }
            check(!defaults.bool(forKey: Prefs.showTOC) && hidden, "⌃⌘O turns the sidebar off again", detail: "\(tv.frame.width)")
            tv.scrollToBeginningOfDocument(nil)
        } else {
            check(false, "editor feeds a table-of-contents model")
        }

        // 6. Themes: light/dark follow the preference and palettes change.
        var shots: [String] = []
        for theme in [ThemeChoice.light, .dark] {
            UserDefaults.standard.set(theme.rawValue, forKey: Prefs.theme)
            ThemeChoice.applyCurrent()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            check(isDark == (theme == .dark), "theme \(theme.rawValue) applies to the app")
            check(coordinator.styler.palette == Palette.palette(for: theme == .dark ? .dark : .light), "editor palette follows \(theme.rawValue)")
            tv.setSelectedRange(NSRange(location: caretOffset(in: tv, after: "comes back", plus: 3), length: 0))
            try? await Task.sleep(nanoseconds: 800_000_000)
            tv.scrollToBeginningOfDocument(nil)
            try? await Task.sleep(nanoseconds: 600_000_000)
            let file = outDir.appendingPathComponent("window-\(theme.rawValue).png")
            let ok = capture(window: window, to: file)
            shots.append(file.lastPathComponent)
            check(ok, "screenshot of real window (\(theme.rawValue))", detail: ok ? "" : "screencapture unavailable; see in-process snapshots")
            if let card = tv.subviews.compactMap({ $0 as? DiagramView }).first {
                tv.scrollToVisible(card.frame.insetBy(dx: 0, dy: -150))
                try? await Task.sleep(nanoseconds: 900_000_000)
                _ = capture(window: window, to: outDir.appendingPathComponent("window-\(theme.rawValue)-diagram.png"))
            }
            if let grid = coordinator.tableOverlay.grids.first {
                tv.scrollToVisible(grid.frame.insetBy(dx: 0, dy: -160))
                grid.focus(TableCellPosition(row: 2, column: 1), atEnd: true)
                grid.simulateHover(row: 2, column: 1)
                try? await Task.sleep(nanoseconds: 700_000_000)
                _ = capture(window: window, to: outDir.appendingPathComponent("window-\(theme.rawValue)-table.png"))
                grid.simulateHover(row: nil, column: nil)
                window.makeFirstResponder(tv)
            }
            // The sidebar next to the editor, with the section holding the caret highlighted.
            UserDefaults.standard.set(true, forKey: Prefs.showTOC)
            tv.setSelectedRange(NSRange(location: caretOffset(in: tv, after: "Lists that keep up", plus: 3), length: 0))
            tv.scrollToBeginningOfDocument(nil)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let tocShot = capture(window: window, to: outDir.appendingPathComponent("window-\(theme.rawValue)-toc.png"))
            check(tocShot, "screenshot with the table of contents open (\(theme.rawValue))", detail: tocShot ? "" : "screencapture unavailable")
            UserDefaults.standard.set(false, forKey: Prefs.showTOC)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // 6b. Editing helpers: the third backtick at the start of a line closes the fence; undo takes it back in one step.
        do {
            let before = tv.string
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
            tv.insertText("\n\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            for _ in 0..<3 { tv.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            check(tv.string.hasSuffix("```\n\n```"), "typing the third backtick adds the closing fence", detail: String(tv.string.suffix(24)))
            let opening = NSRange(location: tv.string.utf16.count - 8, length: 0)
            check(tv.selectedRange().location == opening.location + 3, "caret waits after the opening fence", detail: "\(tv.selectedRange())")
            tv.undoManager?.undo()
            check(!tv.string.hasSuffix("```\n\n```"), "undo removes the auto-closed fence", detail: String(tv.string.suffix(24)))
            // Put the document back exactly as it was for the screenshots below.
            while tv.string != before, tv.undoManager?.canUndo == true, tv.string.utf16.count > before.utf16.count { tv.undoManager?.undo() }
        }

        // 6c. Selection stays visible on top of code cards and inline code pills.
        for theme in [ThemeChoice.light, .dark] {
            UserDefaults.standard.set(theme.rawValue, forKey: Prefs.theme)
            ThemeChoice.applyCurrent()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let code = (tv.string as NSString).range(of: "Hello")
            let inline = (tv.string as NSString).range(of: "inline code")
            check(code.location != NSNotFound && inline.location != NSNotFound, "sample has a code block and inline code to select")
            guard code.location != NSNotFound, inline.location != NSNotFound else { continue }
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: code.location, length: code.length + 12))
            tv.scrollRangeToVisible(code)
            try? await Task.sleep(nanoseconds: 700_000_000)
            _ = capture(window: window, to: outDir.appendingPathComponent("window-\(theme.rawValue)-code-selection.png"))
            tv.setSelectedRange(inline)
            tv.scrollRangeToVisible(inline)
            try? await Task.sleep(nanoseconds: 700_000_000)
            _ = capture(window: window, to: outDir.appendingPathComponent("window-\(theme.rawValue)-inline-selection.png"))
        }
        tv.setSelectedRange(NSRange(location: 0, length: 0))

        // 7. Back to system theme leaves the app following macOS.
        UserDefaults.standard.set(ThemeChoice.system.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        check(NSApp.appearance == nil, "system theme clears the appearance override")

        // 8. Regression (runs last because it replaces the document): with a wide table (the README's keyboard shortcuts) the grid must stay lined up with the text
        // and keep the right reserved height while the sidebar opens and closes, however fast.
        if let extra = extraFile, let readme = try? String(contentsOf: extra, encoding: .utf8), let tables = coordinator.tableOverlay {
            let whole = NSRange(location: 0, length: tv.string.utf16.count)
            tv.setSelectedRange(whole)
            tv.insertText(readme, replacementRange: whole)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: Prefs.showTOC)
            let ready = await waitUntil(timeout: 20) { !tables.grids.isEmpty && tables.grids.allSatisfy { $0.tableSize.width > 0 } }
            check(ready, "README tables become grids", detail: "\(tables.grids.count) grids")
            func settled() async -> [String] {
                var found: [String] = []
                _ = await waitUntil(timeout: 6) { found = tables.layoutProblems(); return found.isEmpty }
                return found
            }
            func geometry(_ label: String) {
                report.append("DIAG README \(label): text view \(Int(tv.frame.width)) pt, inset \(tv.textContainerInset.width), grid frames \(tables.grids.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" })")
            }
            let wide = tv.frame.width
            var problems = await settled()
            geometry("start")
            check(problems.isEmpty, "README tables are lined up with the text at the start", detail: problems.joined(separator: "; "))
            if let grid = tables.grids.first { tv.scrollToVisible(grid.frame.insetBy(dx: 0, dy: -60)) }

            press("o", keyCode: 31, [.command, .control])
            _ = await waitUntil(timeout: 10) { tv.frame.width < wide - 150 }
            problems = await settled()
            geometry("sidebar open")
            check(problems.isEmpty, "README tables stay lined up with the sidebar open", detail: problems.joined(separator: "; "))
            if let grid = tables.grids.first { tv.scrollToVisible(grid.frame.insetBy(dx: 0, dy: -60)) }
            try? await Task.sleep(nanoseconds: 700_000_000)
            _ = capture(window: window, to: outDir.appendingPathComponent("window-readme-toc-open.png"))

            press("o", keyCode: 31, [.command, .control])
            _ = await waitUntil(timeout: 10) { abs(tv.frame.width - wide) < 2 }
            problems = await settled()
            geometry("sidebar closed again")
            check(problems.isEmpty, "README tables are lined up again after the sidebar closes", detail: problems.joined(separator: "; "))
            if let grid = tables.grids.first { tv.scrollToVisible(grid.frame.insetBy(dx: 0, dy: -60)) }
            try? await Task.sleep(nanoseconds: 700_000_000)
            _ = capture(window: window, to: outDir.appendingPathComponent("window-readme-toc-closed.png"))

            for _ in 0..<4 {
                press("o", keyCode: 31, [.command, .control]); try? await Task.sleep(nanoseconds: 150_000_000)
                press("o", keyCode: 31, [.command, .control]); try? await Task.sleep(nanoseconds: 150_000_000)
            }
            _ = await waitUntil(timeout: 10) { abs(tv.frame.width - wide) < 2 }
            problems = await settled()
            geometry("after rapid toggling")
            check(problems.isEmpty, "README tables are lined up after rapid sidebar toggling", detail: problems.joined(separator: "; "))

            defaults.set(false, forKey: Prefs.showTOC)
        }

        finish(outDir)
    }

    // MARK: Helpers

    /// Offset `plus` characters into the first occurrence of `text`, or 0 when it is not in the document.
    private static func caretOffset(in tv: EditorTextView, after text: String, plus: Int) -> Int {
        let r = (tv.string as NSString).range(of: text)
        return r.location == NSNotFound ? 0 : min(r.location + plus, tv.string.utf16.count)
    }

    private static func editors() -> [EditorTextView] {
        func find(_ v: NSView) -> [EditorTextView] {
            (v as? EditorTextView).map { [$0] } ?? v.subviews.flatMap(find)
        }
        return NSApp.windows.compactMap(\.contentView).flatMap(find)
    }

    private static func waitForEditor(file name: String) async -> EditorTextView? {
        var found: EditorTextView?
        _ = await waitUntil(timeout: 25) {
            found = editors().first { $0.window?.representedURL?.lastPathComponent == name }
            return found != nil
        }
        return found
    }

    private static func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }

    private static func capture(window: NSWindow, to url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 20_000
    }

    private static func dumpMenus(_ dir: URL) {
        var lines: [String] = []
        for top in NSApp.mainMenu?.items ?? [] {
            lines.append("# \(top.title)")
            for item in top.submenu?.items ?? [] where !item.isSeparatorItem {
                let key = item.keyEquivalent.isEmpty ? "" : "  [\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)]"
                lines.append("  - \(item.title)\(key)")
                for sub in item.submenu?.items ?? [] where !sub.isSeparatorItem {
                    let k = sub.keyEquivalent.isEmpty ? "" : "  [\(sub.keyEquivalentModifierMask.rawValue):\(sub.keyEquivalent)]"
                    lines.append("      · \(sub.title)\(k)")
                }
            }
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
    }

    private static func finish(_ outDir: URL) {
        report.append("")
        report.append(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("selftest-report.txt"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
