import XCTest
import SwiftUI
import AppKit
@testable import Downwrite
import DownwriteCore

/// Settings is three short tabs rather than one pane too tall for most screens.
@MainActor
final class SettingsTabsTests: XCTestCase {
    private func size<V: View>(of view: V) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// A pane has to fit comfortably on the smallest screens the app supports (a 13-inch MacBook is 800 pt tall, minus the menu
    /// bar, the window's title bar and its tab strip).
    private let tallestPane: CGFloat = 560

    func testThereAreThreeTabsWithTitlesAndIcons() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title), ["Appearance", "Editor", "General"])
        XCTAssertEqual(Set(SettingsTab.allCases.map(\.symbol)).count, 3, "each tab has its own icon")
        XCTAssertEqual(SettingsTab.allCases.map(\.rawValue), ["appearance", "editor", "general"])
    }

    func testEveryTabFitsOnASmallScreen() {
        let panes: [(String, CGSize)] = [("Appearance", size(of: AppearancePane())), ("Editor", size(of: EditorPane())),
                                         ("General", size(of: GeneralPane()))]
        for (name, s) in panes {
            XCTAssertGreaterThan(s.height, 60, "\(name) has content")
            XCTAssertLessThan(s.height, tallestPane, "\(name) is \(Int(s.height)) pt tall")
            XCTAssertEqual(s.width, 500, accuracy: 1, "\(name) has the shared width")
        }
    }

    func testTheOldSinglePaneWasTooTallAndTheTabsAreEachMuchShorter() {
        let heights = [size(of: AppearancePane()).height, size(of: EditorPane()).height, size(of: GeneralPane()).height]
        let together = heights.reduce(0, +)
        XCTAssertGreaterThan(together, tallestPane, "all the settings together would not fit")
        XCTAssertLessThan(heights.max()!, together * 0.7, "no tab carries most of it")
    }

    func testAManyThemeLibraryScrollsInsteadOfGrowingThePane() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("downwrite-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let saved = ThemeStore.shared.directory
        defer { ThemeStore.shared.directory = saved; ThemeStore.shared.reload(); try? FileManager.default.removeItem(at: scratch) }
        ThemeStore.shared.directory = scratch.appendingPathComponent("Themes", isDirectory: true)
        ThemeStore.shared.reload()
        let empty = size(of: AppearancePane()).height
        for i in 0..<10 {
            let file = scratch.appendingPathComponent("theme\(i).json")
            try "{\"name\": \"Theme \(i)\", \"colors\": {\"editor.background\": \"#10\(String(format: "%02x", i))20\"}}".write(to: file, atomically: true, encoding: .utf8)
            _ = try ThemeStore.shared.importTheme(from: file)
        }
        XCTAssertEqual(ThemeStore.shared.library.imported.count, 10)
        let full = size(of: AppearancePane()).height
        XCTAssertLessThan(full, tallestPane, "ten imported themes still fit (\(Int(empty)) → \(Int(full)) pt)")
    }

    // MARK: - Imported theme list

    private func definition(_ name: String, dark: Bool = false) -> ThemeDefinition {
        ThemeDefinition(id: "custom-\(name)", name: name, appearance: dark ? .dark : .light, palette: Palette.palette(for: dark ? .dark : .light))
    }

    /// Renders a view on white at 1x and returns its pixels, so the layout can be measured rather than guessed.
    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.background(Color.white))
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// Left and right edge (px) of everything that is not white.
    private func inkSpan(_ rep: NSBitmapImageRep) -> (min: Int, max: Int)? {
        var lo = Int.max, hi = -1
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if min(c.redComponent, c.greenComponent, c.blueComponent) < 0.85 { lo = min(lo, x); hi = max(hi, x); break }
            }
        }
        return hi >= 0 ? (lo, hi) : nil
    }

    func testAnImportedThemeRowUsesTheWholeWidthWithRemoveAtTheRightEdge() throws {
        let width: CGFloat = 440
        let short = try render(ImportedThemeRow(theme: definition("Nord"), remove: {}).frame(width: width))
        let long = try render(ImportedThemeRow(theme: definition("A Theme Whose Name Is Far Too Long To Fit On A Single Line Of The Settings Pane, Really"), remove: {}).frame(width: width))
        for (label, rep) in [("short", short), ("long", long)] {
            let span = try XCTUnwrap(inkSpan(rep), "\(label) row draws something")
            XCTAssertLessThan(span.min, 12, "\(label): the name starts at the left edge")
            XCTAssertGreaterThan(span.max, Int(width) - 12, "\(label): Remove sits at the right edge, not half way across (ink ends at \(span.max) of \(Int(width)))")
        }
        XCTAssertEqual(long.pixelsHigh, short.pixelsHigh, "a long name is truncated, it does not wrap to a second line")
    }

    func testStackedImportedRowsStayOneLineEach() throws {
        // Three rows stacked as the pane does: as tall as three short ones, whatever the names are.
        func stack(_ names: [String]) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(names, id: \.self) { ImportedThemeRow(theme: self.definition($0), remove: {}) }
            }
            .frame(width: 440, alignment: .leading)
        }
        let plain = try render(stack(["A", "B", "C"]))
        let longNames = try render(stack(["Catppuccin Frappé Extra Long Variant Name With Many Words In It To Wrap", "Another Remarkably Wordy Theme Name That Goes On And On Forever And Ever", "Short"]))
        XCTAssertEqual(longNames.pixelsHigh, plain.pixelsHigh)
    }

    func testTheImportNoteIsShortAndSaysWhatHappened() {
        let one = ThemeImportOutcome.summary([.imported(name: "Nord", dark: true, replaced: false, warnings: [])])
        XCTAssertEqual(one.text, "Added “Nord” as a dark theme and selected it.")
        XCTAssertFalse(one.isError)
        XCTAssertEqual(ThemeImportOutcome.summary([.imported(name: "Nord", dark: false, replaced: true, warnings: [])]).text,
                       "Updated “Nord” as a light theme and selected it.")
        let many = ThemeImportOutcome.summary((1...6).map { .imported(name: "Theme \($0)", dark: $0 % 2 == 0, replaced: false, warnings: []) })
        XCTAssertEqual(many.text, "Added 6 themes.", "a batch is one line, not one sentence per file")
        let broken = ThemeImportOutcome.summary([.imported(name: "Nord", dark: true, replaced: false, warnings: []),
                                                 .failed(file: "bad.json", reason: "The file is not valid JSON.")])
        XCTAssertTrue(broken.isError)
        XCTAssertTrue(broken.text.contains("bad.json: The file is not valid JSON."))
        XCTAssertTrue(broken.text.contains("Added “Nord”"))
    }

    func testTheImportNoteNeverGrowsPastItsLimit() {
        let warnings = (1...6).map { "Warning number \($0)." }
        let noisy = ThemeImportOutcome.summary([.imported(name: "Nord", dark: true, replaced: false, warnings: warnings)])
        let lines = noisy.text.split(separator: "\n")
        XCTAssertEqual(lines.count, ThemeImportOutcome.maximumLines)
        XCTAssertEqual(lines.last, "… and 4 more.")
        XCTAssertEqual(lines.first, "Added “Nord” as a dark theme and selected it.")
        let fits = ThemeImportOutcome.summary([.imported(name: "Nord", dark: true, replaced: false, warnings: Array(warnings.prefix(3)))])
        XCTAssertEqual(fits.text.split(separator: "\n").count, 4, "exactly the limit is shown in full")
        XCTAssertFalse(fits.text.contains("more"))
        let batch = ThemeImportOutcome.summary([.imported(name: "A", dark: true, replaced: false, warnings: ["w"]),
                                                .imported(name: "B", dark: true, replaced: false, warnings: [])])
        XCTAssertTrue(batch.text.contains("“A”: w"), "with several files a warning names its theme")
    }

    func testTheLastTabIsRemembered() {
        let defaults = UserDefaults.standard
        let before = defaults.string(forKey: Prefs.settingsTab)
        defer { if let before { defaults.set(before, forKey: Prefs.settingsTab) } else { defaults.removeObject(forKey: Prefs.settingsTab) } }
        defaults.set(SettingsTab.editor.rawValue, forKey: Prefs.settingsTab)
        XCTAssertEqual(SettingsTab(rawValue: defaults.string(forKey: Prefs.settingsTab) ?? ""), .editor)
        Prefs.registerDefaults()
        XCTAssertEqual(defaults.string(forKey: Prefs.settingsTab), SettingsTab.editor.rawValue, "registering defaults never overrides a choice")
    }

    func testTheGeneralTabShowsTheVersion() {
        XCTAssertFalse(GeneralPane.versionText.isEmpty)
        XCTAssertFalse(GeneralPane.versionText.hasPrefix("__"), "template tokens are never shown")
    }

    func testTheWholeSettingsViewBuilds() {
        let host = NSHostingView(rootView: SettingsView())
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 400)
    }
}
