import AppKit
import SwiftUI

enum Prefs {
    static let theme = "theme"
    static let font = "fontChoice"
    static let fontSize = "fontSize"
    static let lineHeight = "lineHeight"
    static let width = "contentWidth"
    static let spellCheck = "spellCheck"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            theme: ThemeChoice.system.rawValue,
            font: FontChoice.avenirNext.rawValue,
            fontSize: 17.0,
            lineHeight: 1.45,
            width: 720.0,
            spellCheck: false,
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
