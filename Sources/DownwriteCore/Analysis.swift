import Foundation

/// Per-character style facts produced by `MarkdownAnalysis`. The app layer maps these onto
/// fonts, colours and paragraph styles; the engine itself knows nothing about AppKit.
public struct StyleFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let bold = StyleFlags(rawValue: 1 << 0)
    public static let italic = StyleFlags(rawValue: 1 << 1)
    public static let strike = StyleFlags(rawValue: 1 << 2)
    public static let highlight = StyleFlags(rawValue: 1 << 3)
    /// Inline code span.
    public static let code = StyleFlags(rawValue: 1 << 4)
    public static let link = StyleFlags(rawValue: 1 << 5)
    public static let image = StyleFlags(rawValue: 1 << 6)
    /// A syntax character (`**`, `#`, `>` …). Hidden unless the caret is inside its pair.
    public static let marker = StyleFlags(rawValue: 1 << 7)
    /// Set on markers that are currently hidden (computed against a selection).
    public static let hidden = StyleFlags(rawValue: 1 << 8)
    public static let codeBlock = StyleFlags(rawValue: 1 << 9)
    public static let quote = StyleFlags(rawValue: 1 << 10)
    public static let fence = StyleFlags(rawValue: 1 << 11)
    public static let frontMatter = StyleFlags(rawValue: 1 << 12)
    public static let html = StyleFlags(rawValue: 1 << 13)
    public static let math = StyleFlags(rawValue: 1 << 14)
    public static let footnote = StyleFlags(rawValue: 1 << 15)
    /// Any character on a table line.
    public static let table = StyleFlags(rawValue: 1 << 16)
    public static let tableHeader = StyleFlags(rawValue: 1 << 17)
    public static let tableDelimiter = StyleFlags(rawValue: 1 << 18)
    public static let hr = StyleFlags(rawValue: 1 << 19)
    /// The `[ ]` / `[x]` checkbox of a task item.
    public static let task = StyleFlags(rawValue: 1 << 20)
    /// Text of a completed task item.
    public static let taskDone = StyleFlags(rawValue: 1 << 21)
    public static let listMarker = StyleFlags(rawValue: 1 << 22)
    /// De-emphasised punctuation that is never hidden (table pipes, setext underline …).
    public static let dim = StyleFlags(rawValue: 1 << 23)
    public static let headingMarker = StyleFlags(rawValue: 1 << 24)
}

public struct FormatSpan: Equatable, Sendable {
    public var range: NSRange
    public var flags: StyleFlags
}

/// A run of syntax characters. `reveal` is the range the selection has to touch for the marker to show.
public struct Marker: Equatable, Sendable {
    public var range: NSRange
    public var reveal: NSRange
    public var flags: StyleFlags
}

public struct LinkSpan: Equatable, Sendable {
    public var range: NSRange
    public var textRange: NSRange
    public var destination: String
}

public struct ImageSpan: Equatable, Sendable {
    public var range: NSRange
    public var alt: String
    public var source: String
}

public struct TaskBox: Equatable, Sendable {
    /// The three characters `[ ]` / `[x]`.
    public var range: NSRange
    public var checked: Bool
}

public struct MermaidBlock: Equatable, Sendable {
    /// Whole fenced block, fences included.
    public var range: NSRange
    public var source: String
    /// Index of the first/last source line of the block (closing is nil if unterminated).
    public var firstLine: Int
    public var lastLine: Int
}

/// A line that consists of nothing but one image (`![alt](src)`): previewed under the line.
public struct ImageBlock: Equatable, Sendable {
    public var line: Int
    public var range: NSRange
    public var alt: String
    public var source: String
}

/// Anything shown as a rendered card under (or instead of) its source: Mermaid diagrams and standalone images.
public struct PreviewBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case mermaid(source: String)
        case image(source: String, alt: String)
    }
    public var kind: Kind
    public var firstLine: Int
    public var lastLine: Int
    /// The source collapses while the selection is outside this range.
    public var reveal: NSRange
}

public struct TableBlock: Equatable, Sendable {
    public var range: NSRange
    public var firstLine: Int
    public var lastLine: Int
}

public struct HeadingInfo: Equatable, Sendable {
    public var level: Int
    public var title: String
    public var range: NSRange
}

public enum LineKind: Equatable, Sendable {
    case body
    case heading(Int)
    case setextUnderline
    case codeBlock
    case fence
    case frontMatter
    case hr
    case html
    case tableHeader
    case tableDelimiter
    case tableRow
}

