import AppKit
import DownwriteCore

/// GitHub-style callouts, end to end (DW-006): the real app, a real `NSDocument` on disk holding the shared corpus
/// (`Tests/Fixtures/callouts.md`), the label and bar the window really draws, the caret moving through the real text view, a fold, the
/// source view, the announcement, and screenshots in both themes.
extension SelfTest {
    /// `--selftest-callouts=<file>`: the shared callout corpus. Without it the step is skipped.
    static var calloutFixture: URL? {
        CommandLine.arguments.first { $0.hasPrefix("--selftest-callouts=") }.map { URL(fileURLWithPath: String($0.dropFirst("--selftest-callouts=".count))) }
    }

    /// `--selftest-callouts-only`: run only this step (for development; `--selftest-input` is still required and opened).
    static var calloutsOnly: Bool { CommandLine.arguments.contains("--selftest-callouts-only") }

    /// One `## <id> <expected>` row of the corpus: `expected` is `plain`, `callout <kind>` or `callout <kind> "<title>"`.
    private struct CalloutRow {
        var id: String
        var kind: CalloutKind?
        var title: String?
        /// The heading's line and the lines under it, up to the next heading (0-based).
        var headingLine: Int
        var lines: ClosedRange<Int>
    }

    private static func calloutRows(in text: String) -> [CalloutRow] {
        let lines = text.components(separatedBy: "\n")
        var rows: [CalloutRow] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("## ") {
            let parts = line.dropFirst(3).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            var kind: CalloutKind?
            var title: String?
            if parts[1] != "plain" {
                let words = parts[1].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard words.count >= 2, words[0] == "callout" else { continue }
                kind = CalloutKind(rawValue: String(words[1]))
                if words.count == 3, let a = words[2].firstIndex(of: "\""), let b = words[2].lastIndex(of: "\""), a < b {
                    title = String(words[2][words[2].index(after: a)..<b])
                }
            }
            rows.append(CalloutRow(id: String(parts[0]), kind: kind, title: title, headingLine: i, lines: (i + 1)...(i + 1)))
        }
        for i in rows.indices {
            let end = i + 1 < rows.count ? rows[i + 1].headingLine - 1 : lines.count - 1
            rows[i].lines = (rows[i].headingLine + 1)...max(rows[i].headingLine + 1, end)
        }
        return rows
    }

    /// Runs in the run's first editor window (the one SwiftUI resolves the menu bar against), which it reloads the way an external change
    /// is, so the document stays real, unedited and on disk.
    static func calloutWalkthrough(outDir: URL, fixture: URL, reusing tv: EditorTextView) async {
        func fail(_ what: String, _ detail: String = "") { check(false, "callouts: " + what, detail: detail) }
        guard let window = tv.window, let url = window.representedURL, let document = NSDocumentController.shared.document(for: url),
              let coordinator = tv.coordinator, let layout = tv.layoutManager as? DWLayoutManager,
              let text = try? String(contentsOf: fixture, encoding: .utf8) else { return fail("the editor window and the fixture are available") }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try document.revert(toContentsOf: url, ofType: document.fileType ?? "")
        } catch { return fail("the document reloads", "\(error)") }
        guard await waitUntil(timeout: 10, { tv.string == text }) else { return fail("the window shows the corpus", "\(tv.string.count) characters") }

