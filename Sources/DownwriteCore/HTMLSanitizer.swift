import Foundation

/// Locks down the HTML that a document carries into an exported page (R13).
///
/// It does not patch the text with regular expressions. It reads the HTML the way a browser's tokeniser does, drops what must go, and
/// writes every tag it keeps again in one canonical form (`<name attr="value" …>`: valid names only, double-quoted values with `<`, `>`
/// and `"` escaped, a lone `<` in text escaped). So the output contains markup only where it was understood, and a browser cannot read
/// it differently from how it was read here.
///
/// What goes: `script` and `style` with their content; the tags (not the content) of `iframe`, `frame`, `frameset`, `object`, `embed`,
/// `applet`, `form`, `link`, `meta`, `base` and `title`; every `on…` attribute and `srcset`; comments, processing instructions, CDATA and
/// declarations; `href`, `xlink:href`, `action` and `formaction` values that `LinkPolicy` refuses; a `src` the caller's closure refuses.
/// Anything that never ends (a `<script>` without its end tag, a `<!--` without `-->`, a tag without `>`) is cut off at the next
/// ``blockBoundary`` or the end of the input, so one broken tag cannot swallow the rest of a document.
public enum HTMLSanitizer {
    /// A character the caller puts between blocks. Nothing unterminated runs past it. It is passed through as text.
    public static let blockBoundary: Character = "\u{E002}"

    public struct Output: Equatable, Sendable {
        public var html: String
        /// The decoded `src` of every `<img>` that survived, without repeats, in order of appearance.
        public var imageSources: [String]
    }

    /// What `rewriteImages` does with one `<img>`.
    public enum ImageRewrite: Equatable, Sendable {
        case keep
        /// Use this attribute text (already escaped) as the `src`.
        case source(String)
        /// Put this markup (trusted) where the `<img>` was.
        case replace(String)
    }

    /// The sanitised `html`. `allowImageSource` decides each `src` (decoded and trimmed) of any element; a source it refuses is removed.
    public static func sanitize(_ html: String, allowImageSource: (String) -> Bool) -> String {
        scan(html, openDetails: false, allowImageSource: allowImageSource).html
    }

    /// Sanitises and reports the `<img>` sources that survived. With `openDetails` every `<details>` gets `open` (paper cannot show a
    /// closed one).
    public static func scan(_ html: String, openDetails: Bool, allowImageSource: (String) -> Bool) -> Output {
        var sources: [String] = []
        var seen = Set<String>()
        let out = process(html, openDetails: openDetails, allowImageSource: allowImageSource) { source, _ in
            if seen.insert(source).inserted { sources.append(source) }
            return .keep
        }
        return Output(html: out, imageSources: sources)
    }

    /// Runs the sanitiser again over `html` (it changes nothing that is already clean) and lets `transform` change each `<img>` that has a
    /// `src`. It is given the decoded source and the decoded `alt` (nil if there is none).
    public static func rewriteImages(in html: String, _ transform: (_ source: String, _ alt: String?) -> ImageRewrite) -> String {
        process(html, openDetails: false, allowImageSource: { _ in true }, imageHandler: transform)
    }

    // MARK: Filtering

    private static let removedElements: Set<String> = [
        "script", "style", "iframe", "frame", "frameset", "object", "embed", "applet", "form", "link", "meta", "base", "title",
    ]
    private static let linkAttributes: Set<String> = ["href", "xlink:href", "action", "formaction"]
    private static let animationElements: Set<String> = ["animate", "set", "animatetransform", "animatemotion"]
    private static let animatedValueAttributes: Set<String> = ["values", "to", "from", "by"]

    private static func isLetter(_ c: Unicode.Scalar) -> Bool { (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A) }
    private static func isNameCharacter(_ c: Unicode.Scalar) -> Bool { isLetter(c) || (c.value >= 0x30 && c.value <= 0x39) }

