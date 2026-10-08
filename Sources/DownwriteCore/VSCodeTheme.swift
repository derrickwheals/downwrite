import Foundation

/// A colour theme read from a VS Code theme file, converted to a Downwrite `Palette`.
public struct ImportedTheme: Equatable, Sendable {
    public var name: String
    /// Light or dark, decided by how light the editor background is (what matters for legibility), not by the file's `type`.
    public var appearance: Theme
    public var palette: Palette
    /// Things the importer had to guess or could not use (shown to the person importing).
    public var warnings: [String]
}

public enum VSCodeThemeError: Error, Equatable, LocalizedError {
    case notJSON(String)
    case notATheme
    case extensionManifest

    public var errorDescription: String? {
        switch self {
        case .notJSON(let detail): return "The file is not valid JSON (\(detail))."
        case .notATheme: return "This does not look like a VS Code colour theme: it has no \"colors\" or \"tokenColors\"."
        case .extensionManifest:
            return "This is an extension's package.json, not a theme. Choose one of the theme files listed under \"contributes\" ▸ \"themes\" (usually in the extension's \"themes\" folder)."
        }
    }
}

/// Converts a VS Code colour theme file (the JSON format of `themes/*.json` in a theme extension, comments and trailing commas
/// allowed) to a Downwrite palette.
///
/// VS Code themes colour a code editor, Downwrite shows prose, so only some keys apply:
///
/// | Palette | Taken from (first one present) |
/// | --- | --- |
/// | page | `editor.background` |
/// | text | `editor.foreground`, `foreground`, a `tokenColors` rule without scope |
/// | secondary text | `descriptionForeground`, `editorLineNumber.foreground` |
/// | markers | `editorLineNumber.foreground`, `editorWhitespace.foreground` |
/// | accent (bullets, checkboxes) | token `markup.heading`, `textLink.foreground`, `focusBorder`, `button.background` |
/// | links | `textLink.foreground`, token `markup.underline.link`, the accent |
/// | code | `textPreformat.foreground`, `textCodeBlock.background` (else a tint of the page) |
/// | quote bar | `textBlockQuote.border` |
/// | highlight | `editor.findMatchHighlightBackground`, `editor.wordHighlightBackground` |
/// | rules | `editorGroup.border`, `panel.border`, `editorWidget.border` |
/// | selection | `editor.selectionBackground` |
///
/// Whatever is missing is derived from the page and text colours. Every foreground colour is then nudged just far enough
/// towards black or white to stay legible on its background, so an odd theme can never make the editor unreadable.
public enum VSCodeTheme {
    public static func convert(_ text: String, fallbackName: String,
                               resolveInclude: (String) -> String? = { _ in nil }) throws -> ImportedTheme {
        var warnings: [String] = []
        let merged = try load(text, resolveInclude: resolveInclude, depth: 0, warnings: &warnings)
        guard merged.hasThemeContent else { throw VSCodeThemeError.notATheme }

        let colors = merged.colors
        let tokens = merged.tokens
        func hex(_ key: String) -> RGBA? { colors[key].flatMap { RGBA(cssHex: $0) } }

        // Page and appearance.
        let declaredType = (merged.type ?? "").lowercased()
        let guessedDark = declaredType == "dark" || declaredType == "hc" || declaredType == "hc-black"
        var background: RGBA
        if let b = hex("editor.background") {
            background = RGBA(b.r, b.g, b.b)
        } else {
            background = guessedDark ? RGBA(hex: 0x1E1E1E) : RGBA(hex: 0xFFFFFF)
            warnings.append("The theme does not set editor.background; \(guessedDark ? "a dark" : "a light") page was assumed.")
        }
        // Light text or dark text, whichever reads better on this page (they are equally good at a luminance of about 0.18);
        // that also decides whether the theme is offered as a dark or a light one.
        let pole = bestPole(for: background)
        let appearance: Theme = pole.r > 0.5 ? .dark : .light
        let declaredLight = ["light", "hc-light", "hclight"].contains(declaredType)
        if (guessedDark && appearance == .light) || (declaredLight && appearance == .dark) {
            warnings.append("The file says its type is \"\(declaredType)\" but its page is \(appearance == .dark ? "dark" : "light"); it is offered as a \(appearance == .dark ? "dark" : "light") theme.")
        }

        func solid(_ key: String) -> RGBA? { hex(key).map { $0.flattened(over: background) } }
        func token(_ scopes: [String]) -> RGBA? {
            for scope in scopes {
                if let c = tokens.foreground(for: scope).flatMap({ RGBA(cssHex: $0) }) { return c.flattened(over: background) }
            }
            return nil
        }

        let ink = (solid("editor.foreground") ?? solid("foreground") ?? tokens.globalForeground.flatMap { RGBA(cssHex: $0) } ?? pole)
            .flattened(over: background)
            .ensuringContrast(4.5, against: background, toward: pole)
        let secondary = (solid("descriptionForeground") ?? solid("editorLineNumber.foreground") ?? ink.mixed(with: background, 0.35))
            .ensuringContrast(3.0, against: background, toward: pole)
        let marker = (solid("editorLineNumber.foreground") ?? solid("editorWhitespace.foreground") ?? ink.mixed(with: background, 0.55))
            .ensuringContrast(2.2, against: background, toward: pole)
        let accent = (token(["markup.heading", "entity.name.section.markdown", "heading.1.markdown"]) ?? solid("textLink.foreground")
                      ?? solid("focusBorder") ?? solid("button.background") ?? ink)
            .ensuringContrast(3.0, against: background, toward: pole)
        let link = (solid("textLink.foreground") ?? token(["markup.underline.link", "string.other.link"]) ?? accent)
            .ensuringContrast(3.5, against: background, toward: pole)

        // Code cards: the theme's own colour if the text can be read on it and it shows against the page, else a tint of the page.
        var codeBackground = solid("textCodeBlock.background") ?? background.mixed(with: pole, 0.05)
        if codeBackground.contrast(with: background) < 1.04 || ink.contrast(with: codeBackground) < 4.0 {
            codeBackground = background.mixed(with: pole, 0.05)
        }
        // Inline code: a tint of the page, as strong as the ink can still be read on.
        var tint = 0.1
        var inlineCode = background.mixed(with: pole, tint)
        while ink.contrast(with: inlineCode) < 4.0, tint > 0.03 { tint -= 0.01; inlineCode = background.mixed(with: pole, tint) }
        let codeText = (solid("textPreformat.foreground") ?? ink)
            .ensuringContrast(4.5, against: codeBackground, toward: bestPole(for: codeBackground))

        let quoteBar = solid("textBlockQuote.border") ?? accent.withAlpha(0.55)

        // Highlight: the theme's find/word highlight, else a soft yellow, else a tint of the ink: the first the ink can be read on.
        let highlightChoices = [hex("editor.findMatchHighlightBackground"), hex("editor.wordHighlightBackground"),
                                appearance == .dark ? RGBA(hex: 0xF9E2AF, alpha: 0.25) : RGBA(hex: 0xFFE770, alpha: 0.75),
                                ink.withAlpha(0.18)].compactMap { $0 }
        let highlight = highlightChoices.first { ink.contrast(with: $0.flattened(over: background)) >= 3.5 } ?? ink.withAlpha(0.18)

        var rule = solid("editorGroup.border") ?? solid("panel.border") ?? solid("editorWidget.border") ?? background.mixed(with: pole, 0.14)
        if rule.contrast(with: background) < 1.15 { rule = background.mixed(with: pole, 0.14) }

        let selectionChoices = [hex("editor.selectionBackground"), accent.withAlpha(0.3), accent.withAlpha(0.2), ink.withAlpha(0.2)].compactMap { $0 }
        let selection = selectionChoices.first { ink.contrast(with: $0.flattened(over: background)) >= 3.0 } ?? ink.withAlpha(0.2)

        let palette = Palette(background: background, text: ink, secondaryText: secondary, marker: marker, accent: accent, link: link,
                              codeText: codeText, codeBackground: codeBackground, inlineCodeBackground: inlineCode, quoteBar: quoteBar,
                              highlightBackground: highlight, rule: rule, selection: selection)
        let name = merged.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? fallbackName
        return ImportedTheme(name: name, appearance: appearance, palette: palette, warnings: warnings)
    }

