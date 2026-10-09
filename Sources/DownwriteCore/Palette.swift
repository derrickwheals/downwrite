import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    /// The colour as a CSS value: `#rrggbb`, or `rgba(r, g, b, a)` when translucent.
    public var css: String {
        func byte(_ c: Double) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        if a >= 1 {
            func hex(_ n: Int) -> String { (n < 16 ? "0" : "") + String(n, radix: 16) }
            return "#" + hex(byte(r)) + hex(byte(g)) + hex(byte(b))
        }
        let alpha = (min(max(a, 0), 1) * 1000).rounded() / 1000
        return "rgba(\(byte(r)), \(byte(g)), \(byte(b)), \(alpha))"
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio between two opaque colours.
    public func contrast(with other: RGBA) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

public enum Theme: String, CaseIterable, Sendable {
    case light, dark
}

/// Editor colour tokens. The app converts these to `NSColor`; keeping them here lets tests guard legibility.
public struct Palette: Equatable, Sendable {
    public var background: RGBA
    public var text: RGBA
    public var secondaryText: RGBA
    /// Syntax characters while revealed.
    public var marker: RGBA
    public var accent: RGBA
    public var link: RGBA
    public var codeText: RGBA
    public var codeBackground: RGBA
    public var inlineCodeBackground: RGBA
    public var quoteBar: RGBA
    public var highlightBackground: RGBA
    public var rule: RGBA
    public var selection: RGBA

    public static func palette(for theme: Theme) -> Palette {
        switch theme {
        case .light:
            return Palette(
                background: RGBA(hex: 0xFFFFFF), text: RGBA(hex: 0x24242B), secondaryText: RGBA(hex: 0x66666F),
                marker: RGBA(hex: 0x8A8A96), accent: RGBA(hex: 0x4054D6), link: RGBA(hex: 0x3548C9),
                codeText: RGBA(hex: 0x2B2B38), codeBackground: RGBA(hex: 0xF3F3F6), inlineCodeBackground: RGBA(hex: 0xEEEEF2),
                quoteBar: RGBA(hex: 0xC7CBF2), highlightBackground: RGBA(hex: 0xFFE98A, alpha: 0.75),
                rule: RGBA(hex: 0xDADADF), selection: RGBA(hex: 0x4054D6, alpha: 0.22))
        case .dark:
            return Palette(
                background: RGBA(hex: 0x1B1B1F), text: RGBA(hex: 0xE9E7E2), secondaryText: RGBA(hex: 0x9C9CA8),
                marker: RGBA(hex: 0x7B7B88), accent: RGBA(hex: 0x95A4FF), link: RGBA(hex: 0x9EABFF),
                codeText: RGBA(hex: 0xD8D8E4), codeBackground: RGBA(hex: 0x26262C), inlineCodeBackground: RGBA(hex: 0x2C2C33),
                quoteBar: RGBA(hex: 0x4A4F8F), highlightBackground: RGBA(hex: 0x8A7400, alpha: 0.55),
                rule: RGBA(hex: 0x3A3A42), selection: RGBA(hex: 0x95A4FF, alpha: 0.28))
        }
    }
}
