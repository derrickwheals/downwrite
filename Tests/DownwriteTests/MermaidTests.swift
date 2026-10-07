import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

@MainActor
final class MermaidTests: XCTestCase {
    func testRendersEveryCommonDiagramType() async {
        let diagrams = [
            "flowchart LR\n  A[Start] --> B{Ok?}\n  B -->|yes| C[Done]",
            "sequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi",
            "classDiagram\n  Animal <|-- Dog\n  Animal : +int age",
            "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Busy",
            "erDiagram\n  CUSTOMER ||--o{ ORDER : places",
            "gantt\n  title Plan\n  dateFormat YYYY-MM-DD\n  section A\n  Task :a1, 2026-01-01, 3d",
            "pie title Pets\n  \"Dogs\" : 5\n  \"Cats\" : 3",
            "journey\n  title Day\n  section Work\n    Code: 5: Me",
            "gitGraph\n  commit\n  branch dev\n  commit",
            "mindmap\n  root((Idea))\n    A\n    B",
        ]
        for source in diagrams {
            let result = await MermaidService.shared.render(source, dark: false)
            switch result {
            case .success(let svg):
                XCTAssertTrue(svg.contains("<svg"), source)
                XCTAssertNotNil(MermaidSupport.intrinsicSize(ofSVG: svg), "no size for: \(source)")
            case .failure(let e):
                XCTFail("render failed for \(source.prefix(20)): \(e)")
            }
        }
    }

    func testSyntaxErrorsAreReportedNotCrashed() async {
        let result = await MermaidService.shared.render("flowchart TD\n  A -->", dark: false)
        guard case .failure(.failed(let message)) = result else { return XCTFail("expected failure, got \(result)") }
        XCTAssertFalse(message.isEmpty)
    }

    func testDarkThemeProducesDifferentArtwork() async {
        let src = "flowchart LR\n A --> B"
        guard case .success(let l) = await MermaidService.shared.render(src, dark: false),
              case .success(let d) = await MermaidService.shared.render(src, dark: true) else { return XCTFail("render failed") }
        XCTAssertNotEqual(l, d)
    }

    func testScriptInjectionIsNeutralised() async {
        let result = await MermaidService.shared.render("flowchart LR\n  A[\"<img src=x onerror=alert(1)>\"] --> B", dark: false)
        if case .success(let svg) = result { XCTAssertFalse(svg.contains("onerror")) }
    }

    func testEditorShowsDiagramCardAndReservesSpace() async {
        let text = "# T\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nafter\n"
        let h = EditorHarness(text: text)
        h.select(0)
        let ok = await waitUntil { (h.coordinator.overlay.reservedHeights[2] ?? 0) > 100 }
        XCTAssertTrue(ok, "diagram never finished rendering")
        XCTAssertEqual(h.textView.subviews.compactMap { $0 as? DiagramView }.count, 1)
        // Source collapses while the caret is outside…
        let fence = h.index(of: "```mermaid")
        XCTAssertTrue(h.isHidden(at: fence))
        let lastFence = h.index(of: "```\n\nafter")
        XCTAssertEqual(h.paragraph(at: lastFence).paragraphSpacing, h.coordinator.overlay.reservedHeights[2]!, accuracy: 0.5)
        // …and returns when the caret enters the block.
        h.select(h.index(of: "flowchart") + 3)
        XCTAssertFalse(h.isHidden(at: fence))
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        h.coordinator.overlay.reposition(analysis: h.coordinator.analysis)
        let card = h.textView.subviews.compactMap { $0 as? DiagramView }.first!
        XCTAssertGreaterThan(card.frame.height, 40)
        XCTAssertGreaterThan(card.frame.minY, 20)
    }

    func testEditingDiagramSourceReRenders() async {
        let h = EditorHarness(text: "```mermaid\ngraph TD\n  A --> B\n```\n")
        _ = await waitUntil { (h.coordinator.overlay.reservedHeights[0] ?? 0) > 100 }
        let first = h.coordinator.overlay.reservedHeights[0]!
        h.select(h.index(of: "B"), 1)
        h.textView.insertText("B\n  B --> C\n  C --> D\n  D --> E", replacementRange: h.textView.selectedRange())
        let grew = await waitUntil { (h.coordinator.overlay.reservedHeights[0] ?? 0) > first + 20 }
        XCTAssertTrue(grew, "taller diagram should reserve more space")
    }

    func testBrokenDiagramShowsErrorCardWithoutBreakingEditor() async {
        let h = EditorHarness(text: "```mermaid\nnot a diagram at all ???\n```\n\ntext\n")
        let ok = await waitUntil { h.coordinator.overlay.reservedHeights[0] == 56 }
        XCTAssertTrue(ok)
        h.select(h.textView.string.utf16.count)
        XCTAssertEqual(h.textView.string.hasSuffix("text\n"), true)
    }
}
