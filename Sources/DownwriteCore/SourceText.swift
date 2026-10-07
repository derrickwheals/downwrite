import Foundation

/// UTF-16 view of a document with a line table. cmark reports positions as (line, UTF-8 column);
/// AppKit wants UTF-16 offsets — this type bridges the two.
struct SourceText {
    let units: [UInt16]
    /// UTF-16 offset of each line start. A trailing terminator yields a final empty line.
    private(set) var lineStarts: [Int] = [0]
    /// End of each line's content (excluding terminator).
    private(set) var lineContentEnds: [Int] = []
    /// End of each line including its terminator (== next start).
    private(set) var lineEnds: [Int] = []

    init(_ string: String) {
        units = Array(string.utf16)
        let n = units.count
        var i = 0
        while i < n {
            let c = units[i]
            if c == 10 {
                lineContentEnds.append(i); i += 1
                lineEnds.append(i); lineStarts.append(i)
            } else if c == 13 {
                lineContentEnds.append(i)
                i += (i + 1 < n && units[i + 1] == 10) ? 2 : 1
                lineEnds.append(i); lineStarts.append(i)
            } else {
                i += 1
            }
        }
        lineContentEnds.append(n)
        lineEnds.append(n)
    }

    var lineCount: Int { lineStarts.count }
    var length: Int { units.count }

    /// Converts a 1-based (line, UTF-8 column) cmark position to a UTF-16 offset.
    func offset(line: Int, column: Int) -> Int {
        let li = min(max(line - 1, 0), lineCount - 1)
        let start = lineStarts[li], end = lineContentEnds[li]
        var bytes = column - 1
        var p = start
        while bytes > 0 && p < end {
            let u = units[p]
            if u < 0x80 { bytes -= 1; p += 1 }
            else if u < 0x800 { bytes -= 2; p += 1 }
            else if u >= 0xD800 && u < 0xDC00 { bytes -= 4; p += 2 }
            else { bytes -= 3; p += 1 }
        }
        if bytes > 0 { p = lineEnds[li] }   // pointed at/after the terminator
        return min(p, length)
    }

    func lineIndex(containing offset: Int) -> Int {
        var lo = 0, hi = lineCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func string(_ r: NSRange) -> String {
        let a = max(0, r.location), b = min(length, NSMaxRange(r))
        guard b > a else { return "" }
        return String(decoding: units[a..<b], as: UTF16.self)
    }

    func isSpaceOrTab(_ i: Int) -> Bool { units[i] == 32 || units[i] == 9 }
}
