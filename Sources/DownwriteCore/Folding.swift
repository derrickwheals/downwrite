import Foundation

/// Which headings and list items are folded in one editor window. A fold is identified by its anchor, the UTF-16 offset of the
/// start of its header line (`FoldRegion.anchor`), so the state is plain data that survives re-analysis: the editor keeps it
/// in memory, maps it through each edit, and asks it which lines to hide. Nothing here knows about AppKit.
public struct FoldState: Equatable, Sendable {
    /// Header-line starts of the folded regions.
    public private(set) var anchors: Set<Int>

    public init(anchors: Set<Int> = []) { self.anchors = anchors }

    public var isEmpty: Bool { anchors.isEmpty }

    public func isFolded(_ region: FoldRegion) -> Bool { anchors.contains(region.anchor) }

    // MARK: Queries

    /// The source lines hidden by folds, sorted and merged. A folded region inside another folded region adds nothing.
    public func hiddenLineRanges(in analysis: MarkdownAnalysis) -> [ClosedRange<Int>] {
        guard !anchors.isEmpty else { return [] }
        var out: [ClosedRange<Int>] = []
        for h in analysis.foldRegions.filter(isFolded).map(\.hiddenLines).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, h.lowerBound <= last.upperBound + 1 {
                if h.upperBound > last.upperBound { out[out.count - 1] = last.lowerBound...h.upperBound }
            } else {
                out.append(h)
            }
        }
        return out
    }

    /// The outermost folded region that hides the caret position `offset`, if any. The end of a header line is visible (the
    /// chip sits there); the start of its first hidden line is not. When the hidden text runs to the end of the document,
    /// the position at the very end is hidden too, since it sits on the last hidden line.
    public func foldHiding(offset: Int, in analysis: MarkdownAnalysis) -> FoldRegion? {
        guard !anchors.isEmpty else { return nil }
        // Regions are in anchor order, and an outer region starts before the regions inside it.
        return analysis.foldRegions.first { r in
            guard isFolded(r) else { return false }
            let end = NSMaxRange(r.hiddenRange)
            return offset >= r.hiddenRange.location && (offset < end || (offset == end && end == analysis.length))
        }
    }

    // MARK: Changing the state

    public func toggled(_ region: FoldRegion) -> FoldState {
        var next = self
        if next.anchors.remove(region.anchor) == nil { next.anchors.insert(region.anchor) }
        return next
    }

    /// Fold (R11): the innermost unfolded region whose header or hidden lines hold the caret's line. When the caret line is the
    /// header of a folded region that region is skipped, so repeated calls fold outwards. `nil` when there is nothing to fold.
    public func folding(atCaret caret: Int, in analysis: MarkdownAnalysis) -> FoldState? {
        let line = analysis.lineIndex(at: caret)
        var innermost: FoldRegion?
        // Regions holding one line are nested, and the one that starts last is the innermost.
        for r in analysis.foldRegions where !isFolded(r) && line >= r.headerLines.lowerBound && line <= r.hiddenLines.upperBound {
            innermost = r
        }
        return innermost.map(toggled)
    }

    /// Unfold (R11): the folded region whose header holds the caret's line. `nil` when there is none.
    public func unfolding(atCaret caret: Int, in analysis: MarkdownAnalysis) -> FoldState? {
        let line = analysis.lineIndex(at: caret)
        return analysis.foldRegions.first { isFolded($0) && $0.headerLines.contains(line) }.map(toggled)
    }

    /// Fold All (R12): every heading and every list item.
    public func foldingAll(in analysis: MarkdownAnalysis) -> FoldState {
        FoldState(anchors: Set(analysis.foldRegions.map(\.anchor)))
    }

    /// Unfold All (R12).
    public func unfoldingAll() -> FoldState { FoldState() }

    /// Fold to Level (R12): headings of `level` or deeper fold, shallower ones open, list items keep whatever state they had.
    public func folding(toLevel level: Int, in analysis: MarkdownAnalysis) -> FoldState {
        var next = anchors
        for r in analysis.foldRegions {
            guard case .heading(let l) = r.kind else { continue }
            if l >= level { next.insert(r.anchor) } else { next.remove(r.anchor) }
        }
        return FoldState(anchors: next)
    }

    /// Opens the folds that hide the start of `range`, outermost first (R15); folds that do not hide it stay as they are. Only
    /// the start matters: a selection may end in hidden text (R17).
    public func revealing(_ range: NSRange, in analysis: MarkdownAnalysis) -> FoldState {
        var next = self
        while let hiding = next.foldHiding(offset: range.location, in: analysis) { next.anchors.remove(hiding.anchor) }
        return next
    }
}
