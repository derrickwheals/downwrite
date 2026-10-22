import AppKit

/// Copies the look of a styled copy of the text onto the editor's text storage, writing only the attribute runs that differ.
///
/// The styler used to begin every restyle with `setAttributes` over the whole document. NSTextStorage reports that as an attribute edit
/// over the whole text, so the layout manager threw away the layout of the entire document on every keystroke; with non-contiguous layout
/// the text view's height then fell back to an estimate, the clip view clamped its scroll position to it, and layout grew both back inside
/// the same keystroke — the view flashed about a line lower near the end of a long document (DW-024). Styling a detached copy and writing
/// the difference leaves the final attributes exactly as before while invalidating only the lines whose look really changed: none at all
/// for a letter typed into plain text.
enum StyleDiff {
    /// Makes `storage`'s attributes equal to `styled`'s (which must hold the same text) and returns the number of ranges written. Writes
    /// nothing, and does not even begin an edit, when they are already equal. Equality is `NSDictionary`'s, so every attribute value must
    /// compare by value (`NSFont`, `NSColor`, `NSParagraphStyle` and the editor's own marks do).
    @discardableResult
    static func apply(_ styled: NSAttributedString, to storage: NSTextStorage) -> Int {
        let length = min(styled.length, storage.length)
        guard length > 0 else { return 0 }
        var writes: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        let compare = styled.length == storage.length              // (different texts: a programming error; write everything rather than guess)
        styled.enumerateAttributes(in: NSRange(location: 0, length: length), options: []) { wanted, run, _ in
            guard compare else { writes.append((run, wanted)); return }
            let wantedDictionary = wanted as NSDictionary
            var location = run.location
            let end = NSMaxRange(run)
            var pending: NSRange?                                  // the differing stretch of this run so far
            while location < end {
                var effective = NSRange()
                let current = storage.attributes(at: location, effectiveRange: &effective)
                let piece = NSRange(location: location, length: min(NSMaxRange(effective), end) - location)
                if false && wantedDictionary.isEqual(to: current) {   // MUTATION M2
                    if let p = pending { writes.append((p, wanted)); pending = nil }
                } else {
                    pending = pending.map { NSRange(location: $0.location, length: NSMaxRange(piece) - $0.location) } ?? piece
                }
                location = NSMaxRange(piece)
            }
            if let p = pending { writes.append((p, wanted)) }
        }
        guard !writes.isEmpty else { return 0 }
        storage.beginEditing()
        for write in writes { storage.setAttributes(write.attributes, range: write.range) }
        storage.endEditing()
        return writes.count
    }
}
