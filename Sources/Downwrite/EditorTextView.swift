import AppKit
import DownwriteCore

/// Carries a `FormatCommand` through the responder chain (`NSApp.sendAction` takes an `Any?` sender).
final class FormatCommandBox: NSObject {
    let command: FormatCommand
    init(_ command: FormatCommand) { self.command = command }
}

/// Carries the level of a Fold to Level command through the responder chain.
final class FoldLevelBox: NSObject {
    let level: Int
    init(_ level: Int) { self.level = level }
}

/// The Markdown editing surface: a TextKit 1 `NSTextView` with Markdown-aware commands, smart Return/Tab,
/// clickable task boxes and a centred readable column.
final class EditorTextView: NSTextView {
    weak var coordinator: EditorCoordinator?
    /// Identifies the cell whose keystrokes are currently being merged into one undo step (see `applyTableText`).
    var gridTypingKey: AnyHashable?
    private var isApplyingGridEdit = false
    var maxContentWidth: CGFloat = 720 { didSet { if oldValue != maxContentWidth { updateInsets() } } }
    private let minSideInset: CGFloat = 30

    // MARK: Construction

    static func make() -> (NSScrollView, EditorTextView) {
        let storage = NSTextStorage()
        let layout = DWLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.usesFontPanel = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 30, height: 28)
        tv.setAccessibilityIdentifier("editor")
        tv.setAccessibilityLabel("Markdown editor")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = true
        return (scroll, tv)
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        updateInsets()
        // Table grids and preview cards are placed from this view's geometry. A width change re-flows the text but does
        // not reliably produce a layout-completion callback once layout is idle (the sidebar opening and closing), which
        // used to leave a grid in the old column, overlapping the paragraphs below it. Ask for a reposition explicitly.
        if widthChanged { coordinator?.scheduleReposition() }
    }

    func updateInsets() {
        let width = bounds.width
        guard width > 0 else { return }
        let side = max(minSideInset, ((width - maxContentWidth) / 2).rounded())
        let inset = NSSize(width: side, height: 28)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        coordinator?.appearanceDidChange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.appearanceDidChange()
        coordinator?.applyChrome()                 // (the window may only exist now)
    }

    // MARK: Scrolling

    /// Scrolls so the line holding `range.location` sits `margin` points below the top edge of the visible area, as far
    /// as the ends of the document allow.
    func scrollToTop(of range: NSRange, margin: CGFloat = 28, animated: Bool) {
        guard let scroll = enclosingScrollView, let target = scrollTarget(for: range, margin: margin) else { return }
        let clip = scroll.contentView
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scroll.reflectScrolledClipView(clip)
        // Diagram and image cards reserve their height after layout; if the line moved meanwhile, follow it
        // (unless the reader has already scrolled elsewhere).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: animate ? 400_000_000 : 50_000_000)
            guard let self, abs(clip.bounds.origin.y - target.y) <= 1,
                  let settled = self.scrollTarget(for: range, margin: margin), abs(settled.y - target.y) > 1 else { return }
            clip.setBoundsOrigin(settled)
            scroll.reflectScrolledClipView(clip)
        }
    }

    private func scrollTarget(for range: NSRange, margin: CGFloat) -> NSPoint? {
        guard let lm = layoutManager, let storage = textStorage, let scroll = enclosingScrollView, storage.length > 0 else { return nil }
        let location = min(range.location, storage.length - 1)
        // Layout is non-contiguous: everything above the line must be laid out first or its position is only an estimate.
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: location + 1))
        let used = lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: location), effectiveRange: nil)
        let clip = scroll.contentView
        let lineY = used.minY + textContainerOrigin.y
        // A heading that already sits within a margin or two of the start just shows the top of the document.
        let y = lineY <= margin * 2 ? -clip.contentInsets.top : lineY - margin - clip.contentInsets.top
        let wanted = NSRect(x: clip.bounds.origin.x, y: y, width: clip.bounds.width, height: clip.bounds.height)
        return clip.constrainBoundsRect(wanted).origin
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let coordinator, let styler = coordinator.styler else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: coordinator.typography.font(),
            .foregroundColor: styler.palette.marker.nsColor.withAlphaComponent(0.8),
        ]
        "Start writing…".draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: attrs)
    }

    /// Fold chevrons and chips are drawn here, before the text: they reach into the margins, outside the layout manager's clip.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        (layoutManager as? DWLayoutManager)?.drawFoldControls(in: rect, origin: textContainerOrigin)
    }

    override func didChangeText() {
        super.didChangeText()
        if !isApplyingGridEdit { gridTypingKey = nil }
        if string.utf16.count <= 1 { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.tableOverlay?.scheduleHandOff() }
        return ok
    }

    // MARK: Applying edits

    /// Applies a computed edit through the text system so that undo, the delegate and SwiftUI all see it.
    func apply(_ edit: TextEdit, scrollToSelection: Bool = true) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        if scrollToSelection { scrollRangeToVisible(edit.selection) }
    }

    /// Replaces the Markdown of the grid table that starts at `tableStart` — the one write path for everything done in a
    /// grid. Undo is registered by hand so that a run of keystrokes in one cell (`coalesceKey`) is a single step and
    /// every structural change (add row, move column …) is its own.
    func applyTableText(tableStart: Int, markdown: String, undoName: String, coalesceKey: AnyHashable? = nil) {
        guard let storage = textStorage, let analysis = coordinator?.analysis, analysis.length == storage.length,
              let block = analysis.tables.first(where: { $0.isGrid && $0.range.location == tableStart }) else { return }
        let old = (string as NSString).substring(with: block.range)
        guard old != markdown else { return }
        let um = undoManager
        let undoing = um?.isUndoing == true || um?.isRedoing == true
        let continuing = coalesceKey != nil && coalesceKey == gridTypingKey && !undoing
        um?.disableUndoRegistration()
        isApplyingGridEdit = true
        var applied = false
        if shouldChangeText(in: block.range, replacementString: markdown) {
            storage.replaceCharacters(in: block.range, with: markdown)
            didChangeText()
            applied = true
        }
        isApplyingGridEdit = false
        um?.enableUndoRegistration()
        guard applied else { return }
        if !continuing {
            let payload: [String: Any] = ["start": tableStart, "text": old, "name": undoName]
            um?.registerUndo(withTarget: self, selector: #selector(dwUndoTableEdit(_:)), object: payload as NSDictionary)
            um?.setActionName(undoName)
        }
        gridTypingKey = undoing ? nil : coalesceKey
    }

    /// Undo/redo of `applyTableText`: puts the remembered Markdown back (which registers the opposite action).
    @objc func dwUndoTableEdit(_ payload: Any?) {
        guard let d = payload as? [String: Any], let start = d["start"] as? Int, let text = d["text"] as? String else { return }
        gridTypingKey = nil
        applyTableText(tableStart: start, markdown: text, undoName: (d["name"] as? String) ?? "Table Edit")
    }

    func perform(_ command: FormatCommand) {
        guard let edit = Formatter.apply(command, to: string, selection: selectedRange()) else { NSSound.beep(); return }
        apply(edit)
    }

    // MARK: Actions (menu items / shortcuts reach these via the responder chain)

    @objc func dwApplyFormat(_ sender: Any?) {
        guard let box = sender as? FormatCommandBox else { return }
        perform(box.command)
    }

    /// Table commands from the Format menu when the caret is in a table whose Markdown is showing.
    @objc func dwTableCommand(_ sender: Any?) {
        guard let box = sender as? TableCommandBox, let overlay = coordinator?.tableOverlay else { NSSound.beep(); return }
        overlay.perform(box.command, atOffset: selectedRange().location)
    }

    // Folding (View menu): the commands live on the coordinator, which owns the fold state.
    @objc func dwFold(_ sender: Any?) { coordinator?.foldAtCaret() }
    @objc func dwUnfold(_ sender: Any?) { coordinator?.unfoldAtCaret() }
    @objc func dwFoldAll(_ sender: Any?) { coordinator?.foldAll() }
    @objc func dwUnfoldAll(_ sender: Any?) { coordinator?.unfoldAll() }
    @objc func dwFoldToLevel(_ sender: Any?) {
        guard let box = sender as? FoldLevelBox else { return }
        coordinator?.fold(toLevel: box.level)
    }

    @objc func dwIndent(_ sender: Any?) { apply(ListEditing.indent(in: string, selection: selectedRange(), outdent: false)) }
    @objc func dwOutdent(_ sender: Any?) { apply(ListEditing.indent(in: string, selection: selectedRange(), outdent: true)) }

    // MARK: Caret movement over folds (R14)

    /// Arrow keys (with ⌥ and ⌘), Page Up/Down and their Shift forms: run the command, then, if the end that moved landed in
    /// folded text, step it to the nearest visible position in the direction of travel.
    override func doCommand(by selector: Selector) {
        guard let coordinator, coordinator.isCaretMovement(selector), !hasMarkedText() else { super.doCommand(by: selector); return }
        let before = selectedRange()
        coordinator.isMovingCaret = true
        super.doCommand(by: selector)
        coordinator.snapCaretOverFolds(from: before, after: selector)
        coordinator.isMovingCaret = false
    }

    // MARK: Smart keys

    /// Backspace / forward-delete next to a grid table go into the table instead of merging text with its hidden source, and next
    /// to a fold they open it instead of joining a visible line to hidden text.
    override func deleteBackward(_ sender: Any?) {
        if guardDelete(backwards: true) { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if guardDelete(backwards: false) { return }
        super.deleteForward(sender)
    }

    // Word and line deletes would eat the hidden newline next to a table (or a fold) just the same.
    override func deleteWordBackward(_ sender: Any?) { if !guardDelete(backwards: true, byWord: true) { super.deleteWordBackward(sender) } }
    override func deleteToBeginningOfLine(_ sender: Any?) { if !guardDelete(backwards: true) { super.deleteToBeginningOfLine(sender) } }
    override func deleteToBeginningOfParagraph(_ sender: Any?) { if !guardDelete(backwards: true) { super.deleteToBeginningOfParagraph(sender) } }
    override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) { if !guardDelete(backwards: true) { super.deleteBackwardByDecomposingPreviousCharacter(sender) } }
    override func deleteWordForward(_ sender: Any?) { if !guardDelete(backwards: false, byWord: true) { super.deleteWordForward(sender) } }
    override func deleteToEndOfLine(_ sender: Any?) { if !guardDelete(backwards: false) { super.deleteToEndOfLine(sender) } }
    override func deleteToEndOfParagraph(_ sender: Any?) { if !guardDelete(backwards: false) { super.deleteToEndOfParagraph(sender) } }

    /// `byWord`: the word delete skips punctuation and line breaks, so it can reach hidden text from further than the line's edge.
    private func guardDelete(backwards: Bool, byWord: Bool = false) -> Bool {
        coordinator?.openFoldInsteadOfDeleting(backwards: backwards, byWord: byWord) == true || guardTableDelete(backwards: backwards)
    }

    private func guardTableDelete(backwards: Bool) -> Bool {
        guard !hasMarkedText(), selectedRange().length == 0 else { return false }
        return coordinator?.tableOverlay?.enterTable(adjacentToCaret: selectedRange().location, backwards: backwards) == true
    }

    override func insertNewline(_ sender: Any?) {
        coordinator?.openFoldBeforeReturn()
        if !hasMarkedText(), let edit = FenceEditing.returnEdit(in: string, selection: selectedRange()) {
            // Return on a freshly opened fence steps into its empty body; nothing is inserted.
            setSelectedRange(edit.selection)
            scrollRangeToVisible(edit.selection)
        } else if !hasMarkedText(), let edit = ListEditing.returnKey(in: string, selection: selectedRange()) {
            apply(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    /// Typing the third backtick at the start of a line closes the code fence for you.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        let sel = selectedRange()
        let atCaret = replacementRange.location == NSNotFound || (replacementRange.length == 0 && replacementRange.location == sel.location)
        if !hasMarkedText(), atCaret, let typed, let edit = FenceEditing.autoCloseEdit(typing: typed, in: self.string, selection: sel) {
            apply(edit)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), shouldHandleTabAsIndent() { dwIndent(sender) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), shouldHandleTabAsIndent() { dwOutdent(sender) } else { super.insertBacktab(sender) }
    }

    private func shouldHandleTabAsIndent() -> Bool {
        let sel = selectedRange()
        if sel.length > 0, (string as NSString).substring(with: sel).contains("\n") { return true }
        return ListEditing.isListLine(in: string, selection: sel)
    }

    /// Pasting a URL over selected text turns the selection into a link.
    override func paste(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0, let s = NSPasteboard.general.string(forType: .string), Formatter.looksLikeURL(s),
           !(string as NSString).substring(with: sel).contains("\n") {
            let text = (string as NSString).substring(with: sel)
            let link = "[\(text)](\(s.trimmingCharacters(in: .whitespacesAndNewlines)))"
            apply(TextEdit(range: sel, replacement: link, selection: NSRange(location: sel.location + link.utf16.count, length: 0)))
            return
        }
        super.paste(sender)
    }

    // MARK: Mouse

    /// The task whose checkbox is under `point` (text view coordinates): the drawn square while the `- [ ] ` source is
    /// hidden, otherwise the raw `[ ]` characters.
    func taskBox(at point: NSPoint) -> TaskBox? {
        guard coordinator?.sourceMode != true, let analysis = coordinator?.analysis, let lm = layoutManager, let tc = textContainer else { return nil }
        return taskBox(atPoint: point, index: characterIndexForInsertion(at: point), analysis: analysis, layout: lm, container: tc)
    }

    private func taskBox(atPoint point: NSPoint, index: Int, analysis: MarkdownAnalysis, layout lm: NSLayoutManager, container tc: NSTextContainer) -> TaskBox? {
        let origin = textContainerOrigin
        if let drawn = lm as? DWLayoutManager, let box = analysis.taskBox(onLine: analysis.lineIndex(at: index)), let prefix = box.prefix,
           textStorage?.attribute(.dwCheckbox, at: prefix.location, effectiveRange: nil) != nil {
            guard var rect = drawn.checkboxRect(forCharacterAt: prefix.location) else { return nil }
            rect.origin.x += origin.x; rect.origin.y += origin.y
            return rect.insetBy(dx: -4, dy: -4).contains(point) ? box : nil
        }
        guard let box = analysis.taskBox(at: index) else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: box.range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.x += origin.x; rect.origin.y += origin.y
        return rect.insetBy(dx: -4, dy: -3).contains(point) ? box : nil
    }

    // MARK: Fold controls

    private var foldTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = foldTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        foldTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        coordinator?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.pointerLeft()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A click on a chevron or a ⋯ chip folds or unfolds without touching the selection.
        if let header = coordinator?.foldControl(at: point) {
            if event.clickCount == 1 {
                if window?.firstResponder !== self { window?.makeFirstResponder(self) }
                coordinator?.toggleFold(headerLine: header.firstLine)
            }
            return
        }
        if coordinator?.tableOverlay?.focusNearestCell(atTextViewPoint: point) == true { return }
        if let analysis = coordinator?.analysis, let lm = layoutManager, let tc = textContainer {
            let index = characterIndexForInsertion(at: point)
            if event.clickCount == 1, let box = taskBox(atPoint: point, index: index, analysis: analysis, layout: lm, container: tc) {
                // Keep the caret where it was: moving it into the hidden `- [ ] ` would reveal the source.
                if window?.firstResponder !== self { window?.makeFirstResponder(self) }
                apply(ListEditing.toggleTask(in: string, box: box.range, keeping: selectedRange()), scrollToSelection: false)
                return
            }
            if event.modifierFlags.contains(.command), let link = analysis.link(at: index) {
                coordinator?.open(destination: link.destination)
                return
            }
        }
        // A click or drag is caret movement: where it leaves the start of the selection in folded text (the blank page below a
        // document whose end is folded) it steps over the fold like the arrow keys, instead of opening it.
        coordinator?.isMovingCaret = true
        super.mouseDown(with: event)
        coordinator?.isMovingCaret = false
        coordinator?.snapSelectionAfterMouse()
    }
}
