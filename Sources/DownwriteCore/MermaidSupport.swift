import Foundation

/// Pure helpers for presenting Mermaid output. The actual rendering happens in a WebKit view in the app target.
public enum MermaidSupport {
    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public init(width: Double, height: Double) { self.width = width; self.height = height }
        public var aspect: Double { height > 0 ? width / height : 1 }
    }

    /// Intrinsic size of an SVG from its `viewBox` (falling back to numeric `width`/`height` attributes).
    public static func intrinsicSize(ofSVG svg: String) -> Size? {
        let head = String(svg.prefix(4096))
        if let m = firstMatch(#"viewBox\s*=\s*"([-\d.eE+]+)[\s,]+([-\d.eE+]+)[\s,]+([\d.eE+]+)[\s,]+([\d.eE+]+)""#, in: head),
           let w = Double(m[3]), let h = Double(m[4]), w > 0, h > 0 {
            return Size(width: w, height: h)
        }
        if let w = firstMatch(#"\bwidth\s*=\s*"([\d.]+)(?:px)?""#, in: head).flatMap({ Double($0[1]) }),
           let h = firstMatch(#"\bheight\s*=\s*"([\d.]+)(?:px)?""#, in: head).flatMap({ Double($0[1]) }), w > 0, h > 0 {
            return Size(width: w, height: h)
        }
        return nil
    }

    /// Fit a diagram into `maxWidth` without ever scaling it up beyond its natural size.
    public static func fittedSize(_ natural: Size, maxWidth: Double, maxHeight: Double = 640) -> Size {
        var scale = min(1, maxWidth / max(natural.width, 1))
        scale = min(scale, maxHeight / max(natural.height, 1))
        return Size(width: natural.width * scale, height: natural.height * scale)
    }

    /// Minimal HTML page that centres an SVG on a transparent background.
    public static func page(wrapping svg: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden;height:100%}
        body{display:flex;align-items:center;justify-content:center}
        svg{max-width:100% !important;max-height:100% !important;width:100%;height:100%}
        </style></head><body>\(svg)</body></html>
        """
    }

    /// Human-readable one-liner from a Mermaid/JS error message.
    public static func friendlyError(_ message: String) -> String {
        let firstLine = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? message
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(157)) + "…" : trimmed
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : NSString(string: s).substring(with: r)
        }
    }
}
