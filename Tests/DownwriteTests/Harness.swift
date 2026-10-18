import XCTest
import SwiftUI
import AppKit
@testable import Downwrite
import DownwriteCore

final class TextBox { var value: String; init(_ v: String) { value = v } }

/// A real editor (scroll view + text view + coordinator) hosted in an offscreen-capable window.
@MainActor
struct EditorHarness {
    let window: NSWindow
    let scroll: NSScrollView
    let textView: EditorTextView
    let coordinator: EditorCoordinator
    let box: TextBox

    init(text: String, dark: Bool = false, size: NSSize = NSSize(width: 960, height: 760), font: FontChoice = .avenirNext, fileURL: URL? = nil) {
        _ = NSApplication.shared
        let b = TextBox(text)
        box = b
        let (s, tv) = EditorTextView.make()
        scroll = s
        textView = tv
        let binding = Binding<String>(get: { b.value }, set: { b.value = $0 })
        let c = EditorCoordinator(text: binding)
        coordinator = c
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        s.frame = NSRect(origin: .zero, size: size)
        w.contentView = s
        window = w
        c.fileURL = fileURL
        c.attach(scroll: s, textView: tv, settings: EditorSettings(font: font, size: 17, lineHeight: 1.45, width: 720), initialText: text)
        w.orderFront(nil)
        c.appearanceDidChange()
    }

    var storage: NSTextStorage { textView.textStorage! }
    func attrs(at i: Int) -> [NSAttributedString.Key: Any] { storage.attributes(at: i, effectiveRange: nil) }
    func font(at i: Int) -> NSFont { attrs(at: i)[.font] as! NSFont }
    func color(at i: Int) -> NSColor? { attrs(at: i)[.foregroundColor] as? NSColor }
    func isHidden(at i: Int) -> Bool { font(at: i).pointSize < 1 && (color(at: i) == NSColor.clear) }
    func paragraph(at i: Int) -> NSParagraphStyle { attrs(at: i)[.paragraphStyle] as! NSParagraphStyle }
    func select(_ loc: Int, _ len: Int = 0) { textView.setSelectedRange(NSRange(location: loc, length: len)) }
    func index(of s: String) -> Int { (textView.string as NSString).range(of: s).location }
}

extension EditorHarness {
    /// Keeps the text column one width whatever the document's height. This scroll view is in the legacy style in a test (it asks for
    /// `.overlay` and does not get it), so a 17 pt vertical scroller appears once the document outgrows the window and takes 17 pt from
    /// the column (900 → 883, text inset 90 → 82): a grid or card placed a moment before it appeared is then 8 pt out. A test that is not
    /// about the scroller pins the column first.
    func pinColumnWidth() {
        scroll.hasVerticalScroller = false
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
    }

