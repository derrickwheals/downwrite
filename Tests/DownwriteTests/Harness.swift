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
