import Foundation

/// Which destinations and image sources an exported document may keep (R12, R13). A browser decodes character references in an attribute,
/// ignores tabs and line breaks inside a URL and trims control characters and spaces around it, so the check does the same before it
/// reads the scheme, and refuses what it cannot read rather than guess.
enum LinkPolicy {
    // MARK: Character references

    /// ASCII punctuation (and the no-break space) that has a named reference. Letters and digits have none, so nothing outside this table
    /// can spell part of a scheme.
    private static let namedReferences: [String: String] = [
        "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">", "quot": "\"", "QUOT": "\"", "apos": "'", "nbsp": "\u{A0}",
        "colon": ":", "Tab": "\t", "NewLine": "\n", "lpar": "(", "rpar": ")", "period": ".", "sol": "/", "bsol": "\\", "num": "#",
        "quest": "?", "plus": "+", "comma": ",", "semi": ";", "equals": "=", "excl": "!", "percnt": "%", "dollar": "$", "ast": "*",
        "midast": "*", "commat": "@", "lsqb": "[", "lbrack": "[", "rsqb": "]", "rbrack": "]", "lowbar": "_", "lcub": "{", "lbrace": "{",
        "rcub": "}", "rbrace": "}", "verbar": "|", "vert": "|", "VerticalLine": "|", "grave": "`", "Hat": "^",
    ]

    /// `s` with its character references decoded the way an HTML attribute value is: numeric references with or without the closing
    /// `;`, and the named references in the table above (which need the `;`). A lone `&`, or `&name` without `;`, stays as it is. Nil when
    /// a named reference is not one the check knows: it could be hiding anything, so the caller refuses the whole value.
    static func decodeCharacterReferences(_ s: String) -> String? {
        guard s.contains("&") else { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func isDigit(_ c: Unicode.Scalar, hex: Bool) -> Bool {
            switch c.value {
            case 0x30...0x39: return true
            case 0x41...0x46, 0x61...0x66: return hex
            default: return false
            }
        }
        while i < u.count {
            guard u[i] == "&" else { out.append(u[i]); i += 1; continue }
            if i + 1 < u.count, u[i + 1] == "#" {
                var j = i + 2
                let hex = j < u.count && (u[j] == "x" || u[j] == "X")
                if hex { j += 1 }
                let digitsStart = j
                var value: UInt64 = 0
                while j < u.count, isDigit(u[j], hex: hex) {
                    value = min(value * (hex ? 16 : 10) + UInt64(Int(String(u[j]), radix: 16)!), 0x11_0000)
                    j += 1
                }
                guard j > digitsStart else { out.append("&"); i += 1; continue }
                if j < u.count, u[j] == ";" { j += 1 }
                // NUL, surrogates and anything past U+10FFFF become the replacement character, as in a browser.
                out.append(value == 0 ? "\u{FFFD}" : (Unicode.Scalar(UInt32(value)) ?? "\u{FFFD}"))
                i = j
            } else {
                var j = i + 1
                while j < u.count, (u[j].value < 128 && (CharacterSet.alphanumerics.contains(u[j]))) { j += 1 }
                guard j > i + 1, j < u.count, u[j] == ";" else { out.append("&"); i += 1; continue }
                let name = String(String.UnicodeScalarView(u[(i + 1)..<j]))
                guard let replacement = namedReferences[name] else { return nil }
                out.append(contentsOf: replacement.unicodeScalars)
                i = j + 1
            }
        }
        return String(out)
    }

    // MARK: Reading a destination

    private enum Kind: Equatable { case relative, scheme(String), unreadable }

    /// The value as a browser's URL parser sees it: references decoded, tabs and line breaks removed, control characters and spaces
    /// trimmed from both ends. Nil if a reference cannot be read.
    private static func normalised(_ raw: String) -> String? {
        guard let decoded = decodeCharacterReferences(raw) else { return nil }
        var scalars: [Unicode.Scalar] = decoded.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
        let start = scalars.firstIndex { $0.value > 0x20 } ?? scalars.count
        return String(String.UnicodeScalarView(scalars[start...]))
    }

    /// A destination with no `:` before its first `/`, `?` or `#` has no scheme (a relative path or a fragment). Otherwise what comes
    /// before the colon must be a scheme (a letter, then letters, digits, `+`, `-` or `.`), or the destination is unreadable.
    private static func kind(of s: String) -> Kind {
        let u = Array(s.unicodeScalars)
        guard let colon = u.firstIndex(of: ":") else { return .relative }
        if let stop = u.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }), stop < colon { return .relative }
        let name = u[..<colon]
        func ascii(_ c: Unicode.Scalar) -> Bool { c.value < 128 && CharacterSet.alphanumerics.contains(c) }
        guard let first = name.first, first.value < 128, CharacterSet.letters.contains(first),
              name.dropFirst().allSatisfy({ ascii($0) || $0 == "+" || $0 == "-" || $0 == "." }) else { return .unreadable }
        return .scheme(String(String.UnicodeScalarView(name)).lowercased())
    }

    private static let linkSchemes: Set<String> = ["http", "https", "mailto", "tel", "file"]

    /// R12: a link keeps its destination when it is `http`, `https`, `mailto`, `tel` or `file`, or has no scheme (a relative path or a
    /// `#fragment`). Anything else, and anything that cannot be read, is shown as its text without a link.
    static func isAllowedLinkDestination(_ raw: String) -> Bool {
        guard let s = normalised(raw) else { return false }
        switch kind(of: s) {
        case .relative: return true
        case .unreadable: return false
        case .scheme(let name): return linkSchemes.contains(name)
        }
    }

    /// What kind of image source this is, for R14's table. A path that starts with `/` or `~`, and `file:`, do not depend on the
    /// document's folder; any other scheme-less path does.
    enum ImageSourceKind: Equatable {
        case data, https, http
        case local(relative: Bool)
        case unsupported
    }

    static func imageSourceKind(_ raw: String) -> ImageSourceKind {
        guard let s = normalised(raw), !s.hasPrefix("//") else { return .unsupported }
        switch kind(of: s) {
        case .relative: return .local(relative: !(s.hasPrefix("/") || s.hasPrefix("~")))
        case .unreadable: return .unsupported
        case .scheme("data"): return s.lowercased().hasPrefix("data:image/") ? .data : .unsupported
        case .scheme("https"): return .https
        case .scheme("http"): return .http
        case .scheme("file"): return .local(relative: false)
        case .scheme: return .unsupported
        }
    }

    /// R13/R14: an image source the output may keep for now: a path with no scheme, `file:`, `http:` (left out later with its reason),
    /// `https:`, or a `data:image/…` URI. Anything else (other schemes, `data:` that is not an image, `//host`) loses its `src`.
    static func isCandidateImageSource(_ raw: String) -> Bool {
        guard let s = normalised(raw), !s.hasPrefix("//") else { return false }
        switch kind(of: s) {
        case .relative: return true
        case .unreadable: return false
        case .scheme("data"): return s.lowercased().hasPrefix("data:image/")
        case .scheme(let name): return name == "http" || name == "https" || name == "file"
        }
    }
}
