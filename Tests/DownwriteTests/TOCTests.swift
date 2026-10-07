import XCTest
import SwiftUI
import AppKit
@testable import Downwrite
import DownwriteCore

/// The table-of-contents sidebar: the model that feeds it, caret tracking, and clicking a row to scroll the editor.
@MainActor
final class TOCTests: XCTestCase {
    /// 40 sections, each several screens apart, with a few nested `###` headings.
    static func longDocument() -> String {
        var s = "# Title\n\nIntro paragraph.\n\n"
        for i in 1...40 {
            s += "## Section \(i)\n\n"
            for p in 0..<6 {
                s += "Paragraph \(p) of section \(i). " + String(repeating: "lorem ipsum dolor sit amet ", count: 12) + "\n\n"
            }
            if i % 10 == 0 { s += "### Detail \(i)\n\nA closing note.\n\n" }
        }
        return s
    }

    private func make(_ text: String, size: NSSize = NSSize(width: 960, height: 600)) -> (EditorHarness, TOCModel) {
        let h = EditorHarness(text: text, size: size)
        let model = TOCModel()
        h.coordinator.toc = model
        return (h, model)
    }

    private func row(_ model: TOCModel, _ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> TOCRow {
        try XCTUnwrap(model.rows.first { $0.title == title }, "no row titled \(title)", file: file, line: line)
    }

    /// Top of the heading's line in text-view coordinates.
    private func lineTop(_ h: EditorHarness, of heading: HeadingInfo) -> CGFloat {
        let lm = h.textView.layoutManager!
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(heading.range)))
        let used = lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: heading.range.location), effectiveRange: nil)
        return used.minY + h.textView.textContainerOrigin.y
    }

    /// Distance from the top of the visible area (below any toolbar inset) to the heading line.
    private func distanceFromTop(_ h: EditorHarness, _ heading: HeadingInfo) -> CGFloat {
        let clip = h.scroll.contentView
        return lineTop(h, of: heading) - (clip.bounds.origin.y + clip.contentInsets.top)
    }

    // MARK: Model

    func testModelListsHeadingsNestedByLevel() async {
        let (h, model) = make("# One\n\n## Two\n\n### Three\n\n## Four\n")
        let ok = await waitUntil { model.rows.count == 4 }
        XCTAssertTrue(ok)
        XCTAssertEqual(model.rows.map(\.title), ["One", "Two", "Three", "Four"])
        XCTAssertEqual(model.rows.map(\.depth), [0, 1, 2, 1])
        withExtendedLifetime(h) {}
    }

    func testModelShowsTitlesWithoutSyntax() async {
        let (h, model) = make("# **Bold** and [a link](https://example.com)\n")
        let ok = await waitUntil { model.rows.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(model.rows.first?.title, "Bold and a link")
        withExtendedLifetime(h) {}
    }

    func testModelFollowsEdits() async {
        let (h, model) = make("# One\n\n## Two\n")
        _ = await waitUntil { model.rows.count == 2 }
        h.textView.insertText("\n\n## Three\n", replacementRange: NSRange(location: h.textView.string.utf16.count, length: 0))
        var ok = await waitUntil { model.rows.count == 3 }
        XCTAssertTrue(ok, "a new heading appears as it is typed")
        h.textView.insertText("Zwei", replacementRange: NSRange(location: h.index(of: "Two"), length: 3))
        ok = await waitUntil { model.rows.map(\.title) == ["One", "Zwei", "Three"] }
        XCTAssertTrue(ok, "renaming a heading renames its row")
        h.textView.insertText("", replacementRange: (h.textView.string as NSString).range(of: "## Three\n"))
        ok = await waitUntil { model.rows.count == 2 }
        XCTAssertTrue(ok, "deleting a heading removes its row")
    }

    func testModelAdoptsExternalTextChange() async {
        let (h, model) = make("# Old\n")
        _ = await waitUntil { model.rows.count == 1 }
        h.coordinator.update(text: "# New\n\n## Deeper\n", settings: EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720))
        let ok = await waitUntil { model.rows.map(\.title) == ["New", "Deeper"] }
        XCTAssertTrue(ok)
        withExtendedLifetime(h) {}
    }

    func testEmptyDocumentHasNoRows() async {
        let (h, model) = make("")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.activeID)
        h.textView.insertText("# First", replacementRange: NSRange(location: 0, length: 0))
        let ok = await waitUntil { model.rows.count == 1 }
        XCTAssertTrue(ok)
    }

    func testDetachingStopsFeedingTheModel() async {
        let (h, model) = make("# One\n")
        _ = await waitUntil { model.rows.count == 1 }
        h.coordinator.toc = nil
        XCTAssertNil(model.onSelect, "the coordinator lets go of the model")
        h.textView.insertText("\n## Two\n", replacementRange: NSRange(location: h.textView.string.utf16.count, length: 0))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testAttachingALaterModelFillsItIn() async {
        let h = EditorHarness(text: "# A\n\n## B\n")
        let model = TOCModel()
        h.coordinator.toc = model
        let ok = await waitUntil { model.rows.count == 2 }
        XCTAssertTrue(ok, "a sidebar attached after the document loaded still gets its rows")
        withExtendedLifetime(h) {}
    }

    // MARK: Active heading

    func testActiveHeadingFollowsTheCaret() async {
        let (h, model) = make("Preface\n\n# One\n\ntext\n\n## Two\n\nmore\n\n### Three\n")
        _ = await waitUntil { model.rows.count == 3 }
        h.select(0)
        var ok = await waitUntil { model.activeID == nil && model.rows.count == 3 }
        XCTAssertTrue(ok, "nothing is active before the first heading")
        h.select(h.index(of: "text") + 1)
        ok = await waitUntil { model.activeID == 0 }
        XCTAssertTrue(ok, "body text belongs to the heading above it")
        h.select(h.index(of: "more"))
        ok = await waitUntil { model.activeID == 1 }
        XCTAssertTrue(ok)
        h.select(h.index(of: "Three"))
        ok = await waitUntil { model.activeID == 2 }
        XCTAssertTrue(ok)
        h.select(0)
        ok = await waitUntil { model.activeID == nil }
        XCTAssertTrue(ok, "back in the preface nothing is active again")
    }

    // MARK: Clicking a row

    func testSelectingARowPutsTheCaretAtTheEndOfTheHeading() async throws {
        let (h, model) = make("# One\n\ntext\n\n## Two ##\n\nmore\n")
        _ = await waitUntil { model.rows.count == 2 }
        h.window.makeFirstResponder(nil)
        model.select(try row(model, "Two").id)
        let two = (h.textView.string as NSString).range(of: "## Two ##")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: NSMaxRange(two), length: 0))
        XCTAssertTrue(h.window.firstResponder === h.textView, "typing carries on in the editor")
        let ok = await waitUntil { model.activeID == 1 }
        XCTAssertTrue(ok, "the clicked heading becomes the active one")
        XCTAssertFalse(h.isHidden(at: two.location), "the heading's own syntax shows while the caret is on it")
    }

    func testSelectingAnUnknownRowIsIgnored() async {
        let (h, model) = make("# One\n")
        _ = await waitUntil { model.rows.count == 1 }
        h.select(2)
        h.coordinator.revealHeading(at: 7, animated: false)
        h.coordinator.revealHeading(at: -1, animated: false)
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testRevealPutsTheHeadingNearTheTopOfTheViewport() async throws {
        let (h, model) = make(Self.longDocument())
        _ = await waitUntil { model.rows.count > 40 }
        let id = try row(model, "Section 20").id
        h.coordinator.revealHeading(at: id, animated: false)
        let heading = h.coordinator.analysis.headings[id]
        XCTAssertEqual(distanceFromTop(h, heading), 28, accuracy: 3)
        XCTAssertGreaterThan(h.scroll.contentView.bounds.origin.y, 1000, "the viewport really moved")
        // And back up again.
        let first = try row(model, "Section 2").id
        h.coordinator.revealHeading(at: first, animated: false)
        XCTAssertEqual(distanceFromTop(h, h.coordinator.analysis.headings[first]), 28, accuracy: 3)
    }

    func testRevealWorksForEveryHeadingOfALongDocument() async throws {
        let (h, model) = make(Self.longDocument())
        _ = await waitUntil { model.rows.count > 40 }
        for r in model.rows where r.depth == 1 && r.id % 7 == 0 {
            h.coordinator.revealHeading(at: r.id, animated: false)
            let visible = h.textView.visibleRect
            let top = lineTop(h, of: h.coordinator.analysis.headings[r.id])
            XCTAssertTrue(top >= visible.minY && top <= visible.maxY, "\(r.title) is on screen")
        }
    }

    func testFirstAndLastHeadingStayInsideTheDocument() async throws {
        let (h, model) = make(Self.longDocument())
        _ = await waitUntil { model.rows.count > 40 }
        h.coordinator.revealHeading(at: try row(model, "Title").id, animated: false)
        XCTAssertEqual(h.scroll.contentView.bounds.origin.y, -h.scroll.contentView.contentInsets.top, accuracy: 1, "can't scroll above the start")
        let last = try row(model, "Detail 40").id
        h.coordinator.revealHeading(at: last, animated: false)
        let heading = h.coordinator.analysis.headings[last]
        let visible = h.textView.visibleRect
        let top = lineTop(h, of: heading)
        XCTAssertTrue(top >= visible.minY && top <= visible.maxY, "the last heading is on screen even though it can't reach the top")
        XCTAssertLessThanOrEqual(visible.maxY, h.textView.frame.maxY + 1, "no scrolling past the end")
    }

    func testAnimatedRevealArrivesAtTheSamePlace() async throws {
        let (h, model) = make(Self.longDocument())
        _ = await waitUntil { model.rows.count > 40 }
        let id = try row(model, "Section 15").id
        model.select(id)
        let heading = h.coordinator.analysis.headings[id]
        let ok = await waitUntil(timeout: 8) { abs(self.distanceFromTop(h, heading) - 28) < 3 }
        XCTAssertTrue(ok, "ended \(distanceFromTop(h, heading)) pt from the top")
    }

    func testRevealAfterTypingUsesTheNewPositions() async throws {
        let (h, model) = make(Self.longDocument())
        _ = await waitUntil { model.rows.count > 40 }
        h.textView.insertText(String(repeating: "A very long inserted line. ", count: 200) + "\n\n", replacementRange: NSRange(location: 0, length: 0))
        _ = await waitUntil { h.coordinator.analysis.length == h.textView.string.utf16.count }
        let id = try row(model, "Section 25").id
        h.coordinator.revealHeading(at: id, animated: false)
        XCTAssertEqual(distanceFromTop(h, h.coordinator.analysis.headings[id]), 28, accuracy: 3)
        XCTAssertEqual(h.textView.string.substring(with: h.coordinator.analysis.headings[id].range), "## Section 25")
    }

    func testRevealWithTheCaretInsideAGridTable() async throws {
        let doc = "# Top\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n" + String(repeating: "filler line\n\n", count: 80) + "## Bottom\n"
        let (h, model) = make(doc)
        _ = await waitUntil { model.rows.count == 2 && !h.coordinator.tableOverlay.grids.isEmpty }
        h.select(h.index(of: "| 1"))
        h.coordinator.revealHeading(at: try row(model, "Bottom").id, animated: false)
        XCTAssertEqual(h.textView.selectedRange().location, NSMaxRange((h.textView.string as NSString).range(of: "## Bottom")))
        XCTAssertTrue(h.window.firstResponder === h.textView)
    }
}

