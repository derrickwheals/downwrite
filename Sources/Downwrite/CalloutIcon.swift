import AppKit
import DownwriteCore

/// The icon of each callout kind: an SF Symbol with its own silhouette (so the kinds differ in shape, not only in colour), drawn in
/// the callout colour. Used by the layout manager for the label and by the test that renders all five in one colour.
enum CalloutIcon {
    static func symbolName(for kind: CalloutKind) -> String {
        switch kind {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.bubble"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "exclamationmark.octagon"
        }
    }

    /// Draws the icon, as large as fits and centred, in the square `rect` (upright in a flipped or an unflipped context).
    static func draw(_ kind: CalloutKind, in rect: NSRect, color: NSColor) {
        guard rect.width > 0, rect.height > 0,
              let symbol = NSImage(systemSymbolName: symbolName(for: kind), accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)),
              symbol.size.width > 0, symbol.size.height > 0 else { return }
        // The symbol is a template (alpha only); tint it in an image of its own, so that filling "source in" cannot touch the page.
        let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceIn)
            return true
        }
        let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
    }
}
