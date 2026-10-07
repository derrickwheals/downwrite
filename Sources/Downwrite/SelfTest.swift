import AppKit
import DownwriteCore

/// End-to-end test mode, used by CI and available to anyone:
///
///     Downwrite.app/Contents/MacOS/Downwrite --selftest <outputDir> <markdownFile>
///
/// Launches the real app, opens the file through the document system, drives it with real key events through the real
/// menu bar, saves to disk, flips the theme, captures screenshots of the actual window and writes `selftest-report.txt`.
/// Exits 0 when every check passes.
@MainActor
enum SelfTest {
    static var arguments: (outDir: URL, input: URL)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: args[i + 1], isDirectory: true), URL(fileURLWithPath: args[i + 2]))
    }

    private static var report: [String] = []
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, detail: String = "") {
        report.append((ok ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : " — " + detail))
        if !ok { failures += 1 }
    }

    static func run() async {
        guard let (outDir, input) = arguments else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
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
        var found = await waitForEditor(containing: "Welcome")
        if found == nil { found = await waitForEditor(containing: "") }
        guard let tv = found else {
            check(false, "editor window appears")
            return finish(outDir)
        }
        check(true, "editor window appears")
        check(tv.string == original, "document text loaded into editor", detail: "\(tv.string.count) vs \(original.count) chars")
        let window = tv.window!
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 500_000_000)

        dumpMenus(outDir)
        check(NSApp.mainMenu?.items.contains { $0.title == "Format" } == true, "Format menu is installed")

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
        if let card = tv.subviews.compactMap({ $0 as? DiagramView }).first {
            check(card.frame.height > 80 && card.frame.width > 200, "diagram card has a sensible frame", detail: "\(card.frame)")
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
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "comes back").location + 3, length: 0))
            try? await Task.sleep(nanoseconds: 800_000_000)
            let file = outDir.appendingPathComponent("window-\(theme.rawValue).png")
            let ok = capture(window: window, to: file)
            shots.append(file.lastPathComponent)
            check(ok, "screenshot of real window (\(theme.rawValue))", detail: ok ? "" : "screencapture unavailable; see in-process snapshots")
        }

        // 7. Back to system theme leaves the app following macOS.
        UserDefaults.standard.set(ThemeChoice.system.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        check(NSApp.appearance == nil, "system theme clears the appearance override")

        finish(outDir)
    }

    // MARK: Helpers

    private static func editors() -> [EditorTextView] {
        func find(_ v: NSView) -> [EditorTextView] {
            (v as? EditorTextView).map { [$0] } ?? v.subviews.flatMap(find)
        }
        return NSApp.windows.compactMap(\.contentView).flatMap(find)
    }

    private static func waitForEditor(containing needle: String) async -> EditorTextView? {
        var found: EditorTextView?
        _ = await waitUntil(timeout: 20) {
            found = editors().first { $0.string.contains(needle) }
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
