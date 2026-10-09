import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Folding in the app: what hidden lines look like, how the coordinator and overlays follow the fold state, caret policy,
/// edit guards and speed. The Markdown-level rules (regions, `FoldState`) are tested in `DownwriteCoreTests/FoldingTests`.
@MainActor
final class FoldTests: XCTestCase {
    // MARK: Fixture

    /// Fixture F, shared with the Core tests and the end-to-end step (`Tests/Fixtures/fold-demo.md`, no trailing newline).
    static func fixtureF(file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fold-demo.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Thin collapse (R5)

    /// A real editor holding `Header`, `hiddenLines` lines (text and blank lines mixed) and `Footer`, with the hidden lines
    /// collapsed to `lineHeight`. Returns the laid-out document height and the heights of the hidden lines' fragments.
    private func measure(hiddenLines n: Int, lineHeight: CGFloat) -> (height: CGFloat, hiddenFragments: [CGFloat]) {
        let header = "Header\n"
        var hidden = ""
        for i in 0..<n { hidden += i % 3 == 2 ? "\n" : "hidden text line \(i)\n" }
        let h = EditorHarness(text: header + hidden + "Footer")
        h.select(h.textView.string.utf16.count)
        let range = NSRange(location: header.utf16.count, length: hidden.utf16.count)
        if range.length > 0 {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = lineHeight
            p.maximumLineHeight = lineHeight
            h.storage.beginEditing()
            h.storage.setAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear, .paragraphStyle: p], range: range)
            h.storage.endEditing()
        }
        let lm = h.textView.layoutManager!
        let container = h.textView.textContainer!
        lm.ensureLayout(for: container)
        var fragments: [CGFloat] = []
        if range.length > 0 {
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                fragments.append(rect.height)
            }
        }
        return (lm.usedRect(for: container).height, fragments)
    }

    /// R5: the room left by hidden lines is at most 1 pt per 1,000 lines. Measured in the real editor (plan step 1):
    /// 0.1 pt per line leaves 10 pt for 100 lines and 100 pt for 1,000; 0.01 pt leaves 1 and 10; 0.001 pt leaves 0.1 and 1.
    func testThinCollapseLeavesAtMostOnePointPerThousandLines() {
        let thin = MarkdownStyler.foldedLineHeight
        let base = measure(hiddenLines: 0, lineHeight: thin).height
        for (count, allowed) in [(100, 0.1), (1000, 1.0)] as [(Int, CGFloat)] {
            let m = measure(hiddenLines: count, lineHeight: thin)
            XCTAssertEqual(m.hiddenFragments.count, count, "one line fragment per hidden line")
            XCTAssertLessThanOrEqual(m.height - base, allowed + 0.001, "\(count) hidden lines leave \(m.height - base) pt")
            // The layout manager's card and bar drawing skip fragments of 1 pt or less (`lineRect.height > 1`).
            XCTAssertTrue(m.hiddenFragments.allSatisfy { $0 < 1 }, "hidden fragments stay below the 1 pt drawing filter")
        }
        // The line height used for collapsed sources, by contrast, is far over the limit.
        let old = measure(hiddenLines: 1000, lineHeight: 0.1).height - base
        XCTAssertGreaterThan(old, 50, "the old 0.1 pt collapse leaves \(old) pt for 1,000 lines")
    }

    func testFixtureFHasNoTrailingNewline() throws {
        let text = try Self.fixtureF()
        XCTAssertFalse(text.hasSuffix("\n"))
        XCTAssertEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 36)
    }
}
