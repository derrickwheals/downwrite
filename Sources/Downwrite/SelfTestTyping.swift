import AppKit
import DownwriteCore

/// Typing at the end of a long document, end to end (DW-024): the real app, a real `NSDocument` on disk, real key-down events sent through
/// the window, in the formatted editor and the source view. For every key it records the clip view's scroll position and the text view's
/// height in the order they change — over the key and a short settle after it, so SwiftUI's round trip through the `text` binding is
/// included — and the ranges the text storage reports as edited. A key passes when neither value went outside the interval between where
/// it started and where it settled, and nothing outside the typed paragraph was edited. The report says which scroller style the run had:
/// the runner and a test harness get a legacy one whatever the Mac is set to, so the overlay scroller is the maintainer's hand check.
extension SelfTest {
    /// `--selftest-typing-only`: run only this step (for development; `--selftest-input` is still required and opened).
    static var typingOnly: Bool { CommandLine.arguments.contains("--selftest-typing-only") }

    /// A plain document far taller than the window: 300 paragraphs of 60 words.
    private static var typingDocument: String {
        let words = ["the", "quiet", "river", "carried", "small", "boats", "past", "old", "stone", "houses", "while", "evening", "light",
                     "settled", "over", "fields", "and", "distant", "hills", "slowly"]
        return (0..<300).map { p in (0..<60).map { words[(p * 7 + $0 * 3) % words.count] }.joined(separator: " ") }.joined(separator: "\n\n")
    }

    /// Runs in the run's first editor window, which it reloads the way an external change is (so the document is real and on disk), and
    /// reloads again at the end so the next step finds an unedited document.
    static func typingWalkthrough(outDir: URL, reusing tv: EditorTextView) async {
        func fail(_ what: String, _ detail: String = "") { check(false, "typing: " + what, detail: detail) }
        let text = typingDocument
        guard let window = tv.window, let url = window.representedURL, let document = NSDocumentController.shared.document(for: url),
              let coordinator = tv.coordinator, let scroll = tv.enclosingScrollView, let storage = tv.textStorage else { return fail("the editor window is available") }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try document.revert(toContentsOf: url, ofType: document.fileType ?? "")
        } catch { return fail("the document reloads", "\(error)") }
        guard await waitUntil(timeout: 10, { tv.string == text }) else { return fail("the window shows the document", "\(tv.string.count) characters") }
        NSApp.activate(ignoringOtherApps: true)
        window.setContentSize(NSSize(width: 1000, height: 780))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        try? await Task.sleep(nanoseconds: 600_000_000)

        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        tv.postsFrameChangedNotifications = true
        let styleName = { (s: NSScroller.Style) in s == .overlay ? "overlay" : "legacy" }
        check(true, "typing: scroller style", detail: "this window \(styleName(scroll.scrollerStyle)), system preference \(styleName(NSScroller.preferredScrollerStyle))")
        check(tv.frame.height > clip.bounds.height * 4, "typing: the document is far taller than the window",
              detail: String(format: "text view %.0f pt, clip %.0f pt", Double(tv.frame.height), Double(clip.bounds.height)))

        func key(_ c: Character) -> NSEvent? {
            let chars = String(c)
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                    isARepeat: false, keyCode: c == " " ? 49 : (c == "a" ? 0 : 11))
        }
        func excursion(_ trace: [CGFloat]) -> CGFloat {
            guard let first = trace.first, let last = trace.last else { return 0 }
            let lo = min(first, last), hi = max(first, last)
            return trace.reduce(0) { max($0, $1 < lo ? lo - $1 : ($1 > hi ? $1 - hi : 0)) }
        }
        func f(_ trace: [CGFloat]) -> String { trace.map { String(format: "%.1f", Double($0)) }.joined(separator: "→") }

        /// Types each key at the end of the document and checks it.
        func typeAtTheEnd(_ view: String) async {
            tv.setSelectedRange(NSRange(location: storage.length, length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
            try? await Task.sleep(nanoseconds: 400_000_000)
            for c in "a  b " {
                let seen = TypingTrace(clip: clip.bounds.origin.y, height: tv.frame.height)
                let center = NotificationCenter.default
                let observers = [
                    center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
                        MainActor.assumeIsolated { seen.clip.append(clip.bounds.origin.y) }
                    },
                    center.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: nil) { _ in
                        MainActor.assumeIsolated { seen.height.append(tv.frame.height) }
                    },
                    center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in
                        MainActor.assumeIsolated { seen.edits.append(storage.editedRange) }
                    },
                ]
                if let e = key(c) { window.sendEvent(e) }
                try? await Task.sleep(nanoseconds: 150_000_000)  // (SwiftUI's round trip through the binding, and a frame or two)
                observers.forEach(center.removeObserver)
                let (clipTrace, heightTrace, edits) = (seen.clip, seen.height, seen.edits)
                let name = c == " " ? "Space" : String(c)
                let string = tv.string as NSString
                let paragraph = string.paragraphRange(for: NSRange(location: max(0, string.length - 1), length: 0))
                let outside = edits.filter { $0.location < paragraph.location || NSMaxRange($0) > NSMaxRange(paragraph) }
                let detail = "clip \(f(clipTrace)), height \(f(heightTrace)), edits \(edits.map { NSStringFromRange($0) }.joined(separator: " "))"
                check(excursion(clipTrace) <= 0.5 && excursion(heightTrace) <= 0.5, "typing: \(name) at the end of a long document does not move the view (\(view))", detail: detail)
                check(!edits.isEmpty && outside.isEmpty, "typing: \(name) edits only its own paragraph (\(view))", detail: detail)
            }
        }

        check(!coordinator.sourceMode, "typing: the formatted editor is showing")
        await typeAtTheEnd("formatted")

        let slash = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "/", charactersIgnoringModifiers: "/",
                                     isARepeat: false, keyCode: 44)!
        _ = NSApp.mainMenu?.performKeyEquivalent(with: slash)
        let slashReached = await waitUntil(timeout: 3, { coordinator.sourceMode })
        if !slashReached { coordinator.setSourceMode(true) }
        // (SwiftUI's round trip: its `sourceMode` state is only changed by the menu command, so after the fallback above it puts the formatted
        // editor back at the next update, and keys typed then would be recorded as the source view's.)
        try? await Task.sleep(nanoseconds: 600_000_000)
        if coordinator.sourceMode {
            await typeAtTheEnd("source view")
            _ = NSApp.mainMenu?.performKeyEquivalent(with: slash)
            if !(await waitUntil(timeout: 3, { !coordinator.sourceMode })) { coordinator.setSourceMode(false) }
        } else {
            fail("the source view is showing", slashReached ? "⌘/ was handled, but the formatted editor is showing again"
                 : "⌘/ did not reach the View menu (SwiftUI has not resolved the focused window, as in the other ⌘/ checks), so the source view was not typed in")
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try document.revert(toContentsOf: url, ofType: document.fileType ?? "")
        } catch { return fail("the document reloads at the end", "\(error)") }
        _ = await waitUntil(timeout: 10) { tv.string == text }
    }
}

/// What the notification blocks of `typingWalkthrough` record (they are `@Sendable` and cannot mutate a captured `var`; they run
/// synchronously on the main thread, where the notifications are posted).
private final class TypingTrace: @unchecked Sendable {
    var clip: [CGFloat]
    var height: [CGFloat]
    var edits: [NSRange] = []
    init(clip: CGFloat, height: CGFloat) { self.clip = [clip]; self.height = [height] }
}
