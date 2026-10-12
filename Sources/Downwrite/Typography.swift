import AppKit
import DownwriteCore

enum FontChoice: String, CaseIterable, Identifiable {
    case avenirNext, newYork, sfPro, charter, sfMono
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .avenirNext: return "Avenir Next"
        case .newYork: return "New York"
        case .sfPro: return "SF Pro"
        case .charter: return "Charter"
        case .sfMono: return "SF Mono"
        }
    }

    /// The same face as a CSS `font-family` value, for HTML shown inside the editor.
    var cssFontFamily: String {
        switch self {
        case .avenirNext: return "'Avenir Next', -apple-system, sans-serif"
        case .newYork: return "ui-serif, 'New York', Georgia, serif"
        case .sfPro: return "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        case .charter: return "Charter, 'Charter BT', Georgia, serif"
        case .sfMono: return "ui-monospace, 'SF Mono', Menlo, monospace"
        }
    }
}

/// Fonts and metrics for the editor. Cheap to copy; fonts are memoised per (size, bold, italic, mono).
final class Typography {
    var choice: FontChoice
    var size: CGFloat
    var lineHeight: CGFloat
    var readableWidth: CGFloat

    private struct Key: Hashable { var size: CGFloat; var bold: Bool; var italic: Bool; var mono: Bool }
    private var cache: [Key: NSFont] = [:]

    init(choice: FontChoice = .avenirNext, size: CGFloat = 17, lineHeight: CGFloat = 1.45, readableWidth: CGFloat = 720) {
        self.choice = choice; self.size = size; self.lineHeight = lineHeight; self.readableWidth = readableWidth
    }

    func update(choice: FontChoice, size: CGFloat, lineHeight: CGFloat, readableWidth: CGFloat) {
        if choice != self.choice || size != self.size { cache.removeAll() }
        self.choice = choice; self.size = size; self.lineHeight = lineHeight; self.readableWidth = readableWidth
    }

