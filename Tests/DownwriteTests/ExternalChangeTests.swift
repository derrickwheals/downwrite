import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// A document whose file was rewritten by another process is handed to the editor as new text. The editor applies it as
/// the smallest replacement so the view keeps its place.
@MainActor
final class ExternalChangeTests: XCTestCase {
    private let settings = EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720)
    private let old = "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n"

    func testACaretBeforeTheChangeStaysPut() {
        let h = EditorHarness(text: old)
        h.select(3)
        h.coordinator.update(text: old.replacingOccurrences(of: "Second", with: "A much longer second"), settings: settings)
        XCTAssertEqual(h.textView.string, "# Title\n\nFirst paragraph.\n\nA much longer second paragraph.\n")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testACaretAfterTheChangeMovesWithTheText() {
        let h = EditorHarness(text: old)
        let caret = (old as NSString).range(of: "paragraph.\n", options: .backwards).location       // inside the last line
        h.select(caret)
        h.coordinator.update(text: "# Title\n\nFirst paragraph, and a whole new sentence inserted here.\n\nSecond paragraph.\n", settings: settings)
        XCTAssertEqual((h.textView.string as NSString).substring(from: h.textView.selectedRange().location), "paragraph.\n",
                       "the caret is still in the same place in the text it was in")
    }

    func testASelectionIsKeptThroughAChangeElsewhere() {
        let h = EditorHarness(text: old)
        let word = (old as NSString).range(of: "First")
        h.select(word.location, word.length)
        h.coordinator.update(text: old.replacingOccurrences(of: "Second paragraph.", with: "Edited elsewhere."), settings: settings)
        XCTAssertEqual((h.textView.string as NSString).substring(with: h.textView.selectedRange()), "First")
    }

    func testTheScrollPositionIsKept() {
        let lines = (1...400).map { "Line \($0) of a long document that keeps going and going." }
        let text = lines.joined(separator: "\n\n") + "\n"
        let h = EditorHarness(text: text)
        h.select(0)
        // Lay the whole document out first so the scroll range is final, then scroll to the middle of it.
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        h.window.displayIfNeeded()
        let target = (h.textView.frame.height * 0.4).rounded()
        h.scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        h.scroll.reflectScrolledClipView(h.scroll.contentView)
        let before = h.scroll.contentView.bounds.origin.y
        XCTAssertEqual(before, target, accuracy: 1, "the view is scrolled to the middle of the document")
        h.coordinator.update(text: text.replacingOccurrences(of: "Line 395 of", with: "Line 395, rewritten, of"), settings: settings)
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        XCTAssertEqual(h.scroll.contentView.bounds.origin.y, before, accuracy: 2, "the view stays where it was")
        XCTAssertTrue(h.textView.string.contains("Line 395, rewritten, of"))
    }

    func testTheNewTextIsStyledAndAnalysed() {
        let h = EditorHarness(text: "just a line\n")
        h.select(0)
        h.coordinator.update(text: "just a line\n\n## A new heading\n\nand **bold** text\n", settings: settings)
        XCTAssertEqual(h.coordinator.analysis.headings.map(\.plainTitle), ["A new heading"])
        XCTAssertGreaterThan(h.font(at: h.index(of: "A new")).pointSize, 20, "the heading is styled")
        XCTAssertTrue(h.isHidden(at: h.index(of: "**bold**")), "and so is the bold, with its syntax hidden")
    }

    func testTheUndoHistoryIsDroppedBecauseItsOffsetsAreStale() {
        let h = EditorHarness(text: "start\n")
        h.window.makeFirstResponder(h.textView)
        h.select(h.textView.string.utf16.count)
        h.textView.insertText("typed by hand", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(h.textView.undoManager?.canUndo, true)
        h.coordinator.update(text: "something else entirely\n", settings: settings)
        XCTAssertEqual(h.textView.undoManager?.canUndo, false, "undo would act on text that no longer exists")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.textView.string, "something else entirely\n")
    }

    func testTheSameTextChangesNothing() {
        let h = EditorHarness(text: old)
        h.window.makeFirstResponder(h.textView)
        h.select(2, 5)
        h.textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        let after = h.textView.string, selection = h.textView.selectedRange()
        h.coordinator.update(text: after, settings: settings)
        XCTAssertEqual(h.textView.string, after)
        XCTAssertEqual(h.textView.selectedRange(), selection)
        XCTAssertEqual(h.textView.undoManager?.canUndo, true, "nothing happened, so the history stays")
    }

    func testEmojiAroundTheChangeSurviveIt() {
        let h = EditorHarness(text: "😀 one 😀\n")
        h.select(0)
        h.coordinator.update(text: "😀 two 😁\n", settings: settings)
        XCTAssertEqual(h.textView.string, "😀 two 😁\n")
    }

    func testAFileChangeWithoutAnOpenDocumentIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("downwrite-external-\(UUID().uuidString).md")
        try "one\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let h = EditorHarness(text: "one\n", fileURL: url)
        try "two\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(h.coordinator.checkForExternalChange(), "no NSDocument owns this file, so there is nothing to revert")
        XCTAssertEqual(h.textView.string, "one\n")
    }
}
