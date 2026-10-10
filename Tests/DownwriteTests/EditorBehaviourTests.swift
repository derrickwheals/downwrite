import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

@MainActor
final class EditorBehaviourTests: XCTestCase {
    func testTypingUpdatesBinding() {
        let h = EditorHarness(text: "")
        h.textView.insertText("Hello **world**", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(h.textView.string, "Hello **world**")
        XCTAssertEqual(h.box.value, "Hello **world**")
        XCTAssertEqual(h.coordinator.analysis.length, 15)
    }

    func testExternalTextChangeIsAdopted() {
        let h = EditorHarness(text: "one")
        h.coordinator.update(text: "# two", settings: EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720))
        XCTAssertEqual(h.textView.string, "# two")
        XCTAssertEqual(h.coordinator.analysis.headings.count, 1)
    }

    func testBoldItalicCodeShortcutsThroughResponderChain() {
        let h = EditorHarness(text: "make this strong")
        h.select(5, 4)
        h.textView.dwApplyFormat(FormatCommandBox(.bold))
        XCTAssertEqual(h.textView.string, "make **this** strong")
        h.textView.dwApplyFormat(FormatCommandBox(.bold))
        XCTAssertEqual(h.textView.string, "make this strong")
        h.select(5, 4)
        h.textView.dwApplyFormat(FormatCommandBox(.italic))
        XCTAssertEqual(h.textView.string, "make *this* strong")
        h.textView.dwApplyFormat(FormatCommandBox(.inlineCode))
        XCTAssertEqual(h.textView.string, "make *`this`* strong")
    }