    private static func isValidTagName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isLetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { isNameCharacter($0) || $0 == ":" || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func isValidAttributeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isLetter(first) || first == "_" || first == ":" else { return false }
        return name.unicodeScalars.allSatisfy { isNameCharacter($0) || $0 == ":" || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func escapeAttributeValue(_ v: String) -> String {
        guard v.contains(where: { $0 == "\"" || $0 == "<" || $0 == ">" }) else { return v }
        return v.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func serialise(_ tag: HTMLTag) -> String {
        var s = "<" + tag.name
        for a in tag.attributes {
            s += " " + a.name
            if let v = a.value { s += "=\"" + escapeAttributeValue(v) + "\"" }
        }
        return s + (tag.selfClosing ? " />" : ">")
    }

    /// The tag as it may stay, or nil if the tag goes.
    private static func filtered(_ tag: HTMLTag, openDetails: Bool, allowImageSource: (String) -> Bool) -> HTMLTag? {
        guard isValidTagName(tag.name) else { return nil }
        let name = tag.name.lowercased()
        guard !removedElements.contains(name) else { return nil }

        // An animation element can point an `href` at a script through `values`, `to`, `from` or `by`.
        var animatesALink = false
        if animationElements.contains(name),
           let target = tag.attributes.first(where: { $0.name.lowercased() == "attributename" })?.value {
            animatesALink = (LinkPolicy.decodeCharacterReferences(target) ?? "href").lowercased().hasSuffix("href")
        }

        var kept = HTMLTag(name: tag.name, attributes: [], selfClosing: tag.selfClosing)
        for a in tag.attributes {
            guard isValidAttributeName(a.name) else { continue }
            let attribute = a.name.lowercased()
            if attribute.hasPrefix("on") || attribute == "srcset" { continue }
            if let value = a.value {
                if linkAttributes.contains(attribute) {
                    guard LinkPolicy.isAllowedLinkDestination(value) else { continue }
                } else if attribute == "src" {
                    guard let decoded = LinkPolicy.decodeCharacterReferences(value),
                          allowImageSource(decoded.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                } else if animatesALink, animatedValueAttributes.contains(attribute) {
                    guard value.split(separator: ";", omittingEmptySubsequences: false).allSatisfy({ LinkPolicy.isAllowedLinkDestination(String($0)) }) else { continue }
                }
            }
            kept.attributes.append(a)
        }
        if openDetails, name == "details", !kept.attributes.contains(where: { $0.name.lowercased() == "open" }) {
            kept.attributes.append(HTMLAttribute(name: "open", value: nil))
        }
        return kept
    }

    private static func process(_ html: String, openDetails: Bool, allowImageSource: (String) -> Bool,
                                imageHandler handler: (String, String?) -> ImageRewrite) -> String {
        var out = ""
        out.reserveCapacity(html.utf8.count)
        HTMLTokenizer(html).run { token in
            switch token {
            case .text(let text):
                out += text
            case .end(let name):
                guard isValidTagName(name), !removedElements.contains(name.lowercased()) else { return }
                out += "</" + name + ">"
            case .start(let tag):
                guard var kept = filtered(tag, openDetails: openDetails, allowImageSource: allowImageSource) else { return }
                if kept.name.lowercased() == "img",
                   let at = kept.attributes.firstIndex(where: { $0.name.lowercased() == "src" && $0.value != nil }),
                   let source = LinkPolicy.decodeCharacterReferences(kept.attributes[at].value!) {
                    let alt = kept.attributes.first { $0.name.lowercased() == "alt" }?.value.flatMap(LinkPolicy.decodeCharacterReferences)
                    switch handler(source.trimmingCharacters(in: .whitespacesAndNewlines), alt) {
                    case .keep: break
                    case .source(let value): kept.attributes[at].value = value
                    case .replace(let markup): out += markup; return
                    }
                }
                out += serialise(kept)
            }
        }
        return out
    }
}

// MARK: - Tokenising

struct HTMLAttribute: Equatable {
    var name: String
    /// The value as written, character references and all. Nil for an attribute with no `=`.
    var value: String?
}

struct HTMLTag: Equatable {
    var name: String
    var attributes: [HTMLAttribute]
    var selfClosing: Bool
}

enum HTMLToken {
    case text(String)
    case start(HTMLTag)
    case end(String)
}

/// Reads HTML the way the HTML standard's tokeniser does for tags, attributes, comments and raw text, without building a tree. Comments,
/// processing instructions, CDATA and declarations produce no token. The content of `script` and `style` is skipped after their start
/// tag. A construct that never ends is dropped up to the next ``HTMLSanitizer/blockBoundary`` (or the end). A `<` that starts nothing is
/// text, written as `&lt;`. NUL becomes U+FFFD.
struct HTMLTokenizer {
    private let u: [Unicode.Scalar]
    private let boundaries: [Int]

    init(_ s: String) {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(s.utf8.count)
        var marks: [Int] = []
        for c in s.unicodeScalars {
            if c.value == 0 { scalars.append("\u{FFFD}"); continue }
            if c == "\u{E002}" { marks.append(scalars.count) }
            scalars.append(c)
        }
        u = scalars
        boundaries = marks
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\u{0C}" || c == "\r" }
    private static func isLetter(_ c: Unicode.Scalar) -> Bool { (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A) }

    private func string(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(u[a..<b])) }

    private func firstIndex(of c: Unicode.Scalar, from: Int, to end: Int) -> Int? {
        var p = from
        while p < end { if u[p] == c { return p }; p += 1 }
        return nil
    }

    /// Whether the scalars at `at` spell `word`, ignoring ASCII case.
    private func matches(_ word: String, at: Int, to end: Int) -> Bool {
        var p = at
        for w in word.unicodeScalars {
            guard p < end else { return false }
            let c = u[p]
            let lower = (c.value >= 0x41 && c.value <= 0x5A) ? Unicode.Scalar(c.value + 32)! : c
            guard lower == w else { return false }
            p += 1
        }
        return true
    }

    func run(_ emit: (HTMLToken) -> Void) {
        var text = String.UnicodeScalarView()
        var nextBoundary = 0
        func windowEnd(_ i: Int) -> Int {
            while nextBoundary < boundaries.count, boundaries[nextBoundary] < i { nextBoundary += 1 }
            return nextBoundary < boundaries.count ? boundaries[nextBoundary] : u.count
        }
        func flush() {
            if !text.isEmpty { emit(.text(String(text))); text = String.UnicodeScalarView() }
        }
        var i = 0
        while i < u.count {
            let c = u[i]
            guard c == "<" else { text.append(c); i += 1; continue }
            let w = windowEnd(i)
            guard i + 1 < w else { text.append(contentsOf: "&lt;".unicodeScalars); i += 1; continue }
            let n = u[i + 1]
            if Self.isLetter(n) {
                guard let (tag, next) = parseTag(from: i + 1, to: w) else { i = w; continue }
                flush()
                emit(.start(tag))
                i = next
                let name = tag.name.lowercased()
                if name == "script" || name == "style" { i = skipRawText(name, from: i, to: w) }
            } else if n == "/" {
                if i + 2 < w, Self.isLetter(u[i + 2]) {
                    guard let (tag, next) = parseTag(from: i + 2, to: w) else { i = w; continue }
                    flush()
                    emit(.end(tag.name))
                    i = next
                } else if i + 2 < w, u[i + 2] == ">" {
                    i += 3
                } else {
                    i = firstIndex(of: ">", from: i + 2, to: w).map { $0 + 1 } ?? w
                }
            } else if n == "!" {
                if matches("--", at: i + 2, to: w) {
                    i = commentEnd(from: i + 4, to: w)
                } else if matches("[cdata[", at: i + 2, to: w) {
                    i = indexAfter("]]>", from: i + 9, to: w) ?? w
                } else {
                    i = firstIndex(of: ">", from: i + 2, to: w).map { $0 + 1 } ?? w
                }
            } else if n == "?" {
                i = firstIndex(of: ">", from: i + 2, to: w).map { $0 + 1 } ?? w
            } else {
                text.append(contentsOf: "&lt;".unicodeScalars)
                i += 1
            }
        }
        flush()
    }

    private func indexAfter(_ word: String, from: Int, to end: Int) -> Int? {
        var p = from
        while p < end {
            if u[p] == word.unicodeScalars.first!, matches(word, at: p, to: end) { return p + word.unicodeScalars.count }
            p += 1
        }
        return nil
    }

    /// Where a comment whose text starts at `start` ends: after `>` (`<!-->`), after `->` (`<!--->`), or after the first `-->` or `--!>`.
    /// These are the HTML standard's own ways to end one, so a browser agrees about where the next markup begins.
    private func commentEnd(from start: Int, to end: Int) -> Int {
        if start < end, u[start] == ">" { return start + 1 }
        if start + 1 < end, u[start] == "-", u[start + 1] == ">" { return start + 2 }
        var p = start
        while p + 2 < end {
            if u[p] == "-", u[p + 1] == "-" {
                if u[p + 2] == ">" { return p + 3 }
                if u[p + 2] == "!", p + 3 < end, u[p + 3] == ">" { return p + 4 }
            }
            p += 1
        }
        return end
    }

    /// After `<script>` or `<style>`: past the matching end tag, or to the end of the window if it never comes.
    private func skipRawText(_ name: String, from: Int, to end: Int) -> Int {
        var p = from
        while let lt = firstIndex(of: "<", from: p, to: end) {
            let after = lt + 2 + name.unicodeScalars.count
            if lt + 1 < end, u[lt + 1] == "/", matches(name, at: lt + 2, to: end), after < end,
               Self.isSpace(u[after]) || u[after] == "/" || u[after] == ">" {
                return parseTag(from: lt + 2, to: end)?.1 ?? end
            }
            p = lt + 1
        }
        return end
    }

    /// A start or end tag whose name begins at `from`, with the index after its `>`; nil if it does not end before `end`. The attribute
    /// rules are the standard's: a name runs to white space, `/`, `>` or `=` (an `=` first is part of the name); `/` is only a self-closing
    /// mark right before `>`; a value is quoted, or unquoted up to white space or `>`.
    private func parseTag(from: Int, to end: Int) -> (HTMLTag, Int)? {
        var p = from
        while p < end, !Self.isSpace(u[p]), u[p] != "/", u[p] != ">" { p += 1 }
        guard p < end else { return nil }
        var tag = HTMLTag(name: string(from, p), attributes: [], selfClosing: false)
        while true {
            while p < end, Self.isSpace(u[p]) { p += 1 }
            guard p < end else { return nil }
            if u[p] == ">" { return (tag, p + 1) }
            if u[p] == "/" {
                guard p + 1 < end else { return nil }
                if u[p + 1] == ">" { tag.selfClosing = true; return (tag, p + 2) }
                p += 1
                continue
            }
            let nameStart = p
            p += 1
            while p < end, !Self.isSpace(u[p]), u[p] != "/", u[p] != ">", u[p] != "=" { p += 1 }
            guard p < end else { return nil }
            let name = string(nameStart, p)
            while p < end, Self.isSpace(u[p]) { p += 1 }
            guard p < end else { return nil }
            var value: String?
            if u[p] == "=" {
                p += 1
                while p < end, Self.isSpace(u[p]) { p += 1 }
                guard p < end else { return nil }
                let q = u[p]
                if q == "\"" || q == "'" {
                    guard let close = firstIndex(of: q, from: p + 1, to: end) else { return nil }
                    value = string(p + 1, close)
                    p = close + 1
                } else if q == ">" {
                    tag.attributes.append(HTMLAttribute(name: name, value: ""))
                    return (tag, p + 1)
                } else {
                    var e = p
                    while e < end, !Self.isSpace(u[e]), u[e] != ">" { e += 1 }
                    guard e < end else { return nil }
                    value = string(p, e)
                    p = e
                }
            }
            tag.attributes.append(HTMLAttribute(name: name, value: value))
        }
    }
}
