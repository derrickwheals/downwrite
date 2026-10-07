import AppKit
import DownwriteCore

/// Carries a `FormatCommand` through the responder chain (`NSApp.sendAction` takes an `Any?` sender).
final class FormatCommandBox: NSObject {
    let command: FormatCommand
    init(_ command: FormatCommand) { self.command = command }
}

/// The Markdown editing surface: a TextKit 1 `NSTextView` with Markdown-aware commands, smart Return/Tab,
/// clickable task boxes and a centred readable column.
final class EditorTextView: NSTextView {
    weak var coordinator: EditorCoordinator?
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
        super.setFrameSize(newSize)
        updateInsets()
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

    override func didChangeText() {
        super.didChangeText()
        if string.utf16.count <= 1 { needsDisplay = true }
    }

    // MARK: Applying edits

    /// Applies a computed edit through the text system so that undo, the delegate and SwiftUI all see it.
    func apply(_ edit: TextEdit) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
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

    @objc func dwIndent(_ sender: Any?) { apply(ListEditing.indent(in: string, selection: selectedRange(), outdent: false)) }
    @objc func dwOutdent(_ sender: Any?) { apply(ListEditing.indent(in: string, selection: selectedRange(), outdent: true)) }

    // MARK: Smart keys

    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), let edit = ListEditing.returnKey(in: string, selection: selectedRange()) {
            apply(edit)
        } else {
            super.insertNewline(sender)
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let analysis = coordinator?.analysis, let lm = layoutManager, let tc = textContainer {
            let index = characterIndexForInsertion(at: point)
            if event.clickCount == 1, let box = analysis.taskBox(at: index) {
                let glyphs = lm.glyphRange(forCharacterRange: box.range, actualCharacterRange: nil)
                var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
                rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
                if rect.insetBy(dx: -4, dy: -3).contains(point) {
                    apply(ListEditing.toggleTask(in: string, box: box.range))
                    return
                }
            }
            if event.modifierFlags.contains(.command), let link = analysis.link(at: index) {
                coordinator?.open(destination: link.destination)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
