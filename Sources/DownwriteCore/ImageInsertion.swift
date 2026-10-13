import Foundation

// Pasting and dropping images (DW-002). Everything that can be decided without a pasteboard, a file system or ImageIO
// lives here, so it is tested on Linux: what the bytes are, what the file is called, what the link says, how far to
// shrink, and where the link goes in the text. The app target (ImageIntake, EditorImages) only does the I/O.

// MARK: - Formats

/// An image format recognised from its bytes. The file name is never consulted: a PNG called `.jpg` is a PNG.
public enum ImageFormat: Sendable, Equatable {
    case png, jpeg, gif, webp, svg, tiff, heic, bmp
    /// Something ImageIO opens that the sniffer does not name (AVIF, JPEG 2000, RAW …). Saved as PNG.
    case other
}

extension ImageFormat {
    /// The format of `bytes`, or nil when they are none of the formats named above (ImageIO may still open them).
    public static func sniff(_ bytes: [UInt8]) -> ImageFormat? {
        let n = bytes.count
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            n >= offset + signature.count && bytes[offset..<(offset + signature.count)].elementsEqual(signature)
        }
        func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(ascii("GIF87a")) || starts(ascii("GIF89a")) { return .gif }
        if starts(ascii("RIFF")) && starts(ascii("WEBP"), at: 8) { return .webp }
        if starts(ascii("ftyp"), at: 4), n >= 12 {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if heifBrands.contains(brand) { return .heic }
            return nil
        }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts(ascii("BM")), n >= 26 {
            // "BM" alone is two letters of text. A bitmap's information header says how long it is, in one of a few sizes.
            let headerSize = Int(bytes[14]) | Int(bytes[15]) << 8 | Int(bytes[16]) << 16 | Int(bytes[17]) << 24
            if bmpHeaderSizes.contains(headerSize) { return .bmp }
        }
        if looksLikeSVG(bytes) { return .svg }
        return nil
    }

    private static let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"]
    private static let bmpHeaderSizes: Set<Int> = [12, 40, 52, 56, 64, 108, 124]

    /// An SVG is an XML document whose root element is `svg`. Anything before the root that XML allows (a byte order mark,
    /// white space, the `<?xml?>` declaration, comments, a doctype) is skipped; a page that merely contains an `<svg>` is not.
    private static func looksLikeSVG(_ bytes: [UInt8]) -> Bool {
        var text = Substring(String(decoding: bytes.prefix(65_536), as: UTF8.self))
        if text.hasPrefix("\u{FEFF}") { text = text.dropFirst() }
        while true {
            text = text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            if text.hasPrefix("<?") {
                guard let end = text.range(of: "?>") else { return false }
                text = text[end.upperBound...]
            } else if text.hasPrefix("<!--") {
                guard let end = text.range(of: "-->") else { return false }
                text = text[end.upperBound...]
            } else if text.hasPrefix("<!DOCTYPE") || text.hasPrefix("<!doctype") {
                guard let open = text.firstIndex(of: ">") else { return false }
                if let bracket = text.firstIndex(of: "["), bracket < open {
                    guard let close = text.range(of: "]>") else { return false }   // an internal subset runs to `]>`
                    text = text[close.upperBound...]
                } else {
                    text = text[text.index(after: open)...]
                }
            } else {
                break
            }
        }
        guard text.hasPrefix("<svg") else { return false }
        let after = text.dropFirst(4).first
        return after == nil || after == ">" || after == "/" || after == " " || after == "\t" || after == "\n" || after == "\r"
    }

    /// What is written to `assets/` for this source (R12): the format, and whether the file is copied byte for byte (a
    /// kept format) or re-encoded (TIFF, BMP and the rest become PNG, HEIC and HEIF become JPEG).
    public var saved: (format: ImageFormat, keepsBytes: Bool) {
        switch self {
        case .png, .jpeg, .gif, .webp, .svg: return (self, true)
        case .tiff, .bmp, .other: return (.png, false)
        case .heic: return (.jpeg, false)
        }
    }

    /// The canonical lower-case extension. Written files only ever get `png jpg gif webp svg` (`saved.format`).
    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        case .webp: return "webp"
        case .svg: return "svg"
        case .tiff: return "tiff"
        case .heic: return "heic"
        case .bmp: return "bmp"
        case .other: return "img"
        }
    }

    /// Whether a file or URL ending in `ext` (case-insensitive, without the dot) names an image. Used by `ImagePasteRule`.
    public static func isImageFileExtension(_ ext: String) -> Bool {
        imageFileExtensions.contains(ext.lowercased())
    }

    private static let imageFileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "tif", "tiff", "heic", "heif", "bmp"]
}

