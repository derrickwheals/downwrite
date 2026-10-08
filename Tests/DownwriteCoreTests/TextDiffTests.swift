import XCTest
@testable import DownwriteCore

final class TextDiffTests: XCTestCase {
    private func roundTrip(_ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) throws -> TextEdit {
        let edit = try XCTUnwrap(TextDiff.replacement(from: old, to: new), file: file, line: line)
        XCTAssertEqual(edit.apply(to: old), new, "applying the edit to the old text gives the new text", file: file, line: line)
        return edit
    }

    func testEqualTextsNeedNoEdit() {
        XCTAssertNil(TextDiff.replacement(from: "same", to: "same"))
        XCTAssertNil(TextDiff.replacement(from: "", to: ""))
    }

    func testInsertionInTheMiddle() throws {
        let e = try roundTrip("hello world", "hello brave world")
        XCTAssertEqual(e.range, NSRange(location: 6, length: 0))
        XCTAssertEqual(e.replacement, "brave ")
    }

    func testDeletion() throws {
        let e = try roundTrip("one two three", "one three")
        XCTAssertEqual(e.range.length, 4)
        XCTAssertEqual(e.replacement, "")
    }

    func testReplacementKeepsTheCommonEnds() throws {
        let e = try roundTrip("# Title\n\nOld paragraph.\n\nEnd\n", "# Title\n\nNew paragraph.\n\nEnd\n")
        XCTAssertEqual(e.range, NSRange(location: 9, length: 3))
        XCTAssertEqual(e.replacement, "New")
    }

    func testAppendAndPrepend() throws {
        let appended = try roundTrip("abc", "abcdef")
        XCTAssertEqual(appended.range, NSRange(location: 3, length: 0))
        let prepended = try roundTrip("abc", "xyzabc")
        XCTAssertEqual(prepended.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(prepended.replacement, "xyz")
    }

    func testFromAndToEmpty() throws {
        _ = try roundTrip("", "new document")
        let e = try roundTrip("everything goes", "")
        XCTAssertEqual(e.range, NSRange(location: 0, length: 15))
    }

    func testPrefixAndSuffixNeverOverlap() throws {
        _ = try roundTrip("aaa", "aa")
        _ = try roundTrip("aa", "aaa")
        _ = try roundTrip("abab", "ab")
        _ = try roundTrip("abcabc", "abcabcabc")
    }

    func testASurrogatePairIsNeverSplit() throws {
        // 😀 U+1F600 and 😁 U+1F601 share their high surrogate.
        let e = try roundTrip("a😀b", "a😁b")
        XCTAssertEqual(e.range, NSRange(location: 1, length: 2), "the whole emoji is replaced")
        XCTAssertEqual(e.replacement, "😁")
        // …and the same when only the low surrogate's neighbour is shared at the end.
        _ = try roundTrip("😀", "x😀")
        _ = try roundTrip("😀😀", "😀")
        _ = try roundTrip("é😀é", "é😁é")
    }

    func testLargeDocumentsStayFast() throws {
        let body = String(repeating: "A line of text that is not very interesting.\n", count: 20_000)
        let edited = body.replacingOccurrences(of: "line of text", with: "LINE OF TEXT", options: [], range: body.range(of: "line of text", range: body.index(body.startIndex, offsetBy: 500_000)..<body.endIndex))
        let start = Date()
        let e = try roundTrip(body, edited)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertEqual(e.range.length, 12)
    }

    // MARK: Mapping the selection

    func testSelectionBeforeTheEditStaysPut() throws {
        let e = try roundTrip("hello world", "hello brave world")
        XCTAssertEqual(TextDiff.map(NSRange(location: 2, length: 0), through: e), NSRange(location: 2, length: 0))
        XCTAssertEqual(TextDiff.map(NSRange(location: 6, length: 0), through: e), NSRange(location: 6, length: 0), "a caret right at an insertion stays before it")
        XCTAssertEqual(TextDiff.map(NSRange(location: 1, length: 4), through: e), NSRange(location: 1, length: 4))
    }

    func testSelectionAfterTheEditMovesByTheChangeInLength() throws {
        let grown = try roundTrip("hello world", "hello brave world")
        XCTAssertEqual(TextDiff.map(NSRange(location: 8, length: 0), through: grown), NSRange(location: 14, length: 0))
        let shrunk = try roundTrip("alpha beta gamma", "alpha gamma")
        XCTAssertEqual(shrunk.range, NSRange(location: 6, length: 5))
        XCTAssertEqual(TextDiff.map(NSRange(location: 16, length: 0), through: shrunk), NSRange(location: 11, length: 0))
        XCTAssertEqual(TextDiff.map(NSRange(location: 11, length: 5), through: shrunk), NSRange(location: 6, length: 5))
    }

    func testSelectionInsideTheReplacedTextKeepsItsDistanceFromTheStart() throws {
        let e = try roundTrip("start OLDWORD end", "start NEWERWORD end")
        // The edit replaces "OLD" with "NEWER"; a caret two characters into the old text stays two characters in.
        XCTAssertEqual(TextDiff.map(NSRange(location: e.range.location + 2, length: 0), through: e), NSRange(location: e.range.location + 2, length: 0))
        // …and is clamped to the end of the new text when the replacement is shorter.
        let shorter = try roundTrip("start LONGERWORD end", "start LWORD end")
        XCTAssertEqual(TextDiff.map(NSRange(location: shorter.range.location + 5, length: 0), through: shorter),
                       NSRange(location: shorter.range.location + shorter.replacement.utf16.count, length: 0))
    }

    func testSelectionNeverEndsUpBeyondTheNewText() throws {
        let e = try roundTrip("a long old document", "short")
        let mapped = TextDiff.map(NSRange(location: 19, length: 0), through: e)
        XCTAssertLessThanOrEqual(NSMaxRange(mapped), "short".utf16.count)
    }
}
