import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// The copy control on a code card (DW-012): where it sits, when it shows, what a click or the command copies.
@MainActor
final class CodeCopyTests: XCTestCase {
    static let doc = "intro\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nafter\n"

    private func layout(_ h: EditorHarness) -> DWLayoutManager { h.textView.layoutManager as! DWLayoutManager }

    private func ready(_ text: String = CodeCopyTests.doc) -> EditorHarness {
        let h = EditorHarness(text: text, size: NSSize(width: 900, height: 760))
        h.window.makeKeyAndOrderFront(nil)
        h.window.makeFirstResponder(h.textView)
        h.select(h.textView.string.utf16.count)            // outside every block
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        return h
    }

    /// The line fragment holding the character at `index`, in text container coordinates.
    private func lineRect(_ h: EditorHarness, at index: Int) -> NSRect {
        let lm = layout(h)
        lm.ensureLayout(for: h.textView.textContainer!)
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil)
    }

    /// The card the layout manager draws for block `i`: its visible lines, `cardPad` above and below.
    private func card(_ h: EditorHarness, block i: Int) -> NSRect {
        let lm = layout(h)
        let b = h.coordinator.analysis.codeBlocks[i]
        var union = NSRect.null
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: b.range, actualCharacterRange: nil)) { r, _, _, _, _ in
            if r.height > 1 { union = union.union(r) }
        }
        return union.insetBy(dx: 0, dy: -DWLayoutManager.cardPad)
    }

    // MARK: Geometry (D3)

    func testControlIsASquareSixPointsInFromTheCardsTopRightWithTheFencesCollapsed() {
        let h = ready()
        let block = h.coordinator.analysis.codeBlocks[0]
        let fence = lineRect(h, at: h.index(of: "```swift"))
        XCTAssertLessThan(fence.height, 1, "the fences are collapsed while the caret is outside")
        let first = lineRect(h, at: h.index(of: "let a"))
        let r = layout(h).copyControlRect(forBlock: block)!
        XCTAssertEqual(r.width, 22); XCTAssertEqual(r.height, 22)
        XCTAssertEqual(r.maxX, first.maxX - 6, accuracy: 0.01)
        XCTAssertEqual(r.minY, first.minY, accuracy: 0.01, "6 pt below the card's top edge, which is 6 pt above the first line")
        let c = card(h, block: 0)
        XCTAssertEqual(r.minY - c.minY, 6, accuracy: 0.01)
        XCTAssertEqual(c.maxX - r.maxX, 6, accuracy: 0.01)
        XCTAssertTrue(c.contains(r))
    }

    func testControlMovesToTheOpeningFenceLineWhileTheFencesAreRevealed() {
        let h = ready()
        h.select(h.index(of: "let a"))
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        let fence = lineRect(h, at: h.index(of: "```swift"))
        XCTAssertGreaterThan(fence.height, 1, "revealed")
        let r = layout(h).copyControlRect(forBlock: h.coordinator.analysis.codeBlocks[0])!
        XCTAssertEqual(r.minY, fence.minY, accuracy: 0.01)
        XCTAssertEqual(r.maxX, fence.maxX - 6, accuracy: 0.01)
        XCTAssertTrue(card(h, block: 0).contains(r))
    }

    func testControlStaysInsideTheCardOfAnIndentedBlockAndOfBlocksInAQuoteAndAList() {
        let h = ready("para\n\n    indented\n\n> ```sh\n> quoted\n> ```\n\n- item\n\n  ```sh\n  listed\n  ```\n\nend\n")
        let blocks = h.coordinator.analysis.codeBlocks
        XCTAssertEqual(blocks.count, 3)
        for (i, b) in blocks.enumerated() {
            let r = layout(h).copyControlRect(forBlock: b)
            XCTAssertNotNil(r, "block \(i)")
            XCTAssertTrue(r.map { card(h, block: i).contains($0) } ?? false, "block \(i) control is inside its card")
        }
    }

    func testNoControlForAFoldedBlock() {
        let h = ready("# Title\n\n```sh\nls\n```\n\n# Other\n\ntext\n")
        let region = h.coordinator.analysis.foldRegions.first { $0.headerLines.lowerBound == 0 }!
        h.coordinator.setFoldState(FoldState().toggled(region))
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        XCTAssertNil(layout(h).copyControlRect(forBlock: h.coordinator.analysis.codeBlocks[0]))
    }

    func testNoControlForACollapsedMermaidSourceAndOneWhileItsSourceShows() {
        let h = ready("intro\n\n```mermaid\ngraph TD\n  A-->B\n```\n\nafter\n")
        let block = h.coordinator.analysis.codeBlocks[0]
        XCTAssertNil(layout(h).copyControlRect(forBlock: block), "collapsed under its rendered diagram")
        h.select(h.index(of: "graph TD"))
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        XCTAssertNotNil(layout(h).copyControlRect(forBlock: block), "the source shows as a code card")
    }

    func testRangesBeyondTheTextAreClampedAndEmptyOnesHaveNoControl() {
        let h = ready()
        let real = h.coordinator.analysis.codeBlocks[0]
        var stale = real
        stale.range = NSRange(location: real.range.location, length: 100_000)
        XCTAssertEqual(layout(h).copyControlRect(forBlock: stale), layout(h).copyControlRect(forBlock: real))
        stale.range = NSRange(location: 100_000, length: 5)
        XCTAssertNil(layout(h).copyControlRect(forBlock: stale))
        stale.range = NSRange(location: 3, length: 0)
        XCTAssertNil(layout(h).copyControlRect(forBlock: stale))
        let empty = EditorHarness(text: "")
        XCTAssertNil(layout(empty).copyControlRect(forBlock: real))
    }
}
