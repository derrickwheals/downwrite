import XCTest
@testable import DownwriteCore

final class VSCodeThemeTests: XCTestCase {
    // A dark theme written the way theme authors write them: comments, trailing commas, #RRGGBBAA, scope arrays.
    private let midnight = """
    {
      // Midnight — a made-up theme for the tests
      "name": "Midnight",
      "type": "dark",
      "colors": {
        "editor.background": "#0f1220",
        "editor.foreground": "#d6deeb",
        "editor.selectionBackground": "#2a3a6a99",
        "editorLineNumber.foreground": "#5f7e97",
        "descriptionForeground": "#9aa7c7",
        "textLink.foreground": "#82aaff",
        "textCodeBlock.background": "#161a2e",
        "textBlockQuote.border": "#3b4a7a",
        "editor.findMatchHighlightBackground": "#ffcb6b40",
        "editorGroup.border": "#262c47",
        "focusBorder": "#7e57c2",
      },
      "tokenColors": [
        { "scope": ["markup.heading", "entity.name.section"], "settings": { "foreground": "#c792ea", "fontStyle": "bold" } },
        { "scope": "markup.underline.link, string.other.link", "settings": { "foreground": "#7fdbca" } },
        { "settings": { "foreground": "#d6deeb" } },
      ],
    }
    """

    private let paper = """
    { "name": "Paper", "type": "light", "colors": { "editor.background": "#fbf7ef", "editor.foreground": "#3b3228" } }
    """

    func testAFullThemeMapsTheColoursThatApply() throws {
        let t = try VSCodeTheme.convert(midnight, fallbackName: "file")
        XCTAssertEqual(t.name, "Midnight")
        XCTAssertEqual(t.appearance, .dark)
        let p = t.palette
        XCTAssertEqual(p.background, RGBA(hex: 0x0F1220))
        XCTAssertEqual(p.text, RGBA(hex: 0xD6DEEB))
        XCTAssertEqual(p.link, RGBA(hex: 0x82AAFF), "textLink.foreground")
        XCTAssertEqual(p.accent, RGBA(hex: 0xC792EA), "the markup.heading colour")
        XCTAssertEqual(p.codeBackground, RGBA(hex: 0x161A2E))
        XCTAssertEqual(p.quoteBar, RGBA(hex: 0x3B4A7A))
        XCTAssertEqual(p.rule, RGBA(hex: 0x262C47))
        XCTAssertEqual(p.selection.a, 0x99 / 255.0, accuracy: 0.001, "the selection keeps its translucency")
        XCTAssertEqual(p.highlightBackground.a, 0x40 / 255.0, accuracy: 0.001)
        XCTAssertTrue(t.warnings.isEmpty, "\(t.warnings)")
    }

    func testAMinimalThemeGetsEverythingElseDerived() throws {
        let t = try VSCodeTheme.convert(paper, fallbackName: "file")
        XCTAssertEqual(t.appearance, .light)
        let p = t.palette
        XCTAssertEqual(p.background, RGBA(hex: 0xFBF7EF))
        for c in [p.codeBackground, p.inlineCodeBackground, p.rule] {
            XCTAssertGreaterThan(c.contrast(with: p.background), 1.03, "derived tints are visible")
        }
        assertLegible(p, "Paper")
    }

