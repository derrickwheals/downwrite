import XCTest
@testable import DownwriteCore

final class FenceEditingTests: XCTestCase {
    /// Types a backtick at the `|` caret in `marked` and returns the result in the same notation, or "nil" when the
    /// keystroke is not intercepted.
    private func type(_ marked: String) -> String {
        let (text, sel) = FormatterTests.parse(marked)
        guard let e = FenceEditing.autoCloseEdit(typing: "`", in: text, selection: sel) else { return "nil" }
        return FormatterTests.render(e.apply(to: text), e.selection)
    }

    private func ret(_ marked: String) -> String {
        let (text, sel) = FormatterTests.parse(marked)
        guard let e = FenceEditing.returnEdit(in: text, selection: sel) else { return "nil" }
        return FormatterTests.render(e.apply(to: text), e.selection)
    }

    // MARK: Auto-close

    func testThirdBacktickAtStartOfDocumentClosesTheFence() {
        XCTAssertEqual(type("``|"), "```|\n\n```")
    }

    func testWorksOnLaterLinesAndKeepsTheRestOfTheDocument() {
        XCTAssertEqual(type("intro\n\n``|\n\nafter"), "intro\n\n```|\n\n```\n\nafter")
    }

    func testIndentationIsRepeatedOnTheBodyAndClosingFence() {
        XCTAssertEqual(type("- item\n  ``|"), "- item\n  ```|\n  \n  ```")
    }

    func testOnlyAfterTwoBackticks() {
        XCTAssertEqual(type("`|"), "nil")
        XCTAssertEqual(type("|"), "nil")
        XCTAssertEqual(type("```|"), "nil")          // a fourth backtick is just a backtick
    }

    func testNotInTheMiddleOfAProseLine() {
        XCTAssertEqual(type("some text ``|"), "nil")
        XCTAssertEqual(type("a``|"), "nil")
    }

    func testNotWhenTextFollowsTheCaret() {
        XCTAssertEqual(type("``|x"), "nil")
        XCTAssertEqual(type("``|x "), "nil")
    }

    func testStraySpacesAfterTheCaretAreAbsorbed() {
        XCTAssertEqual(type("``|  "), "```|\n\n```")
    }

    func testNotInsideAnOpenCodeBlock() {
        // Typing ``` inside a block is how you close it; it must not start another one.
        XCTAssertEqual(type("```swift\nlet x = 1\n``|"), "nil")
        XCTAssertEqual(type("~~~\ncode\n``|"), "nil")
    }

    func testAfterAClosedBlockItIsActiveAgain() {
        XCTAssertEqual(type("```\ncode\n```\n\n``|"), "```\ncode\n```\n\n```|\n\n```")
    }

    func testNotForOtherCharactersOrSelections() {
        let (t1, s1) = FormatterTests.parse("``|")
        XCTAssertNil(FenceEditing.autoCloseEdit(typing: "a", in: t1, selection: s1))
        XCTAssertNil(FenceEditing.autoCloseEdit(typing: "``", in: t1, selection: s1))
        let (t2, s2) = FormatterTests.parse("‹``›")
        XCTAssertNil(FenceEditing.autoCloseEdit(typing: "`", in: t2, selection: s2))
    }

    func testResultIsAValidFencedBlock() {
        let (text, sel) = FormatterTests.parse("para\n\n``|")
        let e = FenceEditing.autoCloseEdit(typing: "`", in: text, selection: sel)!
        let a = MarkdownAnalyzer.analyze(e.apply(to: text))
        XCTAssertEqual(a.lines[2].kind, .fence)
        XCTAssertEqual(a.lines[3].kind, .codeBlock)
        XCTAssertEqual(a.lines[4].kind, .fence)
    }

    func testUnicodeBeforeTheFence() {
        XCTAssertEqual(type("世界 😀\n\n``|"), "世界 😀\n\n```|\n\n```")
    }

    // MARK: Return

    func testReturnOnAFreshFenceStepsIntoTheEmptyBody() {
        XCTAssertEqual(ret("```|\n\n```"), "```\n|\n```")
    }

    func testReturnAfterAnInfoStringStepsIntoTheBody() {
        XCTAssertEqual(ret("```swift|\n\n```"), "```swift\n|\n```")
    }

    func testReturnKeepsIndentation() {
        XCTAssertEqual(ret("- item\n  ```|\n  \n  ```"), "- item\n  ```\n  |\n  ```")
    }

    func testReturnIsLeftAloneWhenTheBodyHasCode() {
        XCTAssertEqual(ret("```|\nlet x\n```"), "nil")
    }

    func testReturnIsLeftAloneWhenThereIsNoClosingFence() {
        XCTAssertEqual(ret("```|\n\nprose"), "nil")
        XCTAssertEqual(ret("```|"), "nil")
    }

    func testReturnIsLeftAloneWhenTheCaretIsNotAtTheEndOfTheFenceLine() {
        XCTAssertEqual(ret("`|``\n\n```"), "nil")
        XCTAssertEqual(ret("plain|\n\n```"), "nil")
    }

    func testReturnInsideTheBodyOrOnTheClosingFenceIsLeftAlone() {
        XCTAssertEqual(ret("```\n|\n```"), "nil")
        XCTAssertEqual(ret("```\n\n```|"), "nil")
    }
}
