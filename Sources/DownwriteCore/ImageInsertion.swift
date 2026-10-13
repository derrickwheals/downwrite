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
