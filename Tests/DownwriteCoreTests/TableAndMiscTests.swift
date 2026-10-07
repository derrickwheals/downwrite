import XCTest
@testable import DownwriteCore

final class TableAndMiscTests: XCTestCase {
    func testTableFormatAligns() {
        let out = TableFormatter.format(["|a|bb|", "|-|:-:|", "|long cell|x|"])
        XCTAssertEqual(out, [
            "| a         | bb  |",
            "| --------- | :-: |",
            "| long cell |  x  |",
        ])
    }

    func testTableRightAlignAndEscapedPipe() {
        let out = TableFormatter.format(["| n | t |", "| -: | --- |", "| 5 | a\\|b |"])
        XCTAssertEqual(out[0], "|   n | t    |")
        XCTAssertEqual(out[2], "|   5 | a\\|b |")
    }

    func testFormatEditFindsTableAroundCaret() {
        let text = "intro\n\n|a|b|\n|-|-|\n|1|2|\n\noutro\n"
        let e = Formatter.apply(.formatTable, to: text, selection: NSRange(location: 12, length: 0))
        XCTAssertNotNil(e)
        XCTAssertTrue(e!.apply(to: text).contains("| a   | b   |"))
        XCTAssertNil(Formatter.apply(.formatTable, to: text, selection: NSRange(location: 1, length: 0)))
    }

    func testInsertTable() {
        let e = Formatter.apply(.insertTable, to: "", selection: NSRange(location: 0, length: 0))!
        let out = e.apply(to: "")
        XCTAssertTrue(out.hasPrefix("| Column 1 | Column 2 | Column 3 |"))
        let a = MarkdownAnalyzer.analyze(out)
        XCTAssertEqual(a.tables.count, 1)
    }

    func testTableWideCharacters() {
        let out = TableFormatter.format(["| 名 | b |", "| --- | --- |", "| 1 | 2 |"])
        XCTAssertEqual(out[0].count, out[2].count - 1) // CJK counts as two columns, so one fewer scalar
    }

    func testStats() {
        let s = DocumentStats("Hello world.\nSecond  line here")
        XCTAssertEqual(s.words, 5)
        XCTAssertEqual(s.lines, 2)
        XCTAssertEqual(s.readingMinutes, 1)
        XCTAssertEqual(DocumentStats("").words, 0)
        XCTAssertEqual(DocumentStats("").readingMinutes, 0)
    }

    func testPaletteLegibility() {
        for theme in Theme.allCases {
            let p = Palette.palette(for: theme)
            XCTAssertGreaterThanOrEqual(p.text.contrast(with: p.background), 10, "\(theme) text")
            XCTAssertGreaterThanOrEqual(p.secondaryText.contrast(with: p.background), 4.5, "\(theme) secondary")
            XCTAssertGreaterThanOrEqual(p.accent.contrast(with: p.background), 4.5, "\(theme) accent")
            XCTAssertGreaterThanOrEqual(p.link.contrast(with: p.background), 4.5, "\(theme) link")
            XCTAssertGreaterThanOrEqual(p.marker.contrast(with: p.background), 3.0, "\(theme) marker")
            XCTAssertGreaterThanOrEqual(p.codeText.contrast(with: p.codeBackground), 7, "\(theme) code")
            XCTAssertGreaterThanOrEqual(p.text.contrast(with: p.inlineCodeBackground), 7, "\(theme) inline code")
        }
    }

    func testLightAndDarkAreOpposites() {
        let l = Palette.palette(for: .light), d = Palette.palette(for: .dark)
        XCTAssertGreaterThan(l.background.luminance, 0.8)
        XCTAssertLessThan(d.background.luminance, 0.05)
    }
}
