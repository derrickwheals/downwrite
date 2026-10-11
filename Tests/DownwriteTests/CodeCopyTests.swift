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

    // MARK: When it shows (D2)

    /// A point (text view coordinates) on the line holding the character at `index`, `x` points in from the left of the text column.
    private func point(_ h: EditorHarness, at index: Int, x: CGFloat = 100) -> NSPoint {
        let o = h.textView.textContainerOrigin
        return NSPoint(x: o.x + x, y: o.y + lineRect(h, at: index).midY)
    }

    private func controlFrame(_ h: EditorHarness, block i: Int = 0) -> NSRect {
        h.coordinator.copyControlFrame(ofBlock: i, in: layout(h))!
    }

    func testTheControlShowsOnTheBlockUnderThePointerAndGoesWhenItLeaves() {
        let h = ready()
        let lm = layout(h)
        XCTAssertEqual(lm.codeBlocks, h.coordinator.analysis.codeBlocks)
        XCTAssertNil(lm.hoveredCodeBlock)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let a")))
        XCTAssertEqual(lm.hoveredCodeBlock, 0)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let b")))
        XCTAssertEqual(lm.hoveredCodeBlock, 0, "any line of the block")
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "intro")))
        XCTAssertNil(lm.hoveredCodeBlock)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let a")))
        h.coordinator.pointerLeft()
        XCTAssertNil(lm.hoveredCodeBlock)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "after")))
        XCTAssertNil(lm.hoveredCodeBlock)
    }

    func testThePointerOutInAMarginDoesNotShowTheControl() {
        let h = ready()
        let o = h.textView.textContainerOrigin
        let y = point(h, at: h.index(of: "let a")).y
        let width = h.textView.textContainer!.size.width
        h.coordinator.pointerMoved(to: NSPoint(x: o.x - 10, y: y))
        XCTAssertNil(layout(h).hoveredCodeBlock, "left margin")
        h.coordinator.pointerMoved(to: NSPoint(x: o.x + width + 10, y: y))
        XCTAssertNil(layout(h).hoveredCodeBlock, "right margin")
        h.coordinator.pointerMoved(to: NSPoint(x: o.x + 5, y: y))
        XCTAssertEqual(layout(h).hoveredCodeBlock, 0, "just inside the column")
    }

    func testThePointerOnTheControlItselfIsToldApart() {
        let h = ready()
        let frame = controlFrame(h)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let a")))
        XCTAssertFalse(layout(h).pointerOnCopyControl)
        h.coordinator.pointerMoved(to: NSPoint(x: frame.midX, y: frame.midY))
        XCTAssertEqual(layout(h).hoveredCodeBlock, 0)
        XCTAssertTrue(layout(h).pointerOnCopyControl)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let b")))
        XCTAssertFalse(layout(h).pointerOnCopyControl)
        h.coordinator.pointerMoved(to: NSPoint(x: frame.midX, y: frame.midY))
        h.coordinator.pointerLeft()
        XCTAssertFalse(layout(h).pointerOnCopyControl)
    }

    func testTheControlShowsWhileTheCaretIsInTheBlockEndsIncluded() {
        let h = ready()
        let r = h.coordinator.analysis.codeBlocks[0].range
        XCTAssertNil(layout(h).activeCodeBlock, "the caret is at the end of the document")
        for (offset, shows) in [(r.location - 1, false), (r.location, true), (r.location + 14, true), (NSMaxRange(r), true), (NSMaxRange(r) + 1, false)] {
            h.select(offset)
            XCTAssertEqual(layout(h).activeCodeBlock, shows ? 0 : nil, "caret at \(offset - r.location) in a block of \(r.length)")
        }
    }

    func testASelectionThatTouchesTheBlockShowsItsControl() {
        let h = ready()
        let r = h.coordinator.analysis.codeBlocks[0].range
        h.select(0, r.location + 3)                                  // from the top of the document into the block
        XCTAssertEqual(layout(h).activeCodeBlock, 0)
        h.select(NSMaxRange(r) - 2, 10)                              // from inside it to the text after
        XCTAssertEqual(layout(h).activeCodeBlock, 0)
        h.select(0, r.location - 1)                                  // ends just short of it
        XCTAssertNil(layout(h).activeCodeBlock)
    }

    func testSelectAllShowsTheControlOfTheFirstBlockOnly() {
        let h = ready("```\none\n```\n\n```\ntwo\n```\n")
        h.select(0, h.textView.string.utf16.count)
        XCTAssertEqual(h.coordinator.analysis.codeBlocks.count, 2)
        XCTAssertEqual(layout(h).activeCodeBlock, 0)
    }

    func testTheActiveBlockFollowsTheCaretThroughAnEditAbove() {
        let h = ready("```\none\n```\n\n```\ntwo\n```\n\nend\n")
        let blocks = h.coordinator.analysis.codeBlocks
        h.select(blocks[1].range.location + 6)
        XCTAssertEqual(layout(h).activeCodeBlock, 1)
        // Remove the first block: the caret's block is now the only one.
        h.textView.insertText("", replacementRange: NSRange(location: 0, length: blocks[1].range.location))
        XCTAssertEqual(h.coordinator.analysis.codeBlocks.count, 1)
        XCTAssertEqual(layout(h).codeBlocks, h.coordinator.analysis.codeBlocks)
        XCTAssertEqual(layout(h).activeCodeBlock, 0)
        // And with the caret back at the end of the document no block is active.
        h.select(h.textView.string.utf16.count)
        XCTAssertNil(layout(h).activeCodeBlock)
    }

    func testAnEditClearsThePointersBlockAndTheTick() {
        let h = ready()
        layout(h).hoveredCodeBlock = 0
        layout(h).pointerOnCopyControl = true
        layout(h).copiedCodeBlock = 0
        h.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(layout(h).hoveredCodeBlock)
        XCTAssertFalse(layout(h).pointerOnCopyControl)
        XCTAssertNil(layout(h).copiedCodeBlock)
        XCTAssertEqual(layout(h).codeBlocks, h.coordinator.analysis.codeBlocks, "the new offsets")
    }

    func testTheSourceViewHasNoControlAndTheFormattedViewGetsItBack() {
        let h = ready()
        h.select(h.index(of: "let a"))
        XCTAssertEqual(layout(h).activeCodeBlock, 0)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let a")))
        layout(h).copiedCodeBlock = 0
        h.coordinator.setSourceMode(true)
        XCTAssertEqual(layout(h).codeBlocks, [])
        XCTAssertNil(layout(h).activeCodeBlock)
        XCTAssertNil(layout(h).hoveredCodeBlock)
        XCTAssertNil(layout(h).copiedCodeBlock)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let a")))
        XCTAssertNil(layout(h).hoveredCodeBlock, "the pointer over source text shows nothing")
        h.select(h.index(of: "let b"))
        XCTAssertNil(layout(h).activeCodeBlock, "nor does the caret")
        h.coordinator.setSourceMode(false)
        XCTAssertEqual(layout(h).codeBlocks, h.coordinator.analysis.codeBlocks)
        XCTAssertEqual(layout(h).activeCodeBlock, 0, "back with the caret still in the block")
    }

    func testAFoldedBlockAndACollapsedMermaidCardCannotBeHovered() {
        let h = ready("# Title\n\n```sh\nls\n```\n\n# Other\n\ntext\n\n```mermaid\ngraph TD\n  A-->B\n```\n\nend\n")
        let lm = layout(h)
        let mermaid = h.coordinator.analysis.codeBlocks[1]
        // The collapsed diagram's last line is as tall as the card it reserves room for: the pointer there is on the diagram.
        let cardLine = lineRect(h, at: h.index(of: "```\n\nend"))
        XCTAssertGreaterThan(cardLine.height, 20)
        h.coordinator.pointerMoved(to: NSPoint(x: h.textView.textContainerOrigin.x + 100, y: h.textView.textContainerOrigin.y + cardLine.midY))
        XCTAssertNil(lm.hoveredCodeBlock, "the rendered diagram has no control")
        h.select(mermaid.range.location + 15)
        XCTAssertEqual(lm.activeCodeBlock, 1, "its source shows as a code card while the caret is inside")
        XCTAssertNotNil(h.coordinator.copyControlFrame(ofBlock: 1, in: lm))
        // Folded away: nothing to point at, and the caret cannot be inside it.
        h.select(h.textView.string.utf16.count)
        let region = h.coordinator.analysis.foldRegions.first { $0.headerLines.lowerBound == 0 }!
        h.coordinator.setFoldState(FoldState().toggled(region))
        XCTAssertNil(h.coordinator.copyControlFrame(ofBlock: 0, in: lm))
        XCTAssertNil(lm.activeCodeBlock)
    }

    func testPointerMovementEditsNoText() {
        let h = ready()
        let storage = h.textView.textStorage!
        var edits = 0
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        h.window.displayIfNeeded()
        let words = ["intro", "let a", "let b", "after", "let a"]
        for round in 0..<8 { for w in words { h.coordinator.pointerMoved(to: point(h, at: h.index(of: w), x: CGFloat(20 + round * 30))) } }
        h.coordinator.pointerLeft()
        XCTAssertEqual(edits, 0, "no restyle, no text-storage edit")

    }

    /// Everything the controls ask to have redrawn is the controls' own rectangle (a point of slack around it).
    func testMovingThePointerOrTheCaretRedrawsOnlyTheControls() {
        let h = ready()
        var asked: [NSRect] = []
        h.coordinator.onCopyControlInvalidated = { asked.append($0) }
        let frame = controlFrame(h)
        func onlyTheControl(_ what: String) {
            XCTAssertFalse(asked.isEmpty, what)
            for r in asked { XCTAssertTrue(frame.insetBy(dx: -2, dy: -2).contains(r), "\(what): \(r) is outside the control \(frame)") }
            asked = []
        }
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let a")))
        onlyTheControl("the pointer enters the block")
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let b"), x: 300))
        XCTAssertTrue(asked.isEmpty, "moving within the block changes nothing")
        h.coordinator.pointerMoved(to: NSPoint(x: frame.midX, y: frame.midY))
        onlyTheControl("the pointer reaches the control")
        h.coordinator.pointerLeft()
        onlyTheControl("the pointer leaves")
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "intro")))
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "after")))
        XCTAssertTrue(asked.isEmpty, "moving over other text changes nothing")
        // The caret goes in: the fences reveal, so the card's first line (and the control with it) moves up to the fence line.
        h.select(h.index(of: "let a"))
        let revealed = controlFrame(h)
        XCTAssertNotEqual(revealed.minY, frame.minY)
        XCTAssertFalse(asked.isEmpty)
        for r in asked { XCTAssertTrue(r.height < 30 && r.width < 30, "\(r) is a control's rectangle, not a band of text") }
    }

    func testTheControlTakesTheThemesColours() {
        let h = ready()
        XCTAssertEqual(layout(h).copyControlStyle, CopyControlStyle(palette: h.coordinator.styler.palette))
        h.coordinator.update(text: h.textView.string, settings: EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720,
                                                                               lightTheme: "catppuccin-latte", darkTheme: "catppuccin-latte"))
        XCTAssertEqual(h.coordinator.styler.palette, ThemeCatalog.builtIn.first { $0.id == "catppuccin-latte" }!.palette)
        XCTAssertEqual(layout(h).copyControlStyle, CopyControlStyle(palette: h.coordinator.styler.palette))
    }

    // MARK: Clicking it (D1, D4, D7)

    /// The harness with a private pasteboard (the person's clipboard is never touched) and a short tick.
    private func armed(_ text: String = CodeCopyTests.doc, tick: TimeInterval = 0.25) -> (h: EditorHarness, pb: NSPasteboard) {
        let h = ready(text)
        let pb = NSPasteboard(name: NSPasteboard.Name("downwrite.test.codecopy.\(UUID().uuidString)"))
        pb.clearContents()
        h.coordinator.codeCopyPasteboard = pb
        h.coordinator.codeCopyTickDuration = tick
        return (h, pb)
    }

    /// A left click at `point` (text view coordinates). A click that is not on a control falls through to `NSTextView`, which tracks
    /// the mouse until the button comes up, so `release` posts that mouse-up first.
    private func click(_ h: EditorHarness, atView point: NSPoint, count: Int = 1, release: Bool = false) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: h.textView.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        if release { NSApp.postEvent(event(.leftMouseUp), atStart: false) }
        h.textView.mouseDown(with: event(.leftMouseDown))
    }

    private func centre(_ r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }

    /// Moves the pointer onto block `i` and clicks its control.
    private func clickControl(_ h: EditorHarness, block i: Int = 0, count: Int = 1) {
        let lm = layout(h)
        let block = h.coordinator.analysis.codeBlocks[i]
        h.coordinator.pointerMoved(to: point(h, at: block.range.location + (block.range.length / 2)))
        click(h, atView: centre(controlFrame(h, block: i)), count: count)
        XCTAssertNotNil(lm.hoveredCodeBlock)
    }

    func testClickingTheControlPutsExactlyTheCodeOnTheClipboardAsPlainText() {
        let (h, pb) = armed()
        clickControl(h)
        XCTAssertEqual(pb.string(forType: .string), "let a = 1\nlet b = 2", "no fences, no language tag, no final line break")
        // Plain text only. (AppKit lists its synonyms for a string, such as the UTF-8 and legacy types; there is no styled flavour.)
        let types = Set(pb.types ?? [])
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.isDisjoint(with: [.rtf, .rtfd, .html, .pdf, .tiff, .png, .fileURL, .URL]), "no RTF, HTML or other flavour: \(types)")
    }

    func testTheSameTextIsCopiedWithTheFencesRevealed() {
        let (h, pb) = armed()
        h.select(h.index(of: "let b") + 3)
        XCTAssertGreaterThan(lineRect(h, at: h.index(of: "```swift")).height, 1, "revealed")
        clickControl(h)
        XCTAssertEqual(pb.string(forType: .string), "let a = 1\nlet b = 2")
    }

    func testBlocksInAQuoteAnListAndIndentedBlocksCopyWithoutTheirPrefix() {
        let (h, pb) = armed("para\n\n    indented\n      deeper\n\n> ```sh\n> echo hi\n> ls\n> ```\n\n- item\n\n  ```\n  npm i\n\n  npm test\n  ```\n\nend\n")
        XCTAssertEqual(h.coordinator.analysis.codeBlocks.count, 3)
        for (i, expected) in ["indented\n  deeper", "echo hi\nls", "npm i\n\nnpm test"].enumerated() {
            pb.clearContents()
            clickControl(h, block: i)
            XCTAssertEqual(pb.string(forType: .string), expected, "block \(i)")
        }
    }

    func testAMermaidBlockCopiesItsSourceWhileItShows() {
        let (h, pb) = armed("intro\n\n```mermaid\ngraph TD\n  A-->B\n```\n\nafter\n")
        h.select(h.index(of: "graph TD") + 2)
        click(h, atView: centre(controlFrame(h)))
        XCTAssertEqual(pb.string(forType: .string), "graph TD\n  A-->B")
    }

    func testCopyingLeavesTheDocumentTheCaretAndTheUndoStackAlone() {
        let (h, _) = armed()
        h.select(h.index(of: "after"), 2)
        let text = h.textView.string, selection = h.textView.selectedRange()
        var changes = 0
        let token = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: h.textView, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        h.textView.undoManager?.removeAllActions()
        clickControl(h)
        XCTAssertEqual(h.textView.string, text)
        XCTAssertEqual(h.box.value, text, "nothing reached the document")
        XCTAssertEqual(h.textView.selectedRange(), selection, "the selection stays where it was")
        XCTAssertEqual(changes, 0, "no didChangeText")
        XCTAssertEqual(h.textView.undoManager?.canUndo, false, "no undo entry")
    }

    func testClickingTheControlGivesTheEditorTheKeyboardWithoutMovingTheCaret() {
        let (h, _) = armed()
        h.window.makeFirstResponder(nil)
        let caret = h.textView.selectedRange()
        clickControl(h)
        XCTAssertTrue(h.window.firstResponder === h.textView)
        XCTAssertEqual(h.textView.selectedRange(), caret)
    }

    func testADoubleClickOnTheControlDoesNothing() {
        let (h, pb) = armed()
        let caret = h.textView.selectedRange()
        clickControl(h, count: 2)
        XCTAssertNil(pb.string(forType: .string))
        XCTAssertEqual(h.textView.selectedRange(), caret, "and it does not select a word either")
        XCTAssertNil(layout(h).copiedCodeBlock)
    }

    func testAClickOnTheCardAwayFromTheControlMovesTheCaretAsUsual() {
        let (h, pb) = armed()
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "let b")))
        click(h, atView: point(h, at: h.index(of: "let b"), x: 40), release: true)
        XCTAssertNil(pb.string(forType: .string))
        let r = h.coordinator.analysis.codeBlocks[0].range
        XCTAssertTrue(NSLocationInRange(h.textView.selectedRange().location, r), "the caret went into the block")
        XCTAssertEqual(layout(h).activeCodeBlock, 0)
    }

    func testAClickWhereTheControlIsNotShowingIsAnOrdinaryClick() {
        let (h, pb) = armed()
        XCTAssertNil(layout(h).hoveredCodeBlock)
        XCTAssertNil(layout(h).activeCodeBlock)
        let place = centre(controlFrame(h))
        click(h, atView: place, release: true)
        XCTAssertNil(pb.string(forType: .string), "nothing is copied")
        XCTAssertTrue(NSLocationInRange(h.textView.selectedRange().location, h.coordinator.analysis.codeBlocks[0].range) ||
                      h.textView.selectedRange().location == NSMaxRange(h.coordinator.analysis.codeBlocks[0].range),
                      "the caret moved to the click, into the card")
    }

    func testTheTickShowsAtOnceAndGoesAfterAMoment() async {
        let (h, _) = armed(tick: 0.2)
        clickControl(h)
        XCTAssertEqual(layout(h).copiedCodeBlock, 0, "ticked")
        XCTAssertNotNil(h.coordinator.codeCopyTickTimer)
        let gone = await waitUntil(timeout: 5) { self.layout(h).copiedCodeBlock == nil }
        XCTAssertTrue(gone, "the tick reverts to the normal control")
        XCTAssertNil(h.coordinator.codeCopyTickTimer)
    }

    func testTheTickIsDroppedByAnEditAndByTheSourceView() {
        let (h, _) = armed(tick: 30)
        clickControl(h)
        XCTAssertEqual(layout(h).copiedCodeBlock, 0)
        h.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(layout(h).copiedCodeBlock)
        XCTAssertNil(h.coordinator.codeCopyTickTimer, "and its timer with it")
        clickControl(h)
        XCTAssertEqual(layout(h).copiedCodeBlock, 0)
        h.coordinator.setSourceMode(true)
        XCTAssertNil(layout(h).copiedCodeBlock)
        XCTAssertNil(h.coordinator.codeCopyTickTimer)
    }

    func testEachCopyIsAnnounced() {
        let (h, _) = armed(tick: 30)
        var heard: [String] = []
        h.coordinator.onAnnouncement = { heard.append($0) }
        clickControl(h)
        clickControl(h)
        XCTAssertEqual(heard, ["Copied code block", "Copied code block"])
    }

    func testAClickRunsThePendingAnalysisOfABigDocumentFirst() {
        // Over 400,000 characters the analysis follows an edit 150 ms late; a click in that gap must still copy the new text.
        let filler = String(repeating: String(repeating: "x", count: 99) + "\n", count: 4_100)
        let (h, pb) = armed("```\nold\n```\n\n" + filler)
        XCTAssertGreaterThan(h.textView.string.utf16.count, 400_000)
        h.coordinator.pointerMoved(to: point(h, at: h.index(of: "old")))
        XCTAssertEqual(layout(h).hoveredCodeBlock, 0)
        let frame = controlFrame(h)
        h.textView.insertText("newer", replacementRange: NSRange(location: h.index(of: "old"), length: 3))
        XCTAssertEqual(h.coordinator.analysis.codeBlocks[0].text, "old", "the analysis is still the old one")
        click(h, atView: centre(frame))
        XCTAssertEqual(pb.string(forType: .string), "newer")
        XCTAssertEqual(h.coordinator.analysis.codeBlocks[0].text, "newer")
        XCTAssertEqual(layout(h).copiedCodeBlock, 0)
    }

    // MARK: The command and the accessibility action (D6)

    func testCopyCodeBlockCopiesTheBlockTheCaretIsInEndsIncluded() {
        let (h, pb) = armed(tick: 30)
        let r = h.coordinator.analysis.codeBlocks[0].range
        for offset in [r.location, r.location + 14, NSMaxRange(r)] {
            pb.clearContents()
            h.select(offset)
            XCTAssertTrue(NSApp.sendAction(#selector(EditorTextView.dwCopyCodeBlock(_:)), to: h.textView, from: nil))
            XCTAssertEqual(pb.string(forType: .string), "let a = 1\nlet b = 2", "caret at \(offset - r.location)")
        }
        XCTAssertEqual(layout(h).copiedCodeBlock, 0, "and its control shows the tick")
    }

    func testCopyCodeBlockBeepsAndLeavesTheClipboardWhenTheCaretIsNotInABlock() {
        let (h, pb) = armed()
        pb.setString("keep me", forType: .string)
        var beeps = 0
        h.coordinator.beep = { beeps += 1 }
        var heard: [String] = []
        h.coordinator.onAnnouncement = { heard.append($0) }
        let r = h.coordinator.analysis.codeBlocks[0].range
        for offset in [0, r.location - 1, NSMaxRange(r) + 1, h.textView.string.utf16.count] {
            h.select(offset)
            h.textView.dwCopyCodeBlock(nil)
        }
        XCTAssertEqual(beeps, 4)
        XCTAssertEqual(pb.string(forType: .string), "keep me")
        XCTAssertNil(layout(h).copiedCodeBlock)
        XCTAssertEqual(heard, [], "nothing was copied, so nothing is announced")
    }

    func testCopyCodeBlockLeavesTheDocumentAloneAndIsAnnounced() {
        let (h, _) = armed()
        var heard: [String] = []
        h.coordinator.onAnnouncement = { heard.append($0) }
        h.select(h.index(of: "let a") + 2)
        let text = h.textView.string, caret = h.textView.selectedRange()
        h.textView.undoManager?.removeAllActions()
        h.textView.dwCopyCodeBlock(nil)
        XCTAssertEqual(h.textView.string, text)
        XCTAssertEqual(h.box.value, text)
        XCTAssertEqual(h.textView.selectedRange(), caret)
        XCTAssertEqual(h.textView.undoManager?.canUndo, false)
        XCTAssertEqual(heard, ["Copied code block"])
    }

    func testCopyCodeBlockWorksInTheSourceViewWhereNothingIsDrawn() {
        let (h, pb) = armed()
        h.coordinator.setSourceMode(true)
        h.select(h.index(of: "let b") + 1)
        h.textView.dwCopyCodeBlock(nil)
        XCTAssertEqual(pb.string(forType: .string), "let a = 1\nlet b = 2", "the code, not the fences, even though the source shows them")
        XCTAssertNil(layout(h).copiedCodeBlock, "no control, so no tick")
        XCTAssertNil(h.coordinator.codeCopyTickTimer)
    }

    func testCopyCodeBlockActsOnTheFirstBlockASelectionTouches() {
        let (h, pb) = armed("```\none\n```\n\ntext\n\n```\ntwo\n```\n")
        h.select(0, h.textView.string.utf16.count)
        h.textView.dwCopyCodeBlock(nil)
        XCTAssertEqual(pb.string(forType: .string), "one", "the block whose control shows")
        let second = h.coordinator.analysis.codeBlocks[1].range
        pb.clearContents()
        h.select(second.location + 4)
        h.textView.dwCopyCodeBlock(nil)
        XCTAssertEqual(pb.string(forType: .string), "two")
    }

    func testTheAccessibilityActionIsOfferedOnlyWhileTheCaretIsInABlockAndCopies() {
        let (h, pb) = armed()
        func names() -> [String] { (h.textView.accessibilityCustomActions() ?? []).map(\.name) }
        XCTAssertFalse(names().contains("Copy Code Block"), "the caret is at the end of the document")
        h.select(h.index(of: "intro"))
        XCTAssertFalse(names().contains("Copy Code Block"))
        h.select(h.index(of: "let a") + 3)
        XCTAssertTrue(names().contains("Copy Code Block"))
        let action = (h.textView.accessibilityCustomActions() ?? []).first { $0.name == "Copy Code Block" }!
        XCTAssertEqual(action.handler?(), true, "performing it reports success")
        XCTAssertEqual(pb.string(forType: .string), "let a = 1\nlet b = 2")
        h.select(h.index(of: "after"))
        XCTAssertFalse(names().contains("Copy Code Block"))
        h.coordinator.setSourceMode(true)
        h.select(h.index(of: "let a") + 3)
        XCTAssertTrue(names().contains("Copy Code Block"), "it is a command on the text, so the source view has it too")
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
