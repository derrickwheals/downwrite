import Foundation

/// The one fixed light style of an exported or printed document (R17 to R20). It uses the light palette whatever the window looks like,
/// names only fonts every Mac has, and loads nothing.
public enum PrintStyle {
    private static let sansSerif = "-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,Helvetica,Arial,sans-serif"
    private static let monospace = "ui-monospace,Menlo,Consolas,\"Liberation Mono\",monospace"

    public static func css(for target: DocumentHTML.Target) -> String {
        let p = Palette.palette(for: .light)
        let isPrint = target == .print
        var rules: [String] = [
            ":root{color-scheme:light}",
            "body{margin:0;background:#ffffff;color:\(p.text.css);font-family:\(sansSerif);font-size:\(isPrint ? "11pt" : "16px");line-height:1.5;"
                + "overflow-wrap:break-word;-webkit-print-color-adjust:exact;print-color-adjust:exact}",
            isPrint ? "main{display:block;max-width:none;margin:0;padding:0}" : "main{display:block;max-width:46em;margin:0 auto;padding:24px}",
            "main>:first-child,main>.keep:first-child>:first-child{margin-top:0}main>:last-child{margin-bottom:0}",

            "h1,h2,h3,h4,h5,h6{line-height:1.25;font-weight:650;margin:1.4em 0 .5em}",
            "h1{font-size:2em}h2{font-size:1.55em}h3{font-size:1.3em}h4{font-size:1.15em}h5{font-size:1em}h6{font-size:.9em}",
            "p,ul,ol,dl,pre,blockquote,details,.dw-table,.dw-diagram{margin:0 0 .8em}",
            "ul,ol{padding-left:1.6em}li{margin:.15em 0}li>ul,li>ol,li>p:last-child{margin-bottom:0}",
            "summary{font-weight:600}",
            "a[href]{color:\(p.link.css);text-decoration:underline}",
            "mark{background:\(p.highlightBackground.css);color:inherit;border-radius:3px;padding:0 .1em}",
            "blockquote{border-left:3px solid \(p.quoteBar.css);padding:0 0 0 1em}",
            "hr{border:0;border-top:1px solid \(p.rule.css);margin:1.4em 0}",

            "code,kbd,samp,pre{font-family:\(monospace);font-size:90%}",
            "code,kbd,samp{background:\(p.inlineCodeBackground.css);border-radius:4px;padding:.1em .35em}",
            "pre{background:\(p.codeBackground.css);color:\(p.codeText.css);border-radius:9px;padding:.8em 1em;"
                + (isPrint ? "white-space:pre-wrap;overflow-wrap:anywhere;overflow:visible}" : "white-space:pre;overflow-x:auto}"),
            "pre code{background:none;padding:0;border-radius:0;font-size:100%}",

            "table{border-collapse:collapse}",
            "th,td{border:1px solid \(p.rule.css);padding:.35em .7em;vertical-align:top}",
            "th{background:\(p.codeBackground.css);font-weight:600}",
            isPrint ? ".dw-table{overflow:visible}" : ".dw-table{overflow-x:auto}",

            "img{max-width:100%;height:auto}",
            ".dw-diagram{text-align:center}.dw-diagram svg{max-width:100%;height:auto}",
            ".dw-missing,.dw-note{color:\(p.secondaryText.css);font-style:italic}",

            // A task item draws its own box and tick, so the look is the same on screen, on paper and in a PDF.
            "ul>li.task{list-style:none;margin-left:-1.4em}",
            ".box{display:inline-block;width:.95em;height:.95em;border:1.5px solid \(p.accent.css);border-radius:.2em;"
                + "vertical-align:-.15em;margin-right:.55em;position:relative}",
            ".done>.box{background:\(p.accent.css)}",
            ".done>.box::after{content:\"\";position:absolute;left:.26em;top:.02em;width:.22em;height:.5em;border:solid #ffffff;"
                + "border-width:0 .13em .13em 0;transform:rotate(45deg)}",
            ".done>.t{color:\(p.secondaryText.css);text-decoration:line-through}",
        ]

        // What the page may not do across a page break. A heading's `break-after: avoid` is only honoured by some engines, so a heading
        // is also wrapped with the block after it in `.keep` (R19).
        var paper = [
            "h1,h2,h3,h4,h5,h6{break-after:avoid;page-break-after:avoid}",
            ".keep,tr,li.task,blockquote,.dw-diagram,img{break-inside:avoid;page-break-inside:avoid}",
            "p,li,pre{orphans:2;widows:2}",
            "img{max-height:23cm}",
        ]
        if isPrint {
            rules += paper
        } else {
            // The HTML file printed from a browser: the same rules, on a page with margins of its own and no column.
            paper += ["pre{white-space:pre-wrap;overflow-wrap:anywhere;overflow:visible}", ".dw-table{overflow:visible}",
                      "body{font-size:11pt}", "main{max-width:none;margin:0;padding:0}", "@page{margin:20mm}"]
            rules.append("@media print{" + paper.joined() + "}")
        }
        return rules.joined()
    }
}
