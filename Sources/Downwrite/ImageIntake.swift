import AppKit
import ImageIO
import UniformTypeIdentifiers
import DownwriteCore

// Turning one pasted or dropped image into a file in `assets/` (DW-002). Everything here is a plain function of its arguments
// and the file system, so it runs off the main thread (R20) and is tested on real files. What the bytes are, what the file is
// called, what the link says and how far to shrink come from `DownwriteCore` (`ImageFormat`, `ImageNaming`, `ImageLink`,
// `ImageShrink`).

/// One image to add: bytes taken off a pasteboard, or a file on disk.
struct ImageSource: Sendable {
    enum Origin: Sendable {
        case bytes(Data)
        case file(URL)
    }

    var origin: Origin
    /// What a message calls it: the file's name, or "Pasted image".
    var displayName: String

    static func pasted(_ data: Data) -> ImageSource { ImageSource(origin: .bytes(data), displayName: "Pasted image") }
    static func file(_ url: URL) -> ImageSource { ImageSource(origin: .file(url), displayName: url.lastPathComponent) }
}

struct PixelSize: Equatable, Sendable, CustomStringConvertible {
    var width: Int
    var height: Int
    var longEdge: Int { max(width, height) }
    var description: String { "\(width) × \(height)" }
}

/// What was done to an image beyond saving it, to be told to the person (R22).
enum ImageNote: Equatable, Sendable {
    /// Scaled down to fit the preview limit; sizes are as the image is shown (the orientation applied).
    case scaled(from: PixelSize, to: PixelSize)
    /// Larger than the preview limit and not safe to shrink (animated, SVG, GIF, WebP): saved as it is.
    case tooBigToPreview
}

/// The outcome for one image: the file the link points to, and the link.
struct PreparedImage: Equatable, Sendable {
    var displayName: String
    /// The file the link points to (in `assets/`, or the dropped file itself when it already lies inside the document's folder).
    var fileURL: URL
    /// The link's path components, relative to the document's folder.
    var linkPath: [String]
    var link: String
    /// False when the link points at a file that was already there (R15).
    var wroteFile: Bool
    var notes: [ImageNote]

    var fileName: String { fileURL.lastPathComponent }
}

/// Why an image could not be added (R21). `message` is the sentence the sheet shows.
enum ImageIntakeError: Error, Equatable, Sendable {
    case notAnImage(String)
    case unreadable(String)
    case tooLarge(String)
    case tooManyPixels(String)
    case cannotShrink(String)
    case assetsIsNotAFolder(folder: String)
    case cannotCreateAssets(folder: String, reason: String)
    case cannotWrite(file: String, reason: String)

    var message: String {
        switch self {
        case .notAnImage(let name): "“\(name)” isn't an image Downwrite can read."
        case .unreadable(let name): "“\(name)” can't be read."
        case .tooLarge(let name): "“\(name)” is over the 100 MB Downwrite will process."
        case .tooManyPixels(let name): "“\(name)” has more than 200 million pixels, which is more than Downwrite will process."
        case .cannotShrink(let name): "“\(name)” can't be made smaller than 8 MB without becoming unreadable."
        case .assetsIsNotAFolder(let folder): "“assets” in “\(folder)” isn't a folder, so images can't be saved there."
        case .cannotCreateAssets(let folder, let reason): "“assets” in “\(folder)” can't be created: \(reason)."
        case .cannotWrite(let file, let reason): "“\(file)” can't be saved in “assets”: \(reason)."
        }
    }
}

enum ImageIntake {
    /// Names tried in a folder before giving up (`name`, `name-2` … `name-10000`).
    static let maxNameAttempts = 10_000
    /// HEIC and HEIF become JPEG at this quality (R12).
    static let conversionQuality = 0.9
    /// A JPEG made smaller is re-encoded at this quality.
    static let shrinkQuality = 0.85

