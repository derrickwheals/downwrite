import XCTest
@testable import DownwriteCore

final class ThemeLibraryTests: XCTestCase {
    private func imported(_ name: String, _ appearance: Theme, bg: UInt32) -> ThemeDefinition {
        let json = "{\"name\": \"\(name)\", \"colors\": {\"editor.background\": \"#\(String(bg, radix: 16))\"}}"
        let t = try! VSCodeTheme.convert(json, fallbackName: name)
        XCTAssertEqual(t.appearance, appearance)
        return ThemeDefinition(id: StoredTheme.identifier(name: name, appearance: appearance), name: name, appearance: appearance, palette: t.palette)
    }

    func testImportedThemesFollowTheBuiltInOnesAndAreSortedByName() {
        let lib = ThemeLibrary(imported: [imported("Zen", .light, bg: 0xfafafa), imported("Ash", .light, bg: 0xeeeeee), imported("Night", .dark, bg: 0x101010)])
        XCTAssertEqual(lib.themes(for: .light).map(\.name), ["Downwrite", "Catppuccin Latte", "Radix", "Ash", "Zen"])
        XCTAssertEqual(lib.themes(for: .dark).map(\.name), ["Downwrite", "Catppuccin Mocha", "Radix", "Night"])
    }

    func testLookupFindsImportedThemesAndFallsBackToDownwrite() {
        let night = imported("Night", .dark, bg: 0x101010)
        let lib = ThemeLibrary(imported: [night])
        XCTAssertEqual(lib.palette(id: night.id, for: .dark), night.palette)
        XCTAssertEqual(lib.palette(id: night.id, for: .light), Palette.palette(for: .light), "a dark theme never colours a light appearance")
        XCTAssertEqual(lib.palette(id: "custom-removed-dark", for: .dark), Palette.palette(for: .dark), "removed: back to Downwrite")
        XCTAssertEqual(lib.palette(id: "catppuccin-mocha", for: .dark), ThemeCatalog.palette(id: "catppuccin-mocha", for: .dark), "built-ins still resolve")
    }

    func testIdentifiersAreStableSluggedAndPerAppearance() {
        XCTAssertEqual(StoredTheme.identifier(name: "Tokyo Night", appearance: .dark), "custom-tokyo-night-dark")
        XCTAssertEqual(StoredTheme.identifier(name: "Tokyo Night", appearance: .light), "custom-tokyo-night-light")
        XCTAssertEqual(StoredTheme.identifier(name: "  Rosé  Pine!! ", appearance: .dark), "custom-ros-pine-dark")
        XCTAssertEqual(StoredTheme.identifier(name: "日本語", appearance: .dark), "custom-theme-dark")
        XCTAssertEqual(StoredTheme.identifier(name: "A", appearance: .dark), StoredTheme.identifier(name: "A", appearance: .dark))
    }

    func testAStoredThemeRoundTripsThroughJSON() throws {
        let t = try VSCodeTheme.convert(##"{"name": "Night", "type": "dark", "colors": {"editor.background": "#101820", "editor.foreground": "#e0e8f0", "editor.selectionBackground": "#4488ff55"}}"##, fallbackName: "x")
        let id = StoredTheme.identifier(name: t.name, appearance: t.appearance)
        let stored = StoredTheme(id: id, name: t.name, appearance: t.appearance, source: "night.json", palette: t.palette)
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredTheme.self, from: data)
        XCTAssertEqual(decoded, stored)
        let definition = try XCTUnwrap(decoded.definition())
        XCTAssertEqual(definition.id, id)
        XCTAssertEqual(definition.appearance, .dark)
        for (a, b) in [(definition.palette.background, t.palette.background), (definition.palette.text, t.palette.text),
                       (definition.palette.selection, t.palette.selection), (definition.palette.accent, t.palette.accent)] {
            XCTAssertEqual(a.r, b.r, accuracy: 0.003); XCTAssertEqual(a.g, b.g, accuracy: 0.003)
            XCTAssertEqual(a.b, b.b, accuracy: 0.003); XCTAssertEqual(a.a, b.a, accuracy: 0.003)
        }
    }

    func testDamagedRecordsAreRejected() throws {
        let t = try VSCodeTheme.convert(##"{"colors": {"editor.background": "#101010"}}"##, fallbackName: "n")
        var stored = StoredTheme(id: "custom-n-dark", name: "n", appearance: .dark, source: "n.json", palette: t.palette)
        XCTAssertNotNil(stored.definition())
        stored.colors["accent"] = "not a colour"
        XCTAssertNil(stored.definition(), "an unreadable colour")
        stored.colors["accent"] = nil
        XCTAssertNil(stored.definition(), "a missing colour")
        var other = StoredTheme(id: "custom-n-dark", name: "n", appearance: .dark, source: "n.json", palette: t.palette)
        other.appearance = "sepia"
        XCTAssertNil(other.definition(), "an unknown appearance")
        var builtin = StoredTheme(id: "radix-dark", name: "n", appearance: .dark, source: "n.json", palette: t.palette)
        XCTAssertNil(builtin.definition(), "a stored theme may not take a built-in theme's id")
        builtin.id = ""
        XCTAssertNil(builtin.definition())
    }
}