        NSApp.activate(ignoringOtherApps: true)
        window.setContentSize(NSSize(width: 1000, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        try? await Task.sleep(nanoseconds: 800_000_000)

        func settle(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func lineRange(_ line: Int) -> NSRange { coordinator.analysis.lines[line].range }
        func mark(at index: Int) -> CalloutMark? { tv.textStorage?.attribute(.dwCallout, at: index, effectiveRange: nil) as? CalloutMark }
        func look(of range: NSRange) -> NSAttributedString { NSAttributedString(attributedString: tv.textStorage!.attributedSubstring(from: range)) }
        func shot(_ name: String) { check(capture(window: window, to: outDir.appendingPathComponent(name)), "callouts: the screenshot \(name) is not blank") }

        // MARK: the starting point
        let rows = calloutRows(in: text)
        check(rows.count >= 45, "callouts: the corpus has its rows", detail: "\(rows.count)")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await settle()
        check(!document.isDocumentEdited, "callouts: the document starts unedited")
        check(tv.undoManager?.canUndo == false, "callouts: and with nothing to undo")

        // MARK: every row is what the file says (R1 to R4), and drawn as such
        var wrong: [String] = [], undrawn: [String] = []
        let analysis = coordinator.analysis
        for row in rows {
            let inside = analysis.callouts.filter { row.lines.contains($0.markerLine) }
            switch row.kind {
            case nil:
                if !inside.isEmpty { wrong.append("\(row.id): expected a plain quote") }
                for line in row.lines where line < analysis.lines.count && analysis.lines[line].range.length > 0 {
                    let r = lineRange(line)
                    if mark(at: r.location) != nil || tv.textStorage?.attribute(.dwCalloutBar, at: r.location, effectiveRange: nil) != nil {
                        undrawn.append("\(row.id): a plain quote is drawn as a callout")
                    }
                }
            case let kind?:
                guard inside.count == 1, let c = inside.first else { wrong.append("\(row.id): expected one \(kind.rawValue) callout, found \(inside.count)"); continue }
                let title = c.titleRange.map { (tv.string as NSString).substring(with: $0) }
                if c.kind != kind || title != row.title { wrong.append("\(row.id): \(c.kind.rawValue) \(title.map { "\"\($0)\"" } ?? "no title")") }
                if mark(at: c.markerRange.location)?.kind != kind { undrawn.append("\(row.id): the label is not on the hidden marker") }
                if tv.textStorage?.attribute(.dwCalloutBar, at: lineRange(c.lastLine).location, effectiveRange: nil) == nil { undrawn.append("\(row.id): the bar is missing") }
            }
        }
        check(wrong.isEmpty, "callouts: every row of the corpus is classified as the file says (\(rows.count) rows)", detail: wrong.joined(separator: "; "))
        check(undrawn.isEmpty, "callouts: callout rows are drawn with their label and bar, plain quotes without", detail: undrawn.joined(separator: "; "))
        check(analysis.callouts.count == rows.filter { $0.kind != nil }.count, "callouts: no callout outside the rows", detail: "\(analysis.callouts.count)")

        // MARK: the caret on a marker line shows the literal text; the label returns when it leaves (R9, R10)
        guard let first = analysis.callouts.first else { return fail("the corpus has a callout") }
        let marker = first.markerRange.location
        tv.setSelectedRange(NSRange(location: marker + 3, length: 0))
        await settle()
        check(mark(at: marker) == nil && layout.calloutLabelRect(forCharacterAt: marker) == nil, "callouts: no label with the caret on the marker line")
        check(((tv.textStorage?.attribute(.font, at: marker, effectiveRange: nil) as? NSFont)?.pointSize ?? 0) > 8, "callouts: the literal [!NOTE] shows")
        tv.setSelectedRange(NSRange(location: lineRange(first.lastLine).location + 3, length: 0))
        await settle()
        check(mark(at: marker) != nil && layout.calloutLabelRect(forCharacterAt: marker) != nil, "callouts: the label returns when the caret leaves the marker line")

        // MARK: the window really repaints: a screenshot with the caret on the marker line, then with it away (R6, R9)
        // (The attributes and the unit tests' own bitmaps cannot tell a stale display from a fresh one; a screenshot of the composited window can.)
        func colouredInk(in viewRect: NSRect, of image: NSBitmapImageRep) -> Int {
            let window = tv.convert(viewRect, to: nil)
            let scale = CGFloat(image.pixelsWide) / (tv.window?.frame.width ?? 1)
            let x0 = Int(window.minX * scale), x1 = Int(window.maxX * scale)
            let y0 = Int(((tv.window?.frame.height ?? 0) - window.maxY) * scale), y1 = Int(((tv.window?.frame.height ?? 0) - window.minY) * scale)
            var n = 0
            for y in max(0, y0)..<min(image.pixelsHigh, max(0, y1)) {
                for x in max(0, x0)..<min(image.pixelsWide, max(0, x1)) {
                    guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent) > 0.3 { n += 1 }
                }
            }
            return n
        }
        for (name, callout) in [("without a title", first), ("with a title", analysis.callouts.first { $0.titleRange != nil && $0.kind == .note })] {
            guard let callout else { fail("the corpus has a callout \(name)"); continue }
            tv.scrollToTop(of: lineRange(callout.markerLine), animated: false)
            let marker = callout.markerRange.location
            tv.setSelectedRange(NSRange(location: lineRange(callout.lastLine).location + 3, length: 0))
            await settle(0.7)
            guard let box = layout.calloutLabelRect(forCharacterAt: marker) else { fail("the label has a place \(name)"); continue }
            let viewBox = box.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            let away = outDir.appendingPathComponent("callout-away.png"), onLine = outDir.appendingPathComponent("callout-on-line.png")
            _ = capture(window: window, to: away)
            tv.setSelectedRange(NSRange(location: marker + 3, length: 0))
            await settle(0.7)
            _ = capture(window: window, to: onLine)
            tv.setSelectedRange(NSRange(location: lineRange(callout.lastLine).location + 3, length: 0))
            await settle(0.7)
            let back = outDir.appendingPathComponent("callout-back.png")
            _ = capture(window: window, to: back)
            if let a = pixels(of: away), let b = pixels(of: onLine), let c = pixels(of: back) {
                let inkAway = colouredInk(in: viewBox, of: a), inkOn = colouredInk(in: viewBox, of: b), inkBack = colouredInk(in: viewBox, of: c)
                check(inkAway > 40 && inkOn * 3 < inkAway && inkBack > 40,
                      "callouts: the window shows the label \(name) with the caret away, the literal text with it on the line, and the label again after",
                      detail: "coloured pixels in the label's box: away \(inkAway), on the line \(inkOn), back \(inkBack)")
            } else {
                fail("the screenshots can be read \(name)")
            }
            for f in [away, onLine, back] { try? FileManager.default.removeItem(at: f) }
        }

        // MARK: moving into a callout is announced (R14)
        var said: [String] = []
        coordinator.onAnnouncement = { said.append($0) }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await settle(0.2)
        let second = analysis.callouts[1]
        tv.setSelectedRange(NSRange(location: lineRange(first.lastLine).location + 3, length: 0))
        tv.setSelectedRange(NSRange(location: lineRange(first.lastLine).location + 4, length: 0))
        tv.setSelectedRange(NSRange(location: lineRange(second.lastLine).location + 3, length: 0))
        if let tip = analysis.callouts.first(where: { $0.kind == .tip }) {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.setSelectedRange(NSRange(location: lineRange(tip.lastLine).location + 3, length: 0))
        }
        coordinator.onAnnouncement = nil
        check(said == ["Note callout", "Note callout", "Tip callout"], "callouts: entering a callout is announced once per entry", detail: "\(said)")

        // MARK: folding the heading above a callout hides it; unfolding brings it back exactly (R13)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await settle()
        let calloutRange = NSRange(location: lineRange(first.firstLine).location, length: NSMaxRange(lineRange(first.lastLine)) - lineRange(first.firstLine).location)
        let beforeFold = look(of: calloutRange)
        if let region = analysis.foldRegions.first(where: { $0.headerLines.lowerBound == rows[0].headingLine }) {
            coordinator.setFoldState(coordinator.foldState.toggled(region))
            await settle()
            let size = (tv.textStorage?.attribute(.font, at: marker, effectiveRange: nil) as? NSFont)?.pointSize ?? 99
            check(size < 1 && mark(at: marker) == nil && layout.calloutLabelRect(forCharacterAt: marker) == nil, "callouts: folding the heading above hides the callout and its label")
            check(tv.textStorage?.attribute(.dwCalloutBar, at: lineRange(first.lastLine).location, effectiveRange: nil) == nil, "callouts: and its bar")
            coordinator.setFoldState(FoldState())
            await settle()
            check(look(of: calloutRange).isEqual(to: beforeFold), "callouts: unfolding restores the callout exactly as it was")
        } else {
            fail("the first row's heading can fold")
        }

        // MARK: the source view shows plain text (R12)
        coordinator.setSourceMode(true)
        await settle(0.9)
        // (The corpus has an emoji in a title, which AppKit gives a fallback font of its own; everything else is one monospaced style.)
        let whole = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        var notMonospaced: [String] = []
        tv.textStorage?.enumerateAttributes(in: whole, options: []) { attrs, range, _ in
            let piece = (tv.string as NSString).substring(with: range)
            if (attrs[.font] as? NSFont)?.isFixedPitch != true, !piece.unicodeScalars.allSatisfy({ $0.value > 0xFFFF }) { notMonospaced.append("\(range.location)+\(range.length)") }
        }
        var drawn: [String] = []
        for key in [NSAttributedString.Key.dwCallout, .dwCalloutBar, .dwQuoteBarColor, .dwQuoteDepth, .kern] {
            tv.textStorage?.enumerateAttribute(key, in: whole, options: []) { value, range, _ in
                if value != nil { drawn.append("\(key.rawValue) at \(range.location)") }
            }
        }
        check(notMonospaced.isEmpty && drawn.isEmpty && mark(at: marker) == nil && layout.calloutLabelRect(forCharacterAt: marker) == nil,
              "callouts: the source view is plain monospaced text with no label, bar or kern",
              detail: (notMonospaced.map { "not monospaced: \($0)" } + drawn).prefix(6).joined(separator: ", "))
        coordinator.setSourceMode(false)
        await settle()
        check(mark(at: marker) != nil, "callouts: leaving the source view brings the label back")

        // MARK: screenshots, five kinds at a time, in both themes
        if let row = rows.first(where: { $0.id == "note-mixed" }) {
            tv.scrollToTop(of: lineRange(row.headingLine), animated: false)
        }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        for theme in [ThemeChoice.light, .dark] {
            UserDefaults.standard.set(theme.rawValue, forKey: Prefs.theme)
            ThemeChoice.applyCurrent()
            await settle(1.0)
            shot("window-\(theme.rawValue)-callouts.png")
            check(mark(at: marker)?.color == coordinator.styler.palette.calloutColor(.note).nsColor,
                  "callouts: the label is in the \(theme.rawValue) theme's colour")
        }
        UserDefaults.standard.set(ThemeChoice.light.rawValue, forKey: Prefs.theme)
        ThemeChoice.applyCurrent()
        await settle(0.6)

        // MARK: nothing here edited the document
        check(!document.isDocumentEdited && tv.undoManager?.canUndo == false && tv.string == text, "callouts: nothing in this step edited the document")
    }
}
