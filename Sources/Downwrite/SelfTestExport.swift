import AppKit
import CryptoKit
import PDFKit
import DownwriteCore

/// The print and export walkthrough of the end-to-end run (`SelfTest`, step 7b): the spec's verification A.3 against the real app: the real File
/// menu, the real document and window, the real controller writing real files, and what each of those leaves untouched.
extension SelfTest {
    /// `--selftest-export=<file>`: the shared Fixture P (`Tests/Fixtures/export-demo.md`; its images sit beside it). Without it the step is skipped.
    static var exportFixture: URL? {
        CommandLine.arguments.first { $0.hasPrefix("--selftest-export=") }.map { URL(fileURLWithPath: String($0.dropFirst("--selftest-export=".count))) }
    }

    /// `--selftest-export-only`: run only this step (for development; `--selftest-input` is still required, and opened).
    static var exportOnly: Bool { CommandLine.arguments.contains("--selftest-export-only") }

    /// Runs in the run's first editor window (`existing`): Fixture P is written to its file and reloaded the way an external change is
    /// (`revert`), so it is a real, unedited document on disk. The window is the one SwiftUI resolves the File menu's focused-object items against.
    static func exportWalkthrough(outDir: URL, fixture: URL, reusing tv: EditorTextView) async {
        func ok(_ condition: Bool, _ what: String, _ detail: String = "") { check(condition, "export: " + what, detail: detail) }
        guard let window = tv.window, let work = window.representedURL, let document = NSDocumentController.shared.document(for: work),
              let controller = DocumentOutputController.controller(for: window) else {
            return ok(false, "the window has a document and an output controller")
        }

        // Fixture P and the images it refers to, next to the document.
        let folder = work.deletingLastPathComponent()
        let fixtures = fixture.deletingLastPathComponent()
        for name in ["local.png", "local.svg"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            try? FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        try? Data(count: 8_000_001).write(to: folder.appendingPathComponent("big.png"))
        guard let text = try? String(contentsOf: fixture, encoding: .utf8), (try? text.write(to: work, atomically: true, encoding: .utf8)) != nil else {
            return ok(false, "Fixture P can be written next to the document")
        }
        do { try document.revert(toContentsOf: work, ofType: document.fileType ?? "") } catch { return ok(false, "the window reloads Fixture P", "\(error)") }
        guard await waitUntil(timeout: 10, { tv.string == text }) else { return ok(false, "the window shows Fixture P", "\(tv.string.count) vs \(text.count) characters") }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // R1: the three items, together, in this order, after Share, with ⌘P on Print…
        let names = ["Print…", "Export as PDF…", "Export as HTML…"]
        func fileMenu() -> NSMenu? { NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu }
        // SwiftUI refreshes a menu's items when AppKit is about to show it (`menuNeedsUpdate`: the menu opens, or a key equivalent is looked
        // up), not the moment its state changes, so reading `isEnabled` without that call returns whatever the last refresh left.
        func items() -> [NSMenuItem] {
            if let menu = fileMenu() { menu.delegate?.menuNeedsUpdate?(menu) }
            NSApp.mainMenu?.update()
            return names.compactMap { n in fileMenu()?.items.first { $0.title == n } }
        }
        let titles = fileMenu()?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        if let first = titles.firstIndex(of: "Print…") {
            ok(Array(titles[first...].prefix(3)) == names, "File menu lists Print…, Export as PDF… and Export as HTML… together, in that order", "\(titles)")
            ok(titles.firstIndex(of: "Share").map { $0 < first } == true, "they follow Share, which is unchanged", "\(titles)")
        } else {
            ok(false, "File menu has Print…", "\(titles)")
        }
        let print = items().first { $0.title == "Print…" }
        ok(print?.keyEquivalent == "p" && print?.keyEquivalentModifierMask.contains(.command) == true, "Print… is ⌘P", "\(String(describing: print?.keyEquivalent))")
        ok(items().filter { $0.title != "Print…" }.allSatisfy { $0.keyEquivalent.isEmpty }, "the two exports have no shortcut")
        ok(["New", "Open…", "Close", "Save", "Share"].allSatisfy { titles.contains($0) }, "the existing File items are still there")

        // R2: enabled with a document window; disabled while preparing; disabled with only Settings frontmost.
        let ready = await waitUntil(timeout: 10) { items().count == 3 && items().allSatisfy(\.isEnabled) }
        ok(ready, "the three items are enabled with a document window frontmost", "\(items().map { "\($0.title)=\($0.isEnabled)" })")

        let originalSnapshot = controller.snapshot
        let originalDiagrams = controller.renderDiagram
        let originalChoose = controller.chooseDestination
        let originalError = controller.presentError
        let originalSheet = controller.presentOmissions
        defer {
            controller.snapshot = originalSnapshot
            controller.renderDiagram = originalDiagrams
            controller.chooseDestination = originalChoose
            controller.presentError = originalError
            controller.presentOmissions = originalSheet
        }

        controller.snapshot = { .init(text: "```mermaid\ngraph TD\n  A-->B\n```\n", fileURL: work, displayName: "work.md") }
        controller.renderDiagram = { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .failure(.failed("slow on purpose"))
        }
        controller.chooseDestination = { _, _, _ in nil }
        controller.presentOmissions = { _ in }
        controller.exportHTML()
        let disabledWhilePreparing = await waitUntil(timeout: 3) { controller.isPreparing && items().allSatisfy { !$0.isEnabled } }
        ok(disabledWhilePreparing, "the items are disabled while a preparation is under way", "\(items().map { "\($0.title)=\($0.isEnabled)" })")
        _ = await waitUntil(timeout: 20) { !controller.isPreparing }
        let enabledAgain = await waitUntil(timeout: 5) { items().allSatisfy(\.isEnabled) }
        ok(enabledAgain, "and enabled again afterwards")
        controller.snapshot = originalSnapshot
        controller.renderDiagram = originalDiagrams

        // ⌘, through the real menu bar, as step 6g does.
        let comma = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
        _ = NSApp.mainMenu?.performKeyEquivalent(with: comma)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let tabTitles = SettingsTab.allCases.map(\.title)
        let settings = NSApp.windows.first { $0 !== window && $0.representedURL == nil && (tabTitles.contains($0.title) || $0.title.localizedCaseInsensitiveContains("settings")) }
        if let settings {
            settings.makeKeyAndOrderFront(nil)
            let disabledInSettings = await waitUntil(timeout: 5) { items().allSatisfy { !$0.isEnabled } }
            ok(disabledInSettings, "the items are disabled with only Settings frontmost", "\(items().map { "\($0.title)=\($0.isEnabled)" })")
            settings.close()
        } else {
            ok(false, "the Settings window opens", "windows: \(NSApp.windows.map(\.title))")
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        _ = await waitUntil(timeout: 5) { items().allSatisfy(\.isEnabled) }

        // R5: what must not change, recorded now and compared after everything below.
        func fileHash() -> String { ((try? Data(contentsOf: work)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }) ?? "" }
        let before = (hash: fileHash(), text: tv.string, selection: tv.selectedRange(), canUndo: tv.undoManager?.canUndo ?? false,
                      edited: document.isDocumentEdited, folds: tv.coordinator?.foldState, source: tv.coordinator?.sourceMode ?? false)
        ok(!before.edited, "the document starts unedited")

        // R23, R14, R16: the HTML file, through the entry point the panel uses.
        let htmlURL = outDir.appendingPathComponent("export-demo.html")
        try? FileManager.default.removeItem(at: htmlURL)
        do {
            let omissions = try await controller.writeHTML(to: htmlURL)
            let html = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? ""
            ok(html.hasPrefix("<!doctype html>"), "the HTML file is a page")
            ok(!html.contains("<script") && !html.contains("onerror") && !html.contains("javascript:") && !html.contains("Secret front matter"), "it holds nothing active and no front matter")
            ok(Set(omissions.map(\.source)) == ["missing.png", "big.png", "http://example.com/a.png"], "exactly three images were left out", "\(omissions.map(\.source))")
            ok(html.contains("data:image/png;base64,"), "local images are embedded")
        } catch {
            ok(false, "Export as HTML… writes the file", "\(error)")
        }

        // R22, R19: the PDF.
        let pdfURL = outDir.appendingPathComponent("export-demo.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        var pdfPages = 0
        do {
            try await controller.writePDF(to: pdfURL)
            let pdf = PDFDocument(url: pdfURL)
            pdfPages = pdf?.pageCount ?? 0
            ok((try? Data(contentsOf: pdfURL))?.starts(with: Data("%PDF-".utf8)) == true, "Export as PDF… writes a PDF")
            ok(pdfPages > 1, "the PDF has several pages", "\(pdfPages)")
            let paper = NSPrintInfo.shared.paperSize
            let box = pdf?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
            ok(Int(box.width.rounded()) == Int(paper.width.rounded()) && Int(box.height.rounded()) == Int(paper.height.rounded()), "its pages are the system paper size", "\(box.size) vs \(paper)")
            ok((pdf?.page(at: 0)?.string ?? "").contains("Fixture P"), "its text is text")
        } catch {
            ok(false, "Export as PDF… writes the file", "\(error)")
        }

        // R21: what the print panel would be given (the panel itself is modal, so the operation is read instead).
        do {
            if let (operation, _) = try await controller.makePrintOperation() {
                let paper = NSPrintInfo.shared.paperSize
                let margin = 20.0 / 25.4 * 72
                ok(Int(operation.printInfo.paperSize.width.rounded()) == Int(paper.width.rounded()) && Int(operation.printInfo.paperSize.height.rounded()) == Int(paper.height.rounded()), "the print operation carries the system paper size")
                ok([operation.printInfo.topMargin, operation.printInfo.bottomMargin, operation.printInfo.leftMargin, operation.printInfo.rightMargin].allSatisfy { abs($0 - margin) < 1 }, "and 20 mm margins")
            } else {
                ok(false, "a print operation can be made")
            }
        } catch {
            ok(false, "a print operation can be made", "\(error)")
        }

        // R26: a destination that cannot be written gives the alert text and leaves no file.
        var alerts: [(String, String)] = []
        let bad = URL(fileURLWithPath: "/nonexistent-folder-for-the-export-check/out.html")
        controller.chooseDestination = { _, _, _ in bad }
        controller.presentError = { alerts.append(($0, $1)) }
        controller.exportHTML()
        _ = await waitUntil(timeout: 20) { !controller.isPreparing }
        ok(alerts.first?.0 == "Couldn't export" && !(alerts.first?.1 ?? "").isEmpty, "an unwritable destination gives “Couldn't export” and the system's reason", "\(alerts)")
        ok(!FileManager.default.fileExists(atPath: bad.path), "and leaves no file")

        // R27: a large document is prepared without blocking the main thread for long.
        var lines: [String] = []
        for i in 0..<1010 {
            lines += ["## Section \(i % 50)", "", "A paragraph with **bold**, `code`, a [link](https://example.com/\(i)) and ==highlight==. " + String(repeating: "More words to fill the line. ", count: 14), "",
                      "- one", "  - [ ] nested", "- [x] done", "", "> quote", "", "| a | b |", "|---|--:|", "| 1 | `x` |", "", "```swift", "let x = \(i)", "```", "", "", ""]
        }
        lines += ["```mermaid", "graph TD", "  A-->B", "```", ""]
        let big = lines.joined(separator: "\n")
        controller.snapshot = { .init(text: big, fileURL: work, displayName: "big.md") }
        controller.renderDiagram = { source in await MermaidService.shared.render(source, dark: false) }
        var running = true
        var longest = 0.0
        let heartbeat = Task { @MainActor in
            var last = Date()
            while running {
                try? await Task.sleep(nanoseconds: 5_000_000)
                let now = Date()
                longest = max(longest, now.timeIntervalSince(last) - 0.005)
                last = now
            }
        }
        let bigURL = outDir.appendingPathComponent("big.html")
        // The heartbeat's own jitter with the main thread idle, so a stall can be told from noise in the run.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let idleJitter = longest
        longest = 0
        let started = Date()
        _ = try? await controller.writeHTML(to: bigURL)
        running = false
        await heartbeat.value
        ok(FileManager.default.fileExists(atPath: bigURL.path), "a \(lines.count)-line document is exported")
        ok(longest < 0.25, "the main thread never stalls for 250 ms while preparing it", "longest \(Int(longest * 1000)) ms over \(String(format: "%.1f", Date().timeIntervalSince(started))) s (idle jitter \(Int(idleJitter * 1000)) ms)")
        controller.snapshot = originalSnapshot

        // R5: nothing about the document changed.
        let after = (hash: fileHash(), text: tv.string, selection: tv.selectedRange(), canUndo: tv.undoManager?.canUndo ?? false,
                     edited: document.isDocumentEdited, folds: tv.coordinator?.foldState, source: tv.coordinator?.sourceMode ?? false)
        ok(after.edited == before.edited && !after.edited, "the document is still unedited (no edited dot)")
        ok(after.canUndo == before.canUndo, "Undo is as it was")
        ok(after.hash == before.hash && !after.hash.isEmpty, "the file on disk is byte for byte what it was")
        ok(after.text == before.text && after.selection == before.selection, "the text and the caret are as they were")
        ok(after.folds == before.folds && after.source == before.source, "folds and the source view are as they were")
    }
}
