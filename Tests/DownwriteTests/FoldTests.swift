import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Folding in the app: what hidden lines look like, how the coordinator and overlays follow the fold state, caret policy,
/// edit guards and speed. The Markdown-level rules (regions, `FoldState`) are tested in `DownwriteCoreTests/FoldingTests`.
@MainActor
final class FoldTests: XCTestCase {
    // MARK: Fixture

    /// Fixture F, shared with the Core tests and the end-to-end step (`Tests/Fixtures/fold-demo.md`, no trailing newline).
    static func fixtureF(file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fold-demo.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Thin collapse (R5)

    /// A real editor holding `Header`, `hiddenLines` lines (text and blank lines mixed) and `Footer`, with the hidden lines
    /// collapsed to `lineHeight`. Returns the laid-out document height and the heights of the hidden lines' fragments.
    private func measure(hiddenLines n: Int, lineHeight: CGFloat) -> (height: CGFloat, hiddenFragments: [CGFloat]) {
        let header = "Header\n"
        var hidden = ""
        for i in 0..<n { hidden += i % 3 == 2 ? "\n" : "hidden text line \(i)\n" }
        let h = EditorHarness(text: header + hidden + "Footer")
        h.select(h.textView.string.utf16.count)
        let range = NSRange(location: header.utf16.count, length: hidden.utf16.count)
        if range.length > 0 {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = lineHeight
            p.maximumLineHeight = lineHeight
            h.storage.beginEditing()
            h.storage.setAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear, .paragraphStyle: p], range: range)
            h.storage.endEditing()
        }
        let lm = h.textView.layoutManager!
        let container = h.textView.textContainer!
        lm.ensureLayout(for: container)
        var fragments: [CGFloat] = []
        if range.length > 0 {
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                fragments.append(rect.height)
            }
        }
        return (lm.usedRect(for: container).height, fragments)
    }

    /// R5: the room left by hidden lines is at most 1 pt per 1,000 lines. Measured in the real editor (plan step 1):
    /// 0.1 pt per line leaves 10 pt for 100 lines and 100 pt for 1,000; 0.01 pt leaves 1 and 10; 0.001 pt leaves 0.1 and 1.
    func testThinCollapseLeavesAtMostOnePointPerThousandLines() {
        let thin = MarkdownStyler.foldedLineHeight
        let base = measure(hiddenLines: 0, lineHeight: thin).height
        for (count, allowed) in [(100, 0.1), (1000, 1.0)] as [(Int, CGFloat)] {
            let m = measure(hiddenLines: count, lineHeight: thin)
            XCTAssertEqual(m.hiddenFragments.count, count, "one line fragment per hidden line")
            XCTAssertLessThanOrEqual(m.height - base, allowed + 0.001, "\(count) hidden lines leave \(m.height - base) pt")
            // The layout manager's card and bar drawing skip fragments of 1 pt or less (`lineRect.height > 1`).
            XCTAssertTrue(m.hiddenFragments.allSatisfy { $0 < 1 }, "hidden fragments stay below the 1 pt drawing filter")
        }
        // The line height used for collapsed sources, by contrast, is far over the limit.
        let old = measure(hiddenLines: 1000, lineHeight: 0.1).height - base
        XCTAssertGreaterThan(old, 50, "the old 0.1 pt collapse leaves \(old) pt for 1,000 lines")
    }

    func testFixtureFHasNoTrailingNewline() throws {
        let text = try Self.fixtureF()
        XCTAssertFalse(text.hasSuffix("\n"))
        XCTAssertEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 36)
    }

    // MARK: Styler (R5, R6, R9)

    /// The fold state with the regions whose header starts on the given 1-based lines folded.
    private func folded(_ h: EditorHarness, _ headers: Int...) -> FoldState {
        headers.reduce(FoldState()) { s, n in s.toggled(h.coordinator.analysis.foldRegions.first { $0.headerLines.lowerBound == n - 1 }!) }
    }

    /// Styles the whole document with `state` applied, the way the coordinator will: nothing else in the harness is told.
    /// (Set the selection first: moving it later restyles lines with the coordinator's own, fold-free state.)
    @discardableResult
    private func style(_ h: EditorHarness, _ state: FoldState) -> PreviewState {
        var p = PreviewState()
        p.setFolds(state, analysis: h.coordinator.analysis, selection: h.textView.selectedRange())
        h.coordinator.styler.styleAll(storage: h.storage, analysis: h.coordinator.analysis, selection: h.textView.selectedRange(), preview: p)
        return p
    }

    private func lineStart(_ h: EditorHarness, _ n: Int) -> Int { h.coordinator.analysis.lines[n - 1].range.location }
    private func lineEnd(_ h: EditorHarness, _ n: Int) -> Int { h.coordinator.analysis.lines[n - 1].contentEnd }

    func testHiddenLinesCollapseToTheThinLineAndShowNothing() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(0)
        style(h, folded(h, 1))                       // # Project folds everything below it: cards, bars, checkboxes, pills...
        let hidden = h.coordinator.analysis.foldRegions[0].hiddenRange
        XCTAssertEqual(hidden, NSRange(location: lineStart(h, 2), length: h.textView.string.utf16.count - lineStart(h, 2)))
        for i in hidden.location..<NSMaxRange(hidden) {
            let attrs = h.attrs(at: i)
            XCTAssertEqual(Set(attrs.keys), [.font, .foregroundColor, .paragraphStyle], "only the collapse attributes at \(i): \(attrs.keys)")
            XCTAssertLessThan(h.font(at: i).pointSize, 1)
            XCTAssertEqual(h.color(at: i), NSColor.clear)
            let p = h.paragraph(at: i)
            XCTAssertEqual(p.minimumLineHeight, MarkdownStyler.foldedLineHeight)
            XCTAssertEqual(p.maximumLineHeight, MarkdownStyler.foldedLineHeight)
            XCTAssertEqual(p.paragraphSpacing, 0)
            XCTAssertEqual(p.paragraphSpacingBefore, 0)
        }
        XCTAssertGreaterThan(h.font(at: h.index(of: "Project")).pointSize, 20, "the header line keeps its look")
    }

    func testLinesOutsideAFoldKeepTheirLook() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(0)
        style(h, folded(h, 20))                       // ## Notes: the Mermaid fence and the groceries hide; the tasks do not
        XCTAssertNotNil(h.attrs(at: h.index(of: "- [ ] Write spec"))[.dwCheckbox], "a task above the fold still has its checkbox")
        XCTAssertGreaterThan(h.font(at: h.index(of: "Plan text")).pointSize, 10)
        XCTAssertNil(h.attrs(at: h.index(of: "- Groceries"))[.dwBullet], "hidden: no bullet")
        XCTAssertGreaterThan(h.font(at: h.index(of: "Empty")).pointSize, 10, "the next heading after the fold is normal")
    }

    func testFoldedHeadingShowsChevronOnItsFirstVisibleCharacterAndAChipAtTheEnd() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(0)
        style(h, folded(h, 5))
        let p = h.coordinator.styler.palette
        let plan = h.index(of: "Plan"), last = lineEnd(h, 5) - 1
        let chevron = try XCTUnwrap(h.attrs(at: plan)[.dwFold] as? FoldMark)
        XCTAssertTrue(chevron.folded)
        XCTAssertFalse(chevron.covered)
        XCTAssertEqual(chevron.chevron, p.marker.nsColor)
        XCTAssertEqual(chevron.chipFill, p.inlineCodeBackground.nsColor)
        XCTAssertEqual(chevron.chipInk, p.text.nsColor)
        XCTAssertNil(h.attrs(at: lineStart(h, 5))[.dwFold], "the hidden `##` is not the first visible character")
        let chip = try XCTUnwrap(h.attrs(at: last)[.dwFoldChip] as? FoldMark)
        XCTAssertTrue(chip.folded)
        XCTAssertNil(h.attrs(at: last - 1)[.dwFoldChip], "the chip is on the last character only")
    }

    func testChevronMovesToTheHeadingMarkersWhileTheyShow() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(lineStart(h, 5) + 4)                 // inside the heading: `## ` shows
        style(h, folded(h, 5))
        XCTAssertNotNil(h.attrs(at: lineStart(h, 5))[.dwFold] as? FoldMark, "the first character is visible now")
        XCTAssertNil(h.attrs(at: h.index(of: "Plan"))[.dwFold])
    }

    func testAnOpenHeaderHasAChevronButNoChip() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(0)
        style(h, folded(h, 5))
        let notes = try XCTUnwrap(h.attrs(at: h.index(of: "Notes"))[.dwFold] as? FoldMark)
        XCTAssertFalse(notes.folded, "an open region: the chevron points down and no chip is drawn")
        XCTAssertNil(h.attrs(at: lineEnd(h, 20) - 1)[.dwFoldChip])
        XCTAssertNil(h.attrs(at: h.index(of: "Empty"))[.dwFold], "## Empty has nothing under it: not foldable")
        XCTAssertNil(h.attrs(at: h.index(of: "Intro"))[.dwFold], "an ordinary paragraph")
    }

    func testRegionsInsideAFoldShowNoChevronOrChip() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(0)
        let p = style(h, folded(h, 1, 5))             // Plan is folded too, but Project hides it
        XCTAssertEqual(p.foldHeaders.keys.sorted(), [0], "only # Project is visible")
        for needle in ["## Plan", "### Tasks", "- [ ] Write spec", "## Notes", "- Groceries"] {
            let i = h.index(of: needle)
            XCTAssertNil(h.attrs(at: i)[.dwFold], needle)
            XCTAssertNil(h.attrs(at: i)[.dwFoldChip], needle)
            XCTAssertLessThan(h.font(at: i).pointSize, 1, needle)
        }
        // Open Project: Plan is still folded inside it (R6) and its chevron and chip are back.
        h.select(0)
        style(h, folded(h, 5))
        XCTAssertEqual((h.attrs(at: h.index(of: "Plan"))[.dwFold] as? FoldMark)?.folded, true)
    }

    func testTaskItemHeaderKeepsItsCheckboxAndGainsAChevronAndChip() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(0)
        style(h, folded(h, 11))
        let start = h.index(of: "- [ ] Write spec")
        XCTAssertNotNil(h.attrs(at: start)[.dwCheckbox], "the checkbox stays")
        XCTAssertEqual((h.attrs(at: start)[.dwFold] as? FoldMark)?.folded, true, "the chevron is on the checkbox's own character")
        XCTAssertNotNil(h.attrs(at: start + "- [ ] Write spec".utf16.count - 1)[.dwFoldChip])
        XCTAssertLessThan(h.font(at: h.index(of: "Draft")).pointSize, 1)
        XCTAssertLessThan(h.font(at: h.index(of: "Review")).pointSize, 1)
        XCTAssertGreaterThan(h.font(at: h.index(of: "Build")).pointSize, 10, "the next sibling is visible")
        XCTAssertNotNil(h.attrs(at: h.index(of: "- [ ] Build"))[.dwCheckbox])
    }

    func testWrappedItemHeaderHasTheChevronOnItsFirstLineAndTheChipOnItsLast() {
        let text = "- first line\n  wrapped line\n  - nested"
        let h = EditorHarness(text: text)
        h.select(0)
        style(h, folded(h, 1))
        XCTAssertNotNil(h.attrs(at: 0)[.dwFold] as? FoldMark)
        XCTAssertNil(h.attrs(at: h.index(of: "wrapped"))[.dwFold])
        XCTAssertNil(h.attrs(at: h.index(of: "first line") + 9)[.dwFoldChip], "not at the end of the first line")
        XCTAssertNotNil(h.attrs(at: h.index(of: "wrapped line") + 11)[.dwFoldChip], "on the last character of the last header line")
        XCTAssertLessThan(h.font(at: h.index(of: "nested")).pointSize, 1)
    }

    func testFoldedItemThatStartsWithACodeFenceKeepsItsHeaderLineOnScreen() {
        // (The analyzer treats a fence inside an item as plain code lines, so nothing collapses the header line.)
        let text = "- ```swift\n  let x = 1\n  ```\n- next"
        let h = EditorHarness(text: text)
        h.select(text.utf16.count)
        style(h, folded(h, 1))
        XCTAssertEqual(h.paragraph(at: 0).maximumLineHeight, 0, "the header line is not collapsed")
        XCTAssertGreaterThan(h.font(at: 0).pointSize, 10)
        XCTAssertEqual((h.attrs(at: 0)[.dwFold] as? FoldMark)?.folded, true)
        XCTAssertNotNil(h.attrs(at: h.index(of: "swift") + 4)[.dwFoldChip])
        XCTAssertLessThan(h.font(at: h.index(of: "let x")).pointSize, 1, "the item's other lines are hidden")
        XCTAssertNil(h.attrs(at: h.index(of: "let x"))[.dwBlockBackground], "and their code card is gone")
        XCTAssertGreaterThan(h.font(at: h.index(of: "- next")).pointSize, 10)
    }

    func testChipIsDrawnCoveredOnlyWhileTheSelectionTouchesHiddenText() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        let hidden = h.coordinator.analysis.foldRegions.first { $0.headerLines.lowerBound == 4 }!.hiddenRange
        func covered(_ selection: NSRange) -> Bool? {
            h.select(selection.location, selection.length)
            let p = style(h, folded(h, 5))
            XCTAssertEqual(p.foldHeaders[4]?.covered, (h.attrs(at: lineEnd(h, 5) - 1)[.dwFoldChip] as? FoldMark)?.covered)
            return p.foldHeaders[4]?.covered
        }
        XCTAssertEqual(covered(NSRange(location: lineStart(h, 3), length: 4)), false, "the selection is above the fold")
        XCTAssertEqual(covered(NSRange(location: lineStart(h, 3), length: lineStart(h, 7) + 3 - lineStart(h, 3))), true, "runs through the header into hidden text")
        XCTAssertEqual(covered(NSRange(location: lineStart(h, 3), length: hidden.location - lineStart(h, 3))), false, "ends exactly where the hidden text starts")
        XCTAssertEqual(covered(NSRange(location: 0, length: h.textView.string.utf16.count)), true, "Select All")
        XCTAssertEqual(covered(NSRange(location: hidden.location + 2, length: 0)), false, "a caret covers nothing")
        let p = h.coordinator.styler.palette
        h.select(0, h.textView.string.utf16.count)
        style(h, folded(h, 5))
        let chip = try XCTUnwrap(h.attrs(at: lineEnd(h, 5) - 1)[.dwFoldChip] as? FoldMark)
        XCTAssertEqual(chip.chipFill, p.selection.nsColor, "covered: the selection colour")
        XCTAssertEqual(chip.chipInk, p.text.nsColor)
    }

    func testStyleLinesGivesTheSameLookAsStyleAll() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(lineStart(h, 12) + 3)
        let state = folded(h, 5, 11, 20, 26)
        style(h, state)
        let expected = NSAttributedString(attributedString: h.storage)

        style(h, FoldState())                         // everything open again
        var p = PreviewState()
        p.setFolds(state, analysis: h.coordinator.analysis, selection: h.textView.selectedRange())
        let all = Set(h.coordinator.analysis.lines.indices)
        h.coordinator.styler.style(lines: all, storage: h.storage, analysis: h.coordinator.analysis,
                                   selection: h.textView.selectedRange(), preview: p)
        XCTAssertTrue(expected.isEqual(to: h.storage), "styling the lines one batch at a time must match styling the document")
        let open = EditorHarness(text: try Self.fixtureF())
        open.select(lineStart(open, 12) + 3)
        style(open, FoldState())
        XCTAssertFalse(expected.isEqual(to: open.storage), "precondition: the folds change the look")
    }

    func testUnfoldingRestoresTheOriginalLook() throws {
        let h = EditorHarness(text: try Self.fixtureF())
        h.select(0)
        let a = h.coordinator.analysis
        let state = folded(h, 5, 20)
        style(h, state)
        let reference = EditorHarness(text: try Self.fixtureF())
        reference.select(0)
        style(reference, FoldState())
        let unfolded = NSAttributedString(attributedString: reference.storage)
        XCTAssertFalse(unfolded.isEqual(to: h.storage), "precondition: the folds changed the look")
        // Restyle just the lines the folds touched: the headers and the hidden lines.
        var lines = Set<Int>()
        for r in a.foldRegions where state.isFolded(r) { for l in r.headerLines.lowerBound...r.hiddenLines.upperBound { lines.insert(l) } }
        var p = PreviewState()
        p.setFolds(FoldState(), analysis: a, selection: h.textView.selectedRange())
        h.coordinator.styler.style(lines: lines, storage: h.storage, analysis: a, selection: h.textView.selectedRange(), preview: p)
        XCTAssertTrue(unfolded.isEqual(to: h.storage), "an unfolded line looks exactly like one that was never folded")
    }
}
