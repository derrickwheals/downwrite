import Foundation

/// How a rendered HTML card should look: the editor's font and the active palette, as CSS values.
public struct HTMLPageStyle: Equatable, Sendable {
    /// CSS `font-family` value.
    public var fontFamily: String
    /// Body text size in CSS pixels (points in the editor).
    public var fontSize: Double
    public var lineHeight: Double
    public var dark: Bool
    public var palette: Palette

    public init(fontFamily: String, fontSize: Double, lineHeight: Double, palette: Palette) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.dark = palette.isDark
        self.palette = palette
    }
}

/// Pure helpers for HTML that is embedded in a Markdown document. Rendering happens in a WebKit view in the app target; this
/// side decides what is worth rendering and builds the locked-down page around it.
public enum HTMLSupport {
    // MARK: Is there anything to draw?

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are literals in this file: a failure here is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let commentRE = regex("<!--.*?(?:-->|$)", [.dotMatchesLineSeparators])
    private static let scriptStyleRE = regex("<(script|style)\\b.*?(?:</\\1\\s*>|$)", [.dotMatchesLineSeparators, .caseInsensitive])
    private static let declarationRE = regex("<\\?.*?(?:\\?>|$)|<!\\[CDATA\\[.*?(?:\\]\\]>|$)|<![A-Za-z][^>]*(?:>|$)", [.dotMatchesLineSeparators])
    private static let tagRE = regex("<(/?)([A-Za-z][A-Za-z0-9-]*)(?:\\s[^>]*)?/?>", [.dotMatchesLineSeparators])

    private static func removing(_ re: NSRegularExpression, from s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.utf16.count), withTemplate: "")
    }

    /// Elements that draw something even without any text inside.
    private static let visibleWithoutText: Set<String> = [
        "img", "hr", "svg", "picture", "video", "audio", "canvas", "progress", "meter", "input", "button", "select", "textarea",
    ]

    /// Whether an HTML block draws anything: it has visible text or an element that is visible on its own (an image, a rule…).
    /// Comments, `<script>`/`<style>` elements, processing instructions, `<!DOCTYPE>`, blocks that only close tags opened in an
    /// earlier block (`</details>`) and bare wrappers (`<div align="center">`) do not, and stay source.
    public static func isRenderable(_ html: String) -> Bool {
        var s = removing(commentRE, from: html)
        s = removing(scriptStyleRE, from: s)
        s = removing(declarationRE, from: s)
        let ns = NSString(string: s)
        for m in tagRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.range(at: 1).length == 0 {
            if visibleWithoutText.contains(ns.substring(with: m.range(at: 2)).lowercased()) { return true }
        }
        return removing(tagRE, from: s).contains { !$0.isWhitespace }
    }

    // MARK: Local images

    private static let imgTagRE = regex("<img\\b[^>]*>", [.dotMatchesLineSeparators, .caseInsensitive])
    private static let srcAttrRE = regex("(\\bsrc\\s*=\\s*)(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))", [.caseInsensitive])

    /// The `src` of every `<img>` in `html`, in order of appearance and without repeats.
    public static func imageSources(in html: String) -> [String] {
        var out: [String] = []
        for ref in imageSourceRefs(in: html) where !out.contains(ref.value) { out.append(ref.value) }
        return out
    }

    /// `html` with each `<img>` source that appears in `map` replaced by its value (the quoting of the attribute is kept).
    public static func replacingImageSources(in html: String, with map: [String: String]) -> String {
        guard !map.isEmpty else { return html }
        var units = Array(html.utf16)
        for ref in imageSourceRefs(in: html).reversed() {
            guard let new = map[ref.value] else { continue }
            units.replaceSubrange(ref.range.location..<NSMaxRange(ref.range), with: Array(new.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    private struct SourceRef { var value: String; var range: NSRange }

    private static func imageSourceRefs(in html: String) -> [SourceRef] {
        let ns = NSString(string: html)
        var out: [SourceRef] = []
        for tag in imgTagRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let m = srcAttrRE.firstMatch(in: html, range: tag.range) else { continue }
            for g in 2...4 where m.range(at: g).location != NSNotFound {
                out.append(SourceRef(value: ns.substring(with: m.range(at: g)), range: m.range(at: g)))
                break
            }
        }
        return out
    }

    /// Whether an image source refers to a file next to the document (or elsewhere on disk) rather than to a URL the page can
    /// fetch by itself.
    public static func isLocalSource(_ source: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, !s.hasPrefix("data:"), !s.hasPrefix("http:"), !s.hasPrefix("https:"), !s.hasPrefix("//") else { return false }
        return true
    }

    // MARK: Page

    /// What the page may load: inline CSS and `data:`/`https:` images, nothing else — no scripts, frames, plug-ins, fonts, forms
    /// or `<base>`. A document can add its own policies, which can only tighten this one.
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'"

    /// The id of the element that wraps the HTML; its height is the card's content height.
    public static let rootID = "dw-root"

    /// JavaScript (run by the app, not by the page) that returns the height of the rendered content in CSS pixels.
    public static let heightScript =
        "(function(){var r=document.getElementById('\(rootID)');return Math.ceil(r?r.getBoundingClientRect().height:document.documentElement.scrollHeight);})()"

    /// A complete page that shows `body` in the editor's typography and colours on a transparent background. The security
    /// policy is the first thing in `<head>`, ahead of anything from the document.
    public static func page(body: String, style: HTMLPageStyle) -> String {
        let p = style.palette
        let family = style.fontFamily.replacingOccurrences(of: "<", with: "")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(style.dark ? "dark" : "light")">
        <style>
        :root{color-scheme:\(style.dark ? "dark" : "light")}
        html,body{margin:0;padding:0;background:transparent}
        body{font:\(style.fontSize)px/\(style.lineHeight) \(family);color:\(p.text.css);overflow:hidden;overflow-wrap:break-word;-webkit-text-size-adjust:none}
        #\(rootID){display:flow-root}
        a{color:\(p.link.css)}
        img{max-width:100%;height:auto}
        h1,h2,h3,h4,h5,h6{line-height:1.2;margin:.6em 0 .3em}
        h1{font-size:1.9em}h2{font-size:1.55em}h3{font-size:1.3em}h4{font-size:1.15em}h5,h6{font-size:1em}
        p,ul,ol,dl,table,pre,blockquote,details{margin:0 0 .7em}
        code,kbd,samp,pre{font-family:ui-monospace,Menlo,monospace;font-size:.9em}
        code,kbd,samp{background:\(p.inlineCodeBackground.css);border-radius:4px;padding:.1em .35em}
        pre{background:\(p.codeBackground.css);color:\(p.codeText.css);border-radius:9px;padding:.8em 1em;overflow:hidden;white-space:pre-wrap}
        pre code{background:none;padding:0}
        mark{background:\(p.highlightBackground.css);color:inherit;border-radius:3px}
        blockquote{border-left:3px solid \(p.quoteBar.css);margin-left:0;padding-left:1em}
        hr{border:0;border-top:1px solid \(p.rule.css);margin:1em 0}
        table{border-collapse:collapse}
        th,td{border:1px solid \(p.rule.css);padding:.35em .7em}
        summary{cursor:default}
        </style></head><body><div id="\(rootID)">\(body)</div></body></html>
        """
    }
}
