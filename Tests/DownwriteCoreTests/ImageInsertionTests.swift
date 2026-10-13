import XCTest
@testable import DownwriteCore

// MARK: - Step 1: formats and limits

final class ImageFormatTests: XCTestCase {
    private func bytes(_ values: [UInt8], padTo count: Int = 32) -> [UInt8] {
        values + [UInt8](repeating: 0, count: max(0, count - values.count))
    }

    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testPNG() {
        XCTAssertEqual(ImageFormat.sniff(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), .png)
        XCTAssertNil(ImageFormat.sniff(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0B])), "the signature is eight bytes")
    }

    func testJPEG() {
        XCTAssertEqual(ImageFormat.sniff(bytes([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(ImageFormat.sniff(bytes([0xFF, 0xD8, 0xFF, 0xE1])), .jpeg)
        XCTAssertNil(ImageFormat.sniff(bytes([0xFF, 0xD8, 0x00])))
    }

    func testGIF() {
        XCTAssertEqual(ImageFormat.sniff(ascii("GIF89a") + [1, 0, 1, 0]), .gif)
        XCTAssertEqual(ImageFormat.sniff(ascii("GIF87a") + [1, 0, 1, 0]), .gif)
        XCTAssertNil(ImageFormat.sniff(ascii("GIF90a") + [1, 0, 1, 0]))
    }

    func testWebP() {
        XCTAssertEqual(ImageFormat.sniff(ascii("RIFF") + [0x24, 0, 0, 0] + ascii("WEBPVP8 ")), .webp)
        XCTAssertNil(ImageFormat.sniff(ascii("RIFF") + [0x24, 0, 0, 0] + ascii("WAVEfmt ")), "RIFF alone is not WebP")
    }

    func testHEICAndHEIF() {
        for brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"] {
            XCTAssertEqual(ImageFormat.sniff([0, 0, 0, 0x18] + ascii("ftyp" + brand) + [0, 0, 0, 0]), .heic, brand)
        }
        XCTAssertNil(ImageFormat.sniff([0, 0, 0, 0x18] + ascii("ftypmp42") + [0, 0, 0, 0]), "a video is not an image")
        XCTAssertNil(ImageFormat.sniff([0, 0, 0, 0x18] + ascii("ftypavif") + [0, 0, 0, 0]), "left to ImageIO, which names it .other")
    }

    func testTIFFInBothByteOrders() {
        XCTAssertEqual(ImageFormat.sniff(bytes([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])), .tiff)
        XCTAssertEqual(ImageFormat.sniff(bytes([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8])), .tiff)
        XCTAssertNil(ImageFormat.sniff(bytes([0x49, 0x49, 0x2A, 0x01])))
    }

    func testBMPNeedsAPlausibleHeader() {
        var bmp = ascii("BM") + [UInt8](repeating: 0, count: 12)
        bmp += [40, 0, 0, 0]                                     // BITMAPINFOHEADER size at offset 14
        bmp += [UInt8](repeating: 0, count: 20)
        XCTAssertEqual(ImageFormat.sniff(bmp), .bmp)
        XCTAssertNil(ImageFormat.sniff(ascii("BMW is a car maker, and this text is longer than a header")), "two letters are not a signature")
        XCTAssertNil(ImageFormat.sniff(ascii("BM")))
    }

    func testPlainSVG() {
        XCTAssertEqual(ImageFormat.sniff(ascii("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>")), .svg)
        XCTAssertEqual(ImageFormat.sniff(ascii("<svg>\n</svg>")), .svg)
        XCTAssertEqual(ImageFormat.sniff(ascii("  \n\t<svg/>")), .svg, "leading whitespace")
    }

    func testSVGWithPrologDoctypeBOMAndComments() {
        let prolog = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg width=\"1\"/>"
        XCTAssertEqual(ImageFormat.sniff(ascii(prolog)), .svg)
        XCTAssertEqual(ImageFormat.sniff([0xEF, 0xBB, 0xBF] + ascii(prolog)), .svg, "a UTF-8 byte order mark")
        XCTAssertEqual(ImageFormat.sniff(ascii("<!-- made by hand -->\n<svg/>")), .svg)
        XCTAssertEqual(ImageFormat.sniff(ascii("<?xml version=\"1.0\"?>\n<!-- a > b -->\n<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x.dtd\">\n<svg/>")), .svg)
        XCTAssertEqual(ImageFormat.sniff(ascii("<!DOCTYPE svg [ <!ENTITY a \"b\"> ]>\n<svg/>")), .svg, "an internal subset")
    }

    func testSVGMustBeTheRootElement() {
        XCTAssertNil(ImageFormat.sniff(ascii("<html><body><svg/></body></html>")), "inline SVG in a page is a page")
        XCTAssertNil(ImageFormat.sniff(ascii("<svgfoo/>")), "the element name is svg, not a prefix of one")
        XCTAssertNil(ImageFormat.sniff(ascii("<!-- never closed <svg/>")))
        XCTAssertNil(ImageFormat.sniff(ascii("hello <svg/>")))
    }

    func testBytesThatAreNoneOfThem() {
        XCTAssertNil(ImageFormat.sniff([]))
        XCTAssertNil(ImageFormat.sniff([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31]), "a PDF is not an image here")
        XCTAssertNil(ImageFormat.sniff(ascii("just some text")))
        XCTAssertNil(ImageFormat.sniff([0x00]))
    }

    func testTheNameNeverMattersOnlyTheBytes() {
        // The sniffer has no name parameter; a PNG's bytes are PNG whatever the file is called.
        XCTAssertEqual(ImageFormat.sniff([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]), .png)
    }

    func testWhatEachFormatIsSavedAs() {
        XCTAssertTrue(ImageFormat.png.saved.keepsBytes)
        for kept in [ImageFormat.png, .jpeg, .gif, .webp, .svg] {
            XCTAssertEqual(kept.saved.format, kept)
            XCTAssertTrue(kept.saved.keepsBytes, "\(kept) is copied byte for byte")
        }
        XCTAssertEqual(ImageFormat.tiff.saved.format, .png)
        XCTAssertEqual(ImageFormat.bmp.saved.format, .png)
        XCTAssertEqual(ImageFormat.other.saved.format, .png)
        XCTAssertEqual(ImageFormat.heic.saved.format, .jpeg)
        for converted in [ImageFormat.tiff, .bmp, .other, .heic] {
            XCTAssertFalse(converted.saved.keepsBytes, "\(converted) is converted")
        }
    }

    func testCanonicalExtensions() {
        XCTAssertEqual(ImageFormat.png.fileExtension, "png")
        XCTAssertEqual(ImageFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ImageFormat.gif.fileExtension, "gif")
        XCTAssertEqual(ImageFormat.webp.fileExtension, "webp")
        XCTAssertEqual(ImageFormat.svg.fileExtension, "svg")
        // What gets written is always one of the five.
        for any in [ImageFormat.png, .jpeg, .gif, .webp, .svg, .tiff, .heic, .bmp, .other] {
            XCTAssertTrue(["png", "jpg", "gif", "webp", "svg"].contains(any.saved.format.fileExtension), "\(any)")
        }
    }

    func testLimitsAreTheSpecsNumbers() {
        XCTAssertEqual(ImageLimits.maxSourceBytes, 100_000_000)
        XCTAssertEqual(ImageLimits.maxPixels, 200_000_000)
        XCTAssertEqual(ImageLimits.minLongEdge, 320)
    }

    func testImageFileExtensionsKnownToThePasteRule() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "svg", "tif", "tiff", "heic", "heif", "bmp"] {
            XCTAssertTrue(ImageFormat.isImageFileExtension(ext), ext)
            XCTAssertTrue(ImageFormat.isImageFileExtension(ext.uppercased()), ext.uppercased())
        }
        XCTAssertFalse(ImageFormat.isImageFileExtension("pdf"))
        XCTAssertFalse(ImageFormat.isImageFileExtension("md"))
        XCTAssertFalse(ImageFormat.isImageFileExtension(""))
    }
}

