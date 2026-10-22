import XCTest
import Markdown
@testable import DownwriteCore

/// DW-025: a table ends where the person stopped writing rows. A line under the delimiter row that is not a row (see `TableTails.isRow`)
/// is body text, as if a blank line separated it from the table.
final class TableTailsTests: XCTestCase {
    private func ns(_ s: String, _ r: NSRange) -> String { NSString(string: s).substring(with: r) }

    /// The card's sample: a header, an empty body row and then text typed straight under it.
    static let card = "| Column 1 | Column 2 | Column 3 |\n| -------- | -------- | -------- |\n| | | |\nsxasdasdas\nsadasd\n"
        + "Ipsum duis elit, eu est. Eu est proident duis elit amet aute cillum.\n\nAfter.\n"

    private func spans(_ a: MarkdownAnalysis) -> [String] {
        a.tables.map { "\($0.firstLine)-\($0.lastLine)" }
    }

    // MARK: The card

    func testTextTypedUnderTheLastRowIsNotPartOfTheTable() throws {
        let a = MarkdownAnalyzer.analyze(Self.card)
        XCTAssertEqual(a.tables.count, 1)
        let t = try XCTUnwrap(a.tables.first)
        XCTAssertEqual(t.firstLine, 0)
        XCTAssertEqual(t.lastLine, 2, "the header, the delimiter row and the one empty row")
        XCTAssertTrue(t.isGrid)
        XCTAssertEqual(t.model?.rowCount, 2)
        XCTAssertEqual(t.model?.columnCount, 3)
        for l in 3...7 where l != 6 { XCTAssertEqual(a.lines[l].kind, .body, "line \(l)") }
        XCTAssertEqual(ns(Self.card, t.range), "| Column 1 | Column 2 | Column 3 |\n| -------- | -------- | -------- |\n| | | |")
    }

    func testTheTextIsNeverTouchedAndOffsetsAfterTheTableAreOriginal() throws {
        let s = "| a |\n| - |\n| 1 |\ntext **bold**\n\n# Heading\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(a.length, s.utf16.count)
        let bold = try XCTUnwrap(a.spans.first { $0.flags.contains(.bold) })
        XCTAssertEqual(ns(s, bold.range), "**bold**")
        XCTAssertEqual(a.headings.map(\.title), ["Heading"])
        XCTAssertEqual(ns(s, a.headings[0].range), "# Heading")
        XCTAssertTrue(a.markers.contains { $0.flags.contains(.headingMarker) && ns(s, $0.range) == "# " })
        XCTAssertEqual(a.lines.map(\.kind), [.tableHeader, .tableDelimiter, .tableRow, .body, .body, .heading(1), .body])
        XCTAssertEqual(a.lines[3].range, NSRange(location: 18, length: 14))
    }

    func testTheTailSpansTheTableLinesOnly() {
        let s = "| a |\n| - |\n| 1 |\nx\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(spans(a), ["0-2"])
        XCTAssertFalse(a.spans.contains { $0.flags.contains(.table) && $0.range.location >= 18 })
    }

    // MARK: Equivalence with a blank line typed there

    /// (text, index of the first line that is not a row). Typing a blank line before it must change nothing the analysis says.
    private static let breaks: [(name: String, text: String, line: Int, prefix: String)] = [
        ("card", card, 3, ""),
        ("one line", "| a | b |\n| - | - |\n| 1 | 2 |\ntext\nmore\n\nAfter\n", 3, ""),
        ("at the end without a newline", "| a |\n| - |\n| 1 |\ntext", 3, ""),
        ("quote", "> | a |\n> | - |\n> | 1 |\n> text\n> more\n", 3, "> "),
        ("quote with a lazy tail", "> | a |\n> | - |\n> | 1 |\n> text\n\nAfter\n", 3, "> "),
        ("bullet item", "- | a |\n  | - |\n  | 1 |\n  text\n- next\n", 3, "  "),
        ("numbered item", "1. | a |\n   | - |\n   | 1 |\n   text\n2. next\n", 3, "   "),
        ("text over a rule makes a setext heading", "| a |\n| - |\n| 1 |\ntext\n---\n", 3, ""),
        ("text then a pipe row joins the paragraph", "| a |\n| - |\n| 1 |\ntext\n| b |\n", 3, ""),
        ("the last pipeless line is the header of a second table", "| a |\n| - |\n| 1 |\nh1 | h2\n| - | - |\n| x | y |\n", 3, ""),
        ("a pipe-led table, then a one-column pipeless row", "| a |\n| - |\n| 1 |\n2\n", 3, ""),
        ("table after a paragraph and before a fence", "text\n\n| a |\n| - |\n| 1 |\nx\n\n```\ncode\n```\n", 5, ""),
        ("a table that has no tail, then one that has", "| a |\n| - |\n| 1 |\n\n| b |\n| - |\n| 2 |\ntail\n", 7, ""),
    ]

