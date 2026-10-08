import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Bulleted tasks are drawn as rounded-square checkboxes while their `- [ ] ` source is hidden.
@MainActor
final class TaskCheckboxTests: XCTestCase {
    private func lm(_ h: EditorHarness) -> DWLayoutManager { h.textView.layoutManager as! DWLayoutManager }

    private func boxRect(_ h: EditorHarness, at index: Int) -> NSRect {
        var r = lm(h).checkboxRect(forCharacterAt: index) ?? .zero
        r.origin.x += h.textView.textContainerOrigin.x
        r.origin.y += h.textView.textContainerOrigin.y
        return r
    }

    /// Sends a real mouse-down to the text view — but only after confirming the point hits a checkbox: a click that
    /// misses falls through to `NSTextView`'s own mouse tracking, which waits for a mouse-up that never comes.
    private func click(_ h: EditorHarness, at point: NSPoint) throws {
        _ = try XCTUnwrap(h.textView.taskBox(at: point), "the point should be on a checkbox")
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: h.textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                   windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.textView.mouseDown(with: e)
    }

    func testPrefixIsHiddenAndReplacedByACheckbox() throws {
        let h = EditorHarness(text: "intro\n\n- [ ] todo\n- [x] done\n")
        h.select(0)
        let open = h.index(of: "- [ ] todo")
        for i in 0..<6 { XCTAssertTrue(h.isHidden(at: open + i), "prefix character \(i) hidden") }
        XCTAssertFalse(h.isHidden(at: open + 6), "the item's text stays visible")
        let mark = try XCTUnwrap(h.attrs(at: open)[.dwCheckbox] as? CheckboxMark)
        XCTAssertFalse(mark.checked)
        XCTAssertGreaterThan(try XCTUnwrap(h.attrs(at: open)[.kern] as? CGFloat), 10, "room is reserved for the box")
        let done = h.index(of: "- [x] done")
        XCTAssertEqual((h.attrs(at: done)[.dwCheckbox] as? CheckboxMark)?.checked, true)
        XCTAssertNotNil(h.attrs(at: h.index(of: "done"))[.strikethroughStyle], "a completed task is still struck through")
    }

    func testSourceShowsOnlyWhileTheCaretIsInsideThePrefix() {
        let h = EditorHarness(text: "intro\n\n- [ ] todo\n")
        let p = h.index(of: "- [ ] todo")
        h.select(p)
        XCTAssertNotNil(h.attrs(at: p)[.dwCheckbox], "caret at the start of the item: still a checkbox")
        h.select(p + 6)
        XCTAssertNotNil(h.attrs(at: p)[.dwCheckbox], "caret where the text starts (where you type): still a checkbox")
        XCTAssertTrue(h.isHidden(at: p))
        h.select(p + 3)
        XCTAssertNil(h.attrs(at: p)[.dwCheckbox], "caret inside the prefix shows the source")
        XCTAssertFalse(h.isHidden(at: p))
        XCTAssertFalse(h.isHidden(at: p + 3))
        h.select(p + 8)
        XCTAssertNotNil(h.attrs(at: p)[.dwCheckbox], "caret back in the text: checkbox again")
    }

    func testNumberedTasksKeepTheirNumberAndTheRawBox() {
        let h = EditorHarness(text: "1. [ ] numbered\n")
        h.select(h.textView.string.utf16.count)
        XCTAssertNil(h.attrs(at: 0)[.dwCheckbox])
        XCTAssertFalse(h.isHidden(at: 0))
    }

