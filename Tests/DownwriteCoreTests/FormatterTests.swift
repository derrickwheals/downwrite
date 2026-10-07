import XCTest
@testable import DownwriteCore

final class FormatterTests: XCTestCase {
    /// Applies a command to `text` with the selection marked by `‹…›` (or a single `|` caret) and returns the result
    /// in the same notation.
    private func run(_ cmd: FormatCommand, _ marked: String) -> String {
        let (text, sel) = Self.parse(marked)
        guard let edit = Formatter.apply(cmd, to: text, selection: sel) else { return "nil" }
        return Self.render(edit.apply(to: text), edit.selection)
    }

    static func parse(_ s: String) -> (String, NSRange) {
        if let open = s.range(of: "‹"), let close = s.range(of: "›") {
            let text = s.replacingOccurrences(of: "‹", with: "").replacingOccurrences(of: "›", with: "")
            let loc = s[s.startIndex..<open.lowerBound].utf16.count
            let len = s[open.upperBound..<close.lowerBound].utf16.count
            return (text, NSRange(location: loc, length: len))
        }
        let idx = s.range(of: "|")!
        return (s.replacingCharacters(in: idx, with: ""), NSRange(location: s[s.startIndex..<idx.lowerBound].utf16.count, length: 0))
    }

    static func render(_ text: String, _ sel: NSRange) -> String {
        let ns = NSString(string: text)
        if sel.length == 0 { return ns.replacingCharacters(in: sel, with: "|") }
        return ns.substring(to: sel.location) + "‹" + ns.substring(with: sel) + "›" + ns.substring(from: NSMaxRange(sel))
    }

    // MARK: Bold / italic / etc.

    func testBoldWrapsSelection() { XCTAssertEqual(run(.bold, "a ‹word› b"), "a **‹word›** b") }
    func testBoldUnwrapsWhenMarkersOutside() { XCTAssertEqual(run(.bold, "a **‹word›** b"), "a ‹word› b") }
    func testBoldUnwrapsWhenSelectionIncludesMarkers() { XCTAssertEqual(run(.bold, "a ‹**word**› b"), "a ‹word› b") }
    func testBoldCaretInWordWrapsWord() { XCTAssertEqual(run(.bold, "a wo|rd b"), "a **‹word›** b") }
    func testBoldCaretInBoldWordUnwraps() { XCTAssertEqual(run(.bold, "a **wo|rd** b"), "a ‹word› b") }
    func testBoldEmptyCaretInsertsPair() { XCTAssertEqual(run(.bold, "a |"), "a **|**") }
    func testBoldTrimsSurroundingWhitespace() { XCTAssertEqual(run(.bold, "a‹ word ›b"), "a **‹word›** b") }
    func testBoldAcrossMultipleWords() { XCTAssertEqual(run(.bold, "‹two words›"), "**‹two words›**") }

    func testItalicWrapAndUnwrap() {
        XCTAssertEqual(run(.italic, "‹it›"), "*‹it›*")
        XCTAssertEqual(run(.italic, "*‹it›*"), "‹it›")
        XCTAssertEqual(run(.italic, "_‹it›_"), "‹it›")
    }

    func testItalicInsideBoldAddsThirdAsterisk() {
        XCTAssertEqual(run(.italic, "**‹b›**"), "***‹b›***")
        XCTAssertEqual(run(.bold, "***‹b›***"), "*‹b›*")
        XCTAssertEqual(run(.italic, "***‹b›***"), "**‹b›**")
    }

    func testBoldInsideItalic() {
        XCTAssertEqual(run(.bold, "*‹b›*"), "***‹b›***")
    }

    func testStrikeHighlightCode() {
        XCTAssertEqual(run(.strikethrough, "‹x›"), "~~‹x›~~")
        XCTAssertEqual(run(.strikethrough, "~~‹x›~~"), "‹x›")
        XCTAssertEqual(run(.highlight, "‹x›"), "==‹x›==")
        XCTAssertEqual(run(.highlight, "==‹x›=="), "‹x›")
        XCTAssertEqual(run(.inlineCode, "‹x›"), "`‹x›`")
        XCTAssertEqual(run(.inlineCode, "`‹x›`"), "‹x›")
    }