    private struct Flat: Equatable {
        var lines: [String]
        var tables: [String]
        var spans: [String]
        var markers: [String]
        var links: [String]
        var headings: [String]
    }

    /// The analysis with the line that was inserted at `line` taken out again: offsets after it move back by `shift`.
    private func flat(_ a: MarkdownAnalysis, removingLine removed: Int?, at insertionStart: Int, shift: Int) -> Flat {
        func off(_ o: Int) -> Int { removed != nil && o >= insertionStart + shift ? o - shift : o }
        func range(_ r: NSRange) -> String { "\(off(r.location)),\(off(NSMaxRange(r)) - off(r.location))" }
        func line(_ l: Int) -> Int { removed.map { l > $0 ? l - 1 : l } ?? l }
        var lines: [String] = []
        for (i, l) in a.lines.enumerated() where i != removed {
            lines.append("\(l.kind) q\(l.quoteDepth) l\(l.listDepth) s\(l.isListStart) p\(l.listPrefixLength)")
        }
        return Flat(
            lines: lines,
            tables: a.tables.map { "\(line($0.firstLine))-\(line($0.lastLine)) \(range($0.range)) grid=\($0.isGrid)" },
            spans: a.spans.map { "\($0.flags.rawValue) \(range($0.range))" },
            markers: a.markers.map { "\($0.flags.rawValue) \(range($0.range)) \(range($0.reveal))" },
            links: a.links.map { "\(range($0.range)) \($0.destination)" },
            headings: a.headings.map { "\($0.level) \($0.title) \(range($0.range))" })
    }

    func testAnalysisEqualsTheAnalysisWithABlankLineTypedBeforeTheFirstLineThatIsNotARow() {
        for c in Self.breaks {
            let src = SourceText(c.text)
            let start = src.lineStarts[c.line]
            let typed = c.prefix + "\n"
            let withBlank = NSString(string: c.text).replacingCharacters(in: NSRange(location: start, length: 0), with: typed)
            let plain = flat(MarkdownAnalyzer.analyze(c.text), removingLine: nil, at: 0, shift: 0)
            let typedFlat = flat(MarkdownAnalyzer.analyze(withBlank), removingLine: c.line, at: start, shift: typed.utf16.count)
            XCTAssertEqual(plain.lines, typedFlat.lines, c.name)
            XCTAssertEqual(plain.tables, typedFlat.tables, c.name)
            XCTAssertEqual(plain.spans, typedFlat.spans, c.name)
            XCTAssertEqual(plain.markers, typedFlat.markers, c.name)
            XCTAssertEqual(plain.links, typedFlat.links, c.name)
            XCTAssertEqual(plain.headings, typedFlat.headings, c.name)
            // And it really did end the table there.
            let first = MarkdownAnalyzer.analyze(c.text).tables.first
            XCTAssertEqual(first.map { $0.lastLine < c.line }, true, "\(c.name): the table stops before line \(c.line)")
        }
    }

    func testTheSecondTableStartsOnTheLastPipelessLine() {
        let s = "| a |\n| - |\n| 1 |\nh1 | h2\n| - | - |\n| x | y |\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(spans(a), ["0-2", "3-5"])
        XCTAssertEqual(a.lines.map(\.kind), [.tableHeader, .tableDelimiter, .tableRow, .tableHeader, .tableDelimiter, .tableRow, .body])
    }

    func testATextLineOverARuleBecomesASetextHeadingAsIfABlankLineSeparatedThem() {
        let s = "| a |\n| - |\n| 1 |\ntext\n---\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(spans(a), ["0-2"])
        XCTAssertEqual(a.lines[3].kind, .heading(2))
        XCTAssertEqual(a.lines[4].kind, .setextUnderline)
        XCTAssertEqual(a.headings.map(\.title), ["text"])
    }

