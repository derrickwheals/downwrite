import SwiftUI
import DownwriteCore

extension RGBA {
    /// For SwiftUI previews of a palette.
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// A small sample of a theme's page — heading, body text, link, inline code, a task and a quote — drawn in its own colours,
/// shown under the theme pickers in Settings.
struct ThemePreview: View {
    let palette: Palette
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("A heading").font(.system(size: 15, weight: .bold)).foregroundStyle(palette.text.color)
            HStack(spacing: 5) {
                Text("Text with").foregroundStyle(palette.text.color)
                Text("code")
                    .font(.system(size: 10.5, design: .monospaced))
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(palette.inlineCodeBackground.color))
                    .foregroundStyle(palette.codeText.color)
                Text("a link").underline().foregroundStyle(palette.link.color)
            }
            .font(.system(size: 11.5))
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3.5).fill(palette.accent.color).frame(width: 11, height: 11)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(palette.background.color))
                Text("Done").strikethrough().foregroundStyle(palette.secondaryText.color)
                RoundedRectangle(cornerRadius: 3.5).stroke(palette.marker.color, lineWidth: 1.2).frame(width: 11, height: 11)
                Text("To do").foregroundStyle(palette.text.color)
            }
            .font(.system(size: 11.5))
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(palette.quoteBar.color).frame(width: 3, height: 14)
                Text("A quote").foregroundStyle(palette.secondaryText.color).font(.system(size: 11.5))
                Spacer(minLength: 0)
                Text("marked").padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(palette.highlightBackground.color))
                    .foregroundStyle(palette.text.color).font(.system(size: 11))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.background.color))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.rule.color, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(palette.marker.color).padding(7)
        }
    }
}
