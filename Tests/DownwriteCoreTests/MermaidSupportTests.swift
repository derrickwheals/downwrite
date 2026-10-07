import XCTest
@testable import DownwriteCore

final class MermaidSupportTests: XCTestCase {
    func testViewBoxSize() {
        let svg = #"<svg id="m1" width="100%" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 628.5 366" style="max-width: 628.5px;"><g/></svg>"#
        XCTAssertEqual(MermaidSupport.intrinsicSize(ofSVG: svg), .init(width: 628.5, height: 366))
    }

    func testNegativeViewBoxOrigin() {
        let svg = #"<svg viewBox="-8 -8 200 100"></svg>"#
        XCTAssertEqual(MermaidSupport.intrinsicSize(ofSVG: svg), .init(width: 200, height: 100))
    }

    func testFallsBackToWidthHeight() {
        XCTAssertEqual(MermaidSupport.intrinsicSize(ofSVG: #"<svg width="300px" height="150"></svg>"#), .init(width: 300, height: 150))
        XCTAssertNil(MermaidSupport.intrinsicSize(ofSVG: "<svg></svg>"))
    }

    func testFitNeverUpscalesAndRespectsMaxHeight() {
        let small = MermaidSupport.fittedSize(.init(width: 200, height: 100), maxWidth: 700)
        XCTAssertEqual(small, .init(width: 200, height: 100))
        let wide = MermaidSupport.fittedSize(.init(width: 1400, height: 700), maxWidth: 700)
        XCTAssertEqual(wide, .init(width: 700, height: 350))
        let tall = MermaidSupport.fittedSize(.init(width: 400, height: 1600), maxWidth: 700, maxHeight: 640)
        XCTAssertEqual(tall.height, 640, accuracy: 0.001)
        XCTAssertEqual(tall.aspect, 0.25, accuracy: 0.001)
    }

    func testPageWrapsSVG() {
        let page = MermaidSupport.page(wrapping: "<svg/>")
        XCTAssertTrue(page.contains("<svg/>"))
        XCTAssertTrue(page.contains("background:transparent"))
    }

    func testFriendlyError() {
        XCTAssertEqual(MermaidSupport.friendlyError("Parse error on line 2:\n  ...bad"), "Parse error on line 2:")
        XCTAssertTrue(MermaidSupport.friendlyError(String(repeating: "x", count: 500)).hasSuffix("…"))
    }
}
