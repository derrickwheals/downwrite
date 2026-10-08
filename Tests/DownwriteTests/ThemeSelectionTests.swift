import XCTest
import SwiftUI
import AppKit
@testable import Downwrite
import DownwriteCore

/// The light and dark colour themes chosen in Settings reach the editor: palette, page colour, text, links, pills and
/// checkboxes, per appearance.
@MainActor
final class ThemeSelectionTests: XCTestCase {
    private let sample = "# Title\n\nSome **bold**, `code` and a [link](https://example.com).\n\n- [x] done\n- [ ] open\n"

    private func settings(light: String = ThemeCatalog.defaultLightID, dark: String = ThemeCatalog.defaultDarkID) -> EditorSettings {
        EditorSettings(font: .avenirNext, size: 17, lineHeight: 1.45, width: 720, lightTheme: light, darkTheme: dark)
    }

    private func choose(_ h: EditorHarness, light: String = ThemeCatalog.defaultLightID, dark: String = ThemeCatalog.defaultDarkID) {
        h.coordinator.update(text: h.textView.string, settings: settings(light: light, dark: dark))
    }

    func testTheDefaultIsTheOriginalDownwriteTheme() {
        let light = EditorHarness(text: sample), dark = EditorHarness(text: sample, dark: true)
        XCTAssertEqual(light.coordinator.styler.palette, Palette.palette(for: .light))
        XCTAssertEqual(dark.coordinator.styler.palette, Palette.palette(for: .dark))
    }

    func testChoosingALightThemeRestylesTheWholeEditor() throws {
        let h = EditorHarness(text: sample)
        h.select(h.textView.string.utf16.count)
        choose(h, light: "catppuccin-latte")
        let latte = ThemeCatalog.palette(id: "catppuccin-latte", for: .light)
        XCTAssertEqual(h.coordinator.styler.palette, latte)
        XCTAssertEqual(h.textView.backgroundColor, latte.background.nsColor, "the page colour")
        XCTAssertEqual(h.color(at: h.index(of: "Some")), latte.text.nsColor, "body text")
        XCTAssertEqual(h.color(at: h.index(of: "link")), latte.link.nsColor, "links")
        XCTAssertEqual(h.attrs(at: h.index(of: "code") )[.dwPill] as? NSColor, latte.inlineCodeBackground.nsColor, "inline code pill")
        let box = try XCTUnwrap(h.attrs(at: h.index(of: "- [x]"))[.dwCheckbox] as? CheckboxMark)
        XCTAssertEqual(box.accent, latte.accent.nsColor, "checkbox fill")
        XCTAssertEqual(box.tick, latte.background.nsColor, "checkbox tick")
    }

    func testTheDarkThemeOnlyShowsInTheDarkAppearance() {
        let dark = EditorHarness(text: sample, dark: true), light = EditorHarness(text: sample)
        choose(dark, light: "catppuccin-latte", dark: "catppuccin-mocha")
        choose(light, light: "catppuccin-latte", dark: "catppuccin-mocha")
        XCTAssertEqual(dark.coordinator.styler.palette, ThemeCatalog.palette(id: "catppuccin-mocha", for: .dark))
        XCTAssertEqual(light.coordinator.styler.palette, ThemeCatalog.palette(id: "catppuccin-latte", for: .light))
        XCTAssertEqual(dark.textView.backgroundColor, RGBA(hex: 0x1E1E2E).nsColor)
        XCTAssertEqual(light.textView.backgroundColor, RGBA(hex: 0xEFF1F5).nsColor)
    }

    func testRadixInBothAppearances() {
        let light = EditorHarness(text: sample), dark = EditorHarness(text: sample, dark: true)
        choose(light, light: "radix-light", dark: "radix-dark")
        choose(dark, light: "radix-light", dark: "radix-dark")
        XCTAssertEqual(light.textView.backgroundColor, RGBA(hex: 0xFCFCFD).nsColor)
        XCTAssertEqual(dark.textView.backgroundColor, RGBA(hex: 0x111113).nsColor)
        XCTAssertEqual(dark.color(at: dark.index(of: "Some")), RGBA(hex: 0xEDEEF0).nsColor)
    }

    func testSwitchingBackToTheDefaultRestoresTheOriginalLook() {
        let h = EditorHarness(text: sample)
        choose(h, light: "radix-light")
        XCTAssertNotEqual(h.coordinator.styler.palette, Palette.palette(for: .light))
        choose(h)
        XCTAssertEqual(h.coordinator.styler.palette, Palette.palette(for: .light))
        XCTAssertEqual(h.textView.backgroundColor, RGBA(hex: 0xFFFFFF).nsColor, "pure white again")
    }

    func testAnUnknownThemeFallsBackToTheDefault() {
        let h = EditorHarness(text: sample)
        choose(h, light: "not-a-theme", dark: "catppuccin-latte")
        XCTAssertEqual(h.coordinator.styler.palette, Palette.palette(for: .light))
    }

    func testChangingThemeKeepsTextCaretAndSelection() {
        let h = EditorHarness(text: sample)
        h.select(10, 4)
        choose(h, light: "catppuccin-latte")
        XCTAssertEqual(h.textView.string, sample)
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 10, length: 4))
    }

    func testTheSelectionAndPageColoursComeFromTheTheme() {
        let h = EditorHarness(text: sample)
        choose(h, light: "catppuccin-latte")
        let palette = ThemeCatalog.palette(id: "catppuccin-latte", for: .light)
        XCTAssertEqual(h.textView.selectedTextAttributes[.backgroundColor] as? NSColor, palette.selection.nsColor)
        XCTAssertEqual(h.textView.insertionPointColor, palette.accent.nsColor)
    }

    func testTheWindowBehindTheToolbarTakesThePageColour() {
        let h = EditorHarness(text: sample)
        choose(h, light: "catppuccin-latte")
        XCTAssertEqual(h.window.backgroundColor, RGBA(hex: 0xEFF1F5).nsColor, "no differently coloured band above the page")
        choose(h)
        XCTAssertEqual(h.window.backgroundColor, RGBA(hex: 0xFFFFFF).nsColor)
    }

    func testTheSourceViewUsesTheThemeToo() {
        let h = EditorHarness(text: sample)
        choose(h, light: "radix-light")
        h.coordinator.setSourceMode(true)
        let palette = ThemeCatalog.palette(id: "radix-light", for: .light)
        XCTAssertEqual(h.color(at: 0), palette.text.nsColor)
    }

    func testTheSettingsPreviewRenders() {
        for theme in ThemeCatalog.builtIn {
            let host = NSHostingView(rootView: ThemePreview(palette: theme.palette, label: theme.name).frame(width: 220))
            XCTAssertGreaterThan(host.fittingSize.height, 60, "\(theme.id) preview has content")
        }
    }
}