    private func base(_ size: CGFloat) -> NSFont {
        switch choice {
        case .sfPro:
            return .systemFont(ofSize: size)
        case .newYork:
            let d = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return d.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        case .avenirNext:
            return NSFont(name: "AvenirNext-Regular", size: size) ?? .systemFont(ofSize: size)
        case .charter:
            return NSFont(name: "Charter-Roman", size: size) ?? .systemFont(ofSize: size)
        case .sfMono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func font(size: CGFloat? = nil, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> NSFont {
        let s = size ?? self.size
        let key = Key(size: s, bold: bold, italic: italic, mono: mono)
        if let f = cache[key] { return f }
        var f = mono ? NSFont.monospacedSystemFont(ofSize: s, weight: .regular) : base(s)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(traits))
            f = NSFont(descriptor: d, size: s) ?? f
        }
        cache[key] = f
        return f
    }

    /// Heading size multipliers for H1…H6.
    static let headingScale: [CGFloat] = [1.9, 1.55, 1.3, 1.15, 1.05, 1.0]

    func headingSize(_ level: Int) -> CGFloat {
        size * Self.headingScale[min(max(level, 1), 6) - 1]
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum AppearanceResolver {
    static func theme(for appearance: NSAppearance) -> Theme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The default (Downwrite) palette for an appearance.
    static func palette(for appearance: NSAppearance) -> Palette {
        Palette.palette(for: theme(for: appearance))
    }

    /// The palette of the chosen light or dark theme (built in or imported), whichever matches the appearance.
    @MainActor
    static func palette(for appearance: NSAppearance, lightTheme: String, darkTheme: String) -> Palette {
        let theme = theme(for: appearance)
        return ThemeStore.shared.library.palette(id: theme == .dark ? darkTheme : lightTheme, for: theme)
    }
}

extension NSAttributedString.Key {
    static let dwBlockBackground = NSAttributedString.Key("dw.blockBackground")
    static let dwPill = NSAttributedString.Key("dw.pill")
    static let dwRule = NSAttributedString.Key("dw.rule")
    static let dwQuoteDepth = NSAttributedString.Key("dw.quoteDepth")
    /// Marks a `-`/`*`/`+` list marker character that is displayed as a bullet glyph.
    static let dwBullet = NSAttributedString.Key("dw.bullet")
    /// On the first character of a hidden `- [ ] ` task prefix: a `CheckboxMark` for the layout manager to draw.
    static let dwCheckbox = NSAttributedString.Key("dw.checkbox")
    /// On the first visible character of a foldable header: a `FoldMark` for the layout manager to draw as a chevron.
    static let dwFold = NSAttributedString.Key("dw.fold")
    /// On the last character of a folded header's last line: the same `FoldMark`, drawn as the ⋯ chip after it.
    static let dwFoldChip = NSAttributedString.Key("dw.foldChip")
    /// On the first character of a hidden callout marker (`[!NOTE]`): a `CalloutMark` for the layout manager to draw as the icon and
    /// the type name.
    static let dwCallout = NSAttributedString.Key("dw.callout")
    /// On every line of a callout: its colour. The layout manager draws the first level of the quote bar with it; deeper levels keep
    /// `dwQuoteBarColor`, which every quote line carries.
    static let dwCalloutBar = NSAttributedString.Key("dw.calloutBar")
}

/// What the layout manager draws for a foldable header: a chevron (always while the region is folded, otherwise only while
/// the pointer is over the header) and, when folded, a ⋯ chip after the header's last character. Colours are fixed when the
/// line is styled, like `CheckboxMark`; hover is the one thing that is not in the attributes.
final class FoldMark: NSObject {
    let folded: Bool
    /// The selection covers some of the hidden text, so the chip is drawn in the selection colour.
    let covered: Bool
    let chevron: NSColor
    let chipFill: NSColor
    let chipInk: NSColor

    init(folded: Bool, covered: Bool, chevron: NSColor, chipFill: NSColor, chipInk: NSColor) {
        self.folded = folded; self.covered = covered
        self.chevron = chevron; self.chipFill = chipFill; self.chipInk = chipInk
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? FoldMark else { return false }
        return folded == o.folded && covered == o.covered && chevron == o.chevron && chipFill == o.chipFill && chipInk == o.chipInk
    }

    override var hash: Int {
        var h = Hasher()
        h.combine(folded); h.combine(covered)
        return h.finalize()
    }
}

/// What the layout manager draws in place of a hidden task prefix: a rounded square, filled with a tick when checked.
/// Attached to the prefix's first character together with a `.kern` that reserves the room for it.
final class CheckboxMark: NSObject {
    let checked: Bool
    /// Edge length of the square.
    let side: CGFloat
    /// Distance from the text baseline up to the vertical centre of the square.
    let centerAboveBaseline: CGFloat
    let accent: NSColor
    let outline: NSColor
    let tick: NSColor

    init(checked: Bool, side: CGFloat, centerAboveBaseline: CGFloat, accent: NSColor, outline: NSColor, tick: NSColor) {
        self.checked = checked; self.side = side; self.centerAboveBaseline = centerAboveBaseline
        self.accent = accent; self.outline = outline; self.tick = tick
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CheckboxMark else { return false }
        return checked == o.checked && side == o.side && centerAboveBaseline == o.centerAboveBaseline
            && accent == o.accent && outline == o.outline && tick == o.tick
    }

    override var hash: Int {
        var h = Hasher()
        h.combine(checked); h.combine(side); h.combine(centerAboveBaseline)
        return h.finalize()
    }
}

/// What the layout manager draws in place of a hidden callout marker: the kind's icon and its name, in the callout colour. Attached to
/// the marker's first character together with a `.kern` that reserves the room for it when a title follows, so the title can never
/// start under the label: the styler measures `nameWidth` once, from `font`, and the layout manager draws with the same numbers.
final class CalloutMark: NSObject {
    let kind: CalloutKind
    let color: NSColor
    /// "Note", "Tip" …
    let name: String
    /// The bold face the name is drawn in; the title is set in the same face.
    let font: NSFont
    /// Edge length of the square the icon is drawn in.
    let iconSide: CGFloat
    /// Space between the icon and the name.
    let gap: CGFloat
    let nameWidth: CGFloat
    /// Space between the name and the title that follows it.
    let titleGap: CGFloat

    init(kind: CalloutKind, color: NSColor, font: NSFont, size: CGFloat) {
        self.kind = kind; self.color = color; self.font = font
        name = kind.title
        iconSide = (size * 0.95).rounded()
        gap = (size * 0.4).rounded()
        titleGap = (size * 0.5).rounded()
        nameWidth = (kind.title as NSString).size(withAttributes: [.font: font]).width
    }

    /// Icon, gap and name.
    var labelWidth: CGFloat { iconSide + gap + nameWidth }
    /// The room the label and the gap before the title take: the advance of the marker's first character when a title follows.
    var reservedWidth: CGFloat { labelWidth + titleGap }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CalloutMark else { return false }
        return kind == o.kind && color == o.color && font == o.font && iconSide == o.iconSide && gap == o.gap
            && nameWidth == o.nameWidth && titleGap == o.titleGap
    }

    override var hash: Int {
        var h = Hasher()
        h.combine(kind); h.combine(iconSide); h.combine(nameWidth)
        return h.finalize()
    }
}
