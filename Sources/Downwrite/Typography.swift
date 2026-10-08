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

    static func palette(for appearance: NSAppearance) -> Palette {
        Palette.palette(for: theme(for: appearance))
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
