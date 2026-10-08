import Foundation

public extension RGBA {
    /// Parses a CSS/VS Code hex colour: `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA` (the `#` is optional).
    init?(cssHex string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }) else { return nil }
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(hex: UInt32(value))
        } else {
            self.init(hex: UInt32(value >> 8), alpha: Double(value & 0xFF) / 255)
        }
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not fully opaque.
    var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        return a >= 0.999 ? base : base + String(format: "%02X", byte(a))
    }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    /// This colour moved `fraction` of the way towards `other` (an opaque result).
    func mixed(with other: RGBA, _ fraction: Double) -> RGBA {
        let f = min(max(fraction, 0), 1)
        return RGBA(r * (1 - f) + other.r * f, g * (1 - f) + other.g * f, b * (1 - f) + other.b * f)
    }

    /// This colour drawn over an opaque `background` (what the eye sees for a translucent fill).
    func flattened(over background: RGBA) -> RGBA {
        RGBA(r * a + background.r * (1 - a), g * a + background.g * (1 - a), b * a + background.b * (1 - a))
    }

    /// If this colour (opaque) has less than `minimum` contrast against `background`, moves it towards `target` in 5 % steps
    /// until it does (or reaches `target`).
    func ensuringContrast(_ minimum: Double, against background: RGBA, toward target: RGBA) -> RGBA {
        let start = RGBA(r, g, b)
        if start.contrast(with: background) >= minimum { return start }
        var step = 1
        while step <= 20 {
            let candidate = start.mixed(with: target, Double(step) * 0.05)
            if candidate.contrast(with: background) >= minimum { return candidate }
            step += 1
        }
        return target
    }
}