    func testFormattingIsUndoable() {
        let h = EditorHarness(text: "undo me")
        h.window.makeFirstResponder(h.textView)
        h.select(0, 4)
        h.textView.dwApplyFormat(FormatCommandBox(.bold))
        XCTAssertEqual(h.textView.string, "**undo** me")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.textView.string, "undo me")
        h.textView.undoManager?.redo()
        XCTAssertEqual(h.textView.string, "**undo** me")
    }

    func testHeadingShortcutAndToggle() {
        let h = EditorHarness(text: "title")
        h.select(2)
        h.textView.dwApplyFormat(FormatCommandBox(.heading(2)))
        XCTAssertEqual(h.textView.string, "## title")
        XCTAssertEqual(h.coordinator.analysis.headings.first?.level, 2)
        h.textView.dwApplyFormat(FormatCommandBox(.heading(2)))
        XCTAssertEqual(h.textView.string, "title")
    }

    func testReturnContinuesListAndTabIndents() {
        let h = EditorHarness(text: "- one")
        h.select(5)
        h.textView.insertNewline(nil)
        XCTAssertEqual(h.textView.string, "- one\n- ")
        h.textView.insertText("two", replacementRange: h.textView.selectedRange())
        h.textView.insertTab(nil)
        XCTAssertEqual(h.textView.string, "- one\n    - two")
        h.textView.insertBacktab(nil)
        XCTAssertEqual(h.textView.string, "- one\n- two")
        h.textView.insertNewline(nil)
        h.textView.insertNewline(nil)   // empty item exits the list
        XCTAssertEqual(h.textView.string, "- one\n- two\n")
    }

    func testNumberedListContinues() {
        let h = EditorHarness(text: "1. a")
        h.select(4)
        h.textView.insertNewline(nil)
        XCTAssertEqual(h.textView.string, "1. a\n2. ")
    }

    func testReturnInPlainTextFallsBackToNewline() {
        let h = EditorHarness(text: "plain")
        h.select(5)
        h.textView.insertNewline(nil)
        XCTAssertEqual(h.textView.string, "plain\n")
    }

    func testTaskToggle() {
        let h = EditorHarness(text: "- [ ] todo")
        let box = h.coordinator.analysis.taskBoxes[0]
        h.textView.apply(ListEditing.toggleTask(in: h.textView.string, box: box.range))
        XCTAssertEqual(h.textView.string, "- [x] todo")
        XCTAssertNotNil(h.attrs(at: 8)[.strikethroughStyle])
    }

    func testPastingURLOverSelectionMakesLink() {
        let h = EditorHarness(text: "see docs")
        h.select(4, 4)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://example.com/x", forType: .string)
        h.textView.paste(nil)
        XCTAssertEqual(h.textView.string, "see [docs](https://example.com/x)")
    }

    func testPlainPasteStaysPlain() {
        let h = EditorHarness(text: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("**not styled yet**", forType: .string)
        h.textView.paste(nil)
        XCTAssertEqual(h.textView.string, "**not styled yet**")
    }

    func testSmartSubstitutionsAreOff() {
        let h = EditorHarness(text: "")
        XCTAssertFalse(h.textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(h.textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertTrue(h.textView.usesFindBar)
        XCTAssertTrue(h.textView.allowsUndo)
        XCTAssertFalse(h.textView.isRichText)
    }

    func testReadableColumnIsCentred() {
        let h = EditorHarness(text: "x", size: NSSize(width: 1400, height: 700))
        h.textView.setFrameSize(NSSize(width: 1400, height: 700))
        XCTAssertGreaterThan(h.textView.textContainerInset.width, 300)
        h.textView.setFrameSize(NSSize(width: 500, height: 700))
        XCTAssertEqual(h.textView.textContainerInset.width, 30)
    }

    func testHeadingAnchorLinkScrollsAndSlugs() {
        XCTAssertEqual(HeadingAnchor.slug("Hello, World! 2"), "hello-world-2")
        let h = EditorHarness(text: "intro\n\n## Target Heading\n\ntext")
        h.coordinator.open(destination: "#target-heading")
        XCTAssertEqual(h.textView.selectedRange().location, h.index(of: "## Target"))
    }

    func testFindBarCommandReachesTextView() {
        let h = EditorHarness(text: "findable text")
        h.window.makeFirstResponder(h.textView)
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        XCTAssertTrue(h.textView.responds(to: #selector(NSResponder.performTextFinderAction(_:))))
        h.textView.performTextFinderAction(item)
    }

    // MARK: Fenced code blocks

    private func typeBacktick(_ h: EditorHarness) {
        h.textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func testThirdBacktickClosesTheFence() {
        let h = EditorHarness(text: "intro\n\n")
        h.select(7)
        typeBacktick(h); typeBacktick(h)
        XCTAssertEqual(h.textView.string, "intro\n\n``", "two backticks are just backticks")
        typeBacktick(h)
        XCTAssertEqual(h.textView.string, "intro\n\n```\n\n```")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 10, length: 0), "caret stays after the opening fence")
        XCTAssertEqual(h.box.value, "intro\n\n```\n\n```", "the document binding sees it")
        XCTAssertEqual(h.coordinator.analysis.lines[2].kind, .fence)
    }

    func testReturnOnTheFreshFenceStepsIntoTheBody() {
        let h = EditorHarness(text: "")
        typeBacktick(h); typeBacktick(h); typeBacktick(h)
        h.textView.insertText("swift", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.textView.insertNewline(nil)
        XCTAssertEqual(h.textView.string, "```swift\n\n```", "Return must not add another line")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 9, length: 0))
        h.textView.insertText("let x = 1", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(h.textView.string, "```swift\nlet x = 1\n```")
    }

    func testTypingBackticksInsideACodeBlockDoesNotNest() {
        let h = EditorHarness(text: "```\ncode\n")
        h.select(h.textView.string.utf16.count)
        typeBacktick(h); typeBacktick(h); typeBacktick(h)
        XCTAssertEqual(h.textView.string, "```\ncode\n```", "typing ``` inside a block closes it")
    }

    func testBackticksMidSentenceAreUntouched() {
        let h = EditorHarness(text: "use ")
        h.select(4)
        typeBacktick(h); typeBacktick(h); typeBacktick(h)
        XCTAssertEqual(h.textView.string, "use ```")
    }

    func testFenceAutoCloseIsUndoable() {
        let h = EditorHarness(text: "x\n\n")
        h.window.makeFirstResponder(h.textView)
        h.select(3)
        typeBacktick(h); typeBacktick(h); typeBacktick(h)
        XCTAssertEqual(h.textView.string, "x\n\n```\n\n```")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.textView.string, "x\n\n", "one undo takes the whole block back out")
    }
}
