import Foundation

public extension Palette {
    /// Whether this is a dark palette (a dark page), whatever theme it came from.
    var isDark: Bool { background.luminance < 0.4 }
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
