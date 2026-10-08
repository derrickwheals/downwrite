import Foundation

/// Applying a new version of a document to an open editor without throwing away the view's state: the smallest single
/// replacement that turns the old text into the new one, and where the caret goes afterwards.
public enum TextDiff {
    /// The smallest single replacement that turns `old` into `new` — the common prefix and suffix stay untouched — or nil
    /// when the texts are equal. Offsets are UTF-16, and a surrogate pair (an emoji) is never split. `selection` of the
    /// result is the caret at the end of the inserted text.
    public static func replacement(from old: String, to new: String) -> TextEdit? {
        let a = Array(old.utf16), b = Array(new.utf16)
        if a == b { return nil }
        let limit = min(a.count, b.count)
        var prefix = 0
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0, isHighSurrogate(a[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        let maxSuffix = limit - prefix
        while suffix < maxSuffix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, isLowSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let inserted = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return TextEdit(range: NSRange(location: prefix, length: a.count - prefix - suffix), replacement: inserted,
                        selection: NSRange(location: prefix + (b.count - suffix - prefix), length: 0))
    }

    /// Where `selection` ends up once `edit` has been applied: before the edit it stays put, after it it moves by the
    /// change in length, and a point inside the replaced text keeps its distance from the start of the edit (clamped to
    /// the new text) so the caret stays on the line that was changed.
    public static func map(_ selection: NSRange, through edit: TextEdit) -> NSRange {
        let inserted = edit.replacement.utf16.count
        let editEnd = NSMaxRange(edit.range)
        func point(_ p: Int) -> Int {
            if p <= edit.range.location { return p }
            if p >= editEnd { return p + inserted - edit.range.length }
            return edit.range.location + min(p - edit.range.location, inserted)
        }
        let start = point(selection.location)
        let end = point(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func isHighSurrogate(_ u: UInt16) -> Bool { u >= 0xD800 && u <= 0xDBFF }
    private static func isLowSurrogate(_ u: UInt16) -> Bool { u >= 0xDC00 && u <= 0xDFFF }
}
