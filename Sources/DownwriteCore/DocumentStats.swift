import Foundation

public struct DocumentStats: Equatable, Sendable {
    public var words: Int
    public var characters: Int
    public var lines: Int

    /// Estimated reading time in whole minutes (minimum 1 when there is any text), at 230 wpm.
    public var readingMinutes: Int { words == 0 ? 0 : max(1, Int((Double(words) / 230).rounded())) }

    public init(_ text: String) {
        var w = 0
        var inWord = false
        for u in text.unicodeScalars {
            if u.properties.isWhitespace { inWord = false } else if !inWord { inWord = true; w += 1 }
        }
        words = w
        characters = text.count
        lines = text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
