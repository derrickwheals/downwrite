import XCTest
@testable import DownwriteCore

/// R17 (the look), R18 (the screen layout) and the CSS that R19 and R20 rest on. The page-break rules are only checked here as text; what
/// WebKit's print engine does with them is checked on real PDF output in `DocumentOutputTests`.
final class PrintStyleTests: XCTestCase {
    private let light = Palette.palette(for: .light)
    private let screen = PrintStyle.css(for: .screen)
    private let print = PrintStyle.css(for: .print)

    /// The declarations that the top-level rules for `selector` add up to, as property → value (a later rule wins, as in the cascade).
    /// Rules inside `@media` are not looked at.
    private func declarations(_ selector: String, in css: String) -> [String: String] {
        var out: [String: String] = [:]
        var depth = 0
        var ruleStart = css.startIndex
        var i = css.startIndex
        while i < css.endIndex {
            let c = css[i]
            if c == "{" {
                if depth == 0 {
                    let head = css[ruleStart..<i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if head.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(selector),
                       let close = css[css.index(after: i)...].firstIndex(of: "}") {
                        for part in css[css.index(after: i)..<close].split(separator: ";") {
                            guard let colon = part.firstIndex(of: ":") else { continue }
                            out[part[..<colon].trimmingCharacters(in: .whitespaces)] = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { ruleStart = css.index(after: i) }
            }
            i = css.index(after: i)
        }
        return out
    }

    private func hexColor(_ value: String?) -> RGBA? {
        guard let v = value, v.hasPrefix("#"), v.count == 7, let n = UInt32(v.dropFirst(), radix: 16) else { return nil }
        return RGBA(hex: n)
    }

    // MARK: R17: the look

    func testThePageIsWhiteWithBodyTextAtAContrastOfAtLeastSevenToOne() {
        for css in [screen, print] {
            let body = declarations("body", in: css)
            let background = hexColor(body["background"]), text = hexColor(body["color"])
            XCTAssertEqual(background, RGBA(hex: 0xFFFFFF))
            XCTAssertEqual(text, light.text)
            XCTAssertGreaterThanOrEqual(text!.contrast(with: background!), 7)
        }
    }

    func testTheColoursComeFromTheLightPalette() {
        for css in [screen, print] {
            for (name, colour) in [("link", light.link), ("codeText", light.codeText), ("codeBackground", light.codeBackground),
                                   ("inlineCodeBackground", light.inlineCodeBackground), ("quoteBar", light.quoteBar),
                                   ("rule", light.rule), ("highlight", light.highlightBackground), ("accent", light.accent),
                                   ("secondaryText", light.secondaryText)] {
                XCTAssertTrue(css.contains(colour.css), "\(name) \(colour.css) is missing")
            }
        }
    }

    func testTheStyleDeclaresALightColourScheme() {
        for css in [screen, print] { XCTAssertEqual(declarations(":root", in: css)["color-scheme"], "light") }
    }

    func testTheFontStackIsTheSystemSansSerifAndNamesNoFontOnlySomeMacsHave() {
        for css in [screen, print] {
            let family = declarations("body", in: css)["font-family"] ?? ""
            XCTAssertTrue(family.hasPrefix("-apple-system"), family)
            XCTAssertTrue(family.hasSuffix("sans-serif"), family)
            for name in ["Avenir", "SF Pro", "San Francisco", "SF Mono", "Source Sans", "Inter"] { XCTAssertFalse(css.contains(name), name) }
        }
    }

    func testBodyTextSizesAndLineHeight() {
        XCTAssertEqual(declarations("body", in: screen)["font-size"], "16px")
        XCTAssertEqual(declarations("body", in: print)["font-size"], "11pt")
        for css in [screen, print] { XCTAssertEqual(declarations("body", in: css)["line-height"], "1.5") }
    }

    func testHeadingsGetSmallerWithTheirLevel() {
        for css in [screen, print] {
            let sizes = (1...6).map { Double((declarations("h\($0)", in: css)["font-size"] ?? "").replacingOccurrences(of: "em", with: "")) }
            XCTAssertFalse(sizes.contains { $0 == nil }, "\(sizes)")
            let s = sizes.compactMap { $0 }
            XCTAssertEqual(s, s.sorted(by: >), "\(s)")
            XCTAssertGreaterThan(s[0], s[1]); XCTAssertGreaterThan(s[1], s[2]); XCTAssertGreaterThan(s[2], s[3])
            XCTAssertGreaterThan(s[0], 1.5); XCTAssertLessThanOrEqual(s[5], 1)
        }
    }

    func testCodeIsMonospacedAtNinetyPercentOnALightCard() {
        for css in [screen, print] {
            let code = declarations("code", in: css), pre = declarations("pre", in: css)
            XCTAssertEqual(code["font-size"], "90%")
            XCTAssertTrue(code["font-family"]?.hasSuffix("monospace") == true)
            XCTAssertEqual(hexColor(pre["background"]), light.codeBackground)
            XCTAssertEqual(hexColor(pre["color"]), light.codeText)
            XCTAssertEqual(hexColor(code["background"]), light.inlineCodeBackground)
            XCTAssertGreaterThanOrEqual(light.codeText.contrast(with: light.codeBackground), 6)
        }
    }

    func testHighlightLinkQuoteAndRuleUseThePaletteToo() {
        for css in [screen, print] {
            XCTAssertEqual(declarations("mark", in: css)["background"], light.highlightBackground.css)
            XCTAssertEqual(hexColor(declarations("a[href]", in: css)["color"]), light.link)
            XCTAssertNil(declarations("a", in: css)["color"], "an anchor without an href (its link was refused) does not look like a link")
            XCTAssertTrue(declarations("blockquote", in: css)["border-left"]?.contains(light.quoteBar.css) == true)
            XCTAssertTrue(declarations("hr", in: css)["border-top"]?.contains(light.rule.css) == true)
        }
    }

    // MARK: R8: task boxes

    func testTaskBoxesAreDrawnWithCSSAndTheTickHasTheSameContrastEverywhere() {
        for css in [screen, print] {
            let box = declarations(".box", in: css)
            XCTAssertEqual(box["display"], "inline-block")
            XCTAssertTrue(box["border"]?.contains(light.accent.css) == true, "\(box)")
            let done = declarations(".done>.box", in: css)
            XCTAssertEqual(hexColor(done["background"]), light.accent)
            let tick = declarations(".done>.box::after", in: css)
            XCTAssertEqual(tick["content"], "\"\"")
            XCTAssertTrue(tick["border"]?.contains("#ffffff") == true, "\(tick)")
            XCTAssertGreaterThanOrEqual(light.accent.contrast(with: RGBA(hex: 0xFFFFFF)), 3)
            XCTAssertFalse(css.contains("checkbox"))
        }
    }

    func testATickedItemIsGreyedAndStruckThrough() {
        for css in [screen, print] {
            let text = declarations(".done>.t", in: css)
            XCTAssertEqual(hexColor(text["color"]), light.secondaryText)
            XCTAssertEqual(text["text-decoration"], "line-through")
            XCTAssertGreaterThanOrEqual(light.secondaryText.contrast(with: RGBA(hex: 0xFFFFFF)), 4.5)
        }
    }

    // MARK: R18: on screen

    func testTheScreenLayoutIsOneCentredColumn() {
        let main = declarations("main", in: screen)
        XCTAssertEqual(main["max-width"], "46em")
        XCTAssertEqual(main["padding"], "24px")
        XCTAssertEqual(main["margin"], "0 auto")
    }

    func testOnScreenWideContentScrollsInsideItsOwnBox() {
        XCTAssertEqual(declarations(".dw-table", in: screen)["overflow-x"], "auto")
        XCTAssertEqual(declarations("pre", in: screen)["overflow-x"], "auto")
        XCTAssertEqual(declarations("pre", in: screen)["white-space"], "pre")
        for selector in ["img", ".dw-diagram svg"] {
            XCTAssertEqual(declarations(selector, in: screen)["max-width"], "100%", selector)
            XCTAssertEqual(declarations(selector, in: screen)["height"], "auto", selector)
        }
    }

    // MARK: R19, R20: on paper

    func testThePrintTargetHasNoColumnAndNoPageRuleOfItsOwn() {
        XCTAssertEqual(declarations("main", in: print)["max-width"], "none")
        XCTAssertEqual(declarations("main", in: print)["padding"], "0")
        XCTAssertFalse(print.contains("@page"), "margins come from the print info, so they are not set twice")
        XCTAssertFalse(print.contains("46em"))
    }

    func testBlocksThatShouldStayWholeAreKeptWholeOnPaper() {
        for selector in [".keep", "tr", "li.task", "blockquote", ".dw-diagram", "img"] {
            XCTAssertEqual(declarations(selector, in: print)["break-inside"], "avoid", selector)
            XCTAssertEqual(declarations(selector, in: print)["page-break-inside"], "avoid", selector)
        }
    }

    func testHeadingsAskNotToEndAPageAndWidowsAndOrphansAreTwo() {
        let h = declarations("h1", in: print)
        XCTAssertEqual(h["break-after"], "avoid")
        XCTAssertEqual(h["page-break-after"], "avoid")
        for selector in ["p", "li", "pre"] {
            XCTAssertEqual(declarations(selector, in: print)["orphans"], "2", selector)
            XCTAssertEqual(declarations(selector, in: print)["widows"], "2", selector)
        }
    }

    func testCodeWrapsOnPaperAndImagesFitAPage() {
        XCTAssertEqual(declarations("pre", in: print)["white-space"], "pre-wrap")
        XCTAssertEqual(declarations("pre", in: print)["overflow-wrap"], "anywhere")
        XCTAssertEqual(declarations("img", in: print)["max-height"], "23cm")
        XCTAssertEqual(declarations("img", in: print)["max-width"], "100%")
        XCTAssertEqual(declarations(".dw-table", in: print)["overflow"], "visible")
    }


    func testOnPaperATableIsAColumnOfFlexRowsSoARowCannotBeCutBetweenItsLines() {
        // WebKit cuts a real table row between the lines of a tall cell whatever `break-inside` says; a block-level flex row is kept whole.
        XCTAssertEqual(declarations("table", in: print)["display"], "block")
        XCTAssertEqual(declarations("tbody", in: print)["display"], "block")
        XCTAssertEqual(declarations("tr", in: print)["display"], "flex")
        XCTAssertEqual(declarations("td", in: print)["display"], "block")
        XCTAssertEqual(declarations("td", in: print)["min-width"], "0")
        for n in 1...16 { XCTAssertEqual(declarations("td:nth-child(\(n))", in: print)["flex-grow"], "var(--w\(n),1)") }
        XCTAssertNil(declarations("tr", in: screen)["display"], "on screen the table is a table")
        XCTAssertNil(declarations("td", in: screen)["flex"])
        XCTAssertFalse(screen.contains("--w1"))
    }

    func testFlexCellsDoNotDoubleTheirBorders() {
        XCTAssertEqual(declarations("td+td", in: print)["border-left"], "0")
        XCTAssertTrue(print.contains("tr+tr>td"))
    }


    func testALooseListKeepsTheSpaceBetweenItsParagraphs() {
        for css in [screen, print] { XCTAssertFalse(css.contains("li>p:last-child"), "a loose list's items are spaced by their paragraphs' margins") }
        XCTAssertEqual(declarations("li>ul", in: print)["margin-bottom"], "0", "a nested list adds no gap after itself")
    }

    func testBackgroundsAreKeptWhenPrinting() {
        for css in [screen, print] {
            XCTAssertTrue(css.contains("print-color-adjust:exact"))
            XCTAssertTrue(css.contains("-webkit-print-color-adjust:exact"))
        }
    }

    func testTheScreenFileStillPrintsWellFromABrowser() {
        XCTAssertTrue(screen.contains("@media print{"))
        let afterMedia = String(screen[screen.range(of: "@media print{")!.upperBound...])
        XCTAssertTrue(afterMedia.contains("@page{margin:20mm}"))
        XCTAssertTrue(afterMedia.contains("white-space:pre-wrap"))
        XCTAssertTrue(afterMedia.contains("break-inside:avoid"))
        XCTAssertTrue(afterMedia.contains("font-size:11pt"))
    }

    // MARK: Safety and stability

    func testTheStyleLoadsNothing() {
        for css in [screen, print] {
            for forbidden in ["url(", "@import", "@font-face", "expression(", "javascript:", "<", "behavior:"] { XCTAssertFalse(css.contains(forbidden), forbidden) }
        }
    }

    func testTheStyleIsTheSameEveryTime() {
        XCTAssertEqual(PrintStyle.css(for: .screen), screen)
        XCTAssertEqual(PrintStyle.css(for: .print), print)
        XCTAssertNotEqual(screen, print)
    }
}
