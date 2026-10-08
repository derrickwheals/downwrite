import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DownwriteCore

/// The Settings window's tabs. The raw value is what `Prefs.settingsTab` stores, so the window reopens on the tab it was left on.
enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance, editor, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .editor: return "Editor"
        case .general: return "General"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .editor: return "textformat"
        case .general: return "gearshape"
        }
    }
}

/// Settings, in three short tabs (it used to be one pane too tall for most screens):
/// **Appearance** — light/dark/system, the light and dark colour themes with previews, VS Code theme import;
/// **Editor** — typography and spelling; **General** — default Markdown app, version and licences.
struct SettingsView: View {
    @AppStorage(Prefs.settingsTab) private var tab = SettingsTab.appearance.rawValue

    var body: some View {
        TabView(selection: $tab) {
            AppearancePane()
                .tabItem { Label(SettingsTab.appearance.title, systemImage: SettingsTab.appearance.symbol) }
                .tag(SettingsTab.appearance.rawValue)
            EditorPane()
                .tabItem { Label(SettingsTab.editor.title, systemImage: SettingsTab.editor.symbol) }
                .tag(SettingsTab.editor.rawValue)
            GeneralPane()
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general.rawValue)
        }
        .frame(width: 500)
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @AppStorage(Prefs.theme) private var theme = ThemeChoice.system.rawValue
    @AppStorage(Prefs.lightTheme) private var lightTheme = ThemeCatalog.defaultLightID
    @AppStorage(Prefs.darkTheme) private var darkTheme = ThemeCatalog.defaultDarkID
    @ObservedObject private var themes = ThemeStore.shared
    @State private var themeMessage: (text: String, isError: Bool)?

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Light theme", selection: $lightTheme) {
                    ForEach(themes.library.themes(for: .light)) { Text($0.name).tag($0.id) }
                }
                Picker("Dark theme", selection: $darkTheme) {
                    ForEach(themes.library.themes(for: .dark)) { Text($0.name).tag($0.id) }
                }
                HStack(spacing: 12) {
                    ThemePreview(palette: themes.library.palette(id: lightTheme, for: .light), label: "Light")
                    ThemePreview(palette: themes.library.palette(id: darkTheme, for: .dark), label: "Dark")
                }
                .accessibilityIdentifier("theme-previews")
            }
            Section("Your themes") {
                LabeledContent("VS Code themes") {
                    Button("Add VS Code Theme…") { addThemes() }
                        .accessibilityIdentifier("add-theme")
                }
                if let themeMessage {
                    Text(themeMessage.text).font(.footnote).foregroundStyle(themeMessage.isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if themes.library.imported.isEmpty {
                    Text("Add the colour theme files (.json) from a VS Code theme extension and they appear in the pickers above.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if themes.library.imported.count > 4 {
                    ScrollView { importedRows }.frame(height: 120)           // a long list scrolls instead of growing the window
                } else {
                    importedRows
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { keepChosenThemesValid() }
    }

    private var importedRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(themes.library.imported) { theme in
                ImportedThemeRow(theme: theme) { removeTheme(theme) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A theme file that was deleted behind our back must not leave a picker pointing at nothing.
    private func keepChosenThemesValid() {
        if !themes.library.themes(for: .light).contains(where: { $0.id == lightTheme }) { lightTheme = ThemeCatalog.defaultLightID }
        if !themes.library.themes(for: .dark).contains(where: { $0.id == darkTheme }) { darkTheme = ThemeCatalog.defaultDarkID }
    }

    private func addThemes() {
        let panel = NSOpenPanel()
        panel.title = "Add a VS Code Theme"
        panel.message = "Choose one or more VS Code colour theme files (.json). They are the files in a theme extension's “themes” folder."
        panel.prompt = "Add"
        panel.allowedContentTypes = [UTType.json, UTType(filenameExtension: "jsonc")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importThemes(panel.urls)
    }

    private func importThemes(_ urls: [URL]) {
        var outcomes: [ThemeImportOutcome] = []
        for url in urls {
            do {
                let result = try themes.importTheme(from: url)
                let dark = result.theme.appearance == .dark
                if dark { darkTheme = result.theme.id } else { lightTheme = result.theme.id }
                outcomes.append(.imported(name: result.theme.name, dark: dark, replaced: result.replaced, warnings: result.warnings))
            } catch {
                outcomes.append(.failed(file: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        let summary = ThemeImportOutcome.summary(outcomes)
        themeMessage = (summary.text, summary.isError)
    }

    private func removeTheme(_ theme: ThemeDefinition) {
        themes.remove(id: theme.id)
        if lightTheme == theme.id { lightTheme = ThemeCatalog.defaultLightID }
        if darkTheme == theme.id { darkTheme = ThemeCatalog.defaultDarkID }
        themeMessage = ("Removed “\(theme.name)”.", false)
    }
}

/// One imported theme: the name (one line, truncated, full name in the tooltip) on the left, *Remove* pinned to the right edge.
/// A plain `HStack` rather than `LabeledContent`, which gives the label column only half of a grouped form row.
struct ImportedThemeRow: View {
    let theme: ThemeDefinition
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.name).lineLimit(1).truncationMode(.tail)
                Text(theme.appearance == .dark ? "Dark theme" : "Light theme").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove", action: remove)
                .buttonStyle(.link)
                .fixedSize()
        }
        .help(theme.name)
    }
}

/// What importing one file did, and the short note that sums up a whole batch (a long note made the pane taller and wrapped).
enum ThemeImportOutcome: Equatable {
    case imported(name: String, dark: Bool, replaced: Bool, warnings: [String])
    case failed(file: String, reason: String)

    /// Longest note shown, in lines; the rest is summarised as "… and N more".
    static let maximumLines = 4

    static func summary(_ outcomes: [ThemeImportOutcome]) -> (text: String, isError: Bool) {
        var lines: [String] = []
        var added: [(name: String, dark: Bool, replaced: Bool)] = []
        var notes: [String] = []
        for outcome in outcomes {
            switch outcome {
            case let .imported(name, dark, replaced, warnings):
                added.append((name, dark, replaced))
                notes += warnings.map { outcomes.count > 1 ? "“\(name)”: \($0)" : $0 }
            case let .failed(file, reason):
                lines.append("\(file): \(reason)")
            }
        }
        if added.count == 1, let one = added.first {
            lines.insert("\(one.replaced ? "Updated" : "Added") “\(one.name)” as a \(one.dark ? "dark" : "light") theme and selected it.", at: 0)
        } else if added.count > 1 {
            lines.insert("Added \(added.count) themes.", at: 0)
        }
        lines += notes
        if lines.count > maximumLines {
            let hidden = lines.count - (maximumLines - 1)
            lines = Array(lines.prefix(maximumLines - 1)) + ["… and \(hidden) more."]
        }
        return (lines.joined(separator: "\n"), outcomes.contains { if case .failed = $0 { return true } else { return false } })
    }
}

// MARK: - Editor

struct EditorPane: View {
    @AppStorage(Prefs.font) private var font = FontChoice.avenirNext.rawValue
    @AppStorage(Prefs.fontSize) private var fontSize = 17.0
    @AppStorage(Prefs.lineHeight) private var lineHeight = 1.45
    @AppStorage(Prefs.width) private var width = 720.0
    @AppStorage(Prefs.spellCheck) private var spellCheck = false

    var body: some View {
        Form {
            Section("Typography") {
                Picker("Font", selection: $font) {
                    ForEach(FontChoice.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $fontSize, in: 12...28, step: 1)
                        Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Line spacing") {
                    HStack {
                        Slider(value: $lineHeight, in: 1.1...2.0, step: 0.05)
                        Text(String(format: "%.2f×", lineHeight)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Text width") {
                    HStack {
                        Slider(value: $width, in: 480...1100, step: 20)
                        Text("\(Int(width)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Section("Writing") {
                Toggle("Check spelling while typing", isOn: $spellCheck)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralPane: View {
    @State private var message: String?

    /// "0.9.0 (3)" from the app bundle, or a note when running unpackaged (`swift run`).
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.hasPrefix("__") else { return "development build" }
        let build = (info?["CFBundleVersion"] as? String).flatMap { $0.hasPrefix("__") ? nil : $0 }
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// The bundled licence texts (`Contents/Resources/Legal`), if the app is packaged.
    static var legalFolder: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Legal", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    var body: some View {
        Form {
            Section("Files") {
                Button("Make Downwrite the Default Markdown App") {
                    Task { message = await DefaultHandler.claim() }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Section("About") {
                LabeledContent("Version", value: Self.versionText)
                LabeledContent("Licence", value: "GNU GPL v3.0 · © Derrick Wheals")
                LabeledContent("Third-party licences") {
                    Button("Show in Finder") {
                        if let folder = Self.legalFolder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    .disabled(Self.legalFolder == nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
