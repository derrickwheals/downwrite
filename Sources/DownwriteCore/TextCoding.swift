import Foundation

public enum LineEnding: String, Sendable {
    case lf = "\n", crlf = "\r\n", cr = "\r"
}

/// Result of decoding a file. `text` is always normalised to `\n` line endings for editing.
public struct DecodedText: Equatable, Sendable {
    public var text: String
    public var encoding: String.Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding
}

/// Reads and writes Markdown files without silently changing their encoding, BOM or line endings.
public enum TextCoding {
    public static func decode(_ data: Data) -> DecodedText {
        var encoding: String.Encoding = .utf8
        var body = data
        var bom = false
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = true; body = data.dropFirst(3)
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian; bom = true; body = data.dropFirst(2)
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian; bom = true; body = data.dropFirst(2)
        }
        var text: String
        if encoding == .utf8 {
            let candidate = String(decoding: body, as: UTF8.self)
            // `String(decoding:)` repairs invalid bytes, so a mismatch on re-encode means the file is not valid UTF-8.
            if candidate.utf8.elementsEqual(body) {
                text = candidate
            } else {
                text = decodeCP1252(body); encoding = .windowsCP1252
            }
        } else if let s = String(data: body, encoding: encoding) {
            text = s
        } else {
            text = String(decoding: body, as: UTF8.self); encoding = .utf8
        }
        let ending = detectLineEnding(text)
        if ending != .lf {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return DecodedText(text: text, encoding: encoding, hasBOM: bom, lineEnding: ending)
    }

    public static func encode(_ text: String, encoding: String.Encoding = .utf8, bom: Bool = false, lineEnding: LineEnding = .lf) -> Data {
        var out = text
        if lineEnding != .lf { out = out.replacingOccurrences(of: "\n", with: lineEnding.rawValue) }
        var data = Data()
        if bom {
            switch encoding {
            case .utf16LittleEndian: data.append(contentsOf: [0xFF, 0xFE])
            case .utf16BigEndian: data.append(contentsOf: [0xFE, 0xFF])
            case .utf8: data.append(contentsOf: [0xEF, 0xBB, 0xBF])
            default: break
            }
        }
        if encoding == .windowsCP1252 {
            data.append(encodeCP1252(out))
        } else {
            data.append(out.data(using: encoding, allowLossyConversion: true) ?? Data(out.utf8))
        }
        return data
    }

    static func detectLineEnding(_ text: String) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var prevCR = false
        for u in text.utf8 {
            if u == 13 { cr += 1; prevCR = true; continue }
            if u == 10 { if prevCR { crlf += 1; cr -= 1 } else { lf += 1 } }
            prevCR = false
        }
        if crlf > 0 && crlf >= lf && crlf >= cr { return .crlf }
        if cr > 0 && cr > lf { return .cr }
        return .lf
    }

    // Foundation on Linux has no Windows-1252 codec, so the 0x80…0x9F block is mapped by hand.
    private static let cp1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    static func decodeCP1252(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        for b in data {
            let v = (b >= 0x80 && b < 0xA0) ? cp1252High[Int(b) - 0x80] : UInt32(b)
            scalars.append(Unicode.Scalar(v) ?? "?")
        }
        return String(scalars)
    }

    static func encodeCP1252(_ s: String) -> Data {
        var out = Data()
        for u in s.unicodeScalars {
            if u.value < 0x80 || (u.value >= 0xA0 && u.value <= 0xFF) { out.append(UInt8(u.value)) }
            else if let i = cp1252High.firstIndex(of: u.value) { out.append(UInt8(0x80 + i)) }
            else { out.append(UInt8(ascii: "?")) }
        }
        return out
    }
}
