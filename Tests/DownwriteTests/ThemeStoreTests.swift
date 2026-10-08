import XCTest
import AppKit
@testable import Downwrite
import DownwriteCore

/// Importing VS Code theme files: conversion, storage in the themes folder, replacing, removing, and the editor following.
@MainActor
final class ThemeStoreTests: XCTestCase {
    private var scratch: URL!
    private var savedDirectory: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("downwrite-themes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedDirectory = ThemeStore.shared.directory
    }

    override func tearDownWithError() throws {
        ThemeStore.shared.directory = savedDirectory
        ThemeStore.shared.reload()
        try? FileManager.default.removeItem(at: scratch)
    }

    private let midnight = """
    {
      // Midnight Orchid — made up for the tests
      "name": "Midnight Orchid",
      "type": "dark",
      "colors": {
        "editor.background": "#14101f", "editor.foreground": "#e6e0f5", "textLink.foreground": "#9db4ff",
        "editor.selectionBackground": "#5b3f9a80", "textCodeBlock.background": "#1b1630",
      },
      "tokenColors": [ { "scope": ["markup.heading"], "settings": { "foreground": "#d29bff" } }, ],
    }
    """

    private func write(_ text: String, named name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? scratch).appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeStore() -> (ThemeStore, URL) {
        let dir = scratch.appendingPathComponent("Themes", isDirectory: true)
        return (ThemeStore(directory: dir), dir)
    }

