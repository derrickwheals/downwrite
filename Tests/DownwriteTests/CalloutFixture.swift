import Foundation
import DownwriteCore

/// `Tests/Fixtures/callouts.md` for the app tests: one row per `## <id> <expected>` heading, where `<expected>` is `plain`,
/// `callout <kind>` or `callout <kind> "<title>"`. `CalloutTests` (Core) reads the same file with its own copy of this parser,
/// because the two test targets cannot share source.
enum CalloutFixture {
    struct Row {
        var id: String
        /// Nil for a row that is a plain quote.
        var kind: CalloutKind?
        var title: String?
        /// The row's Markdown with its blank lines at both ends dropped.
        var source: String

        var isCallout: Bool { kind != nil }
    }

    static func text(file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/callouts.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func rows(file: StaticString = #filePath) throws -> [Row] {
        var rows: [Row] = []
        var current: (id: String, expected: String, lines: [String])?
        func close() {
            guard let c = current else { return }
            var lines = c.lines
            while lines.first == "" { lines.removeFirst() }
            while lines.last == "" { lines.removeLast() }
            var kind: CalloutKind?
            var title: String?
            if c.expected != "plain" {
                let words = c.expected.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                precondition(words.count >= 2 && words[0] == "callout", "bad expectation in callouts.md: \(c.expected)")
                kind = CalloutKind(rawValue: String(words[1]))
                precondition(kind != nil, "bad kind in callouts.md: \(c.expected)")
                if words.count == 3, let a = words[2].firstIndex(of: "\""), let b = words[2].lastIndex(of: "\""), a < b {
                    title = String(words[2][words[2].index(after: a)..<b])
                }
            }
            rows.append(Row(id: c.id, kind: kind, title: title, source: lines.joined(separator: "\n")))
        }
        for line in try text(file: file).components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                close()
                let parts = line.dropFirst(3).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                precondition(parts.count == 2, "bad row heading in callouts.md: \(line)")
                current = (String(parts[0]), String(parts[1]), [])
            } else {
                current?.lines.append(line)
            }
        }
        close()
        return rows
    }
}
