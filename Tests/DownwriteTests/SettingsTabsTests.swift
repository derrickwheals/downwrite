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