    /// White or black, whichever has more contrast against `background`.
    static func bestPole(for background: RGBA) -> RGBA {
        RGBA(1, 1, 1).contrast(with: background) >= RGBA(0, 0, 0).contrast(with: background) ? RGBA(1, 1, 1) : RGBA(0, 0, 0)
    }

    // MARK: Reading a theme file (with `include`s)

    private struct Loaded {
        var name: String?
        var type: String?
        var colors: [String: String] = [:]
        var tokens = TokenRules()
        var hasThemeContent = false
    }

    private static func load(_ text: String, resolveInclude: (String) -> String?, depth: Int, warnings: inout [String]) throws -> Loaded {
        let object: [String: Any]
        do {
            object = try JSONC.object(from: text)
        } catch JSONC.ParseError.notAnObject {
            throw VSCodeThemeError.notJSON("the top level is not an object")
        } catch JSONC.ParseError.invalid(let detail) {
            throw VSCodeThemeError.notJSON(detail)
        }
        if let contributes = object["contributes"] as? [String: Any], contributes["themes"] != nil, object["colors"] == nil {
            throw VSCodeThemeError.extensionManifest
        }

        var result = Loaded()
        // An included theme is the base; this file's own entries come after it and win.
        if let include = object["include"] as? String {
            if depth >= 5 {
                warnings.append("Too many nested \"include\"s; \"\(include)\" was ignored.")
            } else if let included = resolveInclude(include) {
                result = try load(included, resolveInclude: resolveInclude, depth: depth + 1, warnings: &warnings)
            } else {
                warnings.append("The included theme \"\(include)\" could not be read, so its colours are missing.")
            }
        }
        if let name = object["name"] as? String { result.name = name }
        if let type = object["type"] as? String { result.type = type }
        if let colors = object["colors"] as? [String: Any] {
            result.hasThemeContent = true
            for (key, value) in colors { if let s = value as? String { result.colors[key] = s } }
        }
        if let rules = object["tokenColors"] as? [[String: Any]] {
            result.hasThemeContent = true
            result.tokens.append(rules)
        } else if object["tokenColors"] is String {
            result.hasThemeContent = true
            warnings.append("The theme's \"tokenColors\" points to a separate .tmTheme file; only its \"colors\" were used.")
        }
        if object["colors"] == nil, object["tokenColors"] == nil, let legacy = object["settings"] as? [[String: Any]] {
            result.hasThemeContent = true
            result.tokens.append(legacy)
        }
        return result
    }

