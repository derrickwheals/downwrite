import XCTest
@testable import DownwriteCore

final class ThemeCatalogTests: XCTestCase {
    func testTheCatalogHasTheAgreedThemes() {
        XCTAssertEqual(ThemeCatalog.themes(for: .light).map(\.name), ["Downwrite", "Catppuccin Latte", "Radix"])
        XCTAssertEqual(ThemeCatalog.themes(for: .dark).map(\.name), ["Downwrite", "Catppuccin Mocha", "Radix"])
        XCTAssertEqual(ThemeCatalog.builtIn.map(\.id), ["downwrite-light", "catppuccin-latte", "radix-light",
                                                        "downwrite-dark", "catppuccin-mocha", "radix-dark"])
    }

    func testIdsAreUniqueAndDefaultsExist() {
        let ids = ThemeCatalog.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ThemeCatalog.theme(id: ThemeCatalog.defaultLightID, for: .light).appearance, .light)
        XCTAssertEqual(ThemeCatalog.theme(id: ThemeCatalog.defaultDarkID, for: .dark).appearance, .dark)
    }

    func testDownwriteIsTheOriginalPair() {
        XCTAssertEqual(ThemeCatalog.palette(id: "downwrite-light", for: .light), Palette.palette(for: .light))
        XCTAssertEqual(ThemeCatalog.palette(id: "downwrite-dark", for: .dark), Palette.palette(for: .dark))
        XCTAssertEqual(ThemeCatalog.palette(id: nil, for: .light), Palette.palette(for: .light), "no preference: Downwrite")
    }

    func testUnknownOrMismatchedIdsFallBackToDownwrite() {
        XCTAssertEqual(ThemeCatalog.palette(id: "no-such-theme", for: .dark), Palette.palette(for: .dark))
        XCTAssertEqual(ThemeCatalog.palette(id: "catppuccin-mocha", for: .light), Palette.palette(for: .light),
                       "a dark theme's id never colours a light appearance")
        XCTAssertEqual(ThemeCatalog.palette(id: "radix-light", for: .dark), Palette.palette(for: .dark))
    }

    func testEveryThemeMatchesItsAppearance() {
        for t in ThemeCatalog.builtIn {
            XCTAssertEqual(t.palette.isDark, t.appearance == .dark, "\(t.id): a \(t.appearance) theme needs a \(t.appearance) page")
        }
    }

    func testEveryThemeIsLegible() {
        for t in ThemeCatalog.builtIn {
            let p = t.palette
            XCTAssertGreaterThanOrEqual(p.text.contrast(with: p.background), 7, "\(t.id) text (AAA)")
            XCTAssertGreaterThanOrEqual(p.secondaryText.contrast(with: p.background), 4.5, "\(t.id) secondary")
            XCTAssertGreaterThanOrEqual(p.accent.contrast(with: p.background), 3, "\(t.id) accent (bullets, checkbox fill)")
            XCTAssertGreaterThanOrEqual(p.link.contrast(with: p.background), 4.0, "\(t.id) link")
            XCTAssertGreaterThanOrEqual(p.marker.contrast(with: p.background), 2.9, "\(t.id) marker")
            XCTAssertGreaterThanOrEqual(p.codeText.contrast(with: p.codeBackground), 6, "\(t.id) code")
            XCTAssertGreaterThanOrEqual(p.text.contrast(with: p.inlineCodeBackground), 6, "\(t.id) inline code")
            // Text on the translucent highlight and on the selection, flattened over the page.
            XCTAssertGreaterThanOrEqual(p.text.contrast(with: flatten(p.highlightBackground, over: p.background)), 4.5, "\(t.id) highlighted text")
            XCTAssertGreaterThanOrEqual(p.text.contrast(with: flatten(p.selection, over: p.background)), 4.5, "\(t.id) selected text")
        }
    }

    func testCardsAndRulesAreVisibleAgainstThePage() {
        for t in ThemeCatalog.builtIn {
            let p = t.palette
            XCTAssertGreaterThan(p.codeBackground.contrast(with: p.background), 1.04, "\(t.id) code card")
            XCTAssertGreaterThan(p.inlineCodeBackground.contrast(with: p.background), 1.1, "\(t.id) inline code")
            XCTAssertGreaterThan(p.rule.contrast(with: p.background), 1.25, "\(t.id) rule")
        }
    }

    func testThemesAreDistinctFromEachOther() {
        for appearance in [Theme.light, .dark] {
            let backgrounds = ThemeCatalog.themes(for: appearance).map(\.palette.background)
            XCTAssertEqual(backgrounds.count, Set(backgrounds.map { "\($0.r),\($0.g),\($0.b)" }).count, "\(appearance) pages differ")
        }
    }

    func testCatppuccinAndRadixUseTheirPublishedValues() {
        let latte = ThemeCatalog.palette(id: "catppuccin-latte", for: .light)
        XCTAssertEqual(latte.background, RGBA(hex: 0xEFF1F5), "Latte base")
        XCTAssertEqual(latte.accent, RGBA(hex: 0x8839EF), "Latte mauve")
        let mocha = ThemeCatalog.palette(id: "catppuccin-mocha", for: .dark)
        XCTAssertEqual(mocha.background, RGBA(hex: 0x1E1E2E), "Mocha base")
        XCTAssertEqual(mocha.text, RGBA(hex: 0xCDD6F4), "Mocha text")
        let radixLight = ThemeCatalog.palette(id: "radix-light", for: .light)
        XCTAssertEqual(radixLight.background, RGBA(hex: 0xFCFCFD), "slate 1")
        XCTAssertEqual(radixLight.accent, RGBA(hex: 0x3E63DD), "indigo 9")
        let radixDark = ThemeCatalog.palette(id: "radix-dark", for: .dark)
        XCTAssertEqual(radixDark.background, RGBA(hex: 0x111113), "slate dark 1")
        XCTAssertEqual(radixDark.text, RGBA(hex: 0xEDEEF0), "slate dark 12")
    }

    func testIsDarkFollowsThePageNotTheName() {
        XCTAssertFalse(Palette.palette(for: .light).isDark)
        XCTAssertTrue(Palette.palette(for: .dark).isDark)
    }

    private func flatten(_ c: RGBA, over bg: RGBA) -> RGBA {
        RGBA(c.r * c.a + bg.r * (1 - c.a), c.g * c.a + bg.g * (1 - c.a), c.b * c.a + bg.b * (1 - c.a))
    }

    // MARK: Callout colours (DW-006)

    /// CIE L*a*b* of an opaque sRGB colour (D65), for the CIE76 distance ΔE*ab.
    private func lab(_ c: RGBA) -> (l: Double, a: Double, b: Double) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    private func deltaE(_ p: RGBA, _ q: RGBA) -> Double {
        let a = lab(p), b = lab(q)
        return ((a.l - b.l) * (a.l - b.l) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    func testCalloutColoursAreOpaqueAndMeetContrastOnEveryBuiltInTheme() {
        for t in ThemeCatalog.builtIn {
            for kind in CalloutKind.allCases {
                let c = t.palette.calloutColor(kind)
                XCTAssertEqual(c.a, 1, "\(t.id) \(kind) is opaque")
                XCTAssertGreaterThanOrEqual(c.contrast(with: t.palette.background), 4.5, "\(t.id) \(kind) against the page")
            }
        }
    }

    /// Any two of the five are told apart by colour alone on the six built-in themes: CIE76 ΔE*ab of at least 25 (the closest
    /// pair, Note and Important, is about 31 at worst, so there is room). Imported pages near luminance 0.18 can converge; the
    /// icon and the type name still tell those apart (spec R16).
    func testCalloutColoursArePairwiseDistinctOnEveryBuiltInTheme() {
        for t in ThemeCatalog.builtIn {
            let kinds = CalloutKind.allCases
            for i in kinds.indices {
                for j in kinds.indices where j > i {
                    let d = deltaE(t.palette.calloutColor(kinds[i]), t.palette.calloutColor(kinds[j]))
                    XCTAssertGreaterThanOrEqual(d, 25, "\(t.id): \(kinds[i]) vs \(kinds[j]) ΔE*ab \(d)")
                }
            }
        }
    }

    func testCalloutColoursAreAFunctionOfThePageAndTheTextOnly() {
        let base = Palette.palette(for: .light)
        var other = base
        other.accent = RGBA(hex: 0xFF00FF); other.link = RGBA(hex: 0x00FFFF); other.quoteBar = RGBA(hex: 0x123456, alpha: 0.3)
        other.rule = RGBA(hex: 0x654321); other.marker = RGBA(hex: 0x111111); other.selection = RGBA(hex: 0x00FF00, alpha: 0.4)
        for kind in CalloutKind.allCases {
            XCTAssertEqual(other.calloutColor(kind), base.calloutColor(kind), "\(kind)")
            XCTAssertEqual(base.calloutColor(kind), base.calloutColor(kind), "pure")
        }
        var darker = base
        darker.background = RGBA(hex: 0x101010)
        XCTAssertNotEqual(darker.calloutColor(.note), base.calloutColor(.note), "the page matters")
    }

    /// Guards the table of hues against a swap: each kind keeps its family on both Downwrite pages.
    func testCalloutColoursKeepTheirFamily() {
        for theme in [Theme.light, .dark] {
            let p = Palette.palette(for: theme)
            let note = p.calloutColor(.note), tip = p.calloutColor(.tip), important = p.calloutColor(.important)
            let warning = p.calloutColor(.warning), caution = p.calloutColor(.caution)
            XCTAssertTrue(note.b > note.r && note.b > note.g * 0.9, "\(theme) note is blue")
            XCTAssertTrue(tip.g > tip.r && tip.g > tip.b, "\(theme) tip is green")
            XCTAssertTrue(important.b > important.g && important.r > important.g, "\(theme) important is purple")
            XCTAssertTrue(warning.r > warning.b && warning.g > warning.b, "\(theme) warning is amber")
            XCTAssertTrue(caution.r > caution.g && caution.r > caution.b, "\(theme) caution is red")
        }
    }
}
