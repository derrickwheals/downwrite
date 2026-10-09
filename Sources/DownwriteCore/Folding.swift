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

    /// The outermost folded region that hides the caret position `offset`, if any: a position is hidden when its line is one of
    /// the region's hidden lines. The end of a header line is visible (the chip sits there); the start of the first hidden line
    /// is not; the start of the line after the region is visible. At the very end of the text the position is on the last
    /// line, which is hidden only if that line is one of the region's hidden lines.
    public func foldHiding(offset: Int, in analysis: MarkdownAnalysis) -> FoldRegion? {
        guard !anchors.isEmpty else { return nil }
        let line = analysis.lineIndex(at: offset)
        // Regions are in anchor order, and an outer region starts before the regions inside it.
        return analysis.foldRegions.first { isFolded($0) && $0.hiddenLines.contains(line) }
    }

    /// The folded region whose header lines hold `offset`'s line, if any (a visible position: its fold chip is on this line).
    public func headerFold(containing offset: Int, in analysis: MarkdownAnalysis) -> FoldRegion? {
        guard !anchors.isEmpty else { return nil }
        let line = analysis.lineIndex(at: offset)
        return analysis.foldRegions.first { isFolded($0) && $0.headerLines.contains(line) }
    }

    /// The outermost folded region whose hidden text ends exactly at `offset`, i.e. the caret sits at the start of the first
    /// visible line after it (where Backspace would join that line to hidden text).
    public func outermostFold(endingAt offset: Int, in analysis: MarkdownAnalysis) -> FoldRegion? {
        guard !anchors.isEmpty else { return nil }
        return analysis.foldRegions.first { isFolded($0) && NSMaxRange($0.hiddenRange) == offset }
    }

    /// Where the caret goes when a fold hides it (R13): the end of the header's last line, where the chip sits.
    public func headerEnd(of region: FoldRegion, in analysis: MarkdownAnalysis) -> Int {
        analysis.lines[region.headerLines.upperBound].contentEnd
    }

    /// The nearest position where the caret can be, in the direction of travel (R13, R14): `offset` itself when it is visible;
    /// otherwise, going forward, the start of the first visible line after the outermost fold hiding it; going back, the end
    /// of that fold's header. When the hidden text runs to the end of the document there is nothing visible after it, so going
    /// forward ends on the header too (⌘↓ with a hidden end of document).
    public func visibleOffset(from offset: Int, forward: Bool, in analysis: MarkdownAnalysis) -> Int {
        var position = offset
        for _ in 0...anchors.count {          // each pass steps over one more fold, so this ends
            guard let hiding = foldHiding(offset: position, in: analysis) else { return position }
            guard forward, hiding.hiddenLines.upperBound < analysis.lines.count - 1 else { return headerEnd(of: hiding, in: analysis) }
            position = NSMaxRange(hiding.hiddenRange)
        }
        return position
    }

    // MARK: Staying attached (R18)

    /// The state after the text changed by `edit` (the single replacement that turns the old text into the new one, e.g.
    /// `TextDiff.replacement`). A fold belongs to its header line: for an edit replacing `[s, e)` and a fold anchored at `a`,
    ///
    /// - `e <= a`: the header moved with the text above it, so the anchor shifts by the change in length. A pure insertion
    ///   exactly at `a` is the exception: it shifts the anchor only if the inserted text ends in a line break (Return at the
    ///   start of the header pushes it down, typing there does not);
    /// - `a < s`: the edit is after the header's first character (inside the header, or below it), so the anchor stays;
    /// - `s < a < e`: the edit replaces text from before the header into it, and the fold goes;
    /// - `s == a < e`: the edit starts at the header's first character. It keeps the fold if it stays within the header's text
    ///   (retyping it, changing its level) and drops it if it runs past the end of the header's last line (the line terminator
    ///   counts as past), so deleting the header line never hands its fold to whatever line comes next.
    ///
    /// After shifting, a fold is kept only if the new analysis has a region at that offset: a line that stopped being a heading
    /// or an item, or an item that lost its extra content, is no longer foldable.
    public func mapped(through edit: TextEdit, from old: MarkdownAnalysis, to new: MarkdownAnalysis) -> FoldState {
        guard !anchors.isEmpty else { return self }
        let s = edit.range.location, e = NSMaxRange(edit.range)
        let delta = edit.replacement.utf16.count - edit.range.length
        let endsInLineBreak = edit.replacement.utf16.last.map { $0 == 10 || $0 == 13 } ?? false
        var next = Set<Int>()
        for a in anchors {
            let target: Int
            if e <= a {
                target = (s == a && e == a && !endsInLineBreak) ? a : a + delta
            } else if a < s {
                target = a
            } else if s < a {
                continue
            } else {
                // s == a < e
                guard let r = Self.region(anchored: a, in: old), e <= old.lines[r.headerLines.upperBound].contentEnd else { continue }
                target = a
            }
            if Self.region(anchored: target, in: new) != nil { next.insert(target) }
        }
        return FoldState(anchors: next)
    }

    /// The region whose anchor is `anchor` (binary search: regions are sorted by anchor).
    private static func region(anchored anchor: Int, in analysis: MarkdownAnalysis) -> FoldRegion? {
        var lo = 0, hi = analysis.foldRegions.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if analysis.foldRegions[mid].anchor < anchor { lo = mid + 1 } else { hi = mid }
        }
        return lo < analysis.foldRegions.count && analysis.foldRegions[lo].anchor == anchor ? analysis.foldRegions[lo] : nil
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
