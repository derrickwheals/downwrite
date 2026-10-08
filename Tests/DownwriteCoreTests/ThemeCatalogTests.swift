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
}
