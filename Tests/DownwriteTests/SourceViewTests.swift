import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// The source view shows the raw Markdown like a plain text editor: one monospaced style, nothing hidden, and none of
/// the things the formatted editor draws (table grids, diagram and image cards, checkboxes, pills, cards, bars).
@MainActor
final class SourceViewTests: XCTestCase {
    private let sample = """
    # Title

    Some **bold** and `code` and ==marked== text with a [link](https://example.com).

    > a quote

    - [ ] todo
    - [x] done

    | a | b |
    | - | - |
    | 1 | 2 |

    ```swift
    let x = 1
    ```

    ```mermaid
    graph TD; A-->B
    ```

    ---

    ![alt](missing.png)

    """

    private func fullRange(_ h: EditorHarness) -> NSRange { NSRange(location: 0, length: h.textView.string.utf16.count) }

    private func attributeRuns(_ h: EditorHarness) -> [[NSAttributedString.Key: Any]] {
        var runs: [[NSAttributedString.Key: Any]] = []
        h.storage.enumerateAttributes(in: fullRange(h), options: []) { attrs, _, _ in runs.append(attrs) }
        return runs
    }

    func testTheFormattedEditorStartsWithTheSourceHidden() {
        let h = EditorHarness(text: sample)
        h.select(0)
        XCTAssertFalse(h.coordinator.sourceMode)
        XCTAssertTrue(h.isHidden(at: h.index(of: "**bold**")), "the ** are hidden in the formatted editor")
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 1)
        XCTAssertNotNil(h.attrs(at: h.index(of: "- [ ] todo"))[.dwCheckbox])
    }

    func testSourceViewIsOnePlainMonospacedStyleWithNothingHidden() throws {
        let h = EditorHarness(text: sample)
        h.select(0)
        h.coordinator.setSourceMode(true)
        XCTAssertTrue(h.coordinator.sourceMode)
        XCTAssertEqual(h.textView.string, sample, "the text is untouched")
        let runs = attributeRuns(h)
        XCTAssertEqual(runs.count, 1, "the whole document is a single plain style")
        let attrs = try XCTUnwrap(runs.first)
        let font = try XCTUnwrap(attrs[.font] as? NSFont)
        XCTAssertTrue(font.isFixedPitch, "monospaced")
        XCTAssertGreaterThan(font.pointSize, 10, "nothing is shrunk to hide it")
        let palette = AppearanceResolver.palette(for: h.textView.effectiveAppearance)
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, palette.text.nsColor)
        for key in [NSAttributedString.Key.dwBlockBackground, .dwPill, .dwCheckbox, .dwQuoteDepth, .dwRule, .dwBullet, .kern,
                    .strikethroughStyle, .underlineStyle, .backgroundColor] {
            XCTAssertNil(attrs[key], "\(key.rawValue) is not used in the source view")
        }
    }

    func testSourceViewHasNoGridsCardsOrCheckboxes() {
        let h = EditorHarness(text: sample)
        h.select(0)
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 1)
        h.coordinator.setSourceMode(true)
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 0, "tables are plain Markdown")
        XCTAssertFalse(h.textView.subviews.contains { $0 is TableGridView }, "no grid views left behind")
        XCTAssertFalse(h.textView.subviews.contains { $0 is DiagramView }, "no diagram or image cards")
        // Every line has its normal height: no collapsed lines for tables, fences or diagram sources.
        let layout = h.textView.layoutManager!
        layout.ensureLayout(for: h.textView.textContainer!)
        var shortest = CGFloat.greatestFiniteMagnitude
        for line in h.coordinator.analysis.lines where line.contentEnd > line.range.location {
            let used = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: line.range.location), effectiveRange: nil)
            shortest = min(shortest, used.height)
        }
        XCTAssertGreaterThan(shortest, 15, "no line is collapsed")
    }

    func testSwitchingKeepsTheCaretAndRestoresTheFormattedLook() {
        let h = EditorHarness(text: sample)
        let selection = NSRange(location: h.index(of: "bold"), length: 4)
        h.select(selection.location, selection.length)
        h.coordinator.setSourceMode(true)
        XCTAssertEqual(h.textView.selectedRange(), selection, "same selection in the source view")
        h.coordinator.setSourceMode(false)
        XCTAssertEqual(h.textView.selectedRange(), selection)
        XCTAssertEqual(h.textView.string, sample)
        h.select(0)
        XCTAssertTrue(h.isHidden(at: h.index(of: "**bold**")), "markers hide again")
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 1, "the table grid is back")
        XCTAssertNotNil(h.attrs(at: h.index(of: "- [ ] todo"))[.dwCheckbox], "…and the checkboxes")
        XCTAssertNotNil(h.attrs(at: h.index(of: "code") )[.dwPill], "…and the inline code pill")
    }

    func testTypingInTheSourceViewStaysPlainAndTheOutlineStillUpdates() throws {
        let h = EditorHarness(text: "# One\n\n")
        h.coordinator.setSourceMode(true)
        h.select(h.textView.string.utf16.count)
        h.textView.insertText("## Two\n\nSome **raw** text", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(h.textView.string, "# One\n\n## Two\n\nSome **raw** text")
        XCTAssertEqual(attributeRuns(h).count, 1, "what you type is styled like everything else")
        h.select(0)                                           // caret elsewhere: still nothing hidden
        XCTAssertFalse(h.isHidden(at: h.index(of: "**raw**")))
        XCTAssertEqual(h.coordinator.analysis.headings.map(\.plainTitle), ["One", "Two"], "the table of contents keeps working")
        let font = try XCTUnwrap(h.attrs(at: 0)[.font] as? NSFont)
        XCTAssertEqual((h.attrs(at: h.index(of: "raw"))[.font] as? NSFont)?.pointSize, font.pointSize)
    }

    func testClickingATaskBoxDoesNotToggleInTheSourceView() throws {
        let h = EditorHarness(text: "- [ ] todo\n")
        h.select(h.textView.string.utf16.count)
        var r = try XCTUnwrap((h.textView.layoutManager as? DWLayoutManager)?.checkboxRect(forCharacterAt: 0))
        r.origin.x += h.textView.textContainerOrigin.x; r.origin.y += h.textView.textContainerOrigin.y
        let point = NSPoint(x: r.midX, y: r.midY)
        XCTAssertNotNil(h.textView.taskBox(at: point), "a click here ticks the box in the formatted editor")
        h.coordinator.setSourceMode(true)
        XCTAssertNil(h.textView.taskBox(at: point), "…but in the source view it is just text")
    }

    func testFormattingCommandsStillWorkOnTheRawText() {
        let h = EditorHarness(text: "make bold")
        h.coordinator.setSourceMode(true)
        h.select(5, 4)
        h.textView.dwApplyFormat(FormatCommandBox(.bold))
        XCTAssertEqual(h.textView.string, "make **bold**")
        XCTAssertEqual(attributeRuns(h).count, 1)
    }

    func testAKeyboardFocusedGridHandsTheKeyboardBackToTheEditor() {
        let h = EditorHarness(text: "| a | b |\n| - | - |\n| 1 | 2 |\n\nend\n")
        h.window.makeKeyAndOrderFront(nil)
        h.select(h.textView.string.utf16.count)
        let grid = h.coordinator.tableOverlay.grids.first
        XCTAssertNotNil(grid)
        grid?.focus(TableCellPosition(row: 1, column: 0), atEnd: true)
        XCTAssertTrue(h.coordinator.tableOverlay.hasFocus)
        h.coordinator.setSourceMode(true)
        XCTAssertTrue(h.window.firstResponder === h.textView, "the editor has the keyboard again")
        XCTAssertEqual(h.coordinator.tableOverlay.grids.count, 0)
    }

    func testSourceViewFollowsTheThemeAndFontSize() throws {
        let dark = EditorHarness(text: sample, dark: true)
        dark.coordinator.setSourceMode(true)
        let attrs = try XCTUnwrap(attributeRuns(dark).first)
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, Palette.palette(for: .dark).text.nsColor)
        XCTAssertEqual(dark.textView.backgroundColor, Palette.palette(for: .dark).background.nsColor)
    }

    func testEachWindowHasItsOwnSourceSwitch() {
        let a = EditorHarness(text: sample), b = EditorHarness(text: sample)
        a.coordinator.setSourceMode(true)
        XCTAssertTrue(a.coordinator.sourceMode)
        XCTAssertFalse(b.coordinator.sourceMode)
        b.select(0)
        XCTAssertTrue(b.isHidden(at: b.index(of: "**bold**")), "the other window is still formatted")
        XCTAssertEqual(b.coordinator.tableOverlay.grids.count, 1)
    }
}
