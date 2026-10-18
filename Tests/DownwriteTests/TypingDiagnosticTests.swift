import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// TEMPORARY (DW-024 build): splits one keystroke into its phases to find what still dips the height by a line. Fails on purpose so the
/// numbers show in CI's error lines; removed before the change is finished.
@MainActor
final class TypingDiagnosticTests: XCTestCase {
    func testDiagnoseTheRemainingDip() {
        var lines: [String] = []
        func run(_ name: String, _ setup: (EditorHarness) -> Void = { _ in }, _ body: (EditorHarness) -> Void) {
            let h = EditorHarness(text: longPlainDocument())
            h.placeCaret(at: h.storage.length)
            setup(h)
            for i in 0..<4 {
                var edits: [NSRange] = []
                let g = h.recordGeometry { edits = h.recordEdits { body(h) } }
                lines.append("DIAG \(name) #\(i): \(g); edits \(edits)")
            }
        }
        // A: AppKit's insertion alone (no delegate: no binding, analysis or restyle).
        run("A no delegate", { $0.textView.delegate = nil }) { $0.type(" ") }
        // B: the whole key.
        run("B whole key") { $0.type(" ") }
        // C: analysis + restyle alone, after nothing typed.
        run("C reanalyze only") { $0.coordinator.reanalyze() }
        // D: restyle alone.
        run("D restyleAll only") { $0.coordinator.restyleAll() }
        // E: insertion, then the restyle steps one by one.
        run("E insert (no delegate) then reanalyze", { $0.textView.delegate = nil }) { h in h.type(" "); h.coordinator.reanalyze() }
        // F: AppKit insertion with layout of the end done first.
        run("F no delegate, contiguous", { h in h.textView.delegate = nil; h.textView.layoutManager?.allowsNonContiguousLayout = false }) { $0.type(" ") }
        // G: whole key, scheduleReposition's overlays out of the picture (no tables/cards in this document anyway): ensureLayout to end.
        run("G whole key after ensureLayout", { h in h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!) }) { $0.type(" ") }
        for line in lines { XCTFail(line) }
    }
}