    /// Reads `source`, decides what to write (keep the bytes, convert, or scale down: R12–R14), and writes it into
    /// `documentFolder`'s `assets` folder under a name nothing else has (R7–R9), or, for a file already inside the document's
    /// folder that needs no change, writes nothing and links it where it is (R15). Nothing on disk is touched before the
    /// image has been read, checked and encoded, so a failure leaves no file and no folder behind.
    ///
    /// - Parameters:
    ///   - now, timeZone: name a pasted image (`image-YYYYMMDD-HHMMSS`); injected so a test names the same file everywhere.
    ///   - maxBytes: the size the preview and the export accept (`ImageLoader.maxEmbeddedBytes`).
    ///   - maxSourceBytes, maxPixels: the intake limits (R14); parameters so a test needs no huge file.
    static func prepare(_ source: ImageSource, documentFolder: URL, now: Date, timeZone: TimeZone = .current,
                        maxBytes: Int = ImageLoader.maxEmbeddedBytes, maxSourceBytes: Int = ImageLimits.maxSourceBytes,
                        maxPixels: Int = ImageLimits.maxPixels) throws -> PreparedImage {
        let name = source.displayName
        let (data, original) = try read(source, maxSourceBytes: maxSourceBytes)
        let image = try inspect(data, name: name, maxPixels: maxPixels)
        let (savedFormat, keepsBytes) = image.format.saved
        let animated = image.frames > 1 && (image.format == .gif || image.format == .webp || image.format == .png)

        // R15: a file that is already in the document's tree, needs no change and fits, is linked where it is.
        if let original, keepsBytes, data.count <= maxBytes,
           let relative = ImageLink.relativePath(of: components(of: canonical(original)), in: components(of: canonical(documentFolder))) {
            return PreparedImage(displayName: name, fileURL: original, linkPath: relative, link: ImageLink.markdown(path: relative),
                                 wroteFile: false, notes: [])
        }

        var notes: [ImageNote] = []
        let output: Data
        if keepsBytes {
            if data.count <= maxBytes {
                output = data
            } else if animated || image.format == .svg || image.format == .gif || image.format == .webp {
                output = data
                notes.append(.tooBigToPreview)
            } else {
                (output, notes) = try shrunk(image, as: savedFormat, startingBytes: data.count, name: name, maxBytes: maxBytes)
            }
        } else {
            let converted = try convert(image, to: savedFormat, name: name)
            if converted.count <= maxBytes {
                output = converted
            } else {
                (output, notes) = try shrunk(image, as: savedFormat, startingBytes: converted.count, name: name, maxBytes: maxBytes)
            }
        }

        let fileExtension = savedFormat.fileExtension
        let wanted: String
        if let original {
            wanted = ImageNaming.droppedName(stem: original.deletingPathExtension().lastPathComponent, fileExtension: fileExtension)
        } else {
            wanted = ImageNaming.pastedName(at: now, timeZone: timeZone, fileExtension: fileExtension)
        }
        let assets = try assetsFolder(in: documentFolder)
        let written = try write(output, named: wanted, in: assets)
        let path = [ImageLink.folderName, written.lastPathComponent]
        return PreparedImage(displayName: name, fileURL: written, linkPath: path, link: ImageLink.markdown(path: path), wroteFile: true, notes: notes)
    }

    // MARK: Reading and checking

    /// The image's bytes and, for a file, its URL. The size limit is checked before the file is read.
    private static func read(_ source: ImageSource, maxSourceBytes: Int) throws -> (Data, URL?) {
        let name = source.displayName
        switch source.origin {
        case .bytes(let data):
            guard data.count <= maxSourceBytes else { throw ImageIntakeError.tooLarge(name) }
            return (data, nil)
        case .file(let url):
            let real = canonical(url)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isFolder) else { throw ImageIntakeError.unreadable(name) }
            guard !isFolder.boolValue else { throw ImageIntakeError.notAnImage(name) }
            let size = (try? real.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= maxSourceBytes else { throw ImageIntakeError.tooLarge(name) }
            guard let data = try? Data(contentsOf: real) else { throw ImageIntakeError.unreadable(name) }
            return (data, url)
        }
    }

    /// What ImageIO (or the SVG check) makes of the bytes, without decoding any pixels.
    struct Inspected {
        var data: Data
        var format: ImageFormat
        var source: CGImageSource?            // nil for an SVG
        var size: PixelSize?                  // as stored; nil for an SVG
        var orientedSize: PixelSize?          // as shown: the orientation applied
        var frames: Int
    }

