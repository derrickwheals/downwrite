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

    init(text: String, dark: Bool = false, size: NSSize = NSSize(width: 960, height: 760), font: FontChoice = .avenirNext) {
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
