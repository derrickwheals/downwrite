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

    // MARK: The analysis record

    private func analyze(_ s: String) -> MarkdownAnalysis { MarkdownAnalyzer.analyze(s) }

    private func expected(_ a: MarkdownAnalysis, in text: String) -> [Expected] {
        a.callouts.map { .callout($0.kind, title: $0.titleRange.map { slice(text, $0) }) }
    }

    func testAnalysisRecordsTheSameCalloutsAsTheRecogniserForEveryRow() throws {
        for row in try Self.rows() {
            for (label, text) in [("LF", row.source + "\n"), ("CRLF", row.source.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")] {
                let found = expected(analyze(text), in: text)
                switch row.expected {
                case .plain: XCTAssertEqual(found, [], "row \(row.id) (\(label))")
                case .callout: XCTAssertEqual(found, [row.expected], "row \(row.id) (\(label))")
                }
            }
        }
    }

    func testWholeFixtureRecordsExactlyTheExpectedCalloutsInOrder() throws {
        let text = try Self.fixture()
        let a = analyze(text)
        let want = try Self.rows().compactMap { $0.expected == .plain ? nil : $0.expected }
        XCTAssertEqual(expected(a, in: text), want)
        var previousEnd = -1
        for c in a.callouts {
            XCTAssertGreaterThan(c.range.location, previousEnd, "callouts are in order and do not overlap")
            previousEnd = NSMaxRange(c.range)
        }
    }

    func testRecordFieldsOfATitledCallout() throws {
        let s = "intro\n\n> [!NOTE] My title\n> body\n\nafter\n"
        let a = analyze(s)
        let c = try XCTUnwrap(a.callouts.first)
        XCTAssertEqual(a.callouts.count, 1)
        XCTAssertEqual(c.kind, .note)
        XCTAssertEqual([c.firstLine, c.markerLine, c.lastLine], [2, 2, 3])
        XCTAssertEqual(slice(s, c.range), "> [!NOTE] My title\n> body")
        XCTAssertEqual(slice(s, c.markerRange), "[!NOTE] ")
        XCTAssertEqual(c.titleRange.map { slice(s, $0) }, "My title")
    }

    func testTitleOnlyCalloutIsOneLine() throws {
        let s = "> [!WARNING] Data loss"
        let c = try XCTUnwrap(analyze(s).callouts.first)
        XCTAssertEqual([c.firstLine, c.markerLine, c.lastLine], [0, 0, 0])
        XCTAssertEqual(slice(s, c.range), s)
    }

    /// `>` / `> [!TIP]` / `> body`: the bar and the lookups cover the blank first line, the marker is on the second.
    func testBlankFirstQuoteLineIsInsideTheCallout() throws {
        let s = "x\n\n>\n> [!TIP]\n> body\n"
        let a = analyze(s)
        let c = try XCTUnwrap(a.callouts.first)
        XCTAssertEqual([c.firstLine, c.markerLine, c.lastLine], [2, 3, 4])
        XCTAssertEqual(slice(s, c.range), ">\n> [!TIP]\n> body")
        XCTAssertEqual(slice(s, c.markerRange), "[!TIP]")
        XCTAssertEqual(a.calloutIndex(containingLine: 2), 0)
    }

    func testLazyAndNestedBlocksBelongToTheCallout() throws {
        let lazy = "> [!NOTE]\nbody\n\nafter\n"
        XCTAssertEqual(try XCTUnwrap(analyze(lazy).callouts.first).lastLine, 1)
        let blocks = "> [!NOTE]\n> - a\n> - b\n>\n> ```\n> x\n> ```\n\nafter\n"
        let c = try XCTUnwrap(analyze(blocks).callouts.first)
        XCTAssertEqual(c.lastLine, 6)
        XCTAssertEqual(slice(blocks, c.range), "> [!NOTE]\n> - a\n> - b\n>\n> ```\n> x\n> ```")
    }

    func testRangeNeverIncludesTheFinalLineBreak() throws {
        for s in ["> [!NOTE]\n> body\n", "> [!NOTE]\r\n> body\r\n", "> [!NOTE]\n> body"] {
            let c = try XCTUnwrap(analyze(s).callouts.first)
            XCTAssertEqual(slice(s, c.range).trimmingCharacters(in: .newlines), slice(s, c.range), s.debugDescription)
        }
    }

    /// The rest of the line analysis is exactly what a plain quote gets: a callout adds a record, a marker and a title span only.
    func testQuoteLinesAndQuoteMarkersAreUnchangedByTheCallout() {
        let callout = "intro\n\n> [!NOTE] My title\n> body\n> > nested\n\nafter\n"
        let plain = callout.replacingOccurrences(of: "[!NOTE]", with: "[?NOTE]")
        let c = analyze(callout), p = analyze(plain)
        XCTAssertEqual(c.callouts.count, 1)
        XCTAssertEqual(p.callouts.count, 0)
        XCTAssertEqual(c.lines, p.lines)
        XCTAssertEqual(c.markers.filter { $0.flags.contains(.quote) }, p.markers.filter { $0.flags.contains(.quote) })
        XCTAssertEqual(c.spans.filter { $0.flags.contains(.quote) }, p.spans.filter { $0.flags.contains(.quote) })
        XCTAssertEqual(c.markers.count, p.markers.count + 1, "the only new marker is the callout's")
    }

    func testPlainQuotesCarryNoCalloutFlagsAndCalloutsCarryExactlyOneMarker() throws {
        for row in try Self.rows() {
            let a = analyze(row.source + "\n")
            let runs = a.runs(in: NSRange(location: 0, length: row.source.utf16.count + 1), selection: NSRange(location: 0, length: 0))
            switch row.expected {
            case .plain:
                XCTAssertTrue(a.callouts.isEmpty, row.id)
                XCTAssertFalse(runs.contains { $0.flags.contains(.calloutMarker) || $0.flags.contains(.calloutTitle) }, row.id)
            case .callout(_, let title):
                XCTAssertEqual(a.markers.filter { $0.flags.contains(.calloutMarker) }.count, 1, row.id)
                XCTAssertEqual(runs.contains { $0.flags.contains(.calloutTitle) }, title != nil, row.id)
            }
        }
    }

    // MARK: Lookups

    func testLookupsByLine() {
        let s = "> [!NOTE]\n> a\n\ntext\n\n>\n> [!TIP] t\n> b\n\nend\n"
        let a = analyze(s)
        XCTAssertEqual(a.callouts.count, 2)
        let byLine = (-1...11).map { a.calloutIndex(containingLine: $0) }
        XCTAssertEqual(byLine, [nil, 0, 0, nil, nil, nil, 1, 1, 1, nil, nil, nil, nil])
        XCTAssertEqual(a.callout(containingLine: 1)?.kind, .note)
        XCTAssertEqual(a.callout(containingLine: 6)?.kind, .tip)
        XCTAssertNil(a.callout(containingLine: 3))
    }

    func testLookupsBySelectionAreInclusiveOfBothEnds() throws {
        let s = "intro\n\n> [!NOTE]\n> a\n\ntext\n\n> [!TIP] t\n> b\n"
        let a = analyze(s)
        let first = a.callouts[0], second = a.callouts[1]
        func at(_ offset: Int, _ length: Int = 0) -> Int? { a.calloutIndex(touching: NSRange(location: offset, length: length)) }
        XCTAssertNil(at(0), "intro")
        XCTAssertNil(at(first.range.location - 1), "the blank line before")
        XCTAssertEqual(at(first.range.location), 0, "start of the quote")
        XCTAssertEqual(at(NSMaxRange(first.range)), 0, "end of the quote's last line")
        XCTAssertNil(at(NSMaxRange(first.range) + 1), "the blank line after")
        XCTAssertEqual(at(second.range.location), 1)
        XCTAssertEqual(at(NSMaxRange(second.range)), 1)
        XCTAssertNil(at(NSMaxRange(second.range) + 1), "past the end")
        XCTAssertNil(at(s.utf16.count + 5))
        // A selection spanning both gives the first it touches; one that starts between them gives the second.
        XCTAssertEqual(at(0, s.utf16.count), 0)
        XCTAssertEqual(at(NSMaxRange(first.range) + 1, 10), 1)
    }

    func testLookupsWithNoCallouts() {
        let a = analyze("> plain\n\ntext\n")
        XCTAssertNil(a.calloutIndex(containingLine: 0))
        XCTAssertNil(a.calloutIndex(touching: NSRange(location: 0, length: 3)))
        XCTAssertNil(a.callout(containingLine: 0))
    }

    // MARK: Hiding and the style flags

    private func calloutMarkerIndex(_ a: MarkdownAnalysis) throws -> Int {
        try XCTUnwrap(a.markers.firstIndex { $0.flags.contains(.calloutMarker) })
    }

    func testMarkerHidesAwayFromTheMarkerLineAndRevealsOnItInclusiveOfBothEnds() throws {
        let s = "intro\n\n> [!NOTE] T\n> body\n"
        let a = analyze(s)
        let i = try calloutMarkerIndex(a)
        let marker = a.markers[i]
        XCTAssertEqual(slice(s, marker.range), "[!NOTE] ")
        XCTAssertEqual(slice(s, marker.reveal), "> [!NOTE] T", "the reveal range is the marker line, like the line's own `>`")
        let lineStart = marker.reveal.location, lineEnd = NSMaxRange(marker.reveal)
        func hidden(_ location: Int, _ length: Int = 0) -> Bool {
            a.hiddenMarkerIndices(selection: NSRange(location: location, length: length)).contains(i)
        }
        XCTAssertTrue(hidden(0), "intro")
        XCTAssertTrue(hidden(lineStart - 1), "the blank line above")
        XCTAssertFalse(hidden(lineStart), "start of the marker line")
        XCTAssertFalse(hidden(lineStart + 4), "inside the marker")
        XCTAssertFalse(hidden(lineEnd), "end of the marker line")
        XCTAssertTrue(hidden(lineEnd + 1), "start of the body line")
        XCTAssertTrue(hidden(lineEnd + 3), "inside the body line")
        XCTAssertFalse(hidden(lineStart - 1, 2), "a selection that reaches into the line")
        XCTAssertFalse(hidden(0, s.utf16.count), "a selection over everything")
    }

    func testRunsFlagTheMarkerAndTheTitle() throws {
        let s = "intro\n\n> [!NOTE] **Bold** t\n> body\n"
        let a = analyze(s)
        let c = try XCTUnwrap(a.callouts.first)
        let away = NSRange(location: 0, length: 0)
        let on = NSRange(location: c.markerRange.location + 2, length: 0)

        let markerRuns = a.runs(in: c.markerRange, selection: away)
        XCTAssertTrue(markerRuns.allSatisfy { $0.flags.isSuperset(of: [.calloutMarker, .marker, .hidden]) })
        XCTAssertEqual(markerRuns.reduce(0) { $0 + $1.range.length }, c.markerRange.length)
        let shown = a.runs(in: c.markerRange, selection: on)
        XCTAssertTrue(shown.allSatisfy { $0.flags.isSuperset(of: [.calloutMarker, .marker]) && !$0.flags.contains(.hidden) })

        let titleRange = try XCTUnwrap(c.titleRange)
        let titleRuns = a.runs(in: titleRange, selection: away)
        XCTAssertTrue(titleRuns.allSatisfy { $0.flags.contains(.calloutTitle) })
        XCTAssertTrue(titleRuns.contains { $0.flags.contains(.bold) && !$0.flags.contains(.marker) }, "inline formatting still applies")
        XCTAssertFalse(titleRuns.contains { $0.flags.contains(.calloutMarker) })

        // Nothing else on the page carries either flag.
        let all = a.runs(in: NSRange(location: 0, length: s.utf16.count), selection: away)
        for r in all where r.flags.contains(.calloutMarker) { XCTAssertTrue(NSIntersectionRange(r.range, c.markerRange).length == r.range.length) }
        for r in all where r.flags.contains(.calloutTitle) { XCTAssertTrue(NSIntersectionRange(r.range, titleRange).length == r.range.length) }
    }

    func testTheQuoteMarkerOfTheMarkerLineIsAnOrdinaryQuoteMarker() throws {
        let s = "> [!NOTE]\n> body\n"
        let a = analyze(s)
        let quoteMarkers = a.markers.filter { $0.flags.contains(.quote) }
        XCTAssertEqual(quoteMarkers.map { slice(s, $0.range) }, ["> ", "> "])
        XCTAssertFalse(quoteMarkers.contains { $0.flags.contains(.calloutMarker) })
    }

    // MARK: The editor and the export agree (R5)

    private func exported(_ text: String) -> String {
        DocumentHTML.prepare(text, options: .init(target: .screen, documentName: "doc.md")).body
    }

    /// The kinds the export wrote as callouts, in order.
    private func exportedKinds(_ html: String) -> [CalloutKind] {
        let pattern = try! NSRegularExpression(pattern: "<blockquote class=\"callout callout-([a-z]+)\">")
        return pattern.matches(in: html, range: NSRange(location: 0, length: html.utf16.count)).compactMap { m in
            CalloutKind(rawValue: NSString(string: html).substring(with: m.range(at: 1)))
        }
    }

    func testEditorAndExportDecideTheSameForEveryRow() throws {
        let rows = try Self.rows()
        for row in rows {
            for (label, text) in [("LF", row.source + "\n"), ("CRLF", row.source.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")] {
                let html = exported(text)
                XCTAssertEqual(exportedKinds(html), analyze(text).callouts.map(\.kind), "row \(row.id) (\(label))")
                switch row.expected {
                case .plain:
                    XCTAssertFalse(html.contains("callout"), "row \(row.id) (\(label)) is a plain quote: \(html)")
                case .callout(let kind, let title):
                    XCTAssertEqual(exportedKinds(html), [kind], "row \(row.id) (\(label))")
                    XCTAssertTrue(html.contains("<span class=\"callout-type\">\(kind.title)</span>"), "row \(row.id) (\(label)): \(html)")
                    if title == nil { XCTAssertTrue(html.contains("</span></p>"), "row \(row.id) has no title: \(html)") }
                    // The marker text is gone, apart from rows whose body or title spell another marker on purpose.
                    if !["second-marker", "title-marker"].contains(row.id) {
                        XCTAssertFalse(html.contains("[!"), "row \(row.id) (\(label)) shows its marker: \(html)")
                    }
                }
            }
        }
    }

    func testEditorAndExportAgreeOnTheWholeFixtureInOneDocument() throws {
        let text = try Self.fixture()
        let html = exported(text)
        XCTAssertEqual(exportedKinds(html), analyze(text).callouts.map(\.kind))
        XCTAssertEqual(exportedKinds(html).count, try Self.rows().filter { $0.expected != .plain }.count)
    }

    /// Plain titles come out as the editor's title text, escaped.
    func testExportedTitlesAreTheEditorsTitles() throws {
        for row in try Self.rows() {
            guard case .callout(_, let title?) = row.expected, !title.contains(where: { "*`[&<>\"".contains($0) }) else { continue }
            XCTAssertTrue(exported(row.source + "\n").contains("</span> \(title)</p>"), "row \(row.id)")
        }
    }
}
