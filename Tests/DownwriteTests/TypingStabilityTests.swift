import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// DW-024: typing never moves the text on screen except to keep the caret in view. The restyle after every edit used to write the
/// attributes of the whole document, which threw its layout away; with non-contiguous layout the text view's height then fell back to an
/// estimate and the clip view clamped its scroll position to it, and layout grew both back inside the same keystroke — a flash about a line
/// lower near the end of a long document. These tests watch the scroll position and the height *during* each key (the notifications are
/// synchronous), not only where they settle, and the ranges the text storage reports as edited, which does not depend on the scroller.
@MainActor
final class TypingStabilityTests: XCTestCase {
    /// Points a value may wander outside the interval between where it started and where it settled.
    private let tolerance: CGFloat = 0.5

    /// A long document of headings, lists, a task, quotes, a callout and a code fence (no table, diagram or image card: those load web
    /// content), ending in a plain paragraph to type at.
    private var mixedDocument: String {
        let section = { (i: Int) in
            """
            ## Section \(i)

            Some text with **bold**, *italic* and `code` in it, long enough to wrap across the column at least once or twice here.

            - item one
            - item two
            - [ ] a task

            > a quote line

            > [!NOTE] A title
            > The callout's body.

            ```swift
            let x = \(i)
            ```

            """
        }
        return (0..<60).map(section).joined(separator: "\n") + "\nThe last paragraph of the document"
    }

    private func harness(_ text: String, source: Bool = false) -> EditorHarness {
        let h = EditorHarness(text: text)
        if source { h.coordinator.setSourceMode(true) }
        h.placeCaret(at: h.storage.length)
        return h
    }

    /// Types each key and checks that neither the scroll position nor the text view's height left the interval between its values before
    /// and after the key.
    private func assertStill(_ h: EditorHarness, keys: [String], viaKeyEvent: Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for key in keys {
            let g = h.recordGeometry { h.type(key, viaKeyEvent: viaKeyEvent) }
            let what = "\(label), \(key == " " ? "Space" : key) via \(viaKeyEvent ? "keyDown" : "insertText"): \(g)\n\(h.geometryReport())"
            XCTAssertLessThanOrEqual(g.clip, tolerance, "the scroll position moved and came back: " + what, file: file, line: line)
            XCTAssertLessThanOrEqual(g.height, tolerance, "the text view's height moved and came back: " + what, file: file, line: line)
        }
    }

    private let keys = ["a", " ", " ", "b", " "]

    // MARK: Stillness

    func testTypingAtTheEndOfALongDocumentNeverMovesTheView() {
        for viaKeyEvent in [false, true] {
            let h = harness(longPlainDocument())
            XCTAssertGreaterThan(h.textView.frame.height, h.scroll.contentView.bounds.height * 4, "precondition: the document is far taller than the window")
            assertStill(h, keys: keys, viaKeyEvent: viaKeyEvent, "formatted editor, at the end")
        }
    }

    func testTheSourceViewDoesNotMoveEither() {
        for viaKeyEvent in [false, true] {
            let h = harness(longPlainDocument(), source: true)
            XCTAssertTrue(h.coordinator.sourceMode)
            assertStill(h, keys: keys, viaKeyEvent: viaKeyEvent, "source view, at the end")
        }
    }

    func testTypingInTheMiddleOfALongDocumentDoesNotMoveTheView() {
        let h = EditorHarness(text: longPlainDocument())
        h.placeCaret(at: 2_000)
        h.type("a")                                   // (the first key may settle the height estimate around the caret once)
        for key in [" ", "b", " ", " "] {
            let g = h.recordGeometry { h.type(key) }
            let what = "\(key == " " ? "Space" : key): \(g)\n\(h.geometryReport())"
            XCTAssertLessThanOrEqual(abs((g.clipTrace.last ?? 0) - (g.clipTrace.first ?? 0)), tolerance, "the view scrolled: " + what)
            XCTAssertLessThanOrEqual(g.clip, tolerance, what)
            XCTAssertLessThanOrEqual(abs((g.heightTrace.last ?? 0) - (g.heightTrace.first ?? 0)), tolerance, "the height changed: " + what)
            XCTAssertLessThanOrEqual(g.height, tolerance, what)
        }
    }

