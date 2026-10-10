import Foundation

/// YAML front matter: `---` on the very first line (trailing spaces allowed), closed by the first following line that is exactly `---` or
/// `...`. The editor (`MarkdownAnalyzer`) and the exported document (`DocumentHTML`) both ask this one rule where it ends.
enum FrontMatter {
    /// The index of the line that closes the front matter, or nil if the document has none. A document of fewer than three lines never does.
    static func endLine(in src: SourceText) -> Int? {
        func content(_ line: Int) -> String {
            src.string(NSRange(location: src.lineStarts[line], length: src.lineContentEnds[line] - src.lineStarts[line]))
        }
        guard src.lineCount > 2, content(0) == "---" || content(0).hasPrefix("---") && content(0).dropFirst(3).allSatisfy({ $0 == " " }) else {
            return nil
        }
        for i in 1..<src.lineCount where content(i) == "---" || content(i) == "..." { return i }
        return nil
    }
}

/// Inline syntax that cmark does not produce on its own and that both the editor and the exported document apply to text outside code
/// and links, so the two cannot drift apart.
enum InlineExtensions {
    /// `==highlight==`: the opening `==` is not followed by a space and the closing one is not preceded by one.
    static let highlight = try! NSRegularExpression(pattern: "==(?!\\s)(.+?)(?<!\\s)==")

    /// Bare URLs (GFM "autolink literals"), which the bundled cmark build does not produce on its own.
    static let bareURL = try! NSRegularExpression(
        pattern: "(?<![\\w/@(\\[])(?:https?://|www\\.)[^\\s<>\\[\\]]*[^\\s<>\\[\\].,;:!?'\"”’)\\]*_~]")

    /// Where a bare URL points: `www.…` gets a scheme, anything else is already one.
    static func destination(forBareURL text: String) -> String { text.hasPrefix("www.") ? "https://" + text : text }
}
