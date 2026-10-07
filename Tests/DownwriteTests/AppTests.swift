import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import Downwrite
import DownwriteCore

@MainActor
final class AppTests: XCTestCase {
    func testBundledResourcesArePresent() {
        for (name, ext) in [("mermaid.min", "js"), ("mermaid-renderer", "html"), ("Welcome", "md"), ("AppIcon-light", "png"), ("AppIcon-dark", "png")] {
            XCTAssertNotNil(AppResources.url(name, ext), "\(name).\(ext) missing")
        }
    }

    func testDockIconsExistForBothAppearancesAndDiffer() {
        guard let light = AppIcon.image(dark: false), let dark = AppIcon.image(dark: true) else { return XCTFail("missing icons") }
        XCTAssertGreaterThanOrEqual(light.size.width, 256)
        XCTAssertNotEqual(light.tiffRepresentation, dark.tiffRepresentation)
    }

    func testThemeChoiceMapsToAppearances() {
        XCTAssertNil(ThemeChoice.system.appearance)
        XCTAssertEqual(ThemeChoice.light.appearance?.name, .aqua)
        XCTAssertEqual(ThemeChoice.dark.appearance?.name, .darkAqua)
    }

    func testThemePreferenceAppliesToApplication() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Prefs.theme)
        defer { defaults.set(saved, forKey: Prefs.theme); ThemeChoice.applyCurrent() }
        defaults.set("dark", forKey: Prefs.theme); ThemeChoice.applyCurrent()
        XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        defaults.set("light", forKey: Prefs.theme); ThemeChoice.applyCurrent()
        XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        defaults.set("system", forKey: Prefs.theme); ThemeChoice.applyCurrent()
        XCTAssertNil(NSApp.appearance)
    }

    private func assertWhite(_ c: NSColor, _ message: String, accuracy: CGFloat) {
        XCTAssertEqual(c.redComponent, 1, accuracy: accuracy, message)
        XCTAssertEqual(c.greenComponent, 1, accuracy: accuracy, message)
        XCTAssertEqual(c.blueComponent, 1, accuracy: accuracy, message)
    }

    func testLightEditorBackgroundIsPureWhite() throws {
        let h = EditorHarness(text: "# Hello\n\nSome text.\n", dark: false)
        for (name, colour) in [("text view", h.textView.backgroundColor), ("scroll view", h.scroll.backgroundColor)] {
            let c = try XCTUnwrap(colour.usingColorSpace(.sRGB), name)
            assertWhite(c, "\(name) is white", accuracy: 0.001)
        }
        // …and what is actually painted: an empty patch of the margin, next to the text column.
        h.window.displayIfNeeded()
        let view = h.window.contentView!
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let px = try XCTUnwrap(rep.colorAt(x: 6, y: rep.pixelsHigh - 6)?.usingColorSpace(.sRGB))
        assertWhite(px, "painted margin is white", accuracy: 0.01)
    }

    func testDarkEditorBackgroundIsUnchanged() throws {
        let h = EditorHarness(text: "# Hello\n", dark: true)
        let c = try XCTUnwrap(h.textView.backgroundColor.usingColorSpace(.sRGB))
        XCTAssertLessThan(c.redComponent + c.greenComponent + c.blueComponent, 0.5)
    }

    func testTableOfContentsPreferenceIsRegisteredOff() {
        Prefs.registerDefaults()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Prefs.showTOC), "the sidebar starts hidden")
        XCTAssertEqual(Prefs.showTOC, "showTOC")
    }

    func testDocumentTypesAndMarkdownIdentifier() {
        XCTAssertEqual(UTType.markdown.identifier, "net.daringfireball.markdown")
        XCTAssertTrue(MarkdownDocument.readableContentTypes.contains(.markdown))
        XCTAssertTrue(MarkdownDocument.readableContentTypes.contains(.plainText))
        XCTAssertEqual(MarkdownDocument().text, "")
    }

    func testInfoPlistClaimsMarkdownFiles() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packaging/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: url))
        let types = try XCTUnwrap(dict["CFBundleDocumentTypes"] as? [[String: Any]])
        let md = try XCTUnwrap(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("net.daringfireball.markdown") == true })
        XCTAssertEqual(md["LSHandlerRank"] as? String, "Owner")
        XCTAssertEqual(md["CFBundleTypeRole"] as? String, "Editor")
        let exts = try XCTUnwrap(md["CFBundleTypeExtensions"] as? [String])
        XCTAssertTrue(exts.contains("md") && exts.contains("markdown"))
        XCTAssertEqual(dict["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertNotNil(dict["UTImportedTypeDeclarations"])
    }

    func testWelcomeDocumentExercisesEveryFeature() throws {
        let url = try XCTUnwrap(AppResources.url("Welcome", "md"))
        let a = MarkdownAnalyzer.analyze(try String(contentsOf: url, encoding: .utf8))
        XCTAssertGreaterThanOrEqual(a.headings.count, 5)
        XCTAssertEqual(a.mermaid.count, 1)
        XCTAssertEqual(a.tables.count, 1)
        XCTAssertEqual(a.taskBoxes.count, 2)
        XCTAssertFalse(a.links.isEmpty)
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.highlight) })
        XCTAssertTrue(a.spans.contains { $0.flags.contains(.footnote) })
    }

    func testTypographyFontsAllResolve() {
        for choice in FontChoice.allCases {
            let t = Typography(choice: choice, size: 17)
            XCTAssertEqual(t.font().pointSize, 17, accuracy: 0.01, choice.displayName)
            XCTAssertTrue(t.font(bold: true).isBold || choice == .sfMono, choice.displayName)
            XCTAssertTrue(t.font(mono: true).isFixedPitch)
        }
    }
}
