import XCTest
import Markdown
@testable import DownwriteCore

/// GitHub-style callouts (DW-006): the shared recogniser that the analyzer and the export both use, run over the corpus in
/// `Tests/Fixtures/callouts.md` (shared with the editor tests, the real-app step and the `gh api markdown` cross-check).
final class CalloutTests: XCTestCase {
    // MARK: The corpus

    enum Expected: Equatable, CustomStringConvertible {
        case plain
        case callout(CalloutKind, title: String?)

        var description: String {
            switch self {
            case .plain: return "plain"
            case .callout(let kind, let title): return "callout \(kind.rawValue)" + (title.map { " \"\($0)\"" } ?? "")
            }
        }

        /// `plain`, `callout warning`, `callout note "My title"`.
        init(_ text: String) {
            if text == "plain" { self = .plain; return }
            let words = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard words.count >= 2, words[0] == "callout", let kind = CalloutKind(rawValue: String(words[1])) else {
                preconditionFailure("bad expectation in callouts.md: \(text)")
            }
            var title: String?
            if words.count == 3 {
                let rest = words[2]
                guard let a = rest.firstIndex(of: "\""), let b = rest.lastIndex(of: "\""), a < b else {
                    preconditionFailure("bad title in callouts.md: \(text)")
                }
                title = String(rest[rest.index(after: a)..<b])
            }
            self = .callout(kind, title: title)
        }
    }

    struct Row {
        var id: String
        var expected: Expected
        /// The row's Markdown with its blank lines at both ends dropped.
        var source: String
    }

