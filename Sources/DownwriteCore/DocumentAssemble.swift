import Foundation

extension DocumentHTML.OmissionReason {
    /// The words the left-out-images sheet uses (R16).
    public var explanation: String {
        switch self {
        case .notFound: return "file not found"
        case .tooLarge: return "larger than 8 MB"
        case .notAnImage: return "not an image"
        case .insecure: return "http images are not allowed"
        case .sizeLimit: return "output size limit"
        case .unsavedDocument: return "document not saved yet"
        }
    }
}

extension DocumentHTML {
    /// What the renderer made of one Mermaid diagram.
    public enum DiagramOutcome: Sendable, Equatable {
        case svg(String)
        /// `reason` is one line, ready to show (for example `MermaidSupport.friendlyError`'s text, `timed out`, `renderer not responding`).
        case failed(reason: String)
    }

    // MARK: Step 2

    /// The complete page, and the images it had to leave out (in document order, each source once). Pure.
    ///
    /// `images` has an outcome for every source `prepare` listed; one that is missing is treated like a file that is not there. `diagrams`
    /// has one outcome per Mermaid fence, in order; a missing one is shown as a note. The sanitiser has already run over the body, so
    /// the diagrams (with their own `<style>`) are put in afterwards.
    public static func assemble(_ p: Prepared, images: [String: ImageOutcome], diagrams: [DiagramOutcome]) -> (html: String, omissions: [Omission]) {
        func outcome(_ source: String) -> ImageOutcome {
            if let known = images[source] { return known }
            switch LinkPolicy.imageSourceKind(source) {
            case .data, .https: return .keep
            default: return .leftOut(.notFound)
            }
        }
        var omissions: [Omission] = []
        for source in p.imageSources {
            if case .leftOut(let reason) = outcome(source) { omissions.append(Omission(source: source, reason: reason)) }
        }

        let withImages = HTMLSanitizer.rewriteImages(in: p.body) { source, alt in
            switch outcome(source) {
            case .embedded(let uri):
                return .source(DocumentRenderer.escapeAttribute(uri))
            case .keep:
                return .keep
            case .leftOut:
                let shown = (alt ?? "").isEmpty ? fileName(of: source) : alt!
                return .replace("<span class=\"dw-missing\">" + DocumentRenderer.escapeText(shown) + "</span>")
            }
        }

        let body = p.diagrams.isEmpty ? withImages : fillSlots(in: withImages, sources: p.diagrams, outcomes: diagrams)
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(HTMLSupport.contentSecurityPolicy)\">"
        let html = """
        <!doctype html>
        <html>
        <head>
        \(csp)
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <title>\(DocumentRenderer.escapeText(p.title))</title>
        <style>\(PrintStyle.css(for: p.target))</style>
        </head>
        <body>
        <main>

        """ + body + "</main>\n</body>\n</html>\n"
        return (html, omissions)
    }

    /// The name to show for an image that is not there and has no alt text: the last part of its path.
    private static func fileName(of source: String) -> String {
        let path = source.prefix { $0 != "?" && $0 != "#" }
        let last = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let decoded = last.removingPercentEncoding ?? last
        return decoded.isEmpty ? "image" : decoded
    }

    // MARK: Diagrams

    private static let unsafeSVG = try! NSRegularExpression(pattern: "<script|[\\s\"'/]on[a-z]+\\s*=|javascript:", options: [.caseInsensitive])

    /// Puts each diagram where its slot is, in one pass.
    private static func fillSlots(in body: String, sources: [String], outcomes: [DiagramOutcome]) -> String {
        var out = ""
        out.reserveCapacity(body.utf8.count)
        var parts = body.components(separatedBy: "\u{E000}")
        out += parts.removeFirst()
        for part in parts {
            // `part` is `D<n>` + U+E001 + the text that follows the slot.
            guard part.hasPrefix("D"), let end = part.firstIndex(of: "\u{E001}"), let n = Int(part[part.index(after: part.startIndex)..<end]),
                  n >= 1, n <= sources.count else {
                out += part
                continue
            }
            out += diagramHTML(number: n, source: sources[n - 1], outcome: n <= outcomes.count ? outcomes[n - 1] : .failed(reason: "not rendered"))
            out += part[part.index(after: end)...]
        }
        return out
    }

    private static func diagramHTML(number n: Int, source: String, outcome: DiagramOutcome) -> String {
        var reason: String
        switch outcome {
        case .svg(let svg):
            let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
            if unsafeSVG.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) == nil {
                return "<div class=\"dw-diagram\">" + rewriteSVGIDs(trimmed, prefix: "dw-d\(n)-") + "</div>"
            }
            reason = "the diagram output was not safe to include"
        case .failed(let why):
            reason = why
        }
        if reason.isEmpty { reason = "unknown error" }
        return "<p class=\"dw-note\">Diagram could not be rendered: " + DocumentRenderer.escapeText(reason) + "</p>\n<pre><code>"
            + DocumentRenderer.escapeText(source) + "</code></pre>"
    }

    /// Renames every `id` in an SVG to `<prefix>1`, `<prefix>2` … by order of first appearance, and follows each name through CSS selectors
    /// (`#id`), `url(#id)`, `href="#id"` and `aria-labelledby`. The new names do not depend on the old ones, so two runs of a renderer that
    /// picks random ids give the same text, and two diagrams never share an id.
    static func rewriteSVGIDs(_ svg: String, prefix: String) -> String {
        let ns = NSString(string: svg)
        let whole = NSRange(location: 0, length: ns.length)
        let idAttribute = try! NSRegularExpression(pattern: "(?<![\\w:-])id\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
        var order: [String] = []
        var seen = Set<String>()
        for m in idAttribute.matches(in: svg, range: whole) {
            let g = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let id = ns.substring(with: g)
            if !id.isEmpty, seen.insert(id).inserted { order.append(id) }
        }
        guard !order.isEmpty else { return svg }
        var renamed: [String: String] = [:]
        for (i, id) in order.enumerated() { renamed[id] = prefix + String(i + 1) }

        let names = order.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let reference = try! NSRegularExpression(pattern:
            "#(\(names))(?![\\w:-])|(?<![\\w:-])(?:id|aria-labelledby|aria-describedby)\\s*=\\s*[\"'](\(names))(?=[\"'])")
        var out = ""
        var at = 0
        for m in reference.matches(in: svg, range: whole) {
            let g = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            out += ns.substring(with: NSRange(location: at, length: g.location - at))
            out += renamed[ns.substring(with: g)] ?? ns.substring(with: g)
            at = NSMaxRange(g)
        }
        return out + ns.substring(from: at)
    }

    // MARK: The summary sheet (R16)

    /// One line for each of the first `limit` left-out images, then `and N more`.
    public static func summaryLines(of omissions: [Omission], limit: Int = 10) -> [String] {
        func shown(_ source: String) -> String { source.count > 80 ? String(source.prefix(77)) + "…" : source }
        var lines = omissions.prefix(limit).map { "\(shown($0.source)) (\($0.reason.explanation))" }
        if omissions.count > limit { lines.append("and \(omissions.count - limit) more") }
        return lines
    }
}

extension OutputNaming {
    /// R24: the display name without its Markdown extension, plus the extension of the file being written (`pdf`, `html`).
    public static func defaultFileName(forDisplayName displayName: String, extension ext: String) -> String {
        baseName(of: displayName) + "." + ext
    }
}