    private static func inspect(_ data: Data, name: String, maxPixels: Int) throws -> Inspected {
        let sniffed = ImageFormat.sniff(Array(data.prefix(65_536)))
        if sniffed == .svg { return Inspected(data: data, format: .svg, source: nil, size: nil, orientedSize: nil, frames: 1) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              type.conforms(to: .image), !type.conforms(to: .pdf),                              // a PDF is not an image here (R12)
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageIntakeError.notAnImage(name) }
        guard width <= maxPixels / max(1, height) else { throw ImageIntakeError.tooManyPixels(name) }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let size = PixelSize(width: width, height: height)
        let oriented = (5...8).contains(orientation) ? PixelSize(width: height, height: width) : size
        return Inspected(data: data, format: sniffed ?? .other, source: source, size: size, orientedSize: oriented,
                         frames: CGImageSourceGetCount(source))
    }

    // MARK: Converting and scaling

    private static func type(for format: ImageFormat) -> UTType { format == .jpeg ? .jpeg : .png }

    /// TIFF, BMP and the rest as PNG, HEIC and HEIF as JPEG: the first image, with the source's metadata carried over where
    /// ImageIO does (R13), and nothing added.
    private static func convert(_ image: Inspected, to format: ImageFormat, name: String) throws -> Data {
        guard let source = image.source else { throw ImageIntakeError.notAnImage(name) }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type(for: format).identifier as CFString, 1, nil) else {
            throw ImageIntakeError.notAnImage(name)
        }
        let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: conversionQuality] : [:]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageIntakeError.notAnImage(name) }
        return out as Data
    }

    /// The image scaled down, step by step (`ImageShrink`), until it encodes within `maxBytes`. The decode goes through ImageIO's
    /// thumbnail path, so the full bitmap is never held. Thumbnails come out upright, so the orientation is reset or a photo
    /// would turn twice.
    private static func shrunk(_ image: Inspected, as format: ImageFormat, startingBytes: Int, name: String,
                               maxBytes: Int) throws -> (Data, [ImageNote]) {
        guard let source = image.source, let size = image.size, let shown = image.orientedSize else { throw ImageIntakeError.notAnImage(name) }
        var edge = size.longEdge
        var bytes = startingBytes
        let baseProperties = metadata(of: source)
        while let next = ImageShrink.nextLongEdge(current: edge, bytes: bytes, limit: maxBytes) {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: next,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw ImageIntakeError.notAnImage(name)
            }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, type(for: format).identifier as CFString, 1, nil) else {
                throw ImageIntakeError.notAnImage(name)
            }
            var properties = baseProperties
            if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = shrinkQuality }
            CGImageDestinationAddImage(destination, thumbnail, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageIntakeError.notAnImage(name) }
            edge = next
            bytes = out.length
            if bytes <= maxBytes {
                return (out as Data, [.scaled(from: shown, to: PixelSize(width: thumbnail.width, height: thumbnail.height))])
            }
        }
        throw ImageIntakeError.cannotShrink(name)
    }

    /// The source's properties for the scaled copy: its metadata (EXIF, GPS, TIFF, IPTC …), minus what no longer describes the
    /// pixels (their dimensions) and with the orientation reset, because the thumbnail has been turned upright.
    private static func metadata(of source: CGImageSource) -> [CFString: Any] {
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel,
                    kCGImagePropertyHasAlpha, kCGImagePropertyIsIndexed, kCGImagePropertyIsFloat, kCGImagePropertyFileSize] {
            properties.removeValue(forKey: key)
        }
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
    }

    // MARK: Paths

    /// `url` with every symbolic link resolved, the last component's included (`realpath(3)`; the `canonicalPathKey` resource value
    /// leaves a link in the last place alone), so two paths can be compared for "inside".
    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.resolvingSymlinksInPath().standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private static func components(of url: URL) -> [String] { url.pathComponents.filter { $0 != "/" } }

    // MARK: Writing

    /// The `assets` folder next to the document, created on first use. A symbolic link to a folder counts as a folder (R7).
    private static func assetsFolder(in documentFolder: URL) throws -> URL {
        let assets = documentFolder.appendingPathComponent(ImageLink.folderName, isDirectory: true)
        let folderName = documentFolder.lastPathComponent
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: assets.path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { throw ImageIntakeError.assetsIsNotAFolder(folder: folderName) }
            return assets
        }
        // Not there, or a symbolic link that leads nowhere (which `fileExists` follows and calls missing).
        if (try? FileManager.default.attributesOfItem(atPath: assets.path)) != nil { throw ImageIntakeError.assetsIsNotAFolder(folder: folderName) }
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        } catch {
            var made: ObjCBool = false
            if FileManager.default.fileExists(atPath: assets.path, isDirectory: &made), made.boolValue { return assets }   // created meanwhile
            throw ImageIntakeError.cannotCreateAssets(folder: folderName, reason: reason(for: error))
        }
        return assets
    }

    /// Creates the file under `wanted`, or the next free name (`name-2` …), and returns its URL. The create is exclusive
    /// (`O_CREAT | O_EXCL`), so a file that appears between choosing a name and writing is never overwritten: that name is
    /// skipped (R8). A failure removes the partial file this call made, and only that.
    private static func write(_ data: Data, named wanted: String, in assets: URL) throws -> URL {
        var taken = Set<String>()
        func exists(_ name: String) -> Bool {
            taken.contains(name) || (try? FileManager.default.attributesOfItem(atPath: assets.appendingPathComponent(name).path)) != nil
        }
        while taken.count < maxNameAttempts {
            guard let name = ImageNaming.firstFree(wanted, limit: maxNameAttempts, isTaken: exists) else { break }
            let url = assets.appendingPathComponent(name)
            do {
                try createExclusively(data, at: url)
                return url
            } catch let error as POSIXError where error.code == .EEXIST {
                taken.insert(name)
            } catch {
                throw ImageIntakeError.cannotWrite(file: name, reason: reason(for: error))
            }
        }
        throw ImageIntakeError.cannotWrite(file: wanted, reason: "there are too many files with that name")
    }

    private static func createExclusively(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count, failure == 0 {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno != EINTR { failure = errno }
                } else {
                    offset += written
                }
            }
        }
        if close(descriptor) != 0, failure == 0 { failure = errno }
        if failure != 0 {
            unlink(url.path)                                       // our own partial file: made by the exclusive open above
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    /// A short reason for the sheet.
    private static func reason(for error: Error) -> String {
        let posix = (error as? POSIXError)?.code
        let cocoa = (error as? CocoaError)?.code
        if posix == .EACCES || posix == .EPERM || posix == .EROFS || cocoa == .fileWriteNoPermission || cocoa == .fileWriteVolumeReadOnly {
            return "the folder is read-only"
        }
        if posix == .ENOSPC || posix == .EDQUOT || cocoa == .fileWriteOutOfSpace { return "the disk is full" }
        if posix == .ENAMETOOLONG { return "the name is too long" }
        let text = (error as NSError).localizedDescription
        return text.prefix(1).lowercased() + text.dropFirst().replacingOccurrences(of: ".", with: "")
    }
}

