import AppKit
import SwiftUI
import DownwriteCore

enum Prefs {
    static let theme = "theme"
    /// Which colour theme is used while the editor is light / dark (`ThemeCatalog` ids).
    static let lightTheme = "lightTheme"
    static let darkTheme = "darkTheme"
    static let font = "fontChoice"
    static let fontSize = "fontSize"
    static let lineHeight = "lineHeight"
    static let width = "contentWidth"
    static let spellCheck = "spellCheck"
    static let showTOC = "showTOC"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            theme: ThemeChoice.system.rawValue,
            lightTheme: ThemeCatalog.defaultLightID,
            darkTheme: ThemeCatalog.defaultDarkID,
            font: FontChoice.avenirNext.rawValue,
            fontSize: 17.0,
            lineHeight: 1.45,
            width: 720.0,
            spellCheck: false,
            showTOC: false,
        ])
    }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyCurrent() {
        let raw = UserDefaults.standard.string(forKey: Prefs.theme) ?? ThemeChoice.system.rawValue
        NSApp.appearance = (ThemeChoice(rawValue: raw) ?? .system).appearance
    }
}
