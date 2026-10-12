import Foundation
import Markdown

/// The five GitHub callout (alert) types.
public enum CalloutKind: String, CaseIterable, Sendable {
    case note, tip, important, warning, caution

    /// The name shown on the marker line and in the export: "Note", "Tip" …
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// `"note"`, `"NOTE"`, `"Note"` …: the word between `[!` and `]`, in any ASCII letter case.
    public init?(marker: String) {
        self.init(units: Array(marker.utf16)[...])
    }

    /// Case-insensitive on UTF-16 units and ASCII only (no Foundation folding), so Linux and macOS agree and a dotless ı or a
    /// Kelvin sign is not a letter of the name.
    init?(units: ArraySlice<UInt16>) {
        for kind in CalloutKind.allCases {
            let name = kind.rawValue.utf16
            guard units.count == name.count else { continue }
            var same = true
            for (u, n) in zip(units, name) where (u >= 65 && u <= 90 ? u + 32 : u) != n { same = false; break }
            if same { self = kind; return }
        }
        return nil
    }
}

/// What the shared recogniser found in a block quote that is a callout (offsets are UTF-16 in the text it was given).
struct CalloutMatch: Equatable {
    var kind: CalloutKind
    /// The line the marker is on (0-based). Not always the quote's first line: `>` / `> [!NOTE]` / `> body` is a callout.
    var markerLine: Int
    /// `[!TYPE]` plus the spaces and tabs after it, up to the title or the end of the line's content. This is what hides.
    var markerRange: NSRange
    /// The title: the rest of the marker line, trimmed at both ends; nil when there is none.
    var titleRange: NSRange?
}

/// The one rule for "is this block quote a callout", used by the analyzer (the editor) and the renderer (the export), so the
/// two cannot disagree. cmark does the Markdown work (block structure, indentation, reference definitions); this reads the
/// source only where the tree cannot tell (a trailing hard break, the exact characters of the marker).
enum CalloutSyntax {
    private static let openBracket: UInt16 = 91, bang: UInt16 = 33, closeBracket: UInt16 = 93, greater: UInt16 = 62

    /// The callout `quote` is, or nil. `src` must be the text the quote was parsed from.
    ///
    /// - It is top level: its parent is the document (not another quote, a list item or a table cell).
    /// - Its first block is a paragraph that starts with plain text, which is how cmark reports `[!NOTE]` (a reference named
    ///   `!note` turns it into a link; `**[!NOTE]**`, a heading or an indented code block start with another node).
    /// - At the paragraph's first character the source reads `[!`, a name from `CalloutKind`, `]`, then the end of the line
    ///   or a space or tab. This rules out `+`, `-`, `:`, `\` and the like, and it also guards against a column cmark
    ///   reports differently than expected: an offset that does not hold `[` is a plain quote, never a wrong hide.
    /// - Something follows the marker: a title, a second block, or more lines in the paragraph.
    static func match(_ quote: BlockQuote, in src: SourceText) -> CalloutMatch? {
        guard quote.parent is Document,
              let paragraph = quote.child(at: 0) as? Paragraph,
              paragraph.child(at: 0) is Text else { return nil }

        // Where the paragraph starts. cmark-gfm gives the paragraph no source range when its table extension splits it off from a table
        // right below (`> [!NOTE]` then `> | a | b |`); then it is the first content of the quote itself.
        let p: Int
        if let start = paragraph.range?.lowerBound {
            p = src.offset(line: start.line, column: start.column)
        } else if let first = firstContent(of: quote, in: src) {
            p = first
        } else {
            return nil
        }
        let line = src.lineIndex(containing: p)
        let end = src.lineContentEnds[line]
        guard p + 2 < end, src.units[p] == openBracket, src.units[p + 1] == bang else { return nil }
        var q = p + 2
        while q < end, isASCIILetter(src.units[q]) { q += 1 }
        guard q < end, src.units[q] == closeBracket,
              let kind = CalloutKind(units: src.units[(p + 2)..<q]) else { return nil }
        let after = q + 1
        guard after == end || src.isSpaceOrTab(after) else { return nil }

        var titleStart = after
        while titleStart < end, src.isSpaceOrTab(titleStart) { titleStart += 1 }
        var titleEnd = end
        while titleEnd > titleStart, src.isSpaceOrTab(titleEnd - 1) { titleEnd -= 1 }
        let title = titleStart < titleEnd ? NSRange(location: titleStart, length: titleEnd - titleStart) : nil

        guard title != nil || quote.childCount > 1 || paragraph.childCount > 1 else { return nil }
        return CalloutMatch(kind: kind, markerLine: line, markerRange: NSRange(location: p, length: titleStart - p), titleRange: title)
    }

    /// The offset of the first character after the quote's `>` prefixes that is not a space or tab, scanning from the quote's first line
    /// (blank `>` lines are skipped): the start of the quote's first block. Nil when a line does not start with `>`, or there is none.
    private static func firstContent(of quote: BlockQuote, in src: SourceText) -> Int? {
        guard let start = quote.range?.lowerBound, start.line >= 1 else { return nil }
        var line = start.line - 1
        while line < src.lineCount {
            let end = src.lineContentEnds[line]
            var p = src.lineStarts[line]
            var spaces = 0
            while p < end, src.units[p] == 32, spaces < 3 { p += 1; spaces += 1 }
            guard p < end, src.units[p] == greater else { return nil }
            p += 1
            while p < end, src.isSpaceOrTab(p) { p += 1 }
            if p < end { return p }
            line += 1
        }
        return nil
    }

    private static func isASCIILetter(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) }
}

public extension Palette {
    /// The colour of a callout's bar, icon, type name and title on this page. Pure, opaque, and a function of the page and the
    /// text colour only, so no stored theme needs a new field and imported themes get callouts too.
    ///
    /// The kind's own hue is mixed 15 % toward the text colour (so it sits in the page's tone), then moved toward white or
    /// black, whichever the page is further from, until it has at least 4.5:1 against the page. Either pole has at least 4.58:1
    /// on any page, so the floor holds for every page, including random imported ones. On the six built-in themes the five
    /// colours are also at least ΔE*ab 25 apart (`ThemeCatalogTests`); on an imported page near luminance 0.18 they can converge,
    /// and the icon and the type name still tell them apart.
    func calloutColor(_ kind: CalloutKind) -> RGBA {
        kind.hue.mixed(with: text, 0.15)
            .ensuringContrast(4.5, against: background, toward: VSCodeTheme.bestPole(for: background))
    }
}

private extension CalloutKind {
    /// Downwrite's own hues (blue, green, purple, amber, red); not taken from any third-party palette.
    var hue: RGBA {
        switch self {
        case .note: return RGBA(hex: 0x2978E0)
        case .tip: return RGBA(hex: 0x29AE55)
        case .important: return RGBA(hex: 0x8F51D6)
        case .warning: return RGBA(hex: 0xF59F0A)
        case .caution: return RGBA(hex: 0xE42532)
        }
    }
}
