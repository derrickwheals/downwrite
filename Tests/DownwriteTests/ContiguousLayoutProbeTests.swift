import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// TEMPORARY (DW-024 build): what turning non-contiguous layout off would cost and whether it keeps the view still, measured in one run
/// against today's setting. Prints `TIMING:` lines (the CI test step greps them) and asserts nothing; removed before the change is finished.
@MainActor
final class ContiguousLayoutProbeTests: XCTestCase {
    private var headings: String {
        var s = ""
        for i in 0..<2000 { s += "## Heading \(i)\n\nA paragraph with **bold**, *italic*, `code` and a [link](https://x.y/\(i)).\n\n" }
        return s
    }

    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    private func measure(_ name: String, _ text: String, contiguous: Bool) -> String {
        let h = EditorHarness(text: text)
        let layout = h.textView.layoutManager!
        layout.allowsNonContiguousLayout = !contiguous
        let all = NSRange(location: 0, length: h.storage.length)
        // "Opening": all layout thrown away, then what showing the top of the document needs.
        layout.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        let open = cpuSeconds {
            h.placeCaret(at: 0)
            h.textView.displayIfNeeded()
        }.seconds
        let toEnd = cpuSeconds { h.placeCaret(at: h.storage.length); h.textView.displayIfNeeded() }.seconds
        let atEnd = median((0..<9).map { _ in cpuSeconds { h.type(" "); h.textView.displayIfNeeded() }.seconds })
        var stillEnd: CGFloat = 0
        for key in ["a", " ", " ", "b", " "] {
            let g = h.recordGeometry { h.type(key) }
            stillEnd = max(stillEnd, g.clip, g.height)
        }
        h.placeCaret(at: 2_000)
        let nearTop = median((0..<9).map { _ in cpuSeconds { h.type(" "); h.textView.displayIfNeeded() }.seconds })
        var stillTop: CGFloat = 0
        for key in [" ", "b", " "] {
            let g = h.recordGeometry { h.type(key) }
            stillTop = max(stillTop, g.clip, g.height)
        }
        return String(format: "contiguity probe %@ %@: open=%.4fs jump-to-end=%.4fs key-at-end=%.4fs key-near-top=%.4fs worst-excursion end=%.1f top=%.1f",
                      name, contiguous ? "CONTIGUOUS" : "non-contiguous", open, toEnd, atEnd, nearTop, Double(stillEnd), Double(stillTop))
    }

    func testMeasureContiguousAgainstNonContiguousLayout() {
        for (name, text) in [("plain-111KB", longPlainDocument()), ("headings-180KB", headings)] {
            for contiguous in [false, true, false, true] {         // (twice each, interleaved, so a one-off warm-up shows)
                print("TIMING: " + measure(name, text, contiguous: contiguous))
            }
        }
    }
}
