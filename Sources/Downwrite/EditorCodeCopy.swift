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
        codeCopyTickTimer?.invalidate()
        codeCopyTickTimer = nil
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

    // MARK: Copying (D1, D4, D7)

    /// The block whose control is on screen at `point` (text view coordinates): the one under the pointer, the one holding the
    /// caret, or the one just copied.
    func codeCopyControl(at point: NSPoint) -> Int? {
        guard !sourceMode, let lm = textView?.layoutManager as? DWLayoutManager else { return nil }
        for index in [lm.hoveredCodeBlock, lm.activeCodeBlock, lm.copiedCodeBlock].compactMap({ $0 }) {
            if let frame = copyControlFrame(ofBlock: index, in: lm), frame.contains(point) { return index }
        }
        return nil
    }

    /// A mouse-down at `point`. If a control is showing there it copies its block and swallows the click: no `super`, so the caret
    /// and the selection stay, and no edit is made. The editor takes the keyboard, as it does for a chevron; a double click does
    /// nothing. Returns whether the click was on a control. A click where no control is showing is an ordinary click.
    func handleCopyControlClick(at point: NSPoint, clickCount: Int) -> Bool {
        guard codeCopyControl(at: point) != nil, let tv = textView else { return false }
        if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
        guard clickCount == 1 else { return true }
        // A big document's last edit may still be waiting to be analysed: copy what is there now, not what was there before it.
        if flushPendingAnalysis() { pointerMoved(to: point) }
        if let block = codeCopyControl(at: point) { copyCodeBlock(index: block) }
        return true
    }

    /// Index of the code block the selection touches, the same one whose control shows (the caret's block, for a caret). Reads the
    /// analysis as it stands once any pending one has run.
    private func codeBlockAtCaret() -> Int? {
        guard let tv = textView, let storage = tv.textStorage else { return nil }
        flushPendingAnalysis()
        guard analysis.length == storage.length else { return nil }
        return analysis.codeBlockIndex(touching: tv.selectedRange())
    }

    /// Whether Copy Code Block has a block to act on, for the accessibility action.
    var hasCodeBlockAtCaret: Bool { codeBlockAtCaret() != nil }

    /// Edit ▸ Copy Code Block: copies the block the caret is in. Works in the source view too, as it is a command on the text and
    /// not the drawn control. Beeps (and leaves the clipboard alone) when the caret is not in a block.
    @discardableResult
    func copyCodeBlockAtCaret() -> Bool {
        guard let index = codeBlockAtCaret() else { beep(); return false }
        copyCodeBlock(index: index)
        return true
    }

    /// Puts block `index`'s code on the pasteboard as plain text (D1), ticks its control for a moment (D4) and announces it. Reads
    /// and writes nothing else: no edit, no undo entry, and the document is not marked as edited.
    func copyCodeBlock(index: Int) {
        guard analysis.codeBlocks.indices.contains(index), let tv = textView else { return beep() }
        codeCopyPasteboard.clearContents()
        codeCopyPasteboard.setString(analysis.codeBlocks[index].text, forType: .string)
        showCopyTick(on: index)
        let message = "Copied code block"
        onAnnouncement?(message)
        NSAccessibility.post(element: tv, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Shows the tick on block `index`'s control for `codeCopyTickDuration`. (No control, no tick: the source view has none.)
    private func showCopyTick(on index: Int) {
        guard let tv = textView, let lm = tv.layoutManager as? DWLayoutManager else { return }
        let before = copyControlFrames(in: lm)
        lm.copiedCodeBlock = lm.codeBlocks.indices.contains(index) ? index : nil
        invalidate(before + copyControlFrames(in: lm), in: tv)
        codeCopyTickTimer?.invalidate()
        codeCopyTickTimer = nil
        guard lm.copiedCodeBlock != nil else { return }
        let timer = Timer(timeInterval: codeCopyTickDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearCopyTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        codeCopyTickTimer = timer
    }

    /// Takes the tick off again.
    func clearCopyTick() {
        codeCopyTickTimer?.invalidate()
        codeCopyTickTimer = nil
        guard let tv = textView, let lm = tv.layoutManager as? DWLayoutManager, lm.copiedCodeBlock != nil else { return }
        let before = copyControlFrames(in: lm)
        lm.copiedCodeBlock = nil
        invalidate(before, in: tv)
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
