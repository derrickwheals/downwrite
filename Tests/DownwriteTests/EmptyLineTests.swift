import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// A line whose every character is hidden Markdown syntax (an empty heading, a bare `>`) used to collapse to a sliver,
/// because hidden characters are ~zero-size. It must keep the height and baseline of a line with text.
@MainActor
final class EmptyLineTests: XCTestCase {
    private func metrics(_ h: EditorHarness, at index: Int) -> (height: CGFloat, width: CGFloat, baseline: CGFloat, top: CGFloat) {
        let layout = h.textView.layoutManager!
        let glyph = layout.glyphIndexForCharacter(at: index)
        let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return (used.height, used.width, layout.location(forGlyphAt: glyph).y, layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
    }

    private func assertSame(_ empty: EditorHarness, _ full: EditorHarness, at index: Int, after: String? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
        let e = metrics(empty, at: index), f = metrics(full, at: index)
        XCTAssertGreaterThan(e.height, 15, "the line is not a sliver", file: file, line: line)
        XCTAssertEqual(e.height, f.height, accuracy: 1.0, "same height as the line with text", file: file, line: line)
        XCTAssertEqual(e.baseline, f.baseline, accuracy: 1.0, "same baseline", file: file, line: line)
        XCTAssertEqual(e.top, f.top, accuracy: 1.0, "starts where it does with text", file: file, line: line)
        XCTAssertLessThan(e.width, 3, "and takes no horizontal room (its characters are invisible)", file: file, line: line)
        if let after {
            XCTAssertEqual(metrics(empty, at: empty.index(of: after)).top, metrics(full, at: full.index(of: after)).top, accuracy: 1.0,
                           "everything below sits where it does with a titled heading", file: file, line: line)
        }
    }

    func testEmptyHeadingKeepsAHeadingSizedLine() {
        let empty = EditorHarness(text: "intro\n\n# \n\nafter\n"), full = EditorHarness(text: "intro\n\n# Title\n\nafter\n")
        empty.select(empty.textView.string.utf16.count); full.select(full.textView.string.utf16.count)
        XCTAssertEqual(empty.color(at: 7), NSColor.clear, "the # is not shown")
        assertSame(empty, full, at: 7, after: "after")
    }

    func testEmptyHeadingAtTheEndOfTheDocument() {
        let empty = EditorHarness(text: "intro\n\n# "), full = EditorHarness(text: "intro\n\n# Title")
        empty.select(0); full.select(0)
        assertSame(empty, full, at: 7)
    }

    func testEmptyHeadingLevels() {
        for level in 1...3 {
            let marks = String(repeating: "#", count: level)
            let empty = EditorHarness(text: "intro\n\n\(marks) \n\nafter\n"), full = EditorHarness(text: "intro\n\n\(marks) Title\n\nafter\n")
            empty.select(0); full.select(0)
            assertSame(empty, full, at: 7, after: "after")
        }
    }

    func testBareQuoteMarkerKeepsItsLine() {
        let empty = EditorHarness(text: "> one\n>\n> two\n"), full = EditorHarness(text: "> one\n> mid\n> two\n")
        empty.select(empty.textView.string.utf16.count); full.select(full.textView.string.utf16.count)
        assertSame(empty, full, at: 6, after: "two")
    }

    func testTheMarkerShowsWhileTheCaretIsOnTheEmptyHeading() {
        let h = EditorHarness(text: "intro\n\n# \n\nafter\n")
        h.select(9)                                          // end of the "# " line
        XCTAssertNotEqual(h.color(at: 7), NSColor.clear, "with the caret there the # is shown")
        XCTAssertFalse(h.isHidden(at: 7))
        let m = metrics(h, at: 7)
        XCTAssertGreaterThan(m.height, 15)
    }
}
