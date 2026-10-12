import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Callouts in a real editor (DW-006): the label comes and goes with the caret like every hidden marker, typing and deleting a
/// marker flips a quote between callout and plain on the ordinary re-analysis, and entering a callout is announced.
@MainActor
final class CalloutEditorTests: XCTestCase {
    private let doc = "intro\n\n> [!NOTE] My title\n> body one\n> body two\n\nafter\n"

    private final class Log { var messages: [String] = [] }
    private final class Counter { var value = 0 }

    private func announcements(_ h: EditorHarness) -> Log {
        let log = Log()
        h.coordinator.onAnnouncement = { log.messages.append($0) }
        return log
    }

    /// Each line's attributed text, so a move of the caret can be compared by what it changed.
    private func snapshot(_ h: EditorHarness) -> [NSAttributedString] {
        h.coordinator.analysis.lines.map { h.storage.attributedSubstring(from: $0.range) }
    }

    /// The lines whose look changes when the caret goes from `from` to `to`.
    private func changedLines(_ h: EditorHarness, from: Int, to: Int) -> Set<Int> {
        h.select(from)
        let before = snapshot(h)
        h.select(to)
        let after = snapshot(h)
        return Set(before.indices.filter { !before[$0].isEqual(to: after[$0]) })
    }

    private func typed(_ h: EditorHarness, _ s: String) {
        h.textView.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private var callouts: (EditorHarness) -> [CalloutKind] { { $0.coordinator.analysis.callouts.map(\.kind) } }

    // MARK: Reveal (R9, R10)

    /// A callout adds no restyle path: the lines that change when the caret moves are exactly those of an identical plain quote.
    func testMovingTheCaretRestylesTheSameLinesAsForAPlainQuote() {
        let callout = EditorHarness(text: doc)
        let plain = EditorHarness(text: doc.replacingOccurrences(of: "[!NOTE]", with: "[?NOTE]"))
        XCTAssertEqual(callout.coordinator.analysis.callouts.count, 1)
        XCTAssertEqual(plain.coordinator.analysis.callouts.count, 0)
        let stops = [callout.index(of: "intro"), callout.index(of: "[!NOTE]") + 3, callout.index(of: "My title") + 2,
                     callout.index(of: "body one") + 2, callout.index(of: "body two") + 2, callout.index(of: "after"), 0]
        for (a, b) in zip(stops, stops.dropFirst()) {
            XCTAssertEqual(changedLines(callout, from: a, to: b), changedLines(plain, from: a, to: b), "caret \(a) → \(b)")
        }
        XCTAssertFalse(changedLines(callout, from: stops[3], to: stops[4]).contains(2), "a move between body lines leaves the marker line alone")
        XCTAssertEqual(changedLines(callout, from: stops[3], to: stops[4]), [3, 4], "…and restyles just the line it leaves and the one it enters")
        XCTAssertEqual(changedLines(callout, from: stops[0], to: stops[2]), [2], "entering the marker line restyles that line")
        XCTAssertEqual(changedLines(callout, from: stops[2], to: stops[3]), [2, 3])
    }

    func testMovingTheCaretWithinALineEditsNothing() {
        let h = EditorHarness(text: doc)
        let edits = Counter()
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: h.storage, queue: nil) { _ in
            edits.value += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        h.select(h.index(of: "body one"))
        XCTAssertGreaterThan(edits.value, 0, "precondition: entering a line restyles it")
        for word in ["My title", "body one", "body two"] {
            h.select(h.index(of: word))
            let before = edits.value
            for k in 1..<6 { h.select(h.index(of: word) + k) }
            h.select(h.index(of: word) + 2, 3)
            XCTAssertEqual(edits.value, before, "moving inside \"\(word)\" touches no attribute")
        }
    }

    func testMovingTheCaretNeverChangesTheTextTheBindingOrTheUndoHistory() throws {
        let h = EditorHarness(text: doc)
        let um = try XCTUnwrap(h.textView.undoManager)
        for stop in [0, h.index(of: "[!NOTE]") + 3, h.index(of: "body one") + 2, h.index(of: "after"), h.index(of: "My title"), 5] {
            h.select(stop)
        }
        h.select(h.index(of: "[!NOTE]"), 30)
        XCTAssertEqual(h.textView.string, doc)
        XCTAssertEqual(h.box.value, doc, "the binding that feeds the file is untouched")
        XCTAssertFalse(um.canUndo)
        XCTAssertFalse(um.canRedo)
    }

    func testArrowKeysShowAndHideTheLabelLikeAnyMarker() {
        let h = EditorHarness(text: doc)
        let marker = h.index(of: "[!NOTE]")
        h.select(h.index(of: "intro"))
        XCTAssertNotNil(h.attrs(at: marker)[.dwCallout])
        h.textView.moveDown(nil)                              // the blank line
        XCTAssertNotNil(h.attrs(at: marker)[.dwCallout])
        h.textView.moveDown(nil)                              // the marker line
        XCTAssertNil(h.attrs(at: marker)[.dwCallout], "the caret is on the marker line: the literal text shows")
        XCTAssertFalse(h.isHidden(at: marker))
        h.textView.moveDown(nil)                              // the first body line
        XCTAssertNotNil(h.attrs(at: marker)[.dwCallout], "…and the label returns")
        XCTAssertTrue(h.isHidden(at: marker + 1))
    }

    // MARK: Typing and deleting a marker (R11)

    func testTypingAFirstBodyCharacterMakesAQuoteACalloutAndBreakingTheMarkerUndoesIt() throws {
        let h = EditorHarness(text: "intro\n\n> [!NOTE]\n\nafter\n")
        XCTAssertEqual(callouts(h), [], "a marker alone is a plain quote")
        h.select(h.index(of: "[!NOTE]") + 7)
        h.textView.insertNewline(nil)
        XCTAssertEqual(h.textView.string, "intro\n\n> [!NOTE]\n> \n\nafter\n", "Return continues the quote")
        XCTAssertEqual(callouts(h), [], "an empty continuation line is not a body")
        typed(h, "x")
        XCTAssertEqual(callouts(h), [.note], "the first body character makes it a callout")
        h.select(0)
        let marker = h.index(of: "[!NOTE]")
        XCTAssertNotNil(h.attrs(at: marker)[.dwCallout])
        XCTAssertNotNil(h.attrs(at: h.index(of: "x"))[.dwCalloutBar])

        h.select(h.index(of: "!NOTE") + 1)                    // delete the "!"
        h.textView.deleteBackward(nil)
        XCTAssertEqual(h.textView.string, "intro\n\n> [NOTE]\n> x\n\nafter\n")
        XCTAssertEqual(callouts(h), [])
        h.select(0)
        XCTAssertNil(h.attrs(at: h.index(of: "[NOTE]"))[.dwCallout], "no label")
        XCTAssertNil(h.attrs(at: h.index(of: "x"))[.dwCalloutBar], "no callout colour")
        XCTAssertEqual(h.attrs(at: h.index(of: "x"))[.dwQuoteDepth] as? Int, 1, "it is still a quote")
        XCTAssertFalse(h.isHidden(at: h.index(of: "[NOTE]")), "the text shows as it is")

        h.select(h.index(of: "NOTE]"))                        // type the "!" back
        typed(h, "!")
        XCTAssertEqual(callouts(h), [.note])
        h.select(0)
        XCTAssertNotNil(h.attrs(at: h.index(of: "[!NOTE]"))[.dwCallout])

        // Changing a letter of the name turns it into a plain quote too.
        let n = h.index(of: "NOTE]")
        h.textView.setSelectedRange(NSRange(location: n, length: 1))
        typed(h, "X")
        XCTAssertEqual(h.textView.string, "intro\n\n> [!XOTE]\n> x\n\nafter\n")
        XCTAssertEqual(callouts(h), [])
    }

    func testTypingTheTitleAfterTheMarkerKeepsItACalloutWithThatTitle() throws {
        let h = EditorHarness(text: "> [!WARNING]\n")
        XCTAssertEqual(callouts(h), [])
        h.select(h.textView.string.utf16.count - 1)
        typed(h, " Data loss")
        XCTAssertEqual(callouts(h), [.warning], "a title alone is enough")
        let c = try XCTUnwrap(h.coordinator.analysis.callouts.first)
        XCTAssertEqual(NSString(string: h.textView.string).substring(with: try XCTUnwrap(c.titleRange)), "Data loss")
    }

    func testReturnAtTheEndOfTheMarkerLineContinuesTheQuote() {
        let h = EditorHarness(text: "> [!NOTE] Title\n> body\n")
        h.select(h.index(of: "Title") + 5)
        h.textView.insertNewline(nil)
        XCTAssertEqual(h.textView.string, "> [!NOTE] Title\n> \n> body\n", "the new line starts with `> `, as in any quote")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: "> [!NOTE] Title\n> ".utf16.count, length: 0))
        XCTAssertEqual(callouts(h), [.note])
    }

    // MARK: The announcement (R14)

    func testEnteringACalloutIsAnnouncedOnceAndNamesItsKind() {
        let text = "intro\n\n> [!NOTE] A\n> a1\n> a2\n\nmid\n\n> [!TIP]\n> t1\n\nend\n"
        let h = EditorHarness(text: text)
        let log = announcements(h)
        h.select(h.index(of: "intro"))
        XCTAssertEqual(log.messages, [], "outside every callout")
        h.select(h.index(of: "a1") + 1)
        XCTAssertEqual(log.messages, ["Note callout"], "the type's name and \"callout\", not the title")
        h.select(h.index(of: "a2"))
        h.select(h.index(of: "[!NOTE]") + 2)
        h.select(h.index(of: "a1"))
        XCTAssertEqual(log.messages, ["Note callout"], "not repeated while the caret stays in the same callout")
        h.select(h.index(of: "mid"))
        XCTAssertEqual(log.messages, ["Note callout"], "leaving announces nothing")
        h.select(h.index(of: "t1"))
        XCTAssertEqual(log.messages, ["Note callout", "Tip callout"])
        h.select(h.index(of: "end"))
        h.select(h.index(of: "t1"))
        XCTAssertEqual(log.messages, ["Note callout", "Tip callout", "Tip callout"], "out and back in is announced again")
        h.select(h.index(of: "a1"))
        XCTAssertEqual(log.messages.last, "Note callout", "from one callout straight into another")
        XCTAssertEqual(log.messages.count, 4)
    }

    func testASelectionThatTouchesACalloutAnnouncesTheFirstOne() {
        let text = "intro\n\n> [!NOTE]\n> a\n\nmid\n\n> [!CAUTION]\n> c\n\nend\n"
        let h = EditorHarness(text: text)
        let log = announcements(h)
        h.select(h.index(of: "mid"))
        h.select(h.index(of: "[!NOTE]"), h.index(of: "end") - h.index(of: "[!NOTE]"))
        XCTAssertEqual(log.messages, ["Note callout"])
    }

    func testNothingIsAnnouncedWhileTypingUndoingOrReloading() throws {
        let h = EditorHarness(text: "intro\n\n> [!NOTE]\n\nend\n")
        let log = announcements(h)
        h.select(h.index(of: "[!NOTE]") + 7)
        h.textView.insertNewline(nil)
        typed(h, "x")
        XCTAssertEqual(callouts(h), [.note])
        XCTAssertEqual(log.messages, [], "a callout you just typed, with the caret in it, is not announced")
        let um = try XCTUnwrap(h.textView.undoManager)
        um.undo()
        um.redo()
        XCTAssertEqual(log.messages, [], "undo and redo are silent")
        // The file changed underneath the editor: the caret stays where it was, now inside a different callout.
        let caret = h.textView.selectedRange().location
        let reloaded = "intro\n\n> [!TIP] new title that is long\n> and a body\n\nend\n"
        XCTAssertLessThan(caret, reloaded.utf16.count)
        h.coordinator.update(text: reloaded, settings: EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720))
        XCTAssertEqual(callouts(h), [.tip])
        XCTAssertEqual(log.messages, [], "an external reload is silent")
        // …but once the caret leaves and comes back, it is announced.
        h.select(h.index(of: "end"))
        h.select(h.index(of: "body"))
        XCTAssertEqual(log.messages, ["Tip callout"])
    }

    func testNothingIsAnnouncedInTheSourceView() {
        let text = "intro\n\n> [!NOTE]\n> a\n\nend\n"
        let h = EditorHarness(text: text)
        let log = announcements(h)
        h.coordinator.setSourceMode(true)
        h.select(h.index(of: "a"))
        h.select(h.index(of: "end"))
        h.select(h.index(of: "[!NOTE]") + 2)
        XCTAssertEqual(log.messages, [], "the source view is plain text")
        h.coordinator.setSourceMode(false)
        XCTAssertEqual(log.messages, [], "coming back with the caret inside is silent too")
        h.select(h.index(of: "end"))
        h.select(h.index(of: "a"))
        XCTAssertEqual(log.messages, ["Note callout"], "the formatted editor announces again")
    }
}