public struct LineStyle: Equatable, Sendable {
    /// Range including the line terminator.
    public var range: NSRange
    /// End of the content, excluding the terminator.
    public var contentEnd: Int
    public var kind: LineKind = .body
    public var quoteDepth = 0
    /// UTF-16 length of leading indent + list marker (+ checkbox) used for hanging indents; 0 outside lists.
    public var listPrefixLength = 0
    public var listDepth = 0
    public var isListStart = false

    public var contentRange: NSRange { NSRange(location: range.location, length: contentEnd - range.location) }
}

public struct StyleRun: Equatable, Sendable {
    public var range: NSRange
    public var flags: StyleFlags
}

/// Immutable result of analysing a Markdown document. Re-created on every text change; selection-dependent
/// queries (`runs(in:selection:)`) are cheap and can be repeated on every caret move.
public struct MarkdownAnalysis: Sendable {
    public let length: Int
    public let spans: [FormatSpan]
    public let markers: [Marker]
    public let lines: [LineStyle]
    public let links: [LinkSpan]
    public let images: [ImageSpan]
    public let taskBoxes: [TaskBox]
    public let mermaid: [MermaidBlock]
    public let tables: [TableBlock]
    public let headings: [HeadingInfo]
    public let imageBlocks: [ImageBlock]

    /// Mermaid diagrams and standalone images in document order.
    public var previewBlocks: [PreviewBlock] {
        var out: [PreviewBlock] = mermaid.map {
            PreviewBlock(kind: .mermaid(source: $0.source), firstLine: $0.firstLine, lastLine: $0.lastLine, reveal: $0.range)
        }
        out += imageBlocks.map {
            PreviewBlock(kind: .image(source: $0.source, alt: $0.alt), firstLine: $0.line, lastLine: $0.line, reveal: lines[$0.line].contentRange)
        }
        return out.sorted { $0.firstLine < $1.firstLine }
    }

    /// Index of the line containing `offset` (offsets past the end map to the last line).
    public func lineIndex(at offset: Int) -> Int {
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].range.location <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func line(at offset: Int) -> LineStyle { lines[lineIndex(at: offset)] }

    public static func isRevealed(_ reveal: NSRange, by selection: NSRange) -> Bool {
        selection.location <= NSMaxRange(reveal) && NSMaxRange(selection) >= reveal.location
    }

    /// Markers that are hidden for the given selection.
    public func hiddenMarkerIndices(selection: NSRange) -> Set<Int> {
        var result = Set<Int>()
        for (i, m) in markers.enumerated() where !Self.isRevealed(m.reveal, by: selection) {
            result.insert(i)
        }
        return result
    }

    /// Flattened, non-overlapping style runs covering exactly `range` (every character appears in some run).
    public func runs(in range: NSRange, selection: NSRange) -> [StyleRun] {
        let lo = max(0, range.location), hi = min(length, NSMaxRange(range))
        guard hi > lo else { return [] }
        var flags = [UInt32](repeating: 0, count: hi - lo)

        @inline(__always) func paint(_ r: NSRange, _ f: StyleFlags) {
            let a = max(lo, r.location), b = min(hi, NSMaxRange(r))
            guard b > a else { return }
            for i in a..<b { flags[i - lo] |= f.rawValue }
        }
        for s in spans where s.range.location < hi && NSMaxRange(s.range) > lo { paint(s.range, s.flags) }
        for m in markers where m.range.location < hi && NSMaxRange(m.range) > lo {
            var f = m.flags.union(.marker)
            if !Self.isRevealed(m.reveal, by: selection) { f.insert(.hidden) }
            paint(m.range, f)
        }

        var runs: [StyleRun] = []
        var start = 0
        for i in 1...(hi - lo) {
            if i == hi - lo || flags[i] != flags[start] {
                runs.append(StyleRun(range: NSRange(location: lo + start, length: i - start),
                                     flags: StyleFlags(rawValue: flags[start])))
                start = i
            }
        }
        return runs
    }

    /// The task checkbox whose `[ ]` range contains `offset`.
    public func taskBox(at offset: Int) -> TaskBox? {
        taskBoxes.first { offset >= $0.range.location && offset <= NSMaxRange($0.range) }
    }

    public func link(at offset: Int) -> LinkSpan? {
        links.first { offset >= $0.textRange.location && offset <= NSMaxRange($0.textRange) }
    }

    public func mermaidBlock(containing offset: Int) -> MermaidBlock? {
        mermaid.first { offset >= $0.range.location && offset <= NSMaxRange($0.range) }
    }
}