    func testUnicodeSelection() {
        XCTAssertEqual(run(.bold, "😀 ‹世界›"), "😀 **‹世界›**")
        XCTAssertEqual(run(.bold, "😀 **‹世界›**"), "😀 ‹世界›")
    }

    func testToggleRoundTripsForAllInlineCommands() {
        for cmd in [FormatCommand.bold, .italic, .strikethrough, .highlight, .inlineCode] {
            let once = run(cmd, "x ‹hello› y")
            let (t, s) = Self.parse(once)
            let edit = Formatter.apply(cmd, to: t, selection: s)!
            XCTAssertEqual(Self.render(edit.apply(to: t), edit.selection), "x ‹hello› y", "\(cmd)")
        }
    }

    // MARK: Link

    func testLinkWithSelectionSelectsURLPlaceholder() {
        XCTAssertEqual(run(.link, "‹site›"), "[site](‹url›)")
    }
    func testLinkWithURLSelection() { XCTAssertEqual(run(.link, "‹https://a.b›"), "[|](https://a.b)") }
    func testLinkEmptyCaret() { XCTAssertEqual(run(.link, " |"), " [‹text›](url)") }

    // MARK: Headings

    func testHeadingSetsAndToggles() {
        XCTAssertEqual(run(.heading(2), "ti|tle"), "## ti|tle")
        XCTAssertEqual(run(.heading(2), "## ti|tle"), "ti|tle")
        XCTAssertEqual(run(.heading(1), "## ti|tle"), "# ti|tle")
        XCTAssertEqual(run(.body, "### ti|tle"), "ti|tle")
    }
    func testHeadingMultiLine() {
        XCTAssertEqual(run(.heading(3), "‹a\nb›"), "‹### a\n### b›")
    }

    // MARK: Lists, quote, code, hr

    func testBulletToggle() {
        XCTAssertEqual(run(.bulletList, "item|"), "- item|".replacingOccurrences(of: "item|", with: "item|"))
        XCTAssertEqual(run(.bulletList, "- item|"), "item|")
        XCTAssertEqual(run(.bulletList, "‹a\nb›"), "‹- a\n- b›")
        XCTAssertEqual(run(.bulletList, "‹- a\n- b›"), "‹a\nb›")
    }
    func testBulletConvertsFromNumbered() { XCTAssertEqual(run(.bulletList, "‹1. a\n2. b›"), "‹- a\n- b›") }
    func testNumberedList() {
        XCTAssertEqual(run(.numberedList, "‹a\nb\nc›"), "‹1. a\n2. b\n3. c›")
        XCTAssertEqual(run(.numberedList, "‹1. a\n2. b›"), "‹a\nb›")
    }
    func testTaskList() {
        XCTAssertEqual(run(.taskList, "‹a\nb›"), "‹- [ ] a\n- [ ] b›")
        XCTAssertEqual(run(.taskList, "‹- [ ] a\n- [x] b›"), "‹a\nb›")
    }
    func testListPreservesIndentAndBlankLines() {
        XCTAssertEqual(run(.bulletList, "‹  a\n\n  b›"), "‹  - a\n\n  - b›")
    }
    func testBlockQuote() {
        XCTAssertEqual(run(.blockQuote, "a|"), "> a|")
        XCTAssertEqual(run(.blockQuote, "> a|"), "a|")
        XCTAssertEqual(run(.blockQuote, "‹a\nb›"), "‹> a\n> b›")
    }
    func testCodeBlockWrapsLines() {
        XCTAssertEqual(run(.codeBlock, "‹let x = 1›"), "```\n‹let x = 1›\n```")
        XCTAssertEqual(run(.codeBlock, "|"), "```\n|\n```")
    }
    func testHorizontalRule() {
        let (t, s) = Self.parse("para|")
        let e = Formatter.apply(.horizontalRule, to: t, selection: s)!
        XCTAssertEqual(e.apply(to: t), "para\n\n---\n\n")
        let (t2, s2) = Self.parse("|")
        XCTAssertEqual(Formatter.apply(.horizontalRule, to: t2, selection: s2)!.apply(to: t2), "---\n\n")
    }

    func testOutOfRangeSelectionIsClamped() {
        let e = Formatter.apply(.bold, to: "abc", selection: NSRange(location: 99, length: 5))
        XCTAssertEqual(e?.apply(to: "abc"), "**abc**")  // clamped caret sits at the end of the word
    }
}