    /// The `tokenColors` rules of a theme, queried by TextMate scope the way VS Code does: a rule applies to a scope if its
    /// selector is that scope or a parent of it (`markup.heading` covers `markup.heading.markdown`), and the most specific
    /// rule (the longest selector, the later one on a tie) wins.
    struct TokenRules {
        private var rules: [(selector: String, foreground: String)] = []
        private(set) var globalForeground: String?

        mutating func append(_ entries: [[String: Any]]) {
            for entry in entries {
                guard let settings = entry["settings"] as? [String: Any], let foreground = settings["foreground"] as? String else { continue }
                let scopes: [String]
                if let s = entry["scope"] as? String {
                    scopes = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else if let list = entry["scope"] as? [String] {
                    scopes = list.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                } else {
                    globalForeground = foreground                                // a rule with no scope sets the default
                    continue
                }
                for scope in scopes where !scope.isEmpty { rules.append((scope, foreground)) }
            }
        }

        func foreground(for scope: String) -> String? {
            var best: (length: Int, color: String)?
            for rule in rules {
                // Selectors with spaces (descendant selectors) are matched on their last component only.
                let selector = rule.selector.split(separator: " ").last.map(String.init) ?? rule.selector
                guard scope == selector || scope.hasPrefix(selector + ".") else { continue }
                if best == nil || selector.count >= best!.length { best = (selector.count, rule.foreground) }
            }
            return best?.color
        }
    }
}
