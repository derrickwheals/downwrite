import Foundation

/// One line of the table of contents.
public struct TOCRow: Equatable, Sendable, Identifiable {
    /// Index of the heading in `MarkdownAnalysis.headings` (document order, so rows are numbered 0…n-1).
    public let id: Int
    /// The level as written, 1…6.
    public let level: Int
    /// Nesting depth: 0 for top-level entries. Skipped levels do not add depth (`#` then `###` nests one step).
    public let depth: Int
    /// `id` of the enclosing heading, nil at the top level.
    public let parent: Int?
    /// Visible heading text; empty for a bare `#`.
    public let title: String
    public let hasChildren: Bool
}

/// The nested heading outline of a document, flattened into display order.
public struct TableOfContents: Equatable, Sendable {
    public let rows: [TOCRow]

    public var isEmpty: Bool { rows.isEmpty }

    public init(headings: [HeadingInfo]) {
        // A heading nests under the closest earlier heading with a smaller level.
        var parents: [Int?] = []
        var depths: [Int] = []
        var stack: [Int] = []
        var hasChildren = [Bool](repeating: false, count: headings.count)
        for (i, h) in headings.enumerated() {
            while let top = stack.last, headings[top].level >= h.level { stack.removeLast() }
            parents.append(stack.last)
            depths.append(stack.count)
            if let p = stack.last { hasChildren[p] = true }
            stack.append(i)
        }
        rows = headings.indices.map { i in
            TOCRow(id: i, level: headings[i].level, depth: depths[i], parent: parents[i],
                   title: headings[i].plainTitle, hasChildren: hasChildren[i])
        }
    }
}

extension MarkdownAnalysis {
    public var tableOfContents: TableOfContents { TableOfContents(headings: headings) }

    /// The heading whose section contains `offset`: the last heading that starts at or before it, nil in front of the first.
    public func headingIndex(at offset: Int) -> Int? {
        var lo = 0, hi = headings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if headings[mid].range.location <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}
