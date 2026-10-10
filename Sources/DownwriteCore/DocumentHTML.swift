import Foundation
import Markdown

/// A whole Markdown document as one HTML page, for printing and for export (R4: it depends on the text and the files the text refers to,
/// never on the window).
///
/// It works in two pure steps with the app's file and diagram work between them: ``prepare(_:options:)`` turns the text into a sanitised
/// body and lists the images and diagrams the app must resolve; ``assemble(_:images:diagrams:)`` swaps those in and wraps the result in
/// the print page.
public enum DocumentHTML {
    /// Where the page is going. `print` is the paginated path (Print… and Export as PDF…): every `<details>` is open and the style has no
    /// column of its own. `screen` is the HTML file read in a browser.
    public enum Target: Sendable {
        case screen, print
    }

    public struct Options: Sendable {
        public var target: Target
        /// The document's display name, used for the page title when the document has no heading.
        public var documentName: String
        public init(target: Target = .screen, documentName: String = "") {
            self.target = target
            self.documentName = documentName
        }
    }

    /// The first step's result.
    public struct Prepared: Sendable {
        /// The plain title of the first heading, else the document name, else "Untitled".
        public var title: String
        /// Every distinct image source (Markdown images and `<img>`), decoded, in document order, that the output may still use.
        public var imageSources: [String]
        /// The source of each Mermaid diagram, in document order.
        public var diagrams: [String]
        var body: String
        var target: Target
    }

    // MARK: Step 1

    /// Markdown to a sanitised body with one slot per diagram. Pure, and safe to run off the main thread.
    public static func prepare(_ text: String, options: Options) -> Prepared {
        // The editor's own headings, so that an `id` is the very slug the editor resolves a `#fragment` with (R12).
        let analysis = MarkdownAnalyzer.analyze(text)
        let ids = HeadingAnchor.unique(analysis.headings.map { HeadingAnchor.slug($0.title) })

        var markdown = text
        let source = SourceText(text)
        if let end = FrontMatter.endLine(in: source) {
            markdown = String(decoding: source.units[source.lineEnds[end]...], as: UTF16.self)
        }
        markdown = protectFootnoteDefinitions(markdown)

        // Smart punctuation off: the text is shown as typed (the editor's own parse turns it on because only ranges are used there).
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        let renderer = DocumentRenderer(headingIDs: ids)
        renderer.render(document)

        let scanned = HTMLSanitizer.scan(renderer.html, openDetails: options.target == .print, allowImageSource: LinkPolicy.isCandidateImageSource)
        let body = scanned.html.replacingOccurrences(of: DocumentRenderer.boundary, with: "")

        var title = analysis.headings.first?.plainTitle ?? ""
        if title.isEmpty { title = OutputNaming.baseName(of: options.documentName) }
        return Prepared(title: title, imageSources: scanned.imageSources, diagrams: renderer.diagrams, body: body, target: options.target)
    }

    /// `[^1]: https://example.com` and `[^1]: Note.` are valid link reference definitions to cmark, which would swallow them (and turn
    /// every `[^1]` into a link). Footnotes are shown as typed (R11), so a definition at the start of a line outside a code fence gets a
    /// backslash before its `[`.
    static func protectFootnoteDefinitions(_ text: String) -> String {
        guard text.contains("[^") else { return text }
        var fence: (character: Character, length: Int)?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        out.reserveCapacity(lines.count + 4)
        func isUnderline(_ line: String) -> Bool {
            let stripped = line.drop(while: { $0 == " " })
            guard line.count - stripped.count <= 3, let c = stripped.first, c == "=" || c == "-" else { return false }
            return stripped.allSatisfy { $0 == c || $0 == " " || $0 == "\t" || $0 == "\r" }
        }
        for i in lines.indices {
            var line = lines[i]
            let stripped = line.drop(while: { $0 == " " })
            let indent = line.count - stripped.count
            if indent <= 3, let c = stripped.first, c == "`" || c == "~" {
                let run = stripped.prefix(while: { $0 == c }).count
                if run >= 3 {
                    if let f = fence {
                        if f.character == c, run >= f.length, stripped.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) { fence = nil }
                    } else {
                        fence = (c, run)
                    }
                    out.append(line)
                    continue
                }
            }
            var protected = false
            if fence == nil, indent <= 3, stripped.hasPrefix("[^"), let close = stripped.firstIndex(of: "]"),
               stripped[stripped.index(after: close)...].hasPrefix(":"), !stripped[stripped.index(stripped.startIndex, offsetBy: 2)..<close].contains(where: { $0.isWhitespace }) {
                line = String(line.prefix(indent)) + "\\" + stripped
                protected = true
            }
            out.append(line)
            // cmark used to take the definition line away, leaving a `---` or `===` under it a rule or a paragraph; as text it would become the
            // underline of a heading, so a blank line keeps it what the editor shows.
            if protected, i + 1 < lines.count, isUnderline(lines[i + 1]) { out.append("") }
        }
        return out.joined(separator: "\n")
    }
}

/// Names for the files an output is saved as (R24).
public enum OutputNaming {
    private static let extensions = [".md", ".markdown", ".txt"]

    /// The document's display name without its Markdown extension; "Untitled" if nothing is left.
    public static func baseName(of displayName: String) -> String {
        var name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ext = extensions.first(where: { name.lowercased().hasSuffix($0) }) { name = String(name.dropLast(ext.count)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled" : name
    }
}
