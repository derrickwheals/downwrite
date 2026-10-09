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

    func testFoldedLinesSymmetricDifference() {
        func diff(_ a: [ClosedRange<Int>], _ b: [ClosedRange<Int>]) -> [ClosedRange<Int>] { FoldedLines(a).symmetricDifference(FoldedLines(b)) }
        XCTAssertEqual(diff([], []), [])
        XCTAssertEqual(diff([5...18], []), [5...18], "a fold opening or closing: its hidden lines")
        XCTAssertEqual(diff([], [5...18]), [5...18])
        XCTAssertEqual(diff([5...18], [5...18]), [])
        XCTAssertEqual(diff([5...18], [5...12]), [13...18], "an inner part stays hidden")
        XCTAssertEqual(diff([5...18], [20...31]), [5...18, 20...31])
        XCTAssertEqual(diff([5...18, 20...31], [5...31]), [19...19], "two folds become one")
        XCTAssertEqual(diff([1...35], [5...18]), [1...4, 19...35])
        XCTAssertTrue(FoldedLines([3...4, 9...9]).contains(9))
        XCTAssertFalse(FoldedLines([3...4, 9...9]).contains(5))
        XCTAssertFalse(FoldedLines().contains(0))
    }

    // MARK: Coordinator and overlays (R4, R7, R15, R18, R20, R21)

    private func fixtureHarness(file: StaticString = #filePath) async throws -> EditorHarness {
        let h = EditorHarness(text: try Self.fixtureF(), size: NSSize(width: 900, height: 760))
        h.select(0)
        let ready = await waitUntil { (h.coordinator.tableOverlay.grids.first?.tableSize.width ?? 0) > 0 }
        XCTAssertTrue(ready, "the table never became a grid")
        return h
    }

    /// Waits for the asynchronous repositioning to settle and returns what is still inconsistent.
    private func layoutProblems(_ h: EditorHarness) async -> [String] {
        var found: [String] = []
        _ = await waitUntil(timeout: 8) {
            found = h.coordinator.tableOverlay.layoutProblems() + h.coordinator.overlay.layoutProblems(analysis: h.coordinator.analysis)
            return found.isEmpty
        }
        return found
    }

    /// The text of each folded region's header's first line.
    private func foldedHeaders(_ h: EditorHarness) -> [String] {
        let a = h.coordinator.analysis, ns = NSString(string: h.textView.string)
        return a.foldRegions.filter(h.coordinator.foldState.isFolded).map { ns.substring(with: a.lines[$0.headerLines.lowerBound].contentRange) }
    }

    func testFoldingChangesOnlyWhatIsDrawn() async throws {
        let h = try await fixtureHarness()
        let text = try Self.fixtureF()
        let um = try XCTUnwrap(h.textView.undoManager)
        h.coordinator.setFoldState(folded(h, 5, 20, 26))
        XCTAssertEqual(h.textView.string, text)
        XCTAssertEqual(h.box.value, text, "the binding that feeds the file is untouched")
        XCTAssertFalse(um.canUndo, "folding adds nothing to the undo history")
        XCTAssertFalse(um.canRedo)
        XCTAssertTrue(um.isUndoRegistrationEnabled)
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "## Notes", "- Groceries"])
        XCTAssertLessThan(h.font(at: h.index(of: "Plan text.")).pointSize, 1, "hidden")
        h.coordinator.setFoldState(FoldState())
        XCTAssertEqual(h.textView.string, text)
        XCTAssertEqual(h.box.value, text)
        XCTAssertFalse(um.canUndo)
        XCTAssertGreaterThan(h.font(at: h.index(of: "Plan text.")).pointSize, 10, "shown again")
    }

    func testUnfoldingRestoresExactlyTheLookOfADocumentThatWasNeverFolded() async throws {
        let h = try await fixtureHarness()
        let pristine = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 1, 5, 11, 20, 26, 28, 35))
        XCTAssertFalse(NSAttributedString(attributedString: pristine.storage).isEqual(to: h.storage), "precondition: it changed")
        h.coordinator.setFoldState(FoldState())
        XCTAssertTrue(NSAttributedString(attributedString: pristine.storage).isEqual(to: h.storage))
    }

    func testAnInnerFoldKeepsItsStateWhileTheOuterOneIsFoldedAndOpened() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 1, 5))
        XCTAssertLessThan(h.font(at: h.index(of: "Plan")).pointSize, 1, "Plan hides inside Project")
        XCTAssertGreaterThan(h.font(at: h.index(of: "# Project")).pointSize, 10)
        h.coordinator.setFoldState(folded(h, 5))                         // Project opens
        XCTAssertEqual((h.attrs(at: h.index(of: "Plan"))[.dwFold] as? FoldMark)?.folded, true, "Plan is still folded inside it")
        XCTAssertNotNil(h.attrs(at: lineEnd(h, 5) - 1)[.dwFoldChip])
        XCTAssertLessThan(h.font(at: h.index(of: "Plan text.")).pointSize, 1)
        XCTAssertGreaterThan(h.font(at: h.index(of: "Notes")).pointSize, 10, "Notes is open")
    }

    func testTablesAndDiagramsInsideAFoldAreHiddenReserveNothingAndComeBackInPlace() async throws {
        let h = try await fixtureHarness()
        let c = h.coordinator
        XCTAssertEqual(c.tableOverlay.grids.count, 1)
        XCTAssertEqual(c.overlay.diagramViews.count, 1, "the Mermaid block has a card")
        let tableLine = 15, diagramLine = 21
        XCTAssertNotNil(c.tableOverlay.reservedHeights()[tableLine])
        let problemsBefore = await layoutProblems(h)
        XCTAssertEqual(problemsBefore, [])

        c.setFoldState(folded(h, 5, 20))                                 // Plan holds the table, Notes the diagram
        XCTAssertTrue(c.tableOverlay.grids[0].isHidden)
        XCTAssertTrue(c.overlay.diagramViews[0].isHidden)
        XCTAssertNil(c.tableOverlay.reservedHeights()[tableLine], "no room is reserved for a hidden table")
        XCTAssertNil(c.overlay.reservedHeights[diagramLine], "nor for a hidden diagram")
        let hiddenProblems = await layoutProblems(h)
        XCTAssertEqual(hiddenProblems, [], "hidden blocks are skipped")
        XCTAssertEqual(h.paragraph(at: h.index(of: "| 1 | 2 |")).paragraphSpacing, 0, "the table's last line reserves no room")

        c.setFoldState(FoldState())
        XCTAssertFalse(c.tableOverlay.grids[0].isHidden)
        XCTAssertFalse(c.overlay.diagramViews[0].isHidden)
        XCTAssertNotNil(c.tableOverlay.reservedHeights()[tableLine])
        let after = await layoutProblems(h)
        XCTAssertEqual(after, [], "everything is back in place: \(after)")
    }

    func testAFocusedCellHandsTheKeyboardBackWhenItsTableIsHidden() async throws {
        let h = try await fixtureHarness()
        let grid = h.coordinator.tableOverlay.grids[0]
        grid.focus(.init(row: 1, column: 0))
        XCTAssertTrue(h.coordinator.tableOverlay.hasFocus)
        h.coordinator.setFoldState(folded(h, 5))
        XCTAssertFalse(h.coordinator.tableOverlay.hasFocus)
        XCTAssertTrue(h.window.firstResponder === h.textView, "the text view has the keyboard again")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineEnd(h, 5), length: 0), "with the caret at the end of the fold's header")
    }

    func testTheCaretMovesToTheHeaderOfTheOutermostFoldThatHidesIt() async throws {
        let h = try await fixtureHarness()
        h.select(h.index(of: "Write spec") + 3)
        h.coordinator.setFoldState(folded(h, 5))
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineEnd(h, 5), length: 0), "Plan hides line 11")
        h.coordinator.setFoldState(folded(h, 5, 11))                     // (already hidden by Plan: nothing changes)
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineEnd(h, 5), length: 0))
        // A selection that starts in view is left alone, even if it ends in hidden text.
        h.select(lineStart(h, 3), lineStart(h, 8) - lineStart(h, 3))
        h.coordinator.setFoldState(folded(h, 20))
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineStart(h, 3), length: lineStart(h, 8) - lineStart(h, 3)))
    }

    func testTypingElsewhereKeepsTheFoldsOnTheirHeadersAndUndoDoesToo() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 20, 26))
        h.select(lineEnd(h, 3))
        h.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(h.textView.string.contains("Intro paragraph.!"))
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "## Notes", "- Groceries"], "typing above shifts the folds, it does not change them")
        XCTAssertLessThan(h.font(at: h.index(of: "Plan text.")).pointSize, 1)
        XCTAssertGreaterThan(h.font(at: h.index(of: "Empty")).pointSize, 10)
        // A new first line pushes everything down.
        h.select(0)
        h.textView.insertText("New first line\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "## Notes", "- Groceries"])
        h.textView.undoManager?.undo()
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.textView.string, try Self.fixtureF())
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "## Notes", "- Groceries"], "undo maps the folds back")
        XCTAssertLessThan(h.font(at: h.index(of: "Plan text.")).pointSize, 1)
    }

    func testReturnAtTheStartOfAFoldedHeaderPushesItDownWithItsFold() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        h.select(lineStart(h, 5))
        h.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(foldedHeaders(h), ["## Plan"])
        XCTAssertEqual(h.coordinator.analysis.foldRegions.first { h.coordinator.foldState.isFolded($0) }?.headerLines.lowerBound, 5, "one line lower")
        XCTAssertLessThan(h.font(at: h.index(of: "Plan text.")).pointSize, 1)
    }

    func testAnExternalReloadKeepsTheFolds() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        let reloaded = try Self.fixtureF() + "\ntail\n"
        h.coordinator.update(text: reloaded, settings: EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720))
        XCTAssertEqual(h.textView.string, reloaded)
        XCTAssertEqual(foldedHeaders(h), ["## Plan"])
        XCTAssertLessThan(h.font(at: h.index(of: "Plan text.")).pointSize, 1)
        XCTAssertGreaterThan(h.font(at: h.index(of: "tail")).pointSize, 10)
    }

    func testAnEditThatLeavesTheCaretInHiddenTextOpensTheFoldsHidingIt() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 20))
        h.select(h.index(of: "Plan text.") + 2)                          // as an undo or a paste could leave it
        h.coordinator.reanalyze()
        XCTAssertEqual(foldedHeaders(h), ["## Notes"], "only the fold that hid the caret opened")
        XCTAssertGreaterThan(h.font(at: h.index(of: "Plan text.")).pointSize, 10)
        XCTAssertLessThan(h.font(at: h.index(of: "graph TD")).pointSize, 1)
    }

    func testTheSourceViewShowsEverythingAndKeepsTheFolds() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 20))
        h.coordinator.setSourceMode(true)
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "## Notes"], "the state is kept")
        for needle in ["Plan text.", "graph TD", "## Notes"] {
            XCTAssertGreaterThan(h.font(at: h.index(of: needle)).pointSize, 10, needle)
            XCTAssertNil(h.attrs(at: h.index(of: needle))[.dwFold], needle)
        }
        for i in 0..<h.storage.length {
            XCTAssertNil(h.attrs(at: i)[.dwFold]); XCTAssertNil(h.attrs(at: i)[.dwFoldChip])
        }
        h.coordinator.setSourceMode(false)
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "## Notes"])
        XCTAssertLessThan(h.font(at: h.index(of: "Plan text.")).pointSize, 1, "folded again")
        XCTAssertTrue(h.coordinator.tableOverlay.grids[0].isHidden)
    }

    func testLeavingTheSourceViewWithTheCaretInHiddenTextOpensThatFold() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 20))
        h.coordinator.setSourceMode(true)
        h.select(h.index(of: "Plan text.") + 2)
        h.coordinator.setSourceMode(false)
        XCTAssertEqual(foldedHeaders(h), ["## Notes"])
        XCTAssertGreaterThan(h.font(at: h.index(of: "Plan text.")).pointSize, 10)
    }

    func testAnEditMadeInTheSourceViewMapsTheFolds() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 20))
        h.coordinator.setSourceMode(true)
        h.select(0)
        h.textView.insertText("Inserted line\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.coordinator.setSourceMode(false)
        XCTAssertEqual(foldedHeaders(h), ["## Notes"])
        XCTAssertLessThan(h.font(at: h.index(of: "graph TD")).pointSize, 1)
    }

    func testFoldStateBelongsToOneWindowAndIsNeverStored() async throws {
        let defaultsBefore = Set(UserDefaults.standard.dictionaryRepresentation().keys)
        let a = try await fixtureHarness(), b = try await fixtureHarness()
        a.coordinator.setFoldState(folded(a, 5, 20))
        XCTAssertEqual(foldedHeaders(a), ["## Plan", "## Notes"])
        XCTAssertEqual(foldedHeaders(b), [], "another window is unaffected")
        XCTAssertGreaterThan(b.font(at: b.index(of: "Plan text.")).pointSize, 10)
        let fresh = try await fixtureHarness()
        XCTAssertEqual(foldedHeaders(fresh), [], "every file opens fully unfolded")
        a.coordinator.setFoldState(FoldState())
        XCTAssertEqual(Set(UserDefaults.standard.dictionaryRepresentation().keys), defaultsBefore, "no setting or stored state is added")
    }

    func testUnfoldingAFoldRestylesOnlyWhatChanged() async throws {
        let h = try await fixtureHarness()
        // Mark a line outside the fold: if the coordinator restyled the whole document the mark would be overwritten.
        let probe = h.index(of: "Intro")
        h.storage.addAttribute(NSAttributedString.Key("test.probe"), value: 1, range: NSRange(location: probe, length: 5))
        h.coordinator.setFoldState(folded(h, 5))
        XCTAssertNotNil(h.attrs(at: probe)[NSAttributedString.Key("test.probe")], "folding Plan leaves unrelated lines alone")
        h.coordinator.setFoldState(FoldState())
        XCTAssertNotNil(h.attrs(at: probe)[NSAttributedString.Key("test.probe")], "so does unfolding it")
    }

    // MARK: Clicks (R8, R9)

    /// A left click at `point` (text view coordinates). A click that is not on a fold control falls through to `NSTextView`, which
    /// tracks the mouse until the button comes up, so `release` posts that mouse-up first.
    private func click(_ h: EditorHarness, atView point: NSPoint, count: Int = 1, release: Bool = false) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: h.textView.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        if release { NSApp.postEvent(event(.leftMouseUp), atStart: false) }
        h.textView.mouseDown(with: event(.leftMouseDown))
    }

    private func chevronCentre(_ h: EditorHarness, word: String) -> NSPoint {
        let o = h.textView.textContainerOrigin
        let r = (h.textView.layoutManager as! DWLayoutManager).foldChevronRect(forCharacterAt: h.index(of: word))!
        return NSPoint(x: r.midX + o.x, y: r.midY + o.y)
    }

    func testClickingTheChevronTogglesTheFoldWithoutTouchingTheSelection() async throws {
        let h = try await fixtureHarness()
        h.window.makeKeyAndOrderFront(nil)
        h.select(h.index(of: "Intro") + 3, 4)
        let selection = h.textView.selectedRange()
        click(h, atView: chevronCentre(h, word: "Plan"))
        XCTAssertEqual(foldedHeaders(h), ["## Plan"], "the chevron folds an open region")
        XCTAssertEqual(h.textView.selectedRange(), selection, "and the selection is where it was")
        click(h, atView: chevronCentre(h, word: "Plan"))
        XCTAssertEqual(foldedHeaders(h), [], "the same chevron opens it again")
        XCTAssertEqual(h.textView.selectedRange(), selection)
        XCTAssertFalse(h.textView.undoManager!.canUndo)
        XCTAssertEqual(h.box.value, try Self.fixtureF())
    }

    func testClickingTheChipUnfolds() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        let o = h.textView.textContainerOrigin
        let chip = (h.textView.layoutManager as! DWLayoutManager).foldChipRect(forCharacterAt: lineEnd(h, 5) - 1)!
        click(h, atView: NSPoint(x: chip.midX + o.x, y: chip.midY + o.y))
        XCTAssertEqual(foldedHeaders(h), [])
        XCTAssertGreaterThan(h.font(at: h.index(of: "Plan text.")).pointSize, 10)
    }

    func testClicksElsewhereOnTheHeaderDoNotFold() async throws {
        let h = try await fixtureHarness()
        let o = h.textView.textContainerOrigin
        let r = (h.textView.layoutManager as! DWLayoutManager).boundingRect(forGlyphRange: NSRange(location: h.index(of: "Plan"), length: 4), in: h.textView.textContainer!)
        click(h, atView: NSPoint(x: r.midX + o.x, y: r.midY + o.y), release: true)    // on the heading text
        XCTAssertEqual(foldedHeaders(h), [], "a click on the text just places the caret")
        XCTAssertEqual(h.textView.selectedRange().length, 0)
        click(h, atView: NSPoint(x: o.x + 400, y: r.midY + o.y), release: true)       // far right of the header, in the text column
        XCTAssertEqual(foldedHeaders(h), [])
    }

    func testAChipOnlyExistsWhileFoldedAndAnOpenHeaderHasNoChipToClick() async throws {
        let h = try await fixtureHarness()
        let o = h.textView.textContainerOrigin
        let lm = h.textView.layoutManager as! DWLayoutManager
        XCTAssertNil(lm.foldChipRect(forCharacterAt: lineEnd(h, 5) - 1), "no chip on an open header")
        let end = lm.boundingRect(forGlyphRange: NSRange(location: lineEnd(h, 5) - 1, length: 1), in: h.textView.textContainer!)
        click(h, atView: NSPoint(x: end.maxX + o.x + 14, y: end.midY + o.y), release: true)
        XCTAssertEqual(foldedHeaders(h), [], "clicking where a chip would be does nothing while open")
    }

    func testTheCoveredStateFollowsTheSelection() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        let chipChar = lineEnd(h, 5) - 1
        XCTAssertEqual((h.attrs(at: chipChar)[.dwFoldChip] as? FoldMark)?.covered, false)
        h.select(lineStart(h, 3), lineStart(h, 8) - lineStart(h, 3))
        XCTAssertEqual((h.attrs(at: chipChar)[.dwFoldChip] as? FoldMark)?.covered, true, "restyled when the selection reaches hidden text")
        XCTAssertEqual((h.attrs(at: lineStart(h, 5))[.dwFold] as? FoldMark)?.covered, true, "(the selection shows the heading's `##`, so the chevron is on the first `#`)")
        h.select(0)
        XCTAssertEqual((h.attrs(at: chipChar)[.dwFoldChip] as? FoldMark)?.covered, false, "and back")
    }

    // MARK: Commands (R10 to R13)

    /// Counts the beeps the editor makes (a command with nothing to act on).
    private final class Beeps { var count = 0 }

    private func countBeeps(_ h: EditorHarness) -> Beeps {
        let b = Beeps()
        h.coordinator.beep = { b.count += 1 }
        return b
    }

    func testFoldAtTheCaretWorkedExampleWithTheRealCommand() async throws {
        let h = try await fixtureHarness()
        let beeps = countBeeps(h)
        h.select(h.index(of: "Review") + 2)
        var seen: [[String]] = []
        for _ in 0..<4 {
            h.textView.dwFold(nil)
            seen.append(foldedHeaders(h))
            let a = h.coordinator.analysis, state = h.coordinator.foldState
            let outermost = a.foldRegions.filter { state.isFolded($0) }.min { $0.headerLines.upperBound > $1.headerLines.upperBound }!   // the newest, innermost-out
            _ = outermost
            XCTAssertEqual(h.textView.selectedRange().length, 0)
        }
        XCTAssertEqual(seen[0], ["- [ ] Write spec"])
        XCTAssertEqual(seen[1], ["### Tasks", "- [ ] Write spec"])
        XCTAssertEqual(seen[2], ["## Plan", "### Tasks", "- [ ] Write spec"])
        XCTAssertEqual(seen[3], ["# Project", "## Plan", "### Tasks", "- [ ] Write spec"])
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineEnd(h, 1), length: 0), "the caret ends on the one visible header")
        XCTAssertEqual(beeps.count, 0)
        h.textView.dwFold(nil)
        XCTAssertEqual(beeps.count, 1, "nothing left to fold: the system beep")
        XCTAssertEqual(foldedHeaders(h).count, 4)
    }

    func testFoldMovesTheCaretToTheEndOfTheHeaderOnlyWhenItWasHidden() async throws {
        let h = try await fixtureHarness()
        h.select(h.index(of: "Draft") + 2)                          // inside the nested items
        h.textView.dwFold(nil)
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineEnd(h, 11), length: 0), "hidden by the fold: onto its header")
        h.coordinator.setFoldState(FoldState())
        h.select(lineStart(h, 11) + 3)                              // on the header line itself
        h.textView.dwFold(nil)
        XCTAssertEqual(foldedHeaders(h), ["- [ ] Write spec"])
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineStart(h, 11) + 3, length: 0), "a visible caret is left alone")
    }

    func testUnfoldAtTheCaret() async throws {
        let h = try await fixtureHarness()
        let beeps = countBeeps(h)
        h.coordinator.setFoldState(folded(h, 1, 5))
        h.select(lineEnd(h, 1))
        h.textView.dwUnfold(nil)
        XCTAssertEqual(foldedHeaders(h), ["## Plan"], "Project opens, Plan stays folded inside it")
        h.textView.dwUnfold(nil)
        XCTAssertEqual(beeps.count, 1, "the caret line is not a folded header any more")
        h.select(lineEnd(h, 5))
        h.textView.dwUnfold(nil)
        XCTAssertEqual(foldedHeaders(h), [])
        XCTAssertEqual(beeps.count, 1)
    }

    func testFoldAllUnfoldAllAndFoldToLevel() async throws {
        let h = try await fixtureHarness()
        let beeps = countBeeps(h)
        h.textView.dwFoldAll(nil)
        XCTAssertEqual(foldedHeaders(h), ["# Project", "## Plan", "### Tasks", "- [ ] Write spec", "## Notes", "- Groceries", "  - Eggs", "## Last"])
        h.textView.dwFoldAll(nil)
        XCTAssertEqual(beeps.count, 1, "everything is folded already")
        h.textView.dwUnfoldAll(nil)
        XCTAssertEqual(foldedHeaders(h), [])
        h.textView.dwUnfoldAll(nil)
        XCTAssertEqual(beeps.count, 2)
        h.textView.dwFoldToLevel(FoldLevelBox(2))
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "### Tasks", "## Notes", "## Last"], "Project stays open; list items are left alone; ## Empty cannot fold")
        h.textView.dwFoldToLevel(FoldLevelBox(2))
        XCTAssertEqual(beeps.count, 3, "no change")
        h.textView.dwFoldToLevel(FoldLevelBox(3))
        XCTAssertEqual(foldedHeaders(h), ["### Tasks"], "level 3 opens the shallower headings")
        h.textView.dwFoldToLevel(nil)                              // (no level: ignored)
        XCTAssertEqual(foldedHeaders(h), ["### Tasks"])
    }

    func testFoldCommandsDoNothingInTheSourceView() async throws {
        let h = try await fixtureHarness()
        let beeps = countBeeps(h)
        h.coordinator.setSourceMode(true)
        h.textView.dwFold(nil); h.textView.dwUnfold(nil); h.textView.dwFoldAll(nil); h.textView.dwUnfoldAll(nil)
        h.textView.dwFoldToLevel(FoldLevelBox(1))
        XCTAssertEqual(foldedHeaders(h), [])
        XCTAssertEqual(beeps.count, 5)
    }

    func testTheHeaderIsScrolledIntoViewWhenAFoldHidesTheCaret() async throws {
        var doc = "# Top\n\n"
        for i in 1...150 { doc += "## Section \(i)\n\nFirst line of \(i).\nSecond line of \(i).\n\n" }
        let h = EditorHarness(text: doc, size: NSSize(width: 900, height: 600))
        h.window.makeKeyAndOrderFront(nil)
        h.select(h.index(of: "Second line of 140."))
        h.textView.scrollRangeToVisible(h.textView.selectedRange())
        XCTAssertGreaterThan(h.textView.visibleRect.minY, 1000, "precondition: scrolled far down")
        h.textView.dwFoldAll(nil)                                    // the caret is hidden: it goes to `# Top`, at the very start
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: "# Top".utf16.count, length: 0))
        XCTAssertLessThan(h.textView.visibleRect.minY, 40, "and the view followed it up to the header")
    }

    func testTheActionsAreReachableBySelector() async throws {
        // (The real menu route, through the key window's responder chain, is exercised by the end-to-end run.)
        let h = try await fixtureHarness()
        func send(_ selector: Selector, from sender: Any? = nil) { XCTAssertTrue(NSApp.sendAction(selector, to: h.textView, from: sender), "\(selector)") }
        send(#selector(EditorTextView.dwFoldAll(_:)))
        XCTAssertEqual(foldedHeaders(h).count, 8)
        send(#selector(EditorTextView.dwUnfoldAll(_:)))
        XCTAssertEqual(foldedHeaders(h), [])
        send(#selector(EditorTextView.dwFoldToLevel(_:)), from: FoldLevelBox(2))
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "### Tasks", "## Notes", "## Last"])
        h.select(lineEnd(h, 5))
        send(#selector(EditorTextView.dwUnfold(_:)))
        XCTAssertEqual(foldedHeaders(h), ["### Tasks", "## Notes", "## Last"])
        h.select(lineEnd(h, 5))
        send(#selector(EditorTextView.dwFold(_:)))
        XCTAssertTrue(foldedHeaders(h).contains("## Plan"))
    }

    // MARK: Caret movement and reveal (R14, R15)

    private func move(_ h: EditorHarness, _ selector: Selector) { h.textView.doCommand(by: selector) }
    private func caretLine(_ h: EditorHarness) -> Int { h.coordinator.analysis.lineIndex(at: h.textView.selectedRange().location) + 1 }
    private func caretIsHidden(_ h: EditorHarness) -> Bool {
        h.coordinator.foldState.foldHiding(offset: h.textView.selectedRange().location, in: h.coordinator.analysis) != nil
    }

    func testArrowKeysStepOverAFoldedSection() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        h.select(lineEnd(h, 5))
        move(h, #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(caretLine(h), 20, "↓ from the folded header lands on the next visible line")
        XCTAssertFalse(caretIsHidden(h))
        move(h, #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(caretLine(h), 5, "↑ comes back to the header line")
        XCTAssertEqual(foldedHeaders(h), ["## Plan"], "walking over a fold does not open it")
        h.select(lineEnd(h, 5))
        move(h, #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineStart(h, 20), length: 0), "→ at the end of a folded header goes to the next visible line")
        move(h, #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineEnd(h, 5), length: 0), "← from there goes back to the end of the header")
    }

    func testVerticalMovesKeepTheColumnWhereTheTargetLineIsLongEnough() async throws {
        let h = try await fixtureHarness()
        let text = "# Title\nA longer line of body text here.\n\n## Folded\nhidden body\n\nAnother line of body text, long enough.\n"
        let w = EditorHarness(text: text, size: NSSize(width: 900, height: 600))
        w.select(w.index(of: "A longer") + 9)
        w.coordinator.setFoldState(w.coordinator.analysis.foldRegions.filter { $0.headerLines.lowerBound == 3 }.reduce(FoldState()) { $0.toggled($1) })
        let column = 9
        // ↓ from the paragraph above lands on the folded heading, ↓ again steps over its hidden body to the paragraph below.
        move(w, #selector(NSResponder.moveDown(_:)))
        move(w, #selector(NSResponder.moveDown(_:)))
        move(w, #selector(NSResponder.moveDown(_:)))
        let a = w.coordinator.analysis
        XCTAssertFalse(w.coordinator.foldState.foldHiding(offset: w.textView.selectedRange().location, in: a) != nil)
        XCTAssertEqual(w.textView.selectedRange().location - a.lines[a.lineIndex(at: w.textView.selectedRange().location)].range.location, column, accuracy: 2,
                       "the column is kept on the line below the fold")
        _ = h
    }

    func testWordLineAndDocumentMovesNeverEndInHiddenText() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 20, 35))
        let selectors: [Selector] = [#selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
                                     #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.pageDown(_:)),
                                     #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.moveParagraphForwardAndModifySelection(_:)),
                                     #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveToBeginningOfDocument(_:)),
                                     #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.pageUp(_:))]
        for start in [lineEnd(h, 5), lineEnd(h, 20), lineStart(h, 20), lineEnd(h, 35), h.index(of: "Intro"), 0] {
            for selector in selectors {
                h.select(start)
                move(h, selector)
                XCTAssertFalse(caretIsHidden(h), "\(selector) from \(start) left the caret at \(h.textView.selectedRange().location), in hidden text")
            }
        }
        XCTAssertEqual(foldedHeaders(h), ["## Plan", "## Notes", "## Last"], "none of that opened a fold")
        h.select(0)
        move(h, #selector(NSResponder.moveToEndOfDocument(_:)))
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineEnd(h, 35), length: 0), "⌘↓ with a hidden end goes to the end of the header of the fold hiding it")
    }

    func testShiftArrowsExtendTheSelectionOverTheFold() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        h.select(lineEnd(h, 5))
        move(h, #selector(NSResponder.moveDownAndModifySelection(_:)))
        let sel = h.textView.selectedRange()
        XCTAssertEqual(sel.location, lineEnd(h, 5))
        XCTAssertGreaterThanOrEqual(NSMaxRange(sel), lineStart(h, 20), "it reaches the next visible line, covering the hidden text between")
        XCTAssertLessThanOrEqual(NSMaxRange(sel), lineEnd(h, 20))
        XCTAssertFalse(h.coordinator.foldState.foldHiding(offset: NSMaxRange(sel), in: h.coordinator.analysis) != nil)
        XCTAssertEqual(foldedHeaders(h), ["## Plan"])
        // Extending upwards from below the fold ends on the header.
        h.select(lineStart(h, 20) + 2)
        move(h, #selector(NSResponder.moveUpAndModifySelection(_:)))
        XCTAssertEqual(NSMaxRange(h.textView.selectedRange()), lineStart(h, 20) + 2)
        XCTAssertEqual(h.coordinator.analysis.lineIndex(at: h.textView.selectedRange().location) + 1, 5, "the moving end stops on the header's line (column kept)")
        XCTAssertGreaterThanOrEqual(h.textView.selectedRange().location, lineStart(h, 5))
        XCTAssertLessThanOrEqual(h.textView.selectedRange().location, lineEnd(h, 5))
    }

    func testPageDownThroughAFoldedDocumentNeverLeavesTheCaretHidden() async throws {
        var doc = ""
        for i in 1...40 { doc += "## Section \(i)\n\n" + (1...6).map { "Body line \($0) of \(i)." }.joined(separator: "\n") + "\n\n" }
        let h = EditorHarness(text: doc, size: NSSize(width: 900, height: 500))
        h.window.makeKeyAndOrderFront(nil)
        h.coordinator.setFoldState(h.coordinator.analysis.foldRegions.enumerated().filter { $0.offset % 3 != 0 }.reduce(FoldState()) { $0.toggled($1.element) })
        h.select(0)
        for _ in 0..<12 {
            move(h, #selector(NSResponder.pageDown(_:)))
            XCTAssertFalse(caretIsHidden(h))
        }
        for _ in 0..<12 {
            move(h, #selector(NSResponder.pageUp(_:)))
            XCTAssertFalse(caretIsHidden(h))
        }
    }

    func testASelectionThatReachesIntoHiddenTextOpensOnlyTheFoldsHidingIt() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 20))
        h.select(h.index(of: "Milk"), 4)                              // hidden by Notes (as Find would leave it)
        XCTAssertEqual(foldedHeaders(h), ["## Plan"], "Notes opened, Plan did not hide it")
        XCTAssertGreaterThan(h.font(at: h.index(of: "Milk")).pointSize, 10)
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: h.index(of: "Milk"), length: 4), "the selection is untouched")
    }

    func testAnOpenSelectionEndingInHiddenTextLeavesTheFoldsAlone() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        h.select(0, h.textView.string.utf16.count)                    // Select All
        XCTAssertEqual(foldedHeaders(h), ["## Plan"])
    }

    func testAContentsClickOnAHiddenHeadingOpensItsFolds() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 1, 5))
        let tasks = try XCTUnwrap(h.coordinator.analysis.headings.firstIndex { $0.title == "Tasks" })
        h.coordinator.revealHeading(at: tasks, animated: false)
        XCTAssertEqual(foldedHeaders(h), [], "Project and Plan both hid it")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineEnd(h, 9), length: 0), "the caret is at the end of the heading")
    }

    func testAHashLinkToAHiddenHeadingOpensItsFolds() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 20))
        h.coordinator.open(destination: "#tasks")
        XCTAssertEqual(foldedHeaders(h), ["## Notes"], "only Plan hid ### Tasks")
        XCTAssertEqual(caretLine(h), 9)
    }

    // MARK: Edits at a fold's edge, and selections across folds (R16, R17, R19)

    /// The text after pressing Return at `caret` in a document where `headers` are folded (none: a plain editor).
    private func afterReturn(at caret: (EditorHarness) -> Int, folding headers: [Int]) async throws -> (h: EditorHarness, text: String) {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(headers.reduce(FoldState()) { s, n in s.toggled(h.coordinator.analysis.foldRegions.first { $0.headerLines.lowerBound == n - 1 }!) })
        h.select(caret(h))
        h.textView.insertNewline(nil)
        return (h, h.textView.string)
    }

    func testReturnAtTheEndOrInsideAFoldedHeaderOpensItAndInsertsExactlyWhatItAlwaysDoes() async throws {
        for (name, caret) in [("end", { (h: EditorHarness) in self.lineEnd(h, 5) }), ("inside", { (h: EditorHarness) in self.lineStart(h, 5) + 5 })] as [(String, (EditorHarness) -> Int)] {
            let folded = try await afterReturn(at: caret, folding: [5, 20])
            let plain = try await afterReturn(at: caret, folding: [])
            XCTAssertEqual(folded.text, plain.text, "\(name): the text is the same with and without the fold")
            XCTAssertEqual(foldedHeaders(folded.h), ["## Notes"], "\(name): this fold opened, the other did not")
            XCTAssertEqual(folded.h.textView.selectedRange(), plain.h.textView.selectedRange(), "\(name): same caret")
            XCTAssertGreaterThan(folded.h.font(at: folded.h.index(of: "Plan text.")).pointSize, 10)
        }
        // A list item behaves like a list item: Return after a folded bullet starts a new bullet, and the item opens.
        let item = try await afterReturn(at: { self.lineEnd($0, 26) }, folding: [26])
        let plainItem = try await afterReturn(at: { self.lineEnd($0, 26) }, folding: [])
        XCTAssertEqual(item.text, plainItem.text)
        XCTAssertEqual(foldedHeaders(item.h), [])
    }

    func testReturnAtTheStartOfAFoldedHeaderLeavesItFolded() async throws {
        let r = try await afterReturn(at: { self.lineStart($0, 5) }, folding: [5])
        XCTAssertEqual(foldedHeaders(r.h), ["## Plan"], "it is pushed down a line, still folded")
        XCTAssertLessThan(r.h.font(at: r.h.index(of: "Plan text.")).pointSize, 1)
    }

    func testReturnThenUndoIsASingleStepAndKeepsTheFoldOpen() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        h.select(lineEnd(h, 5))
        h.textView.insertNewline(nil)
        XCTAssertEqual(foldedHeaders(h), [])
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.textView.string, try Self.fixtureF(), "one undo takes the Return back")
        XCTAssertEqual(foldedHeaders(h), [])
    }

    func testBackspaceAtTheStartOfTheLineAfterAFoldOpensItAndDeletesNothing() async throws {
        let text = try Self.fixtureF()
        let variants: [(String, Selector)] = [("⌫", #selector(NSResponder.deleteBackward(_:))), ("⌥⌫", #selector(NSResponder.deleteWordBackward(_:))),
                                              ("⌘⌫", #selector(NSResponder.deleteToBeginningOfLine(_:))), ("paragraph", #selector(NSResponder.deleteToBeginningOfParagraph(_:)))]
        for (name, selector) in variants {
            let h = try await fixtureHarness()
            h.coordinator.setFoldState(folded(h, 5, 9, 20))             // Plan and Tasks (inside it) both end where ## Notes begins
            h.select(lineStart(h, 20))
            h.textView.perform(selector, with: nil)
            XCTAssertEqual(h.textView.string, text, "\(name): nothing was deleted")
            XCTAssertEqual(foldedHeaders(h), ["## Notes"], "\(name): the folds that hid the join opened; Notes (below the caret) did not")
            XCTAssertEqual(h.textView.selectedRange(), NSRange(location: lineStart(h, 20), length: 0), "\(name): the caret stayed")
        }
    }

    func testForwardDeleteAtTheEndOfAFoldedHeaderOpensItAndDeletesNothing() async throws {
        let text = try Self.fixtureF()
        let variants: [(String, Selector)] = [("⌦", #selector(NSResponder.deleteForward(_:))), ("⌥⌦", #selector(NSResponder.deleteWordForward(_:))),
                                              ("⌘⌦", #selector(NSResponder.deleteToEndOfLine(_:))), ("paragraph", #selector(NSResponder.deleteToEndOfParagraph(_:)))]
        for (name, selector) in variants {
            let h = try await fixtureHarness()
            h.coordinator.setFoldState(folded(h, 5, 20))
            h.select(lineEnd(h, 5))
            h.textView.perform(selector, with: nil)
            XCTAssertEqual(h.textView.string, text, "\(name): nothing was deleted")
            XCTAssertEqual(foldedHeaders(h), ["## Notes"], "\(name)")
        }
    }

    func testDeletingElsewhereIsOrdinaryAndKeepsFolds() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5))
        h.select(lineEnd(h, 3))                                         // end of "Intro paragraph."
        h.textView.deleteBackward(nil)
        XCTAssertTrue(h.textView.string.contains("Intro paragraph\n"), "an ordinary Backspace")
        h.select(lineEnd(h, 5) - 1)                                     // inside the folded header, before its last letter
        h.textView.deleteForward(nil)
        XCTAssertTrue(h.textView.string.contains("## Pla\n"), "forward delete inside the header deletes a character")
        XCTAssertEqual(foldedHeaders(h).count, 1, "and the fold stays")
        h.select(lineEnd(h, 5))                                         // at the end of the header: Backspace is ordinary (the letter before the caret shows)
        h.textView.deleteBackward(nil)
        XCTAssertTrue(h.textView.string.contains("## Pl\n"))
        XCTAssertEqual(foldedHeaders(h).count, 1)
    }

    func testSelectionsAcrossFoldsActOnTheHiddenTextToo() async throws {
        let h = try await fixtureHarness()
        let text = try Self.fixtureF()
        h.coordinator.setFoldState(folded(h, 5))
        h.select(lineStart(h, 3), lineStart(h, 20) - lineStart(h, 3))      // from the intro through the whole folded section
        // (What Copy and Cut take is the selected text, with nothing left out: no pasteboard is touched here.)
        let copied = h.textView.attributedSubstring(forProposedRange: h.textView.selectedRange(), actualRange: nil)?.string ?? ""
        XCTAssertTrue(copied.contains("Plan text.") && copied.contains("| 1 | 2 |"), "copy includes the hidden lines")
        h.textView.delete(nil)
        XCTAssertFalse(h.textView.string.contains("Plan text."), "delete removes them too")
        XCTAssertEqual(foldedHeaders(h), [], "the folded header went with the selection")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.textView.string, text, "and undo brings the text back")
    }

    func testTypingOverASelectionThatStartsBeforeTheHeaderDropsTheFold() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 20))
        h.select(lineEnd(h, 3) - 4, lineStart(h, 5) + 5 - (lineEnd(h, 3) - 4))
        h.textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(foldedHeaders(h), ["## Notes"], "Plan's header was overwritten, so its fold is gone; Notes is unaffected")
    }

    func testTypingElsewhereNeverOpensOrClosesAFold() async throws {
        let h = try await fixtureHarness()
        h.coordinator.setFoldState(folded(h, 5, 26))
        let before = foldedHeaders(h)
        for needle in ["Intro", "## Empty", "Final line"] {
            h.select(h.index(of: needle) + 2)
            h.textView.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        h.select(h.index(of: "Plan") + 1)                                  // on the folded header's own text
        h.textView.insertText("q", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(foldedHeaders(h).count, before.count)
        XCTAssertTrue(foldedHeaders(h).contains { $0.contains("Pqlan") || $0.contains("Plan") })
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
