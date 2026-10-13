import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Downwrite
import DownwriteCore

/// `ImageIntake.prepare` on real files (DW-002): formats and conversions (R12), metadata (R13), size (R14), links in place
/// (R15), the images folder and never overwriting (R7, R8), names (R9) and failures that leave nothing behind (R21).
final class ImageIntakeTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var now: Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 41, second: 12))!
    }
    private let fm = FileManager.default

    /// A fresh folder standing for the document's folder, removed (permissions restored first) after the test.
    private func makeFolder(_ name: String = "Notes") throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("downwrite-intake-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { [fm] in
            if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in walker { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? fm.removeItem(at: root)
        }
        return folder
    }

    private func prepare(_ source: ImageSource, in folder: URL, maxBytes: Int = ImageLoader.maxEmbeddedBytes,
                         maxSourceBytes: Int = ImageLimits.maxSourceBytes, maxPixels: Int = ImageLimits.maxPixels) throws -> PreparedImage {
        try ImageIntake.prepare(source, documentFolder: folder, now: now, timeZone: utc, maxBytes: maxBytes,
                                maxSourceBytes: maxSourceBytes, maxPixels: maxPixels)
    }

    private func write(_ data: Data, as name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func names(in folder: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    private func assertFails(_ expected: ImageIntakeError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> PreparedImage) {
        do {
            _ = try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ImageIntakeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: Pasted images and their names (R9)

    func testAPastedPNGIsSavedUnderTheClocksName() throws {
        let folder = try makeFolder()
        let png = ImageFixtures.png()
        let result = try prepare(.pasted(png), in: folder)
        XCTAssertEqual(result.fileName, "image-20261013-094112.png")
        XCTAssertEqual(result.link, "![](assets/image-20261013-094112.png)")
        XCTAssertEqual(result.linkPath, ["assets", "image-20261013-094112.png"])
        XCTAssertTrue(result.wroteFile)
        XCTAssertTrue(result.notes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("assets/image-20261013-094112.png")), png, "byte for byte")
    }

    func testAPastedJPEGGetsTheJpgExtension() throws {
        let folder = try makeFolder()
        let result = try prepare(.pasted(ImageFixtures.jpeg()), in: folder)
        XCTAssertEqual(result.fileName, "image-20261013-094112.jpg")
    }

    func testTheLinkResolvesToTheFileThroughTheImageLoader() throws {
        let folder = try makeFolder()
        let result = try prepare(.pasted(ImageFixtures.png()), in: folder)
        let destination = String(result.link.dropFirst(4).dropLast())
        let resolved = try XCTUnwrap(ImageLoader.fileURL(for: destination, base: folder))
        XCTAssertEqual(ImageIntake.canonical(resolved), ImageIntake.canonical(result.fileURL))
        XCTAssertTrue(fm.fileExists(atPath: resolved.path))
    }

    // MARK: Formats (R12)

    func testPNGJPEGGIFAndSVGAreCopiedByteForByte() throws {
        let sources: [(String, Data)] = [("a.png", ImageFixtures.png()), ("b.jpg", ImageFixtures.jpeg()), ("c.gif", ImageFixtures.gif()),
                                         ("d.svg", ImageFixtures.svg())]
        for (name, data) in sources {
            let folder = try makeFolder()
            let outside = try makeFolder("Elsewhere")
            let url = try write(data, as: name, in: outside)
            let result = try prepare(.file(url), in: folder)
            XCTAssertTrue(result.wroteFile, name)
            XCTAssertEqual(try Data(contentsOf: result.fileURL), data, "\(name) is a byte-identical copy")
            XCTAssertEqual(result.fileURL.pathExtension, (name as NSString).pathExtension, name)
        }
    }

    func testWebPIsCopiedByteForByte() throws {
        try XCTSkipIf(ImageFixtures.frameCount(of: ImageFixtures.webp) == 0, "this system's ImageIO does not read WebP")
        let folder = try makeFolder()
        let result = try prepare(.pasted(ImageFixtures.webp), in: folder)
        XCTAssertEqual(result.fileURL.pathExtension, "webp")
        XCTAssertEqual(try Data(contentsOf: result.fileURL), ImageFixtures.webp)
    }

    func testTIFFAndBMPBecomePNG() throws {
        for (label, data) in [("tiff", ImageFixtures.tiff()), ("bmp", ImageFixtures.bmp())] {
            let folder = try makeFolder()
            let result = try prepare(.pasted(data), in: folder)
            XCTAssertEqual(result.fileURL.pathExtension, "png", label)
            XCTAssertEqual(ImageFormat.sniff(Array(try Data(contentsOf: result.fileURL).prefix(64))), .png, label)
            XCTAssertEqual(ImageFixtures.properties(of: try Data(contentsOf: result.fileURL))[kCGImagePropertyPixelWidth] as? Int, 40, label)
        }
    }

    func testHEICBecomesJPEG() throws {
        let heic = try XCTUnwrap(ImageFixtures.heic(), "this system has no HEIC encoder")
        let folder = try makeFolder()
        let result = try prepare(.pasted(heic), in: folder)
        XCTAssertEqual(result.fileURL.pathExtension, "jpg")
        XCTAssertEqual(ImageFormat.sniff(Array(try Data(contentsOf: result.fileURL).prefix(64))), .jpeg)
    }

    func testAPNGNamedJpgIsSavedAsPNG() throws {
        let folder = try makeFolder()
        let outside = try makeFolder("Elsewhere")
        let url = try write(ImageFixtures.png(), as: "photo.jpg", in: outside)
        let result = try prepare(.file(url), in: folder)
        XCTAssertEqual(result.fileName, "photo.png", "the bytes decide, not the name")
    }

    func testAnAnimatedGIFKeepsItsFrames() throws {
        let folder = try makeFolder()
        let gif = ImageFixtures.gif(frames: 4)
        let result = try prepare(.pasted(gif), in: folder)
        XCTAssertEqual(ImageFixtures.frameCount(of: try Data(contentsOf: result.fileURL)), 4)
        XCTAssertEqual(try Data(contentsOf: result.fileURL), gif)
    }

    func testThingsThatAreNotImagesAreRefused() throws {
        let cases: [(String, Data)] = [
            ("text", Data("hello world, this is not an image".utf8)),
            ("empty", Data()),
            ("random", Data((0..<500).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })),
            ("pdf", ImageFixtures.pdf()),
            ("png header, no body", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])),
            ("html with svg", Data("<html><body><svg/></body></html>".utf8)),
        ]
        for (label, data) in cases {
            let folder = try makeFolder()
            assertFails(.notAnImage("Pasted image")) { try prepare(.pasted(data), in: folder) }
            XCTAssertEqual(names(in: folder), [], "\(label): nothing was created")
        }
    }

    func testAFolderAndAMissingFileAreRefused() throws {
        let folder = try makeFolder()
        let outside = try makeFolder("Elsewhere")
        assertFails(.notAnImage("Elsewhere")) { try prepare(.file(outside), in: folder) }
        assertFails(.unreadable("nope.png")) { try prepare(.file(outside.appendingPathComponent("nope.png")), in: folder) }
        XCTAssertEqual(names(in: folder), [])
    }

    // MARK: Names of dropped files (R9)

    func testADroppedFileKeepsItsNameMadeSafe() throws {
        let folder = try makeFolder()
        let outside = try makeFolder("Elsewhere")
        let url = try write(ImageFixtures.png(), as: "My Photo (1).PNG", in: outside)
        XCTAssertEqual(try prepare(.file(url), in: folder).fileName, "My-Photo-1-.png")
    }

    func testTheSameFileDroppedTwiceGetsANumberAndIsNotReused() throws {
        let folder = try makeFolder()
        let outside = try makeFolder("Elsewhere")
        let url = try write(ImageFixtures.png(), as: "a.png", in: outside)
        XCTAssertEqual(try prepare(.file(url), in: folder).fileName, "a.png")
        XCTAssertEqual(try prepare(.file(url), in: folder).fileName, "a-2.png", "identical bytes are not detected or reused")
        XCTAssertEqual(try prepare(.file(url), in: folder).fileName, "a-3.png")
    }

    // MARK: Never overwrite (R8)

    func testATakenNameIsNeverOverwritten() throws {
        let folder = try makeFolder()
        let assets = folder.appendingPathComponent("assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let sentinel = Data("SENTINEL".utf8)
        try sentinel.write(to: assets.appendingPathComponent("image-20261013-094112.png"))
        let result = try prepare(.pasted(ImageFixtures.png()), in: folder)
        XCTAssertEqual(result.fileName, "image-20261013-094112-2.png")
        XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent("image-20261013-094112.png")), sentinel, "the existing file is untouched")
    }

    func testTwoPastesInTheSameSecondGetDistinctNames() throws {
        let folder = try makeFolder()
        let a = try prepare(.pasted(ImageFixtures.png(width: 10, height: 10)), in: folder)
        let b = try prepare(.pasted(ImageFixtures.png(width: 11, height: 11)), in: folder)
        XCTAssertEqual([a.fileName, b.fileName], ["image-20261013-094112.png", "image-20261013-094112-2.png"])
    }

    func testWritersRacingForTheSameNameAllGetTheirOwnFile() throws {
        let folder = try makeFolder()
        let count = 8
        let inputs = (0..<count).map { ImageFixtures.png(width: 10 + $0, height: 10) }
        let lock = NSLock()
        var results: [PreparedImage] = []
        var failures: [Error] = []
        let now = self.now, utc = self.utc
        DispatchQueue.concurrentPerform(iterations: count) { i in
            do {
                let r = try ImageIntake.prepare(.pasted(inputs[i]), documentFolder: folder, now: now, timeZone: utc)
                lock.lock(); results.append(r); lock.unlock()
            } catch {
                lock.lock(); failures.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(Set(results.map(\.fileName)).count, count, "eight different names")
        let written = try names(in: folder.appendingPathComponent("assets")).map { try Data(contentsOf: folder.appendingPathComponent("assets/\($0)")) }
        XCTAssertEqual(Set(written), Set(inputs), "every input survives in some file; none overwrote another")
    }

    // MARK: The images folder (R7)

    func testTheFolderIsCreatedOnFirstUseAndReused() throws {
        let folder = try makeFolder()
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("assets").path))
        _ = try prepare(.pasted(ImageFixtures.png()), in: folder)
        var isFolder: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("assets").path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
        _ = try prepare(.pasted(ImageFixtures.png()), in: folder)
        XCTAssertEqual(names(in: folder), ["assets"])
        XCTAssertEqual(names(in: folder.appendingPathComponent("assets")).count, 2)
    }

    func testASymbolicLinkToAFolderCountsAsTheFolder() throws {
        let folder = try makeFolder()
        let target = try makeFolder("Shared")
        try fm.createSymbolicLink(at: folder.appendingPathComponent("assets"), withDestinationURL: target)
        let result = try prepare(.pasted(ImageFixtures.png()), in: folder)
        XCTAssertEqual(result.linkPath, ["assets", "image-20261013-094112.png"])
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("image-20261013-094112.png").path), "it landed in the link's target")
    }

    func testAFileCalledAssetsIsAFailureAndIsLeftAlone() throws {
        let folder = try makeFolder()
        let blocker = Data("not a folder".utf8)
        try blocker.write(to: folder.appendingPathComponent("assets"))
        assertFails(.assetsIsNotAFolder(folder: "Notes")) { try prepare(.pasted(ImageFixtures.png()), in: folder) }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("assets")), blocker)
    }

    func testABrokenSymbolicLinkCalledAssetsIsAFailure() throws {
        let folder = try makeFolder()
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("assets").path, withDestinationPath: "/nonexistent/place")
        assertFails(.assetsIsNotAFolder(folder: "Notes")) { try prepare(.pasted(ImageFixtures.png()), in: folder) }
    }

    func testAReadOnlyDocumentFolderCannotGetAnAssetsFolder() throws {
        let folder = try makeFolder()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        assertFails(.cannotCreateAssets(folder: "Notes", reason: "the folder is read-only")) { try prepare(.pasted(ImageFixtures.png()), in: folder) }
        XCTAssertEqual(names(in: folder), [])
    }

    func testAReadOnlyAssetsFolderCannotTakeAFile() throws {
        let folder = try makeFolder()
        let assets = folder.appendingPathComponent("assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: assets.path)
        assertFails(.cannotWrite(file: "image-20261013-094112.png", reason: "the folder is read-only")) { try prepare(.pasted(ImageFixtures.png()), in: folder) }
        XCTAssertEqual(names(in: assets), [], "no partial file")
    }

    // MARK: Size (R14)

    func testAnOverCapPNGIsScaledToFitTheRealLimit() throws {
        let folder = try makeFolder()
        let big = ImageFixtures.png(width: 2400, height: 2400, noise: true)
        try XCTSkipIf(big.count <= ImageLoader.maxEmbeddedBytes, "the fixture did not come out over the cap (\(big.count) bytes)")
        let result = try prepare(.pasted(big), in: folder)
        let saved = try Data(contentsOf: result.fileURL)
        XCTAssertLessThanOrEqual(saved.count, ImageLoader.maxEmbeddedBytes)
        XCTAssertEqual(result.fileURL.pathExtension, "png", "same format")
        guard case .scaled(let from, let to)? = result.notes.first else { return XCTFail("a scaled note, got \(result.notes)") }
        XCTAssertEqual(from, PixelSize(width: 2400, height: 2400))
        XCTAssertLessThan(to.longEdge, 2400)
        XCTAssertEqual(Double(to.width) / Double(to.height), 1, accuracy: 0.01, "aspect ratio kept")
        XCTAssertEqual(ImageFixtures.properties(of: saved)[kCGImagePropertyPixelWidth] as? Int, to.width)
    }

    func testAnOverCapJPEGIsScaledAndStaysAJPEG() throws {
        let folder = try makeFolder()
        let big = ImageFixtures.jpeg(width: 800, height: 400, noise: true, quality: 1.0)
        let cap = big.count / 3
        let result = try prepare(.pasted(big), in: folder, maxBytes: cap)
        let saved = try Data(contentsOf: result.fileURL)
        XCTAssertLessThanOrEqual(saved.count, cap)
        XCTAssertEqual(ImageFormat.sniff(Array(saved.prefix(64))), .jpeg)
        guard case .scaled(let from, let to)? = result.notes.first else { return XCTFail("a scaled note, got \(result.notes)") }
        XCTAssertEqual(from, PixelSize(width: 800, height: 400))
        XCTAssertEqual(Double(to.width) / Double(to.height), 2, accuracy: 0.05)
    }

    func testAnOverCapTIFFBecomesAPNGThatFits() throws {
        let folder = try makeFolder()
        let tiff = try XCTUnwrap(ImageFixtures.data(ImageFixtures.cgImage(width: 700, height: 500, noise: true), as: .tiff))
        let result = try prepare(.pasted(tiff), in: folder, maxBytes: 300_000)
        XCTAssertEqual(result.fileURL.pathExtension, "png")
        XCTAssertLessThanOrEqual(try Data(contentsOf: result.fileURL).count, 300_000)
        XCTAssertFalse(result.notes.isEmpty)
    }

    func testAnImageThatCannotBeMadeSmallEnoughFailsAtThe320Floor() throws {
        let folder = try makeFolder()
        let noisy = ImageFixtures.png(width: 700, height: 700, noise: true)
        assertFails(.cannotShrink("Pasted image")) { try prepare(.pasted(noisy), in: folder, maxBytes: 1_000) }
        XCTAssertEqual(names(in: folder), [], "nothing created")
    }

    func testASmallImageThatIsStillOverTheCapFails() throws {
        let folder = try makeFolder()
        assertFails(.cannotShrink("Pasted image")) { try prepare(.pasted(ImageFixtures.png(width: 200, height: 200, noise: true)), in: folder, maxBytes: 1_000) }
    }

    func testAnOversizeAnimatedGIFIsCopiedAndSaysSo() throws {
        let folder = try makeFolder()
        let gif = ImageFixtures.gif(frames: 4)
        let result = try prepare(.pasted(gif), in: folder, maxBytes: gif.count / 2)
        XCTAssertEqual(result.notes, [.tooBigToPreview])
        XCTAssertEqual(try Data(contentsOf: result.fileURL), gif)
        XCTAssertEqual(ImageFixtures.frameCount(of: try Data(contentsOf: result.fileURL)), 4)
    }

    func testAnOversizeStillGIFAndSVGAreCopiedToo() throws {
        let still = ImageFixtures.gif(frames: 1)
        let svg = ImageFixtures.svg(padding: 5_000)
        for (label, data, cap) in [("gif", still, still.count / 2), ("svg", svg, 1_000)] {
            let folder = try makeFolder()
            let result = try prepare(.pasted(data), in: folder, maxBytes: cap)
            XCTAssertEqual(result.notes, [.tooBigToPreview], label)
            XCTAssertEqual(try Data(contentsOf: result.fileURL), data, label)
        }
    }

    func testAnOversizeAnimatedPNGIsCopiedNotFlattened() throws {
        let apng = ImageFixtures.apng(width: 120, height: 120, frames: 3, noise: true)
        XCTAssertGreaterThan(ImageFixtures.frameCount(of: apng), 1, "ImageIO sees the frames of the fixture")
        let folder = try makeFolder()
        let result = try prepare(.pasted(apng), in: folder, maxBytes: apng.count / 2)
        XCTAssertEqual(result.notes, [.tooBigToPreview])
        XCTAssertEqual(try Data(contentsOf: result.fileURL), apng, "frames kept: the bytes are the source's")
    }

    func testTheIntakeLimits() throws {
        let folder = try makeFolder()
        let png = ImageFixtures.png(width: 100, height: 100)
        assertFails(.tooLarge("Pasted image")) { try prepare(.pasted(png), in: folder, maxSourceBytes: png.count - 1) }
        assertFails(.tooManyPixels("Pasted image")) { try prepare(.pasted(png), in: folder, maxPixels: 9_999) }
        XCTAssertNoThrow(try prepare(.pasted(png), in: folder, maxSourceBytes: png.count, maxPixels: 10_000))
        // A file is refused by its size before it is read.
        let outside = try makeFolder("Elsewhere")
        let url = try write(png, as: "big.png", in: outside)
        assertFails(.tooLarge("big.png")) { try prepare(.file(url), in: folder, maxSourceBytes: png.count - 1) }
        XCTAssertEqual(names(in: folder).filter { $0 != "assets" }, [])
    }

    func testTheDefaultLimitsAreTheSpecsNumbers() throws {
        // A sparse file over 100 MB is refused without being read.
        let outside = try makeFolder("Elsewhere")
        let url = outside.appendingPathComponent("huge.tif")
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ImageLimits.maxSourceBytes + 1))
        try handle.close()
        let folder = try makeFolder()
        assertFails(.tooLarge("huge.tif")) { try ImageIntake.prepare(.file(url), documentFolder: folder, now: now) }
        XCTAssertEqual(ImageLimits.maxSourceBytes, 100_000_000)
        XCTAssertEqual(ImageLimits.maxPixels, 200_000_000)
        XCTAssertEqual(ImageLoader.maxEmbeddedBytes, 8_000_000)
    }

    // MARK: Metadata (R13)

    func testAKeptPhotoIsAByteIdenticalCopyWithItsLocation() throws {
        let folder = try makeFolder()
        let photo = ImageFixtures.jpeg(properties: ImageFixtures.photoMetadata)
        let result = try prepare(.pasted(photo), in: folder)
        XCTAssertEqual(try Data(contentsOf: result.fileURL), photo)
        XCTAssertNotNil(ImageFixtures.properties(of: try Data(contentsOf: result.fileURL))[kCGImagePropertyGPSDictionary], "the location is kept")
    }

    func testAScaledPhotoCarriesItsMetadataOver() throws {
        let folder = try makeFolder()
        let photo = ImageFixtures.jpeg(width: 800, height: 600, noise: true, quality: 1.0, properties: ImageFixtures.photoMetadata)
        let result = try prepare(.pasted(photo), in: folder, maxBytes: photo.count / 3)
        XCTAssertFalse(result.notes.isEmpty)
        let properties = ImageFixtures.properties(of: try Data(contentsOf: result.fileURL))
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], "GPS survives scaling")
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitude] as? Double ?? 0, 51.5, accuracy: 0.001)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W")
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any], "EXIF survives scaling")
        XCTAssertNotNil(exif[kCGImagePropertyExifUserComment])
        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Cameraco")
    }

    func testNothingIsAddedToAPhotoWithoutLocation() throws {
        let folder = try makeFolder()
        let photo = ImageFixtures.jpeg(width: 800, height: 600, noise: true, quality: 1.0,
                                       properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Cameraco"]])
        let result = try prepare(.pasted(photo), in: folder, maxBytes: photo.count / 3)
        let properties = ImageFixtures.properties(of: try Data(contentsOf: result.fileURL))
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no location appears")
    }

    func testAConvertedHEICCarriesItsMetadataOver() throws {
        let heic = try XCTUnwrap(ImageFixtures.heic(properties: ImageFixtures.photoMetadata), "this system has no HEIC encoder")
        let folder = try makeFolder()
        let result = try prepare(.pasted(heic), in: folder)
        let properties = ImageFixtures.properties(of: try Data(contentsOf: result.fileURL))
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary], "the location is kept through the conversion")
    }

    func testARotatedPhotoKeepsItsLookWhenItIsScaled() throws {
        let folder = try makeFolder()
        // Stored landscape (600 × 300) and marked "rotate 90° clockwise": shown as 300 × 600, portrait.
        let photo = ImageFixtures.jpeg(width: 600, height: 300, noise: true, quality: 1.0, properties: [kCGImagePropertyOrientation: 6])
        XCTAssertEqual(ImageFixtures.properties(of: photo)[kCGImagePropertyOrientation] as? Int, 6)
        let result = try prepare(.pasted(photo), in: folder, maxBytes: photo.count / 3)
        guard case .scaled(let from, let to)? = result.notes.first else { return XCTFail("a scaled note, got \(result.notes)") }
        XCTAssertEqual(from, PixelSize(width: 300, height: 600), "the note speaks of the picture as shown")
        XCTAssertLessThan(to.width, to.height)
        let properties = ImageFixtures.properties(of: try Data(contentsOf: result.fileURL))
        XCTAssertLessThan(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
                          "the pixels are portrait now")
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? Int) ?? 1, 1, "so it is not turned a second time")
    }

    // MARK: Files already in the document's folder (R15)

    func testAFileInsideTheFolderIsLinkedWhereItIsAndNothingIsWritten() throws {
        let folder = try makeFolder()
        let url = try write(ImageFixtures.png(), as: "photos/a.png", in: folder)
        let result = try prepare(.file(url), in: folder)
        XCTAssertFalse(result.wroteFile)
        XCTAssertEqual(result.link, "![](photos/a.png)")
        XCTAssertEqual(names(in: folder), ["photos"], "no assets folder, no copy")
        XCTAssertEqual(names(in: folder.appendingPathComponent("photos")), ["a.png"])
    }

    func testAFileInTheSameFolderAsTheDocument() throws {
        let folder = try makeFolder()
        let url = try write(ImageFixtures.png(), as: "a.png", in: folder)
        XCTAssertEqual(try prepare(.file(url), in: folder).link, "![](a.png)")
    }

    func testAFileAlreadyInAssetsIsLinkedAndNotCopied() throws {
        let folder = try makeFolder()
        let url = try write(ImageFixtures.png(), as: "assets/a.png", in: folder)
        let result = try prepare(.file(url), in: folder)
        XCTAssertFalse(result.wroteFile)
        XCTAssertEqual(result.link, "![](assets/a.png)")
        XCTAssertEqual(names(in: folder.appendingPathComponent("assets")), ["a.png"])
    }

    func testTheLinkInPlaceIsEncodedAndResolvesBack() throws {
        let folder = try makeFolder()
        for relative in ["My Photos/a b (1).png", "x#y/z?w%20.png", "é/日本.png"] {
            let url = try write(ImageFixtures.png(), as: relative, in: folder)
            let result = try prepare(.file(url), in: folder)
            XCTAssertFalse(result.wroteFile, relative)
            let destination = String(result.link.dropFirst(4).dropLast())
            let resolved = try XCTUnwrap(ImageLoader.fileURL(for: destination, base: folder), relative)
            XCTAssertEqual(ImageIntake.canonical(resolved), ImageIntake.canonical(url), "\(relative) via \(destination)")
        }
    }

    func testAFileOutsideTheFolderIsCopiedIn() throws {
        let folder = try makeFolder()
        let outside = try makeFolder("Elsewhere")
        let url = try write(ImageFixtures.png(), as: "a.png", in: outside)
        let result = try prepare(.file(url), in: folder)
        XCTAssertTrue(result.wroteFile)
        XCTAssertEqual(result.link, "![](assets/a.png)")
        XCTAssertTrue(fm.fileExists(atPath: url.path), "the original stays")
    }

    func testASiblingFolderWithTheSamePrefixIsOutside() throws {
        let root = try makeFolder("Docs").deletingLastPathComponent()
        let docs = root.appendingPathComponent("Docs")
        let sibling = root.appendingPathComponent("Docs2")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let url = try write(ImageFixtures.png(), as: "a.png", in: sibling)
        let result = try prepare(.file(url), in: docs)
        XCTAssertTrue(result.wroteFile, "/Docs2 is not inside /Docs")
        XCTAssertEqual(result.link, "![](assets/a.png)")
    }

    func testASymbolicLinkInTheTreeThatLeavesItIsCopied() throws {
        let folder = try makeFolder()
        let outside = try makeFolder("Elsewhere")
        let target = try write(ImageFixtures.png(), as: "real.png", in: outside)
        let link = folder.appendingPathComponent("shortcut.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try prepare(.file(link), in: folder)
        XCTAssertTrue(result.wroteFile, "its real path is outside the tree")
        XCTAssertEqual(result.link, "![](assets/shortcut.png)")
        XCTAssertEqual(try Data(contentsOf: result.fileURL), try Data(contentsOf: target))
    }

    func testASymbolicLinkInTheTreeThatStaysInsideIsLinkedAtItsRealPlace() throws {
        let folder = try makeFolder()
        _ = try write(ImageFixtures.png(), as: "real/a.png", in: folder)
        let link = folder.appendingPathComponent("alias.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("real/a.png"))
        let result = try prepare(.file(link), in: folder)
        XCTAssertFalse(result.wroteFile)
    }

    func testAFileInTheTreeThatNeedsConvertingIsSavedToAssetsAndTheOriginalIsUntouched() throws {
        let folder = try makeFolder()
        let tiff = ImageFixtures.tiff()
        let url = try write(tiff, as: "scan.tif", in: folder)
        let result = try prepare(.file(url), in: folder)
        XCTAssertTrue(result.wroteFile)
        XCTAssertEqual(result.link, "![](assets/scan.png)")
        XCTAssertEqual(try Data(contentsOf: url), tiff)
    }

    func testAFileInTheTreeThatIsTooBigIsShrunkIntoAssetsAndTheOriginalIsUntouched() throws {
        let folder = try makeFolder()
        let big = ImageFixtures.png(width: 600, height: 600, noise: true)
        let url = try write(big, as: "big.png", in: folder)
        let result = try prepare(.file(url), in: folder, maxBytes: big.count / 2)
        XCTAssertTrue(result.wroteFile)
        XCTAssertEqual(result.link, "![](assets/big.png)")
        XCTAssertLessThanOrEqual(try Data(contentsOf: result.fileURL).count, big.count / 2)
        XCTAssertEqual(try Data(contentsOf: url), big)
    }
}