    /// What the layout looked like, for the message of a failed layout check: the widths the column is made of, the scroller, and
    /// where each grid and card sits. A failure on a runner we cannot attach to has to say its cause by itself.
    func geometryReport() -> String {
        func f(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
        func r(_ rect: NSRect) -> String { "(\(f(rect.minX)), \(f(rect.minY)), \(f(rect.width))×\(f(rect.height)))" }
        let scroller = scroll.verticalScroller
        var lines = [
            "window \(r(window.frame)) on screen \(window.screen.map { r($0.visibleFrame) } ?? "none")",
            "scroll \(r(scroll.frame)), clip \(r(scroll.contentView.frame)), text view \(r(textView.frame)), inset \(f(textView.textContainerInset.width))",
            "scroller style \(scroll.scrollerStyle.rawValue), wanted \(scroll.hasVerticalScroller), "
                + "hidden \(scroller.map { String($0.isHidden) } ?? "none"), width \(scroller.map { f($0.frame.width) } ?? "none")",
        ]
        let grids = coordinator.tableOverlay.grids
        lines.append("grids " + (grids.isEmpty ? "none" : grids.enumerated().map { "\($0.offset) \(r($0.element.frame))" }.joined(separator: ", ")))
        let cards = coordinator.overlay.diagramViews
        lines.append("cards " + (cards.isEmpty ? "none" : cards.enumerated().map { "\($0.offset) \(r($0.element.frame))" }.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }
}

/// The calling thread's CPU time so far, in seconds. Time spent waiting for a core (a busy shared runner) does not count, so a
/// duration measured with it does not move with the machine's load. It follows the thread that calls it: work handed to other
/// threads is not counted.
func threadCPUSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}

/// Runs `body` and returns what it returned with the CPU seconds the calling thread spent in it.
func cpuSeconds<T>(_ body: () throws -> T) rethrows -> (value: T, seconds: Double) {
    let start = threadCPUSeconds()
    let value = try body()
    return (value, threadCPUSeconds() - start)
}

@MainActor
func waitUntil(timeout: TimeInterval = 25, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

extension NSFont {
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }
}

// MARK: Typing stability (DW-024)

/// How far the view moved during one action, beyond where it started and where it settled. Notifications are posted synchronously,
/// so a shift that is gone by the end of the call still shows in the trace.
struct GeometryExcursion: CustomStringConvertible {
    /// The clip view's scroll position (bounds origin y), in the order it changed, starting with its value before the action.
    var clipTrace: [CGFloat]
    /// The text view's height, in the order it changed, starting with its value before the action.
    var heightTrace: [CGFloat]

    /// The largest distance a value went outside the interval between its first and last values (0 when it moved straight there).
    static func excursion(_ trace: [CGFloat]) -> CGFloat {
        guard let first = trace.first, let last = trace.last else { return 0 }
        let lo = min(first, last), hi = max(first, last)
        return trace.reduce(0) { max($0, $1 < lo ? lo - $1 : ($1 > hi ? $1 - hi : 0)) }
    }

    var clip: CGFloat { Self.excursion(clipTrace) }
    var height: CGFloat { Self.excursion(heightTrace) }

    var description: String {
        func f(_ trace: [CGFloat]) -> String { trace.map { String(format: "%.1f", Double($0)) }.joined(separator: " → ") }
        return String(format: "clip excursion %.1f (%@), height excursion %.1f (%@)", Double(clip), f(clipTrace), Double(height), f(heightTrace))
    }
}

/// A box the notification blocks below append to (they are `@Sendable`, so they cannot mutate a captured `var`; they run synchronously
/// on the main thread, where the notifications are posted).
final class Recorded<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

extension EditorHarness {
    /// Records the clip view's scroll position and the text view's height while `body` runs.
    func recordGeometry(during body: () -> Void) -> GeometryExcursion {
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let result = Recorded(GeometryExcursion(clipTrace: [clip.bounds.origin.y], heightTrace: [textView.frame.height]))
        let tv = textView
        let center = NotificationCenter.default
        let a = center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
            MainActor.assumeIsolated { result.value.clipTrace.append(clip.bounds.origin.y) }
        }
        let b = center.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: nil) { _ in
            MainActor.assumeIsolated { result.value.heightTrace.append(tv.frame.height) }
        }
        body()
        center.removeObserver(a)
        center.removeObserver(b)
        return result.value
    }

    /// The ranges the text storage reported as edited while `body` runs (characters and attributes alike), one per `processEditing`.
    func recordEdits(during body: () -> Void) -> [NSRange] {
        let edits = Recorded<[NSRange]>([])
        let store = storage
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: store, queue: nil) { _ in
            MainActor.assumeIsolated { edits.value.append(store.editedRange) }
        }
        body()
        NotificationCenter.default.removeObserver(token)
        return edits.value
    }

    /// Types `text` at the caret: through `insertText` (what the input system calls), or as one real key-down event per character
    /// through `keyDown`, which goes through the text input context like a key on the keyboard.
    func type(_ text: String, viaKeyEvent: Bool = false) {
        guard viaKeyEvent else {
            textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        window.makeFirstResponder(textView)
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "b": 11, " ": 49, "\r": 36]
        for c in text {
            let chars = String(c)
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: codes[c] ?? 0) else { continue }
            textView.keyDown(with: e)
        }
    }

    /// Puts the caret at `offset` and scrolls it into view, with the layout around it done.
    func placeCaret(at offset: Int) {
        select(offset)
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        scroll.layoutSubtreeIfNeeded()
        textView.displayIfNeeded()
    }

    /// Where the caret is drawn, in the text view's coordinates.
    func caretRect() -> NSRect {
        let layout = textView.layoutManager!
        let loc = textView.selectedRange().location
        layout.ensureLayout(forCharacterRange: NSRange(location: max(0, loc - 1), length: min(1, storage.length)))
        let rect: NSRect
        if loc >= storage.length, layout.extraLineFragmentTextContainer != nil {
            rect = layout.extraLineFragmentRect
        } else {
            rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: min(loc, max(0, storage.length - 1))), effectiveRange: nil)
        }
        return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }
}

/// `paragraphs` paragraphs of `words` plain words each, separated by blank lines: a document far taller than any window, with no Markdown in it.
func longPlainDocument(paragraphs: Int = 300, words: Int = 60) -> String {
    let vocabulary = ["the", "quiet", "river", "carried", "small", "boats", "past", "old", "stone", "houses", "while", "evening", "light",
                      "settled", "over", "fields", "and", "distant", "hills", "slowly"]
    return (0..<paragraphs).map { p in
        (0..<words).map { vocabulary[(p * 7 + $0 * 3) % vocabulary.count] }.joined(separator: " ")
    }.joined(separator: "\n\n")
}