    static func fixture(file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/callouts.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// One row per `## <id> <expected>` heading; the text before the first such heading is not a row.
    static func rows(file: StaticString = #filePath) throws -> [Row] {
        var rows: [Row] = []
        var current: (id: String, expected: Expected, lines: [String])?
        func close() {
            guard let c = current else { return }
            var lines = c.lines
            while lines.first == "" { lines.removeFirst() }
            while lines.last == "" { lines.removeLast() }
            rows.append(Row(id: c.id, expected: c.expected, source: lines.joined(separator: "\n")))
        }
        for line in try fixture(file: file).components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                close()
                let parts = line.dropFirst(3).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { preconditionFailure("bad row heading in callouts.md: \(line)") }
                current = (String(parts[0]), Expected(String(parts[1])), [])
            } else {
                current?.lines.append(line)
            }
        }
        close()
        return rows
    }

    // MARK: Helpers

    /// Every block quote in the tree, outermost first.
    private func quotes(in node: Markup) -> [BlockQuote] {
        var out: [BlockQuote] = []
        if let q = node as? BlockQuote { out.append(q) }
        for c in node.children { out += quotes(in: c) }
        return out
    }

    /// The matches of every block quote in `text`, in document order, with the title text cut from the source.
    private func matches(_ text: String) -> [(match: CalloutMatch, title: String?)] {
        let src = SourceText(text)
        return quotes(in: Document(parsing: text)).compactMap { q in
            CalloutSyntax.match(q, in: src).map { m in (m, m.titleRange.map { src.string($0) }) }
        }
    }

    private func classify(_ text: String) -> Expected {
        let found = matches(text)
        XCTAssertLessThanOrEqual(found.count, 1, "more than one callout in one row: \(text.debugDescription)")
        guard let f = found.first else { return .plain }
        return .callout(f.match.kind, title: f.title)
    }

    private func slice(_ text: String, _ r: NSRange) -> String { NSString(string: text).substring(with: r) }

    // MARK: Kinds

    func testKindFromMarkerWordInAnyCase() {
        XCTAssertEqual(CalloutKind.allCases, [.note, .tip, .important, .warning, .caution])
        for kind in CalloutKind.allCases {
            XCTAssertEqual(CalloutKind(marker: kind.rawValue), kind)
            XCTAssertEqual(CalloutKind(marker: kind.rawValue.uppercased()), kind)
            XCTAssertEqual(CalloutKind(marker: kind.title), kind)
        }
        XCTAssertEqual(CalloutKind(marker: "nOtE"), .note)
        XCTAssertEqual(CalloutKind(marker: "wARNING"), .warning)
    }

    func testKindTitles() {
        XCTAssertEqual(CalloutKind.allCases.map(\.title), ["Note", "Tip", "Important", "Warning", "Caution"])
    }

    func testUnknownOrMalformedWordsAreNotKinds() {
        for word in ["", "info", "NOTES", "NOTE ", " NOTE", "no te", "danger", "quote", "[!NOTE]"] {
            XCTAssertNil(CalloutKind(marker: word), word)
        }
    }

    /// Case folding is ASCII only, on UTF-16 units: a dotless ı, a Kelvin sign or a Greek omicron is not a letter of the name.
    func testCaseFoldingIsAsciiOnly() {
        XCTAssertNil(CalloutKind(marker: "ımportant"))
        XCTAssertNil(CalloutKind(marker: "nοte"))        // Greek omicron
        XCTAssertNil(CalloutKind(marker: "NOTE\u{FF21}")) // full-width A
        XCTAssertEqual(matches("> [!ımportant]\n> body\n").count, 0)
        XCTAssertEqual(matches("> [!nοte]\n> body\n").count, 0)
    }

    // MARK: The corpus

    func testEveryRowIsClassifiedAsTheFileSays() throws {
        let rows = try Self.rows()
        XCTAssertGreaterThanOrEqual(rows.count, 45, "the fixture lost rows")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "row ids must be unique")
        for row in rows {
            XCTAssertEqual(classify(row.source), row.expected, "row \(row.id)\n\(row.source.debugDescription)")
        }
    }

    /// The same rows in one document, as the editor and the real-app step see them: rows do not leak into each other.
    func testWholeFixtureFindsExactlyTheExpectedCallouts() throws {
        let rows = try Self.rows()
        let expected = rows.compactMap { row -> Expected? in row.expected == .plain ? nil : row.expected }
        let found = matches(try Self.fixture()).map { Expected.callout($0.match.kind, title: $0.title) }
        XCTAssertEqual(found, expected)
    }

    func testCRLFDocumentsClassifyTheSameAndNeverReachTheLineBreak() throws {
        for row in try Self.rows() {
            let crlf = row.source.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
            XCTAssertEqual(classify(crlf), row.expected, "row \(row.id) with CRLF")
            for f in matches(crlf) {
                let marker = slice(crlf, f.match.markerRange)
                XCTAssertFalse(marker.contains("\r") || marker.contains("\n"), "marker of \(row.id) reaches the line break")
                if let t = f.match.titleRange {
                    let title = slice(crlf, t)
                    XCTAssertFalse(title.contains("\r") || title.contains("\n"), "title of \(row.id) reaches the line break")
                }
            }
        }
    }

    // MARK: Reference definitions (they cannot share a document with the corpus)

    /// `[!note]: https://x` anywhere makes every `[!NOTE]` in the document a link, so the quote stays plain.
    func testReferenceDefinitionElsewhereMakesTheMarkerALink() {
        XCTAssertEqual(matches("> [!NOTE]\n> body\n").count, 1)
        XCTAssertEqual(matches("> [!NOTE]\n> body\n\n[!note]: https://x\n").count, 0)
        XCTAssertEqual(matches("[!note]: https://x\n\n> [!NOTE]\n> body\n").count, 0)
        XCTAssertEqual(matches("> [!NOTE] My title\n> body\n\n[!note]: https://x\n").count, 0)
        // Only the defined name is affected.
        XCTAssertEqual(matches("> [!TIP]\n> body\n\n[!note]: https://x\n").count, 1)
    }

    /// `> [!NOTE]: x` is itself a reference definition (and defines `!note` for the whole document).
    func testMarkerFollowedByColonIsADefinitionNotACallout() {
        XCTAssertEqual(matches("> [!NOTE]: x\n> body\n").count, 0)
        XCTAssertEqual(matches("> [!NOTE]:\n> body\n").count, 0)
        XCTAssertEqual(matches("> [!NOTE]: x\n").count, 0)
    }

    // MARK: Rules the table leaves implicit

    func testSomethingMustFollowTheMarker() {
        XCTAssertEqual(classify("> [!NOTE]\n"), .plain)
        XCTAssertEqual(classify("> [!NOTE]\n>\n"), .plain)
        XCTAssertEqual(classify("> [!NOTE]   \n"), .plain)
        XCTAssertEqual(classify("> [!NOTE]\n> body\n"), .callout(.note, title: nil))
        XCTAssertEqual(classify("> [!NOTE]\n>\n> body\n"), .callout(.note, title: nil))
        XCTAssertEqual(classify("> [!NOTE]\n> - item\n"), .callout(.note, title: nil))
        XCTAssertEqual(classify("> [!NOTE]\n> ```\n> x\n> ```\n"), .callout(.note, title: nil))
    }

    func testTitleIsTheRestOfTheLineTrimmedAndWhitespaceIsNoTitle() {
        XCTAssertEqual(classify("> [!NOTE] My title\n"), .callout(.note, title: "My title"))
        XCTAssertEqual(classify("> [!NOTE]  \t My title \t \n"), .callout(.note, title: "My title"))
        XCTAssertEqual(classify("> [!NOTE]   \n> body\n"), .callout(.note, title: nil))
        XCTAssertEqual(classify("> [!NOTE]   \n"), .plain)
        // Only the first marker on the first line counts; the rest is title text.
        XCTAssertEqual(classify("> [!NOTE] [!TIP] x\n"), .callout(.note, title: "[!TIP] x"))
        // A title never reaches onto the next line.
        XCTAssertEqual(classify("> [!NOTE] One\n> Two\n"), .callout(.note, title: "One"))
    }

    func testMarkerMustBeFollowedByEndOfLineOrWhitespace() {
        for tail in ["+", "-", ":", "\\", "x", "!", ")", "["] {
            XCTAssertEqual(classify("> [!NOTE]\(tail)\n> body\n"), .plain, "tail \(tail)")
        }
        XCTAssertEqual(classify("> [!NOTE] x\n"), .callout(.note, title: "x"))
        XCTAssertEqual(classify("> [!NOTE]\tx\n"), .callout(.note, title: "x"))
    }

    // MARK: Ranges

    func testRangesOfAMarkerWithATitle() throws {
        let text = "> [!NOTE] My title\n> body\n"
        let found = try XCTUnwrap(matches(text).first)
        XCTAssertEqual(found.match.markerLine, 0)
        XCTAssertEqual(slice(text, found.match.markerRange), "[!NOTE] ")
        XCTAssertEqual(slice(text, try XCTUnwrap(found.match.titleRange)), "My title")
        XCTAssertEqual(found.match.markerRange, NSRange(location: 2, length: 8))
        XCTAssertEqual(found.match.titleRange, NSRange(location: 10, length: 8))
    }

    func testRangesOfAMarkerAloneIncludeTrailingWhitespaceButNoTitle() throws {
        let text = "> [!tip]  \t\n> body\n"
        let found = try XCTUnwrap(matches(text).first)
        XCTAssertEqual(slice(text, found.match.markerRange), "[!tip]  \t")
        XCTAssertNil(found.match.titleRange)
    }

    func testRangesAfterLeadingSpacesAndWithoutASpaceAfterTheQuote() throws {
        let indented = "   > [!WARNING]\n   > body\n"
        XCTAssertEqual(slice(indented, try XCTUnwrap(matches(indented).first).match.markerRange), "[!WARNING]")
        let tight = ">[!CAUTION]\n>body\n"
        XCTAssertEqual(slice(tight, try XCTUnwrap(matches(tight).first).match.markerRange), "[!CAUTION]")
        let wide = ">    [!NOTE] t\n> body\n"
        let found = try XCTUnwrap(matches(wide).first)
        XCTAssertEqual(slice(wide, found.match.markerRange), "[!NOTE] ")
        XCTAssertEqual(slice(wide, try XCTUnwrap(found.match.titleRange)), "t")
    }

    /// `>` / `> [!NOTE]` / `> body` is a callout on GitHub (D2): the marker is on the second line of the quote.
    func testBlankQuoteLineBeforeTheMarker() throws {
        let text = "intro\n\n>\n> [!NOTE]\n> body\n"
        let found = try XCTUnwrap(matches(text).first)
        XCTAssertEqual(found.match.markerLine, 3)
        XCTAssertEqual(slice(text, found.match.markerRange), "[!NOTE]")
    }

    /// Ranges are UTF-16: a title with accents and a non-BMP character is measured in code units, not scalars or bytes.
    func testNonBMPTitleRangeIsInUTF16Units() throws {
        let title = "Héllo 😀 wörld"
        let text = "😀 before\n\n> [!NOTE] \(title)\n> body 😀\n"
        let found = try XCTUnwrap(matches(text).first)
        let r = try XCTUnwrap(found.match.titleRange)
        XCTAssertEqual(slice(text, r), title)
        XCTAssertEqual(r.length, NSString(string: title).length)
        XCTAssertEqual(r.length, 14)
        XCTAssertEqual(found.match.markerLine, 2)
    }

    func testSeveralCalloutsInOneDocument() {
        let text = "> [!NOTE]\n> a\n\ntext\n\n> [!TIP] t\n\n> plain\n\n> [!CAUTION]\n> c\n"
        XCTAssertEqual(matches(text).map(\.match.kind), [.note, .tip, .caution])
        XCTAssertEqual(matches(text).map(\.match.markerLine), [0, 5, 9])
    }

    func testNoQuotesAndEmptyDocument() {
        XCTAssertEqual(matches("").count, 0)
        XCTAssertEqual(matches("[!NOTE]\nbody\n").count, 0)
        XCTAssertEqual(matches("> \n").count, 0)
        XCTAssertEqual(matches(">").count, 0)
    }
}