    func testTextStartsAfterTheBoxAndWrappedLinesAlignWithIt() throws {
        let long = String(repeating: "wrapped words ", count: 30)
        let h = EditorHarness(text: "- [ ] \(long)\n", size: NSSize(width: 560, height: 500))
        h.select(0)
        let layout = lm(h)
        let box = try XCTUnwrap(layout.checkboxRect(forCharacterAt: 0))
        let column = h.coordinator.styler.checkboxColumn(17)
        let firstText = layout.boundingRect(forGlyphRange: NSRange(location: layout.glyphIndexForCharacter(at: 6), length: 1), in: h.textView.textContainer!)
        XCTAssertEqual(firstText.minX - box.minX, column, accuracy: 1.0, "text starts one box-and-gap after the box")
        XCTAssertEqual(h.paragraph(at: 8).headIndent, column, accuracy: 0.6, "wrapped lines hang under the text")
        // The second line fragment really starts under the text.
        var fragments: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, used, _, _, _ in fragments.append(used) }
        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertEqual(fragments[1].minX, firstText.minX, accuracy: 1.0)
    }

    func testBoxIsASquareCentredOnTheText() throws {
        let h = EditorHarness(text: "- [ ] Todo item\n")
        h.select(h.textView.string.utf16.count)
        let layout = lm(h)
        let box = try XCTUnwrap(layout.checkboxRect(forCharacterAt: 0))
        XCTAssertEqual(box.width, box.height, accuracy: 0.01)
        XCTAssertGreaterThan(box.width, 11)
        XCTAssertLessThan(box.width, 17)
        let glyph = layout.glyphIndexForCharacter(at: 6)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = line.minY + layout.location(forGlyphAt: glyph).y
        let font = try XCTUnwrap(h.storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(box.midY, baseline, "centre sits above the baseline")
        XCTAssertGreaterThan(box.midY, baseline - font.capHeight, "…and below the top of capitals")
        XCTAssertGreaterThan(box.minY, line.minY)
        XCTAssertLessThan(box.maxY, line.maxY)
    }

    func testClickingTheDrawnCheckboxTogglesWithoutMovingTheCaret() throws {
        let h = EditorHarness(text: "intro\n\n- [ ] todo\nlast line\n")
        h.window.makeKeyAndOrderFront(nil)
        let end = h.textView.string.utf16.count
        h.select(end)
        let p = h.index(of: "- [ ] todo")
        let r = boxRect(h, at: p)
        XCTAssertGreaterThan(r.width, 10)
        try click(h, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(h.textView.string, "intro\n\n- [x] todo\nlast line\n")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: end, length: 0), "the caret stays put")
        XCTAssertNotNil(h.attrs(at: p)[.dwCheckbox], "…so the source stays hidden")
        XCTAssertEqual((h.attrs(at: p)[.dwCheckbox] as? CheckboxMark)?.checked, true)
        try click(h, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(h.textView.string, "intro\n\n- [ ] todo\nlast line\n", "a second click unticks it")
    }

    func testOnlyTheCheckboxItselfIsAClickTarget() {
        let h = EditorHarness(text: "- [ ] todo\n")
        h.select(h.textView.string.utf16.count)
        let r = boxRect(h, at: 0)
        XCTAssertNotNil(h.textView.taskBox(at: NSPoint(x: r.midX, y: r.midY)))
        XCTAssertNotNil(h.textView.taskBox(at: NSPoint(x: r.minX - 2, y: r.midY)), "a little slack around the box")
        XCTAssertNil(h.textView.taskBox(at: NSPoint(x: r.maxX + 40, y: r.midY)), "the item's text is not a target")
        XCTAssertNil(h.textView.taskBox(at: NSPoint(x: r.midX, y: r.maxY + 30)), "nor is the space below")
    }

    func testToggleIsUndoable() throws {
        let h = EditorHarness(text: "- [ ] todo\n")
        h.window.makeKeyAndOrderFront(nil)
        h.window.makeFirstResponder(h.textView)
        h.select(h.textView.string.utf16.count)
        let r = boxRect(h, at: 0)
        try click(h, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(h.textView.string, "- [x] todo\n")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.textView.string, "- [ ] todo\n")
    }

    func testClickingRawBoxStillTogglesWhileTheSourceIsShown() throws {
        let h = EditorHarness(text: "- [ ] todo\n")
        h.window.makeKeyAndOrderFront(nil)
        h.select(3)                                         // caret inside the prefix: source shown
        XCTAssertNil(h.attrs(at: 0)[.dwCheckbox])
        let layout = lm(h)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 2, length: 3), actualCharacterRange: nil)
        var r = layout.boundingRect(forGlyphRange: glyphs, in: h.textView.textContainer!)
        r.origin.x += h.textView.textContainerOrigin.x; r.origin.y += h.textView.textContainerOrigin.y
        try click(h, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(h.textView.string, "- [x] todo\n")
    }

    func testNestedTaskKeepsItsIndent() throws {
        let h = EditorHarness(text: "- [ ] top\n  - [ ] nested\n")
        h.select(0)
        let top = try XCTUnwrap(lm(h).checkboxRect(forCharacterAt: 0))
        let nestedIndex = h.index(of: "- [ ] nested")
        let nested = try XCTUnwrap(lm(h).checkboxRect(forCharacterAt: nestedIndex))
        XCTAssertGreaterThan(nested.minX, top.minX + 4, "the nested box is indented")
        XCTAssertGreaterThan(nested.minY, top.maxY - 1, "…and on its own line")
    }

    // MARK: Empty items (just after pressing Return)

    /// The drawn box must lie inside its own line, which must be as tall as the line above it.
    private func assertBoxFitsItsLine(_ h: EditorHarness, itemAt index: Int, like reference: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = lm(h)
        let box = try XCTUnwrap(layout.checkboxRect(forCharacterAt: index), file: file, line: line)
        let refBox = try XCTUnwrap(layout.checkboxRect(forCharacterAt: reference), file: file, line: line)
        let frag = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil)
        let refFrag = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: reference), effectiveRange: nil)
        XCTAssertEqual(frag.height, refFrag.height, accuracy: 1.0, "an empty item is as tall as one with text", file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.minY, frag.minY - 0.5, "the box does not rise above its own line", file: file, line: line)
        XCTAssertLessThanOrEqual(box.maxY, frag.maxY + 0.5, "…or sink below it", file: file, line: line)
        XCTAssertEqual(box.minY - frag.minY, refBox.minY - refFrag.minY, accuracy: 1.5, "same place in its line as the box above", file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.minY, refBox.maxY - 0.5, "the two boxes do not overlap", file: file, line: line)
    }

    func testEmptyTaskItemKeepsANormalLineAndItsBoxStaysInIt() throws {
        let h = EditorHarness(text: "- [ ] first\n- [ ] ")
        h.select(h.textView.string.utf16.count)             // caret at the end of the empty item
        XCTAssertNotNil(h.attrs(at: 12)[.dwCheckbox], "the empty item still shows a checkbox")
        try assertBoxFitsItsLine(h, itemAt: 12, like: 0)
    }

    func testReturnAfterATaskStartsANewCheckboxBelowIt() throws {
        let h = EditorHarness(text: "- [x] checkboxes")
        h.window.makeFirstResponder(h.textView)
        h.select(h.textView.string.utf16.count)
        h.textView.insertNewline(nil)
        XCTAssertEqual(h.textView.string, "- [x] checkboxes\n- [ ] ")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: h.textView.string.utf16.count, length: 0))
        try assertBoxFitsItsLine(h, itemAt: 17, like: 0)
        // Typing into it keeps the box where it was.
        let before = try XCTUnwrap(lm(h).checkboxRect(forCharacterAt: 17))
        h.textView.insertText("another", replacementRange: NSRange(location: NSNotFound, length: 0))
        let after = try XCTUnwrap(lm(h).checkboxRect(forCharacterAt: 17))
        XCTAssertEqual(after.minY, before.minY, accuracy: 1.5, "the box does not jump when the first character is typed")
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.5)
        try assertBoxFitsItsLine(h, itemAt: 17, like: 0)
    }

    func testEmptyTaskItemInTheMiddleOfAList() throws {
        let h = EditorHarness(text: "- [ ] one\n- [ ] \n- [ ] three\n")
        h.select(0)
        try assertBoxFitsItsLine(h, itemAt: 10, like: 0)
        try assertBoxFitsItsLine(h, itemAt: 17, like: 0)
    }
}
