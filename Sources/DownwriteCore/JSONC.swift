import Foundation

/// JSON with comments, as VS Code writes its settings and theme files: `// line` and `/* block */` comments and trailing
/// commas are allowed. `sanitize` turns such text into plain JSON that `JSONSerialization` accepts.
public enum JSONC {
    public enum ParseError: Error, Equatable {
        case invalid(String)
        case notAnObject
    }

    /// `text` without comments (outside strings), a leading byte-order mark, or commas that directly precede `]` / `}`.
    public static func sanitize(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        // Pass 1: drop comments.
        var stripped: [Unicode.Scalar] = []
        stripped.reserveCapacity(scalars.count)
        var inString = false
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inString {
                stripped.append(c)
                if c == "\\", i + 1 < scalars.count { stripped.append(scalars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; stripped.append(c); i += 1; continue }
            if c == "/", i + 1 < scalars.count {
                let next = scalars[i + 1]
                if next == "/" {                                    // line comment: up to (not including) the newline
                    i += 2
                    while i < scalars.count, scalars[i] != "\n" { i += 1 }
                    continue
                }
                if next == "*" {                                    // block comment
                    i += 2
                    while i + 1 < scalars.count, !(scalars[i] == "*" && scalars[i + 1] == "/") { i += 1 }
                    i = min(i + 2, scalars.count)
                    stripped.append(" ")                            // `1/**/2` must not fuse into `12`
                    continue
                }
            }
            stripped.append(c)
            i += 1
        }

        // Pass 2: drop trailing commas.
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(stripped.count)
        inString = false
        var j = 0
        while j < stripped.count {
            let c = stripped[j]
            if inString {
                result.append(c)
                if c == "\\", j + 1 < stripped.count { result.append(stripped[j + 1]); j += 2; continue }
                if c == "\"" { inString = false }
                j += 1
                continue
            }
            if c == "\"" { inString = true; result.append(c); j += 1; continue }
            if c == "," {
                var k = j + 1
                while k < stripped.count, stripped[k].properties.isWhitespace { k += 1 }
                if k < stripped.count, stripped[k] == "]" || stripped[k] == "}" { j += 1; continue }
            }
            result.append(c)
            j += 1
        }
        return String(String.UnicodeScalarView(result))
    }

    /// Parses JSONC text whose top level is an object.
    public static func object(from text: String) throws -> [String: Any] {
        let data = Data(sanitize(text).utf8)
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ParseError.invalid("\(error.localizedDescription)")
        }
        guard let object = value as? [String: Any] else { throw ParseError.notAnObject }
        return object
    }
}