    func testAMixedMarkdownDocumentDoesNotMoveEither() {
        let h = harness(mixedDocument)
        XCTAssertFalse(h.coordinator.analysis.callouts.isEmpty, "precondition: the document has callouts")
        assertStill(h, keys: keys, viaKeyEvent: false, "mixed Markdown, at the end")
    }

    // MARK: What a keystroke writes

    /// Independent of the scroller, layout estimates and timing, so CI can always rely on it: a key at the end of the document edits
    /// nothing outside the paragraph it was typed in.
    func testAKeystrokeEditsOnlyItsOwnLine() {
        for source in [false, true] {
            let h = harness(longPlainDocument(), source: source)
            for key in ["a", " ", " "] {
                let edits = h.recordEdits { h.type(key) }
                let text = h.textView.string as NSString
                let paragraph = text.paragraphRange(for: NSRange(location: text.length - 1, length: 0))
                XCTAssertFalse(edits.isEmpty, "precondition: the key is reported")
                for edit in edits {
                    XCTAssertTrue(edit.location >= paragraph.location && NSMaxRange(edit) <= NSMaxRange(paragraph),
                                  "\(source ? "source view" : "formatted editor"), \(key == " " ? "Space" : key): edited \(edit) outside the last paragraph \(paragraph); all edits \(edits)")
                }
            }
        }
    }

    // MARK: What must not change (characterisation)

    func testTheCaretStaysInViewWhileTypingNewLinesAtTheEnd() {
        let h = harness(longPlainDocument(paragraphs: 120))
        for i in 0..<40 {
            h.textView.insertNewline(nil)
            h.type("line \(i)")
            let caret = h.caretRect(), visible = h.textView.visibleRect
            XCTAssertTrue(caret.midY >= visible.minY && caret.midY <= visible.maxY, "line \(i): caret \(caret) is outside the visible \(visible)")
        }
    }

    func testUndoAfterTypingRestoresTextAndLook() throws {
        let original = "# Title\n\nSome **bold** and `code`.\n\n- [ ] a task\n\nlast line"
        let h = harness(original)
        let um = try XCTUnwrap(h.textView.undoManager)
        h.type("abc")
        h.textView.insertNewline(nil)
        h.type("# new heading")
        XCTAssertNotEqual(h.textView.string, original)
        h.textView.breakUndoCoalescing()
        while um.canUndo, h.textView.string != original { um.undo() }
        XCTAssertEqual(h.textView.string, original)
        XCTAssertEqual(h.box.value, original, "the binding follows the undo")
        let fresh = EditorHarness(text: original)
        fresh.select(h.textView.selectedRange().location, h.textView.selectedRange().length)
        XCTAssertTrue(NSAttributedString(attributedString: fresh.storage).isEqual(to: h.storage), "after undo the document looks as if it had just been opened")
    }

    func testMarkedTextIsLeftAloneUntilItIsCommitted() {
        let h = harness(longPlainDocument(paragraphs: 40))
        let end = h.storage.length
        h.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(h.textView.hasMarkedText())
        XCTAssertEqual(h.textView.string.utf16.count, end + 2)
        XCTAssertEqual(h.coordinator.analysis.length, end, "no analysis (or restyle) while text is marked")
        h.textView.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(h.textView.hasMarkedText())
        XCTAssertTrue(h.textView.string.hasSuffix("你") && !h.textView.string.hasSuffix("ni你"), "the committed text replaces the marked text")
        XCTAssertEqual(h.coordinator.analysis.length, h.storage.length, "analysed again once committed")
        XCTAssertEqual(h.textView.markedRange().length, 0)
        XCTAssertEqual(h.box.value, h.textView.string)
    }
}