// MARK: - Step 2: names

final class ImageNamingTests: XCTestCase {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, in zone: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    // MARK: pasted

    func testPastedNameIsPaddedLocalTime() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ImageNaming.pastedName(at: date(2026, 1, 2, 3, 4, 5, in: "UTC"), timeZone: utc, fileExtension: "png"),
                       "image-20260102-030405.png")
        XCTAssertEqual(ImageNaming.pastedName(at: date(2026, 10, 13, 9, 41, 12, in: "UTC"), timeZone: utc, fileExtension: "png"),
                       "image-20261013-094112.png")
        XCTAssertEqual(ImageNaming.pastedName(at: date(2026, 12, 31, 23, 59, 59, in: "UTC"), timeZone: utc, fileExtension: "jpg"),
                       "image-20261231-235959.jpg")
        XCTAssertEqual(ImageNaming.pastedName(at: date(2026, 1, 1, 0, 0, 0, in: "UTC"), timeZone: utc, fileExtension: "gif"),
                       "image-20260101-000000.gif", "midnight is all zeros")
    }

    func testPastedNameUsesTheGivenTimeZoneNotTheMachines() {
        let instant = date(2026, 10, 13, 23, 30, 0, in: "UTC")
        XCTAssertEqual(ImageNaming.pastedName(at: instant, timeZone: TimeZone(identifier: "UTC")!, fileExtension: "png"),
                       "image-20261013-233000.png")
        // Sydney is on daylight time (UTC+11) from 4 October 2026, so the same instant is already the next day there.
        XCTAssertEqual(ImageNaming.pastedName(at: instant, timeZone: TimeZone(identifier: "Australia/Sydney")!, fileExtension: "png"),
                       "image-20261014-103000.png")
        XCTAssertEqual(ImageNaming.pastedName(at: instant, timeZone: TimeZone(identifier: "America/New_York")!, fileExtension: "png"),
                       "image-20261013-193000.png")
    }

    func testPastedNameLowercasesTheExtension() {
        XCTAssertTrue(ImageNaming.pastedName(at: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, fileExtension: "PNG").hasSuffix(".png"))
    }

    // MARK: dropped

    func testASafeNameIsKept() {
        XCTAssertEqual(ImageNaming.droppedName(stem: "photo", fileExtension: "png"), "photo.png")
        XCTAssertEqual(ImageNaming.droppedName(stem: "My_photo-2", fileExtension: "jpg"), "My_photo-2.jpg")
        XCTAssertEqual(ImageNaming.droppedName(stem: "archive.v2", fileExtension: "gif"), "archive.v2.gif", "a dot inside the stem stays")
    }

    func testEveryCharacterThatIsNotSafeBecomesADash() {
        let cases: [(String, String)] = [
            ("my photo", "my-photo"),
            ("a/b", "a-b"), ("a:b", "a-b"), ("a(b)c", "a-b-c"), ("a[b]c", "a-b-c"),
            ("a#b", "a-b"), ("a?b", "a-b"), ("a%b", "a-b"), ("a&b", "a-b"),
            ("a\"b", "a-b"), ("a'b", "a-b"), ("a\\b", "a-b"), ("a*b", "a-b"), ("a|b", "a-b"), ("a<b>c", "a-b-c"),
            ("a\u{0}b", "a-b"), ("a\nb", "a-b"), ("a\tb", "a-b"), ("a\u{7F}b", "a-b"),
            ("photo (1)", "photo-1-"),
            ("🙂smile🙂", "smile-"),
            ("a\u{00A0}b", "a-b"), ("a\u{2028}b", "a-b"),
        ]
        for (stem, expected) in cases {
            XCTAssertEqual(ImageNaming.droppedName(stem: stem, fileExtension: "png"), expected + ".png", "stem \(stem.debugDescription)")
        }
    }

    func testRunsOfDashesCollapse() {
        XCTAssertEqual(ImageNaming.droppedName(stem: "a   b", fileExtension: "png"), "a-b.png")
        XCTAssertEqual(ImageNaming.droppedName(stem: "a - b", fileExtension: "png"), "a-b.png")
        XCTAssertEqual(ImageNaming.droppedName(stem: "a---b", fileExtension: "png"), "a-b.png")
        XCTAssertEqual(ImageNaming.droppedName(stem: "a/:?b", fileExtension: "png"), "a-b.png")
    }

    func testLeadingDotsAndDashesAreRemoved() {
        XCTAssertEqual(ImageNaming.droppedName(stem: ".hidden", fileExtension: "png"), "hidden.png")
        XCTAssertEqual(ImageNaming.droppedName(stem: "..", fileExtension: "png"), "image.png")
        XCTAssertEqual(ImageNaming.droppedName(stem: "../../etc", fileExtension: "png"), "etc.png", "no path can survive")
        XCTAssertEqual(ImageNaming.droppedName(stem: "-rf", fileExtension: "png"), "rf.png", "a name must not look like an option")
        XCTAssertEqual(ImageNaming.droppedName(stem: " .-a", fileExtension: "png"), "a.png")
    }

    func testAnEmptyStemBecomesImage() {
        for stem in ["", "   ", "...", "---", "///", "🙂", ".-.-"] {
            XCTAssertEqual(ImageNaming.droppedName(stem: stem, fileExtension: "png"), "image.png", "stem \(stem.debugDescription)")
        }
    }

    func testLettersOfAnyScriptAreKept() {
        for stem in ["日本語", "Привет", "γειά", "café", "ñandú", "שלום", "مرحبا", "한국어", "कि", "ไทย"] {
            XCTAssertEqual(ImageNaming.droppedName(stem: stem, fileExtension: "png"), stem.precomposedStringWithCanonicalMapping + ".png", stem)
        }
        XCTAssertEqual(ImageNaming.droppedName(stem: "٣٤٥", fileExtension: "png"), "٣٤٥.png", "digits of other scripts")
    }

    func testTheNameIsNormalisedToNFC() {
        let decomposed = "cafe\u{0301}"                        // e + combining acute
        let name = ImageNaming.droppedName(stem: decomposed, fileExtension: "png")
        XCTAssertEqual(name, "caf\u{00E9}.png")
        XCTAssertEqual(Array(name.unicodeScalars).count, "caf\u{00E9}.png".unicodeScalars.count, "one scalar for é, not two")
    }

    func testTheStemIsCutToSixtyCharacters() {
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(ImageNaming.droppedName(stem: long, fileExtension: "png"), String(repeating: "a", count: 60) + ".png")
        let exactly = String(repeating: "b", count: 60)
        XCTAssertEqual(ImageNaming.droppedName(stem: exactly, fileExtension: "png"), exactly + ".png")
        let shorter = String(repeating: "c", count: 59)
        XCTAssertEqual(ImageNaming.droppedName(stem: shorter, fileExtension: "png"), shorter + ".png")
    }

    func testTheCutNeverSplitsAScalar() {
        // U+20000 is a letter outside the Basic Multilingual Plane: two UTF-16 units, four UTF-8 bytes.
        let stem = String(repeating: "\u{20000}", count: 70)
        let name = ImageNaming.droppedName(stem: stem, fileExtension: "png")
        XCTAssertEqual(name, String(repeating: "\u{20000}", count: 60) + ".png")
        XCTAssertFalse(name.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertLessThanOrEqual(name.utf8.count, 240 + 4, "the longest possible name stays far below a file system's 255 bytes")
    }

    func testTheCutIsMadeAfterRemovingWhatIsDropped() {
        // Sixty leading dashes do not eat the budget: they are removed first.
        let stem = String(repeating: "-", count: 60) + String(repeating: "x", count: 10)
        XCTAssertEqual(ImageNaming.droppedName(stem: stem, fileExtension: "png"), String(repeating: "x", count: 10) + ".png")
    }

    func testTheExtensionIsLowercased() {
        XCTAssertEqual(ImageNaming.droppedName(stem: "Photo", fileExtension: "PNG"), "Photo.png")
        XCTAssertEqual(ImageNaming.droppedName(stem: "Photo", fileExtension: "Jpg"), "Photo.jpg")
    }

    // MARK: first free

    func testAFreeNameIsKept() {
        XCTAssertEqual(ImageNaming.firstFree("a.png", isTaken: { _ in false }), "a.png")
    }

    func testATakenNameGetsTheNextNumber() {
        XCTAssertEqual(ImageNaming.firstFree("a.png", isTaken: { $0 == "a.png" }), "a-2.png")
        XCTAssertEqual(ImageNaming.firstFree("a.png", isTaken: { ["a.png", "a-2.png"].contains($0) }), "a-3.png")
        XCTAssertEqual(ImageNaming.firstFree("a.png", isTaken: { ["a.png", "a-2.png", "a-3.png", "a-4.png"].contains($0) }), "a-5.png")
    }

    func testTheNumberGoesBeforeTheLastExtensionOnly() {
        XCTAssertEqual(ImageNaming.firstFree("archive.v2.png", isTaken: { $0 == "archive.v2.png" }), "archive.v2-2.png")
    }

    func testANameWithoutAnExtensionGetsTheSuffixAtTheEnd() {
        XCTAssertEqual(ImageNaming.firstFree("image", isTaken: { $0 == "image" }), "image-2")
    }

    func testCandidatesAreTriedInOrderAndNothingIsSkipped() {
        var tried: [String] = []
        let result = ImageNaming.firstFree("a.png", isTaken: { tried.append($0); return tried.count < 4 })
        XCTAssertEqual(tried, ["a.png", "a-2.png", "a-3.png", "a-4.png"])
        XCTAssertEqual(result, "a-4.png")
    }

    func testItGivesUpAfterTheLimit() {
        var calls = 0
        XCTAssertNil(ImageNaming.firstFree("a.png", limit: 50, isTaken: { _ in calls += 1; return true }))
        XCTAssertEqual(calls, 50, "the name itself, then -2 … -50")
        XCTAssertEqual(ImageNaming.firstFree("a.png", limit: 3, isTaken: { ["a.png", "a-2.png"].contains($0) }), "a-3.png")
        XCTAssertNil(ImageNaming.firstFree("a.png", limit: 3, isTaken: { ["a.png", "a-2.png", "a-3.png"].contains($0) }))
        XCTAssertNil(ImageNaming.firstFree("a.png", isTaken: { _ in true }), "the default limit ends too")
    }
}