/// Intake limits (R14), so the app cannot be made to chew on a file without end. The preview and export size cap itself
/// is the app's `ImageLoader.maxEmbeddedBytes`, passed to `ImageShrink` as `limit`.
public enum ImageLimits {
    /// A source file larger than this is refused ("too large to process").
    public static let maxSourceBytes = 100_000_000
    /// An image with more pixels than this is refused.
    public static let maxPixels = 200_000_000
    /// Shrinking stops here: an image that still does not fit at this long edge cannot be added.
    public static let minLongEdge = 320
}

/// A letter of any script, a mark that belongs to a letter, or a decimal digit. Variation selectors are marks too, but they only
/// ride on emoji, so they do not count.
fileprivate func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
    if (0xFE00...0xFE0F).contains(scalar.value) { return false }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .nonspacingMark, .spacingMark, .decimalNumber:
        return true
    default:
        return false
    }
}

// MARK: - Image or text?

/// What a pasteboard (or a drag) holds, reduced to what the image-or-text rule needs, so the rule is tested without AppKit.
public struct PasteboardImageContent: Sendable, Equatable {
    /// The plain text on the pasteboard, if any.
    public var plainText: String?
    /// Whether image data (PNG, JPEG, GIF, WebP, HEIC or TIFF) is present.
    public var hasImageData: Bool
    /// The file names of the image files present (the names ending in an image extension; the bytes are checked later).
    public var imageFileNames: [String]
    /// Whether files that are not images are present too.
    public var hasOtherFiles: Bool

    public init(plainText: String? = nil, hasImageData: Bool = false, imageFileNames: [String] = [], hasOtherFiles: Bool = false) {
        self.plainText = plainText
        self.hasImageData = hasImageData
        self.imageFileNames = imageFileNames
        self.hasOtherFiles = hasOtherFiles
    }
}

/// R3: one rule for paste and drop alike. Images win when image data or image files are present and the plain text is absent
/// or names an image: one line that looks like a URL (Safari's "Copy Image" puts the image's address beside it) or ends in an
/// image extension (Finder puts the file's name beside the file). Any other text beside an image (spreadsheet cells, a web
/// selection) wins, and files that are all not images are not an image paste.
public enum ImagePasteRule {
    public static func prefersImages(_ content: PasteboardImageContent) -> Bool {
        guard content.hasImageData || !content.imageFileNames.isEmpty else { return false }
        guard let text = content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return true }
        if text.rangeOfCharacter(from: .newlines) != nil { return false }
        return Formatter.looksLikeURL(text) || endsInImageExtension(text)
    }

    private static func endsInImageExtension(_ text: String) -> Bool {
        guard let dot = text.lastIndex(of: "."), dot != text.startIndex else { return false }
        return ImageFormat.isImageFileExtension(String(text[text.index(after: dot)...]))
    }
}

// MARK: - Names

/// File names for images written to `assets/` (R8, R9). Pure: the clock, the time zone and "is this name taken" are arguments.
public enum ImageNaming {
    /// A stem is cut to this many Unicode scalars. Four UTF-8 bytes each keeps the longest name (stem, `-10000`, `.webp`) under
    /// the 255 bytes a file system allows.
    public static let maxStemLength = 60

    /// `image-YYYYMMDD-HHMMSS.<ext>` from the wall-clock time in `timeZone`. The time zone is passed in, never read from the
    /// machine, so a test names the same file everywhere.
    public static func pastedName(at date: Date, timeZone: TimeZone, fileExtension: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let stamp = "\(pad(c.year, 4))\(pad(c.month, 2))\(pad(c.day, 2))-\(pad(c.hour, 2))\(pad(c.minute, 2))\(pad(c.second, 2))"
        return "image-\(stamp).\(fileExtension.lowercased())"
    }

    /// A dropped or Finder-copied file keeps its own name, made safe: every character that is not a letter, a digit, `.`, `_` or
    /// `-` becomes `-` (a mark that belongs to a letter counts as part of it), runs of `-` collapse, leading `.` and `-` go, the
    /// name is normalised to NFC and cut to ``maxStemLength`` scalars, and an empty result is `image`. `stem` is the file name
    /// without its extension; `fileExtension` is the saved format's.
    public static func droppedName(stem: String, fileExtension: String) -> String {
        var scalars: [Unicode.Scalar] = []
        var lastWasDash = false
        for scalar in stem.precomposedStringWithCanonicalMapping.unicodeScalars {
            let isDash = scalar == "-" || !isKept(scalar)       // a dropped character becomes a dash, and a dash after a dash is one
            if isDash {
                if !lastWasDash { scalars.append("-") }
                lastWasDash = true
            } else {
                scalars.append(scalar)
                lastWasDash = false
            }
        }
        while let first = scalars.first, first == "." || first == "-" { scalars.removeFirst() }
        if scalars.count > maxStemLength { scalars.removeSubrange(maxStemLength...) }
        var safe = String.UnicodeScalarView()
        safe.append(contentsOf: scalars)
        let name = String(safe)
        return "\(name.isEmpty ? "image" : name).\(fileExtension.lowercased())"
    }

