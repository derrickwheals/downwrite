import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// A grid table must stay lined up with the text column and keep exactly the height the text reserved for it, however
/// the editor column changes width (sidebar opening and closing, window resizing).
@MainActor
final class TableLayoutTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func readme() throws -> String {
        try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
    }

    private func harness() async throws -> EditorHarness {
        let h = EditorHarness(text: try readme(), size: NSSize(width: 900, height: 760))
        h.select(0)
        let ready = await waitUntil { !h.coordinator.tableOverlay.grids.isEmpty && h.coordinator.tableOverlay.grids.allSatisfy { $0.tableSize.width > 0 } }
        XCTAssertTrue(ready, "README tables never became grids")
        return h
    }

    /// Waits for the asynchronous repositioning to settle and returns whatever is still inconsistent.
    private func settled(_ h: EditorHarness) async -> [String] {
        var found: [String] = []
        _ = await waitUntil(timeout: 8) { found = h.coordinator.tableOverlay.layoutProblems(); return found.isEmpty }
        return found
    }

    private func resize(_ h: EditorHarness, width: CGFloat) {
        h.textView.setFrameSize(NSSize(width: width, height: h.textView.frame.height))
    }

    func testReadmeTablesAreConsistentAtStartup() async throws {
        let h = try await harness()
        let problems = await settled(h)
        XCTAssertEqual(problems, [])
    }

    func testSqueezingTheColumnKeepsGridsAligned() async throws {
        let h = try await harness()
        resize(h, width: 600)
        var problems = await settled(h)
        XCTAssertEqual(problems, [], "after the column narrowed")
        resize(h, width: 900)
        problems = await settled(h)
        XCTAssertEqual(problems, [], "after the column widened again")
    }

    /// A legacy-style vertical scroller takes 17 pt from the column when the document outgrows the window (900 → 883 pt here) and gives it back
    /// when it goes. A grid placed just before the scroller came sits 8 pt out (x=62 where the column implies 54, in a failed CI run of the Fold
    /// test), and it has to be placed again whichever way the scroller moves. The other layout tests pin the column; this one does not.
    func testGridFollowsTheColumnWhenTheScrollerComesAndGoes() async throws {
        let h = EditorHarness(text: try FoldTests.fixtureF(), size: NSSize(width: 900, height: 760))
        h.scroll.scrollerStyle = .legacy               // (whatever the system prefers: the scroller must take room for this test to mean anything)
        h.scroll.tile()
        h.select(0)
        let ready = await waitUntil { (h.coordinator.tableOverlay.grids.first?.tableSize.width ?? 0) > 0 }
        XCTAssertTrue(ready, "the table never became a grid\n\(h.geometryReport())")
        var problems = await settled(h)
        XCTAssertEqual(problems, [], "with the scroller showing\n\(h.geometryReport())")
        let narrow = h.textView.frame.width

        h.scroll.hasVerticalScroller = false
        h.scroll.tile()
        let wide = h.textView.frame.width
        XCTAssertGreaterThan(wide, narrow + 10, "taking the scroller away should widen the column\n\(h.geometryReport())")
        problems = await settled(h)
        XCTAssertEqual(problems, [], "after the scroller went\n\(h.geometryReport())")

        h.scroll.hasVerticalScroller = true
        h.scroll.tile()
        XCTAssertEqual(h.textView.frame.width, narrow, accuracy: 0.5, "…and bringing it back should narrow it again\n\(h.geometryReport())")
        problems = await settled(h)
        XCTAssertEqual(problems, [], "after the scroller came back\n\(h.geometryReport())")
    }

    func testRapidResizesEndConsistent() async throws {
        let h = try await harness()
        for i in 0..<8 { resize(h, width: i % 2 == 0 ? 600 : 900) }
        let problems = await settled(h)
        XCTAssertEqual(problems, [], "after a burst of resizes")
    }

    func testNarrowColumnMakesGridTallerAndTextFollows() async throws {
        let h = try await harness()
        _ = await settled(h)
        let wideHeight = h.coordinator.tableOverlay.grids[0].totalHeight
        resize(h, width: 560)
        let problems = await settled(h)
        XCTAssertEqual(problems, [])
        let narrowHeight = h.coordinator.tableOverlay.grids[0].totalHeight
        XCTAssertGreaterThan(narrowHeight, wideHeight - 0.5, "wrapping cells can only make the grid taller")
    }

    func testProblemsAreReportedWhenAGridIsMoved() async throws {
        let h = try await harness()
        _ = await settled(h)
        let grid = h.coordinator.tableOverlay.grids[0]
        grid.frame.origin.x += 40
        XCTAssertFalse(h.coordinator.tableOverlay.layoutProblems().isEmpty, "the self-check must notice a misplaced grid")
    }
}