    func testTheNameFallsBackToTheFileName() throws {
        let t = try VSCodeTheme.convert(##"{"colors": {"editor.background": "#ffffff"}}"##, fallbackName: "my-theme")
        XCTAssertEqual(t.name, "my-theme")
        let blank = try VSCodeTheme.convert(##"{"name": "  ", "colors": {"editor.background": "#ffffff"}}"##, fallbackName: "other")
        XCTAssertEqual(blank.name, "other")
    }

    func testAppearanceFollowsThePageNotTheDeclaredType() throws {
        let lies = try VSCodeTheme.convert(##"{"type": "dark", "colors": {"editor.background": "#ffffff", "editor.foreground": "#222222"}}"##, fallbackName: "x")
        XCTAssertEqual(lies.appearance, .light, "a white page is a light theme whatever the file says")
        XCTAssertTrue(lies.warnings.contains { $0.contains("dark") }, "and the mismatch is reported: \(lies.warnings)")
        let hc = try VSCodeTheme.convert(##"{"type": "hc", "colors": {"editor.background": "#000000"}}"##, fallbackName: "x")
        XCTAssertEqual(hc.appearance, .dark)
    }

    func testAMissingBackgroundIsAssumedFromTheType() throws {
        let dark = try VSCodeTheme.convert(##"{"type": "dark", "colors": {"editor.foreground": "#eeeeee"}}"##, fallbackName: "x")
        XCTAssertEqual(dark.appearance, .dark)
        XCTAssertTrue(dark.warnings.contains { $0.contains("editor.background") })
        let light = try VSCodeTheme.convert(##"{"tokenColors": []}"##, fallbackName: "x")
        XCTAssertEqual(light.appearance, .light)
    }

    func testShortAndAlphaHexColoursAreUnderstood() {
        XCTAssertEqual(RGBA(cssHex: "#fff"), RGBA(1, 1, 1))
        XCTAssertEqual(RGBA(cssHex: "#f00f"), RGBA(1, 0, 0, 1))
        XCTAssertEqual(RGBA(cssHex: "#11223344")?.a ?? 0, 0x44 / 255.0, accuracy: 0.001)
        XCTAssertEqual(RGBA(cssHex: "336699"), RGBA(hex: 0x336699))
        XCTAssertNil(RGBA(cssHex: "#12"))
        XCTAssertNil(RGBA(cssHex: "red"))
        XCTAssertNil(RGBA(cssHex: "#gggggg"))
        XCTAssertEqual(RGBA(hex: 0x336699).hexString, "#336699")
        XCTAssertEqual(RGBA(hex: 0x336699, alpha: 0.5).hexString, "#33669980")
    }

    // MARK: Include

    func testAnIncludedThemeIsTheBaseAndTheFileOverridesIt() throws {
        let base = ##"{"name": "Base", "type": "dark", "colors": {"editor.background": "#101010", "editor.foreground": "#dddddd", "textLink.foreground": "#4488ff"}}"##
        let child = ##"{"name": "Child", "include": "./base.json", "colors": {"textLink.foreground": "#ff8844"}}"##
        var asked: [String] = []
        let t = try VSCodeTheme.convert(child, fallbackName: "x") { path in asked.append(path); return base }
        XCTAssertEqual(asked, ["./base.json"])
        XCTAssertEqual(t.name, "Child")
        XCTAssertEqual(t.palette.background, RGBA(hex: 0x101010), "from the included theme")
        XCTAssertEqual(t.palette.link, RGBA(hex: 0xFF8844), "overridden by the including file")
    }

    func testAnUnreadableIncludeIsReportedNotFatal() throws {
        let t = try VSCodeTheme.convert(##"{"include": "./gone.json", "colors": {"editor.background": "#ffffff"}}"##, fallbackName: "x")
        XCTAssertTrue(t.warnings.contains { $0.contains("gone.json") })
    }

    func testIncludeLoopsStopAtADepthLimit() throws {
        let loop = ##"{"include": "./self.json", "colors": {"editor.background": "#202020"}}"##
        let t = try VSCodeTheme.convert(loop, fallbackName: "x") { _ in loop }
        XCTAssertEqual(t.appearance, .dark)
        XCTAssertTrue(t.warnings.contains { $0.contains("nested") })
    }

    // MARK: Token scopes

    func testTheMostSpecificTokenRuleWins() throws {
        let theme = """
        { "colors": {"editor.background": "#ffffff", "editor.foreground": "#202020"},
          "tokenColors": [
            { "scope": "markup", "settings": { "foreground": "#aa0000" } },
            { "scope": "markup.heading", "settings": { "foreground": "#0000aa" } },
            { "scope": "markup.heading.markdown", "settings": { "foreground": "#00aa00" } } ] }
        """
        let t = try VSCodeTheme.convert(theme, fallbackName: "x")
        XCTAssertEqual(t.palette.accent, RGBA(hex: 0x0000AA), "markup.heading, not the broader markup or the narrower .markdown rule")
    }

    func testAScopeMustMatchOnDotBoundaries() {
        var rules = VSCodeTheme.TokenRules()
        rules.append([["scope": "markup.head", "settings": ["foreground": "#111111"]]])
        XCTAssertNil(rules.foreground(for: "markup.heading"), "markup.head is not a parent of markup.heading")
        rules.append([["scope": "markup", "settings": ["foreground": "#222222"]]])
        XCTAssertEqual(rules.foreground(for: "markup.heading"), "#222222")
    }

    // MARK: Errors

    func testAnExtensionManifestIsRecognised() {
        let manifest = ##"{"name": "ext", "contributes": {"themes": [{"label": "A", "uiTheme": "vs-dark", "path": "./themes/a.json"}]}}"##
        XCTAssertThrowsError(try VSCodeTheme.convert(manifest, fallbackName: "x")) { XCTAssertEqual($0 as? VSCodeThemeError, .extensionManifest) }
    }

    func testNonThemesAndBrokenFilesAreRejectedWithAReason() {
        XCTAssertThrowsError(try VSCodeTheme.convert(##"{"hello": "world"}"##, fallbackName: "x")) { XCTAssertEqual($0 as? VSCodeThemeError, .notATheme) }
        XCTAssertThrowsError(try VSCodeTheme.convert("{ broken", fallbackName: "x")) {
            guard case .notJSON = $0 as? VSCodeThemeError else { return XCTFail("\($0)") }
            XCTAssertFalse(($0 as? LocalizedError)?.errorDescription?.isEmpty ?? true)
        }
        XCTAssertThrowsError(try VSCodeTheme.convert("[1,2]", fallbackName: "x"))
    }

    func testATokenColorsFilePathIsReported() throws {
        let t = try VSCodeTheme.convert(##"{"colors": {"editor.background": "#ffffff"}, "tokenColors": "./theme.tmTheme"}"##, fallbackName: "x")
        XCTAssertTrue(t.warnings.contains { $0.contains("tmTheme") })
    }

    // MARK: Legibility whatever the file says

    func testHostileColoursAreNudgedIntoLegibility() throws {
        // Text almost the page colour, links invisible, selection and highlight swamping the text.
        let theme = """
        { "colors": {
            "editor.background": "#202020", "editor.foreground": "#242424", "descriptionForeground": "#222222",
            "textLink.foreground": "#212121", "editor.selectionBackground": "#ffffff", "editor.findMatchHighlightBackground": "#ffffff",
            "textPreformat.foreground": "#202020", "editorGroup.border": "#202020", "textCodeBlock.background": "#202020" } }
        """
        let t = try VSCodeTheme.convert(theme, fallbackName: "hostile")
        assertLegible(t.palette, "hostile")
    }

    func testRandomThemesAreAlwaysLegible() throws {
        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        func next() -> UInt32 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt32(truncatingIfNeeded: seed >> 33) }
        func color() -> String { String(format: "#%06X", next() & 0xFFFFFF) }
        for i in 0..<300 {
            let theme = """
            { "colors": { "editor.background": "\(color())", "editor.foreground": "\(color())", "descriptionForeground": "\(color())",
              "textLink.foreground": "\(color())", "focusBorder": "\(color())", "textCodeBlock.background": "\(color())",
              "editor.selectionBackground": "\(color())\(String(format: "%02X", next() & 0xFF))", "editorGroup.border": "\(color())",
              "editor.findMatchHighlightBackground": "\(color())\(String(format: "%02X", next() & 0xFF))" } }
            """
            let t = try VSCodeTheme.convert(theme, fallbackName: "random \(i)")
            assertLegible(t.palette, "random #\(i)")
        }
    }

    private func flat(_ c: RGBA, _ bg: RGBA) -> RGBA { c.flattened(over: bg) }

    private func assertLegible(_ p: Palette, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let bg = p.background
        XCTAssertGreaterThanOrEqual(p.text.contrast(with: bg), 4.5, "\(label) text", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.secondaryText.contrast(with: bg), 3.0, "\(label) secondary", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.accent.contrast(with: bg), 3.0, "\(label) accent", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.link.contrast(with: bg), 3.5, "\(label) link", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.marker.contrast(with: bg), 2.2, "\(label) marker", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.codeText.contrast(with: p.codeBackground), 4.5, "\(label) code", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.text.contrast(with: p.inlineCodeBackground), 3.9, "\(label) inline code", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.text.contrast(with: flat(p.highlightBackground, bg)), 3.0, "\(label) highlight", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.text.contrast(with: flat(p.selection, bg)), 2.9, "\(label) selection", file: file, line: line)
    }
}