    private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "." || scalar == "_" || scalar == "-" || isLetterOrDigit(scalar)
    }

    /// `name` if `isTaken` says it is free, otherwise `name-2`, `name-3` … (the number goes before the last extension) up to
    /// `limit` candidates in all, then nil. The caller still creates the file exclusively: a name that was free here can be
    /// taken a moment later, and the exclusive write is what makes R8 true.
    public static func firstFree(_ name: String, limit: Int = 10_000, isTaken: (String) -> Bool) -> String? {
        let dot = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? $0 : nil }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let tail = dot.map { String(name[$0...]) } ?? ""
        guard limit >= 1 else { return nil }
        for n in 1...limit {
            let candidate = n == 1 ? name : "\(stem)-\(n)\(tail)"
            if !isTaken(candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Links

/// The Markdown for an image in `assets/` or elsewhere under the document's folder (R10, R15). Pure: paths are arrays of
/// components, so nothing here touches a file system.
public enum ImageLink {
    /// The folder pasted and dropped images are saved in, next to the document (R7). A fixed name, not a setting.
    public static let folderName = "assets"

    /// `![](assets/a%20b.png)`: empty alt text, `/` between components, and each component percent-encoded (UTF-8, upper-case
    /// hex) except for letters of any script, digits and `- . _ ~`. The angle-bracket form `<…>` is never used. A first
    /// component that starts with `~` gets a `./` in front: the preview treats `~…` as the home folder.
    public static func markdown(path components: [String]) -> String {
        var segments = components.map(encode)
        if components.first?.hasPrefix("~") == true { segments.insert(".", at: 0) }
        return "![](" + segments.joined(separator: "/") + ")"
    }

    private static func encode(_ component: String) -> String {
        var out = ""
        for scalar in component.unicodeScalars {
            if isLetterOrDigit(scalar) || scalar == "-" || scalar == "." || scalar == "_" || scalar == "~" {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    out += "%" + hex[Int(byte >> 4)] + hex[Int(byte & 0xF)]
                }
            }
        }
        return out
    }

    private static let hex = Array("0123456789ABCDEF").map(String.init)

    /// The components of `file` below `folder`, or nil unless `file` lies strictly inside it. Both arrays are the components of
    /// absolute paths with symbolic links already resolved, so a link in the tree that points out of it does not count. A
    /// sibling that merely shares a prefix (`/Docs2` against `/Docs`) is not inside, nor is the folder itself. Components compare as Swift
    /// strings do (canonically equivalent text is equal, as on APFS) but case-sensitively, so a difference of case says
    /// "outside" and the file is copied, which is always safe.
    public static func relativePath(of file: [String], in folder: [String]) -> [String]? {
        let unusable: Set<String> = ["", ".", ".."]
        guard file.count > folder.count,
              !file.contains(where: unusable.contains), !folder.contains(where: unusable.contains),
              Array(file.prefix(folder.count)) == folder else { return nil }
        return Array(file.dropFirst(folder.count))
    }
}

// MARK: - Shrinking

/// How an image that is over the preview cap is made smaller (R14). The app decodes once through ImageIO's thumbnail path at
/// the edge this returns, encodes, measures, and asks again; this type only does the arithmetic, so the loop's guarantees
/// (every step smaller, it ends) are tested without an image.
public enum ImageShrink {
    /// Encoded size does not fall exactly with the pixel count, so the estimate is pulled in a little.
    public static let safetyMargin = 0.9

    /// The long edge, in pixels, to try after an encoding of `bytes` at `current` came out over `limit`: `current` scaled by
    /// the square root of `limit / bytes` (size follows area) times ``safetyMargin``, at least one pixel less than
    /// `current` and never below ``ImageLimits/minLongEdge``. Nil means give up: `current` is already at or under that floor,
    /// or the arguments describe nothing to shrink (`bytes` not over `limit`).
    public static func nextLongEdge(current: Int, bytes: Int, limit: Int) -> Int? {
        guard current > ImageLimits.minLongEdge, limit > 0, bytes > limit else { return nil }
        let scaled = Double(current) * (Double(limit) / Double(bytes)).squareRoot() * safetyMargin
        return max(ImageLimits.minLongEdge, min(current - 1, Int(scaled)))
    }
}