    func testImportingAThemeStoresItAndListsItForItsAppearance() throws {
        let (store, dir) = makeStore()
        let result = try store.importTheme(from: write(midnight, named: "midnight.json"))
        XCTAssertEqual(result.theme.name, "Midnight Orchid")
        XCTAssertEqual(result.theme.appearance, .dark)
        XCTAssertEqual(result.theme.id, "custom-midnight-orchid-dark")
        XCTAssertFalse(result.replaced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("custom-midnight-orchid-dark.json").path))
        XCTAssertEqual(store.library.themes(for: .dark).map(\.name), ["Downwrite", "Catppuccin Mocha", "Radix", "Midnight Orchid"])
        XCTAssertEqual(store.library.themes(for: .light).map(\.name), ["Downwrite", "Catppuccin Latte", "Radix"], "not offered for light")
        XCTAssertEqual(result.theme.palette.background, RGBA(hex: 0x14101F))
        XCTAssertEqual(result.theme.palette.link, RGBA(hex: 0x9DB4FF))
        XCTAssertEqual(result.theme.palette.accent, RGBA(hex: 0xD29BFF), "the heading colour")
    }

    func testImportedThemesSurviveARestart() throws {
        let (store, dir) = makeStore()
        let imported = try store.importTheme(from: write(midnight, named: "midnight.jsonc")).theme
        let later = ThemeStore(directory: dir)                     // a new launch reads the folder
        XCTAssertEqual(later.library.imported.map(\.id), [imported.id])
        let loaded = try XCTUnwrap(later.library.imported.first)
        XCTAssertEqual(loaded.name, imported.name)
        XCTAssertEqual(loaded.palette.background.hexString, imported.palette.background.hexString)
        XCTAssertEqual(loaded.palette.text.hexString, imported.palette.text.hexString)
        XCTAssertEqual(loaded.palette.selection.hexString, imported.palette.selection.hexString)
    }

    func testImportingTheSameThemeAgainReplacesIt() throws {
        let (store, dir) = makeStore()
        _ = try store.importTheme(from: write(midnight, named: "a.json"))
        let revision = store.revision
        let again = try store.importTheme(from: write(midnight.replacingOccurrences(of: "#9db4ff", with: "#ff9db4"), named: "b.json"))
        XCTAssertTrue(again.replaced)
        XCTAssertEqual(store.library.imported.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1, "one file, not two")
        XCTAssertEqual(store.library.imported.first?.palette.link, RGBA(hex: 0xFF9DB4))
        XCTAssertGreaterThan(store.revision, revision, "editors are told to repaint")
    }

    func testALightAndADarkThemeWithTheSameNameAreBothKept() throws {
        let (store, _) = makeStore()
        _ = try store.importTheme(from: write(##"{"name": "Twin", "colors": {"editor.background": "#101010", "editor.foreground": "#eeeeee"}}"##, named: "d.json"))
        _ = try store.importTheme(from: write(##"{"name": "Twin", "colors": {"editor.background": "#fafafa", "editor.foreground": "#111111"}}"##, named: "l.json"))
        XCTAssertEqual(Set(store.library.imported.map(\.id)), ["custom-twin-dark", "custom-twin-light"])
    }

    func testTheFileNameIsUsedWhenTheThemeHasNoName() throws {
        let (store, _) = makeStore()
        let r = try store.importTheme(from: write(##"{"colors": {"editor.background": "#ffffff"}}"##, named: "solarized-ish.json"))
        XCTAssertEqual(r.theme.name, "solarized-ish")
    }

    func testIncludesAreReadFromBesideTheFile() throws {
        let (store, _) = makeStore()
        _ = try write(##"{"type": "dark", "colors": {"editor.background": "#0d1117", "editor.foreground": "#c9d1d9"}}"##, named: "base.json")
        let r = try store.importTheme(from: write(##"{"name": "Derived", "include": "./base.json", "colors": {"textLink.foreground": "#58a6ff"}}"##, named: "derived.json"))
        XCTAssertEqual(r.theme.palette.background, RGBA(hex: 0x0D1117))
        XCTAssertEqual(r.theme.palette.link, RGBA(hex: 0x58A6FF))
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
    }

    func testBadFilesAreRejectedWithoutTouchingTheLibrary() throws {
        let (store, dir) = makeStore()
        XCTAssertThrowsError(try store.importTheme(from: write("{ broken", named: "broken.json"))) {
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("not valid JSON") == true)
        }
        XCTAssertThrowsError(try store.importTheme(from: write(##"{"hello": "world"}"##, named: "other.json")))
        XCTAssertThrowsError(try store.importTheme(from: write(##"{"contributes": {"themes": []}}"##, named: "package.json")))
        XCTAssertThrowsError(try store.importTheme(from: scratch.appendingPathComponent("missing.json")))
        XCTAssertTrue(store.library.imported.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "nothing was written")
    }

    func testRemovingAThemeDeletesItsFile() throws {
        let (store, dir) = makeStore()
        let id = try store.importTheme(from: write(midnight, named: "m.json")).theme.id
        store.remove(id: id)
        XCTAssertTrue(store.library.imported.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        store.remove(id: "radix-dark")                              // built-ins cannot be removed
        XCTAssertEqual(store.library.themes(for: .dark).count, 3)
    }

    func testDamagedFilesInTheFolderAreSkipped() throws {
        let (store, dir) = makeStore()
        _ = try store.importTheme(from: write(midnight, named: "m.json"))
        try "not json".write(to: dir.appendingPathComponent("junk.json"), atomically: true, encoding: .utf8)
        try ##"{"version":1,"id":"custom-x-dark","name":"x","appearance":"dark","source":"x","colors":{}}"##.write(to: dir.appendingPathComponent("incomplete.json"), atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertEqual(store.library.imported.map(\.name), ["Midnight Orchid"])
    }

    // MARK: The editor

    func testTheEditorUsesAnImportedThemeAndFallsBackWhenItIsRemoved() throws {
        ThemeStore.shared.directory = scratch.appendingPathComponent("Shared", isDirectory: true)
        ThemeStore.shared.reload()
        let theme = try ThemeStore.shared.importTheme(from: write(midnight, named: "m.json")).theme
        let sample = "## Title\n\nSome text with a [link](https://example.com).\n"
        let h = EditorHarness(text: sample, dark: true)
        func settings(dark: String) -> EditorSettings {
            EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720, darkTheme: dark, themeRevision: ThemeStore.shared.revision)
        }
        h.coordinator.update(text: sample, settings: settings(dark: theme.id))
        XCTAssertEqual(h.coordinator.styler.palette, theme.palette)
        XCTAssertEqual(h.textView.backgroundColor, theme.palette.background.nsColor)
        XCTAssertEqual(h.color(at: h.index(of: "link")), theme.palette.link.nsColor)
        // Removing it (and the preference with it) puts Downwrite back.
        ThemeStore.shared.remove(id: theme.id)
        h.coordinator.update(text: sample, settings: settings(dark: ThemeCatalog.defaultDarkID))
        XCTAssertEqual(h.coordinator.styler.palette, Palette.palette(for: .dark))
    }

    func testReplacingAThemeRepaintsEditorsThatAlreadyUseIt() throws {
        ThemeStore.shared.directory = scratch.appendingPathComponent("Shared", isDirectory: true)
        ThemeStore.shared.reload()
        let theme = try ThemeStore.shared.importTheme(from: write(midnight, named: "m.json")).theme
        let sample = "Some text with a [link](https://example.com).\n"
        let h = EditorHarness(text: sample, dark: true)
        func settings() -> EditorSettings {
            EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720, darkTheme: theme.id, themeRevision: ThemeStore.shared.revision)
        }
        h.coordinator.update(text: sample, settings: settings())
        let before = h.coordinator.styler.palette.link
        _ = try ThemeStore.shared.importTheme(from: write(midnight.replacingOccurrences(of: "#9db4ff", with: "#ffb49d"), named: "m2.json"))
        h.coordinator.update(text: sample, settings: settings())
        XCTAssertNotEqual(h.coordinator.styler.palette.link, before)
        XCTAssertEqual(h.coordinator.styler.palette.link, RGBA(hex: 0xFFB49D))
    }
}
