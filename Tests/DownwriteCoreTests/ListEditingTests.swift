import XCTest
@testable import DownwriteCore

final class ListEditingTests: XCTestCase {
    private func ret(_ marked: String) -> String {
        let (t, s) = FormatterTests.parse(marked)
        guard let e = ListEditing.returnKey(in: t, selection: s) else { return "nil" }
        return FormatterTests.render(e.apply(to: t), e.selection)
    }
    private func tab(_ marked: String, outdent: Bool = false) -> String {
        let (t, s) = FormatterTests.parse(marked)
        let e = ListEditing.indent(in: t, selection: s, outdent: outdent)
        return FormatterTests.render(e.apply(to: t), e.selection)
    }

    func testBulletContinues() { XCTAssertEqual(ret("- one|"), "- one\n- |") }
    func testStarAndPlusBulletsKeepTheirMarker() {
        XCTAssertEqual(ret("* one|"), "* one\n* |")
        XCTAssertEqual(ret("+ one|"), "+ one\n+ |")
    }
    func testNumberedIncrements() {
        XCTAssertEqual(ret("1. one|"), "1. one\n2. |")
        XCTAssertEqual(ret("9) nine|"), "9) nine\n10) |")
    }
    func testTaskContinuesUnchecked() { XCTAssertEqual(ret("- [x] done|"), "- [x] done\n- [ ] |") }
    func testEmptyItemExitsList() {
        XCTAssertEqual(ret("- one\n- |"), "- one\n|")
        XCTAssertEqual(ret("1. |"), "|")
    }
    func testEmptyNestedItemOutdents() { XCTAssertEqual(ret("- a\n    - |"), "- a\n- |") }
    func testNestedItemKeepsIndent() { XCTAssertEqual(ret("    - nested|"), "    - nested\n    - |") }
    func testReturnMidItemSplits() { XCTAssertEqual(ret("- ab|cd"), "- ab\n- |cd") }
    func testCaretInsideMarkerFallsBack() { XCTAssertEqual(ret("-| one"), "nil") }
    func testPlainTextFallsBack() { XCTAssertEqual(ret("plain|"), "nil") }
    func testSelectionFallsBack() { XCTAssertEqual(ret("- ‹a›"), "nil") }

    func testQuoteContinuesAndExits() {
        XCTAssertEqual(ret("> quote|"), "> quote\n> |")
        XCTAssertEqual(ret("> a\n> |"), "> a\n|")
    }
    func testQuotedListContinues() { XCTAssertEqual(ret("> - a|"), "> - a\n> - |") }

    func testIndentOutdent() {
        XCTAssertEqual(tab("- a|"), "    - a|")
        XCTAssertEqual(tab("    - a|", outdent: true), "- a|")
        XCTAssertEqual(tab("  - a|", outdent: true), "- a|")
        XCTAssertEqual(tab("\t- a|", outdent: true), "- a|")
        XCTAssertEqual(tab("‹- a\n- b›"), "‹    - a\n    - b›")
        XCTAssertEqual(tab("‹    - a\n    - b›", outdent: true), "‹- a\n- b›")
    }

    func testIsListLine() {
        XCTAssertTrue(ListEditing.isListLine(in: "- a", selection: NSRange(location: 2, length: 0)))
        XCTAssertTrue(ListEditing.isListLine(in: "x\n  3. a", selection: NSRange(location: 6, length: 0)))
        XCTAssertFalse(ListEditing.isListLine(in: "text", selection: NSRange(location: 1, length: 0)))
    }

    func testToggleTask() {
        let t = "- [ ] a\n- [x] b"
        let e1 = ListEditing.toggleTask(in: t, box: NSRange(location: 2, length: 3))
        XCTAssertEqual(e1.apply(to: t), "- [x] a\n- [x] b")
        let e2 = ListEditing.toggleTask(in: t, box: NSRange(location: 10, length: 3))
        XCTAssertEqual(e2.apply(to: t), "- [ ] a\n- [ ] b")
    }

    func testToggleTaskCanKeepTheCaretWhereItWas() {
        let t = "- [ ] a\nline two"
        let keep = NSRange(location: 12, length: 0)
        let e = ListEditing.toggleTask(in: t, box: NSRange(location: 2, length: 3), keeping: keep)
        XCTAssertEqual(e.apply(to: t), "- [x] a\nline two")
        XCTAssertEqual(e.selection, keep, "clicking a drawn checkbox must not move the caret into the hidden prefix")
    }
}