    func testATextLineThenAPipeRowIsOneParagraphAndAddsNoRow() {
        let s = "| a |\n| - |\n| 1 |\ntext\n| b |\n"
        let a = MarkdownAnalyzer.analyze(s)
        XCTAssertEqual(spans(a), ["0-2"])
        XCTAssertEqual(a.lines[3].kind, .body)
        XCTAssertEqual(a.lines[4].kind, .body)
    }

    func testTypingAPipeFirstMakesTheLineARowAndItsTable() {
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("| a |\n| - |\n| 1 |\nx\n")), ["0-2"])
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("| a |\n| - |\n| 1 |\n|x\n")), ["0-3"])
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("| a |\n| - |\n| 1 |\n|\n")), ["0-3"], "a lone pipe is a row")
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("| a |\n| - |\n| 1 |\n  | x |\n")), ["0-3"], "so is an indented one")
    }

    // MARK: The row rule across kinds of delimiter row

    func testATableWithoutOuterPipesKeepsEveryLineWithAPipe() {
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("a | b\n- | -\n1 | 2\n3 | 4\n")), ["0-3"])
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("a | b\n- | -\n1 | 2\ntext\n")), ["0-2"])
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("a | b\n- | -\n1 | 2\nx \\| y\n")), ["0-2"], "an escaped pipe is not a separator")
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("a | b\n- | -\n1 | 2\n| 3 | 4 |\n")), ["0-3"])
    }

    func testAPipelessRowUnderAPipeLedTableIsText() {
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("| a | b |\n| - | - |\n| 1 | 2 |\nx | y\n")), ["0-2"])
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("| a | b |\n| - | - |\n| 1 | 2 |\n\\| x |\n")), ["0-2"])
        XCTAssertEqual(spans(MarkdownAnalyzer.analyze("| a |\n| - |\n| 1 |\n2\n3\n")), ["0-2"], "a one-column table's pipeless rows")
    }

    // MARK: Tables GFM accepts do not change

    /// Where plain cmark ends each table of `text`.
    private func cmarkTables(_ text: String) -> [String] {
        var out: [String] = []
        func visit(_ n: Markup) {
            if n is Table, let r = n.range {
                let last = r.upperBound.column == 1 && r.upperBound.line > r.lowerBound.line ? r.upperBound.line - 1 : r.upperBound.line
                out.append("\(r.lowerBound.line - 1)-\(last - 1)")
            }
            for c in n.children { visit(c) }
        }
        visit(Document(parsing: text))
        return out
    }

    func testTablesThatAreEntirelyRowsAreExactlyWhatCmarkParses() {
        let corpus = [
            "missing cells": "| a | b |\n| - | - |\n| 1 |\n",
            "extra cells": "| a |\n| - |\n| 1 | 2 | 3 |\n",
            "escaped pipes": "| a | b |\n| - | - |\n| x \\| y | z |\n",
            "empty cells": "| a | b |\n| - | - |\n| | |\n| | |\n",
            "no outer pipes": "a | b\n- | -\n1 | 2\n3 | 4\n",
            "a half-piped style": "a | b |\n- | - |\n1 | 2 |\n| 3 | 4\n",
            "ended by a blank line": "| a |\n| - |\n| 1 |\n\ntext\n",
            "ended by a heading": "| a |\n| - |\n| 1 |\n# H\n",
            "ended by a quote": "| a |\n| - |\n| 1 |\n> q\n",
            "ended by a fence": "| a |\n| - |\n| 1 |\n```\ncode\n```\n",
            "at the end without a newline": "| a |\n| - |\n| 1 |",
            "a lone pipe row": "| a |\n| - |\n|\n",
            "indented rows": "| a |\n| - |\n  | 1 |\n   | 2 |\n",
            "header only": "| a |\n| - |\n",
            "aligned": "| a | b | c |\n| :- | :-: | -: |\n| 1 | 2 | 3 |\n",
            "two tables": "| a |\n| - |\n| 1 |\n\n| b |\n| - |\n| 2 |\n",
            "quoted": "> | a |\n> | - |\n> | 1 |\n\ntext\n",
            "in a list item": "- | a |\n  | - |\n  | 1 |\n\n  more\n",
            "ended by a rule": "| a |\n| - |\n| 1 |\n***\n",
            "ended by a list": "| a |\n| - |\n| 1 |\n- item\n",
        ]
        for (name, text) in corpus.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(spans(MarkdownAnalyzer.analyze(text)), cmarkTables(text), name)
        }
    }

    // MARK: Quotes and lists

    func testTheRuleAppliesInsideQuotesAndListItems() {
        let quote = MarkdownAnalyzer.analyze("> | a |\n> | - |\n> | 1 |\n> text\n")
        XCTAssertEqual(spans(quote), ["0-2"])
        XCTAssertEqual(quote.lines[3].kind, .body)
        XCTAssertEqual(quote.lines[3].quoteDepth, 1)
        let bullet = MarkdownAnalyzer.analyze("- | a |\n  | - |\n  | 1 |\n  text\n")
        XCTAssertEqual(spans(bullet), ["0-2"])
        XCTAssertEqual(bullet.lines[3].kind, .body)
        XCTAssertEqual(bullet.lines[3].listDepth, 1)
        let numbered = MarkdownAnalyzer.analyze("1. | a |\n   | - |\n   | 1 |\n   text\n")
        XCTAssertEqual(spans(numbered), ["0-2"])
        XCTAssertEqual(numbered.lines[3].kind, .body)
        let both = MarkdownAnalyzer.analyze("- > | a |\n  > | - |\n  > | 1 |\n  > text\n")
        XCTAssertEqual(spans(both), ["0-2"])
    }

    func testQuotedTablesStayRawSourceAndNeverGrids() {
        let a = MarkdownAnalyzer.analyze("> | a |\n> | - |\n> | 1 |\n> text\n")
        XCTAssertEqual(a.tables.map(\.isGrid), [false])
    }

    // MARK: Random documents

    func testRandomDocumentsKeepEveryTableRowAnActualRow() {
        let fragments = [
            "| a | b |", "| - | - |", "| 1 | 2 |", "|", "| |", "a | b", "- | -", "x | y |", "plain text", "more text", "",
            "> | a |", "> | - |", "> | 1 |", "> quoted", "- | a |", "  | - |", "  | 1 |", "  indented", "- item", "1. item",
            "# Heading", "---", "***", "```", "~~~", "<div>", "text\\| not a cell", "\\| x |", "**bold** | b", "  ", "\t| tab |",
        ]
        var seed: UInt64 = 0x00DC_25AB_C0DE_1234
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        // Written apart from `TableTails`: the text after any run of spaces, tabs and `>`.
        func stripped(_ line: String) -> Substring {
            var s = Substring(line)
            while let f = s.first, f == " " || f == "\t" || f == ">" { s = s.dropFirst() }
            return s
        }
        func hasUnescapedPipe(_ s: Substring) -> Bool {
            var escaped = false
            for ch in s {
                if escaped { escaped = false; continue }
                if ch == "\\" { escaped = true } else if ch == "|" { return true }
            }
            return false
        }
        for n in 0..<300 {
            let count = 3 + next(10)
            let text = (0..<count).map { _ in fragments[next(fragments.count)] }.joined(separator: "\n") + (next(2) == 0 ? "\n" : "")
            let a = MarkdownAnalyzer.analyze(text)
            let lines = text.components(separatedBy: "\n")
            XCTAssertEqual(a.length, text.utf16.count, "document \(n)")
            XCTAssertEqual(a.lines.count, SourceText(text).lineCount, "document \(n)")
            for s in a.spans { XCTAssertTrue(NSMaxRange(s.range) <= a.length && s.range.location >= 0, "document \(n): span \(s.range)") }
            for m in a.markers { XCTAssertTrue(NSMaxRange(m.range) <= a.length && m.range.location >= 0, "document \(n): marker \(m.range)") }
            for t in a.tables {
                XCTAssertTrue(t.firstLine + 1 <= t.lastLine, "document \(n)")
                let delimiter = stripped(lines[t.firstLine + 1])
                let piped = delimiter.first == "|"
                guard t.lastLine >= t.firstLine + 2 else { continue }
                for l in (t.firstLine + 2)...t.lastLine {
                    let row = stripped(lines[l])
                    let ok = piped ? row.first == "|" : hasUnescapedPipe(row)
                    XCTAssertTrue(ok, "document \(n): line \(l) “\(lines[l])” is not a row of the table starting at line \(t.firstLine):\n\(text)")
                }
            }
        }
    }
}
