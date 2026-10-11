import AppKit
import DownwriteCore

/// The copy control on code cards (DW-012): which block shows it. The layout manager draws it from the state set here (like the fold
/// chevrons), so moving the pointer or the caret never touches the text storage: it only redraws the rectangles of the controls
/// that appear or go.
extension EditorCoordinator {
    // MARK: State
    // A control shows on the block under the pointer (while the pointer is inside the text column) and on the block the selection
    // touches, by the rule that reveals its fences. The source view, a folded block and a collapsed Mermaid source show none.

    /// Hands the layout manager this analysis' code blocks (none in the source view) and recomputes what shows. The pointer's block
    /// and a tick belong to the old text and are dropped; the next mouse move sets the pointer's again.
    func syncCodeBlocks() {
        guard let tv = textView, let lm = tv.layoutManager as? DWLayoutManager else { return }
        let before = copyControlFrames(in: lm)
        lm.codeBlocks = sourceMode ? [] : analysis.codeBlocks
        lm.hoveredCodeBlock = nil
        lm.pointerOnCopyControl = false
        lm.copiedCodeBlock = nil
        lm.activeCodeBlock = activeCodeBlockIndex(for: tv.selectedRange())
        invalidate(before + copyControlFrames(in: lm), in: tv)
    }

    /// The caret or selection moved: the control of the block it touches shows, the previous one goes. `before` are the frames
    /// of the controls showing before the restyle that came with the move (lines above can change height and shift the card).
    func updateActiveCodeBlock(selection: NSRange, framesBefore before: [NSRect]) {
        guard let tv = textView, let lm = tv.layoutManager as? DWLayoutManager else { return }
        lm.activeCodeBlock = activeCodeBlockIndex(for: selection)
        invalidate(before + copyControlFrames(in: lm), in: tv)
    }

    /// The first block the selection touches (the caret's block, for a caret). Several blocks can be revealed by one selection
    /// (Select All); only the first shows its control, which is also the one Copy Code Block acts on.
    private func activeCodeBlockIndex(for selection: NSRange) -> Int? {
        guard !sourceMode, textView?.textStorage?.length == analysis.length else { return nil }
        return analysis.codeBlockIndex(touching: selection)
    }

    /// The pointer moved: `hit` is the line under it (nil off the text). Only a block whose control is on screen can be hovered, and
    /// only from inside the text column, so the control does not appear while the pointer is out in a margin.
    func setHoveredCodeBlock(at point: NSPoint, hit: (line: Int, inColumn: Bool)?, in lm: DWLayoutManager) {
        var block: Int?
        var onControl = false
        if let hit, hit.inColumn, let i = analysis.codeBlockIndex(containingLine: hit.line), let frame = copyControlFrame(ofBlock: i, in: lm) {
            block = i
            onControl = frame.contains(point)
        }
        guard block != lm.hoveredCodeBlock || onControl != lm.pointerOnCopyControl else { return }
        let before = copyControlFrames(in: lm)
        lm.hoveredCodeBlock = block
        lm.pointerOnCopyControl = onControl
        if let tv = textView { invalidate(before + copyControlFrames(in: lm), in: tv) }
    }

    func clearHoveredCodeBlock(in lm: DWLayoutManager) {
        guard lm.hoveredCodeBlock != nil || lm.pointerOnCopyControl else { return }
        let before = copyControlFrames(in: lm)
        lm.hoveredCodeBlock = nil
        lm.pointerOnCopyControl = false
        if let tv = textView { invalidate(before, in: tv) }
    }

    /// Hands the layout manager the colours of the current palette.
    func refreshCopyControlStyle() {
        guard let tv = textView, let lm = tv.layoutManager as? DWLayoutManager, styler != nil else { return }
        let style = CopyControlStyle(palette: styler.palette)
        guard style != lm.copyControlStyle else { return }
        lm.copyControlStyle = style
        invalidate(copyControlFrames(in: lm), in: tv)
    }

    // MARK: Geometry

    /// Block `index`'s control in text view coordinates; nil when it has none on screen (folded, collapsed, or text not laid out yet).
    func copyControlFrame(ofBlock index: Int, in lm: DWLayoutManager) -> NSRect? {
        guard let tv = textView, lm.codeBlocks.indices.contains(index),
              let box = lm.copyControlRect(forBlock: lm.codeBlocks[index]) else { return nil }
        return box.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
    }

    /// The frames of the controls the layout manager is told to draw now.
    func copyControlFrames(in lm: DWLayoutManager) -> [NSRect] {
        [lm.hoveredCodeBlock, lm.activeCodeBlock, lm.copiedCodeBlock].compactMap { $0 }.compactMap { copyControlFrame(ofBlock: $0, in: lm) }
    }

    private func invalidate(_ frames: [NSRect], in tv: NSTextView) {
        for frame in frames {
            let dirty = frame.insetBy(dx: -1, dy: -1)
            tv.setNeedsDisplay(dirty)
            onCopyControlInvalidated?(dirty)
        }
    }
}