// MARK: - Reading a pasteboard

/// What an image paste (or drop) holds, read at the moment it happens: the summary `ImagePasteRule` decides on, what to add, and
/// the files that are not images and will be skipped (R16).
struct PasteboardImages {
    var content: PasteboardImageContent
    var sources: [ImageSource]
    var skippedFiles: [String]
}

extension ImageIntake {
    /// Image data in the order R12 takes it: PNG, JPEG, GIF, WebP, HEIC, TIFF.
    static let dataTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("org.webmproject.webp"), NSPasteboard.PasteboardType("public.heic"), .tiff,
    ]

    /// The bytes of image data are copied now (the pasteboard may change); files are only named, and read later off the main
    /// thread. Files win over data when both are present (Finder's copy of a file may carry a preview of it). `copyingData: false`
    /// only looks at the types, which is all a menu needs to know whether Paste is available.
    static func read(_ pasteboard: NSPasteboard, copyingData: Bool = true) -> PasteboardImages {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageFiles = urls.filter(isImageFile)
        let otherFiles = urls.filter { !isImageFile($0) }
        var dataSources: [ImageSource] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let type = dataTypes.first(where: { item.types.contains($0) }) else { continue }
            if !copyingData { dataSources.append(.pasted(Data())); continue }
            if let data = item.data(forType: type) { dataSources.append(.pasted(data)) }
        }
        let content = PasteboardImageContent(plainText: pasteboard.string(forType: .string), hasImageData: !dataSources.isEmpty,
                                             imageFileNames: imageFiles.map(\.lastPathComponent), hasOtherFiles: !otherFiles.isEmpty)
        return PasteboardImages(content: content, sources: imageFiles.isEmpty ? dataSources : imageFiles.map(ImageSource.file),
                                skippedFiles: otherFiles.map(\.lastPathComponent))
    }

    /// Whether the file's name says it is an image (a PDF is not one here). The bytes are checked when it is read.
    static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension
        if ImageFormat.isImageFileExtension(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .pdf)
    }
}