private extension String {
    func substring(with r: NSRange) -> String { (self as NSString).substring(with: r) }
}

/// Renders the sidebar (alone and next to the editor) for the visual pass.
@MainActor
final class TOCSnapshotTests: XCTestCase {
    private func sidebarImage(rows: [TOCRow], active: Int?, dark: Bool, size: NSSize) async throws -> NSImage {
        let model = TOCModel()
        model.update(rows: rows, activeID: active)
        let host = NSHostingView(rootView: TOCSidebar(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        window.orderOut(nil)
        return image
    }

    private func write(_ image: NSImage, _ name: String) throws {
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: SnapshotTests.outputDir.appendingPathComponent("\(name).png"))
    }

    func testSnapshotSidebarLightAndDark() async throws {
        let text = try String(contentsOf: try XCTUnwrap(AppResources.url("Welcome", "md")), encoding: .utf8)
        let rows = MarkdownAnalyzer.analyze(text).tableOfContents.rows
        let active = rows.first { $0.title == "Lists that keep up" }?.id
        for dark in [false, true] {
            let image = try await sidebarImage(rows: rows, active: active, dark: dark, size: NSSize(width: 260, height: 420))
            try write(image, "toc-sidebar-\(dark ? "dark" : "light")")
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var colours = Set<UInt32>()
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                        colours.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
                    }
                }
            }
            XCTAssertGreaterThan(colours.count, 4, "sidebar (\(dark ? "dark" : "light")) rendered something")
        }
    }

    func testSnapshotEmptySidebar() async throws {
        let image = try await sidebarImage(rows: [], active: nil, dark: false, size: NSSize(width: 260, height: 300))
        try write(image, "toc-sidebar-empty-light")
    }

    func testSnapshotEditorWithSidebar() async throws {
        let text = try String(contentsOf: try XCTUnwrap(AppResources.url("Welcome", "md")), encoding: .utf8)
        for dark in [false, true] {
            let h = EditorHarness(text: text, dark: dark, size: NSSize(width: 700, height: 760))
            _ = await waitUntil { (h.coordinator.overlay.reservedHeights.values.first ?? 0) > 100 }
            h.select(h.index(of: "Lists that keep up") + 3)
            h.textView.scrollToBeginningOfDocument(nil)
            h.window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 600_000_000)
            let editorView = h.window.contentView!
            let editorRep = try XCTUnwrap(editorView.bitmapImageRepForCachingDisplay(in: editorView.bounds))
            editorView.cacheDisplay(in: editorView.bounds, to: editorRep)
            let rows = h.coordinator.analysis.tableOfContents.rows
            let active = h.coordinator.analysis.headingIndex(at: h.textView.selectedRange().location)
            let side = try await sidebarImage(rows: rows, active: active, dark: dark, size: NSSize(width: 260, height: 760))
            let editorImage = NSImage(size: editorView.bounds.size)
            editorImage.addRepresentation(editorRep)
            let combined = NSImage(size: NSSize(width: 960, height: 760))
            combined.lockFocus()
            editorImage.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
            side.draw(at: NSPoint(x: 700, y: 0), from: .zero, operation: .copy, fraction: 1)
            combined.unlockFocus()
            try write(combined, "toc-editor-\(dark ? "dark" : "light")")
        }
    }
}
