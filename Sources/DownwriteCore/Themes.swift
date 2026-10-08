import Foundation

public extension Palette {
    /// Whether this is a dark palette: the page is dark enough that light text reads better on it than dark text (the two
    /// are equally good at a luminance of about 0.18), whatever theme it came from.
    var isDark: Bool { background.luminance < 0.18 }
}

/// One selectable colour theme: a name, which macOS appearance it is for, and its palette.
public struct ThemeDefinition: Equatable, Identifiable, Sendable {
    /// Stable identifier stored in the preferences (`downwrite-light`, `catppuccin-mocha` …).
    public let id: String
    /// Name shown in the pickers.
    public let name: String
    /// Which appearance's picker offers it.
    public let appearance: Theme
    public let palette: Palette

    public init(id: String, name: String, appearance: Theme, palette: Palette) {
        self.id = id; self.name = name; self.appearance = appearance; self.palette = palette
    }
}

/// The themes that come with Downwrite. A light theme and a dark theme are chosen independently; the appearance setting
/// (System / Light / Dark) decides which of the two is showing.
///
/// - **Downwrite**: the original palettes (pure white page in light).
/// - **Catppuccin Latte / Mocha**: [Catppuccin](https://github.com/catppuccin/palette) © 2021 Catppuccin, MIT.
/// - **Radix**: built from the slate and indigo scales (plus yellow for highlights) of
///   [Radix Colors](https://github.com/radix-ui/colors) © 2021–2022 Modulz, MIT: slate 1 page, 3/4 cards, 6 rules,
///   9 markers, 11/12 text; indigo for accent, links, quote bars and selection.
///   Licence texts: `ThirdParty/catppuccin-LICENSE.txt`, `ThirdParty/radix-colors-LICENSE.txt`.
public enum ThemeCatalog {
    public static let defaultLightID = "downwrite-light"
    public static let defaultDarkID = "downwrite-dark"

    public static let builtIn: [ThemeDefinition] = [
        ThemeDefinition(id: defaultLightID, name: "Downwrite", appearance: .light, palette: Palette.palette(for: .light)),
        ThemeDefinition(id: "catppuccin-latte", name: "Catppuccin Latte", appearance: .light, palette: Palette(
            background: RGBA(hex: 0xEFF1F5),                         // base
            text: RGBA(hex: 0x4C4F69),                               // text
            secondaryText: RGBA(hex: 0x5C5F77),                      // subtext1
            marker: RGBA(hex: 0x7C7F93),                             // overlay2
            accent: RGBA(hex: 0x8839EF),                             // mauve
            link: RGBA(hex: 0x1E66F5),                               // blue
            codeText: RGBA(hex: 0x4C4F69),
            codeBackground: RGBA(hex: 0xE6E9EF),                     // mantle
            inlineCodeBackground: RGBA(hex: 0xDCE0E8),               // crust
            quoteBar: RGBA(hex: 0x7287FD, alpha: 0.55),              // lavender
            highlightBackground: RGBA(hex: 0xDF8E1D, alpha: 0.35),   // yellow
            rule: RGBA(hex: 0xBCC0CC),                               // surface1
            selection: RGBA(hex: 0x7C7F93, alpha: 0.25))),           // overlay2
        ThemeDefinition(id: "radix-light", name: "Radix", appearance: .light, palette: Palette(
            background: RGBA(hex: 0xFCFCFD),                         // slate 1
            text: RGBA(hex: 0x1C2024),                               // slate 12
            secondaryText: RGBA(hex: 0x60646C),                      // slate 11
            marker: RGBA(hex: 0x8B8D98),                             // slate 9
            accent: RGBA(hex: 0x3E63DD),                             // indigo 9
            link: RGBA(hex: 0x3A5BC7),                               // indigo 11
            codeText: RGBA(hex: 0x1C2024),
            codeBackground: RGBA(hex: 0xF0F0F3),                     // slate 3
            inlineCodeBackground: RGBA(hex: 0xE8E8EC),               // slate 4
            quoteBar: RGBA(hex: 0xABBDF9),                           // indigo 7
            highlightBackground: RGBA(hex: 0xFFE770, alpha: 0.75),   // yellow 5
            rule: RGBA(hex: 0xD9D9E0),                               // slate 6
            selection: RGBA(hex: 0x3E63DD, alpha: 0.22))),           // indigo 9

        ThemeDefinition(id: defaultDarkID, name: "Downwrite", appearance: .dark, palette: Palette.palette(for: .dark)),
        ThemeDefinition(id: "catppuccin-mocha", name: "Catppuccin Mocha", appearance: .dark, palette: Palette(
            background: RGBA(hex: 0x1E1E2E),                         // base
            text: RGBA(hex: 0xCDD6F4),                               // text
            secondaryText: RGBA(hex: 0xA6ADC8),                      // subtext0
            marker: RGBA(hex: 0x7F849C),                             // overlay1
            accent: RGBA(hex: 0xCBA6F7),                             // mauve
            link: RGBA(hex: 0x89B4FA),                               // blue
            codeText: RGBA(hex: 0xCDD6F4),
            codeBackground: RGBA(hex: 0x181825),                     // mantle
            inlineCodeBackground: RGBA(hex: 0x313244),               // surface0
            quoteBar: RGBA(hex: 0xB4BEFE, alpha: 0.45),              // lavender
            highlightBackground: RGBA(hex: 0xF9E2AF, alpha: 0.25),   // yellow
            rule: RGBA(hex: 0x45475A),                               // surface1
            selection: RGBA(hex: 0x9399B2, alpha: 0.25))),           // overlay2
        ThemeDefinition(id: "radix-dark", name: "Radix", appearance: .dark, palette: Palette(
            background: RGBA(hex: 0x111113),                         // slate dark 1
            text: RGBA(hex: 0xEDEEF0),                               // slate dark 12
            secondaryText: RGBA(hex: 0xB0B4BA),                      // slate dark 11
            marker: RGBA(hex: 0x696E77),                             // slate dark 9
            accent: RGBA(hex: 0x9EB1FF),                             // indigo dark 11
            link: RGBA(hex: 0x9EB1FF),                               // indigo dark 11
            codeText: RGBA(hex: 0xEDEEF0),
            codeBackground: RGBA(hex: 0x212225),                     // slate dark 3
            inlineCodeBackground: RGBA(hex: 0x272A2D),               // slate dark 4
            quoteBar: RGBA(hex: 0x304384),                           // indigo dark 6
            highlightBackground: RGBA(hex: 0x665417),                // yellow dark 7
            rule: RGBA(hex: 0x363A3F),                               // slate dark 6
            selection: RGBA(hex: 0x3E63DD, alpha: 0.5))),            // indigo dark 9
    ]

    /// The themes offered for one appearance, in picker order (Downwrite first).
    public static func themes(for appearance: Theme) -> [ThemeDefinition] {
        builtIn.filter { $0.appearance == appearance }
    }

    public static func defaultID(for appearance: Theme) -> String {
        appearance == .dark ? defaultDarkID : defaultLightID
    }

    /// The theme with this id for this appearance, or the Downwrite theme when the id is unknown or belongs to the other
    /// appearance (a stale preference must never leave the editor without colours).
    public static func theme(id: String?, for appearance: Theme) -> ThemeDefinition {
        let candidates = themes(for: appearance)
        return candidates.first { $0.id == id } ?? candidates.first { $0.id == defaultID(for: appearance) } ?? candidates[0]
    }

    public static func palette(id: String?, for appearance: Theme) -> Palette {
        theme(id: id, for: appearance).palette
    }
}

// MARK: - Imported themes

/// The built-in themes plus the ones the person imported (from VS Code theme files), as one list per appearance.
public struct ThemeLibrary: Equatable, Sendable {
    public var imported: [ThemeDefinition]

    public init(imported: [ThemeDefinition] = []) {
        self.imported = imported
    }

    /// Built-in themes first (Downwrite on top), then imported ones by name.
    public func themes(for appearance: Theme) -> [ThemeDefinition] {
        ThemeCatalog.themes(for: appearance)
            + imported.filter { $0.appearance == appearance }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func theme(id: String?, for appearance: Theme) -> ThemeDefinition {
        let all = themes(for: appearance)
        return all.first { $0.id == id } ?? ThemeCatalog.theme(id: nil, for: appearance)
    }

    public func palette(id: String?, for appearance: Theme) -> Palette {
        theme(id: id, for: appearance).palette
    }
}

/// An imported theme as it is kept on disk (`Themes/<id>.json` in Application Support): already converted, so loading it
/// needs no VS Code knowledge and a later change to the converter cannot alter a theme the person has been using.
public struct StoredTheme: Codable, Equatable, Sendable {
    public var version = 1
    public var id: String
    public var name: String
    /// `light` or `dark`.
    public var appearance: String
    /// The file it was imported from (for display).
    public var source: String
    /// Palette entries as `#RRGGBB` / `#RRGGBBAA`, keyed by `Palette` property name.
    public var colors: [String: String]

    public init(id: String, name: String, appearance: Theme, source: String, palette: Palette) {
        self.id = id
        self.name = name
        self.appearance = appearance.rawValue
        self.source = source
        self.colors = [
            "background": palette.background.hexString, "text": palette.text.hexString, "secondaryText": palette.secondaryText.hexString,
            "marker": palette.marker.hexString, "accent": palette.accent.hexString, "link": palette.link.hexString,
            "codeText": palette.codeText.hexString, "codeBackground": palette.codeBackground.hexString,
            "inlineCodeBackground": palette.inlineCodeBackground.hexString, "quoteBar": palette.quoteBar.hexString,
            "highlightBackground": palette.highlightBackground.hexString, "rule": palette.rule.hexString, "selection": palette.selection.hexString,
        ]
    }

    /// The identifier an imported theme gets: stable for the same name and appearance, so importing a theme again replaces it.
    public static func identifier(name: String, appearance: Theme) -> String {
        let slug = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
            .reduce(into: "") { acc, ch in if !(ch == "-" && (acc.last == "-" || acc.isEmpty)) { acc.append(ch) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "custom-\(slug.isEmpty ? "theme" : slug)-\(appearance.rawValue)"
    }

    /// The theme this describes, or nil if the record is damaged (unknown appearance, a missing or unreadable colour).
    public func definition() -> ThemeDefinition? {
        guard let appearance = Theme(rawValue: appearance), !id.isEmpty, id.hasPrefix("custom-") else { return nil }
        func color(_ key: String) -> RGBA? { colors[key].flatMap { RGBA(cssHex: $0) } }
        guard let background = color("background"), let text = color("text"), let secondary = color("secondaryText"),
              let marker = color("marker"), let accent = color("accent"), let link = color("link"), let codeText = color("codeText"),
              let codeBackground = color("codeBackground"), let inline = color("inlineCodeBackground"), let quote = color("quoteBar"),
              let highlight = color("highlightBackground"), let rule = color("rule"), let selection = color("selection") else { return nil }
        let palette = Palette(background: background, text: text, secondaryText: secondary, marker: marker, accent: accent, link: link,
                              codeText: codeText, codeBackground: codeBackground, inlineCodeBackground: inline, quoteBar: quote,
                              highlightBackground: highlight, rule: rule, selection: selection)
        return ThemeDefinition(id: id, name: name, appearance: appearance, palette: palette)
    }
}
