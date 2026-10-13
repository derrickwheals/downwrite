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

// MARK: - Step 3: links

final class ImageLinkTests: XCTestCase {
    private func destination(_ markdown: String) -> String {
        XCTAssertTrue(markdown.hasPrefix("![]("), markdown)
        XCTAssertTrue(markdown.hasSuffix(")"), markdown)
        return String(markdown.dropFirst(4).dropLast())
    }

    func testTheSimplestLink() {
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "a.png"]), "![](assets/a.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["a.png"]), "![](a.png)")
        XCTAssertEqual(ImageLink.folderName, "assets")
    }

    func testTheLinkNamedInTheSpecEncodesAsPinned() {
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "a b.png"]), "![](assets/a%20b.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "a(b).png"]), "![](assets/a%28b%29.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "a#b.png"]), "![](assets/a%23b.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "a?b.png"]), "![](assets/a%3Fb.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "a%b.png"]), "![](assets/a%25b.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "café.png"]), "![](assets/café.png)", "letters of any script stay")
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "日本.png"]), "![](assets/日本.png)")
    }

    func testEveryOtherCharacterIsPercentEncodedAsUTF8InUpperCaseHex() {
        let cases: [(String, String)] = [
            ("[", "%5B"), ("]", "%5D"), ("&", "%26"), ("'", "%27"), ("\"", "%22"), ("<", "%3C"), (">", "%3E"),
            ("\\", "%5C"), ("`", "%60"), ("|", "%7C"), ("*", "%2A"), ("+", "%2B"), (",", "%2C"), (";", "%3B"),
            ("=", "%3D"), ("@", "%40"), ("$", "%24"), ("!", "%21"), (":", "%3A"), ("/", "%2F"), ("\n", "%0A"),
            ("\t", "%09"), ("\u{7F}", "%7F"), ("\u{00A0}", "%C2%A0"), ("🙂", "%F0%9F%99%82"), ("\u{20AC}", "%E2%82%AC"),
        ]
        for (character, encoded) in cases {
            XCTAssertEqual(ImageLink.markdown(path: ["a\(character)b.png"]), "![](a\(encoded)b.png)", character.debugDescription)
        }
    }

    func testUnreservedCharactersAndDigitsStay() {
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "a-b_c.d~e1.png"]), "![](assets/a-b_c.d~e1.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "٣٤٥.png"]), "![](assets/٣٤٥.png)", "digits of other scripts")
    }

    func testOneSegmentPerComponent() {
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "sub dir", "a b.png"]), "![](assets/sub%20dir/a%20b.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["Photos", "2026", "x.jpg"]), "![](Photos/2026/x.jpg)")
    }

    func testAnAngleBracketFormIsNeverUsed() {
        for name in ["a b.png", "a(b).png", "a<b>.png", "a b (1) #2.png"] {
            XCTAssertFalse(ImageLink.markdown(path: ["assets", name]).contains("<"), name)
            XCTAssertFalse(ImageLink.markdown(path: ["assets", name]).contains(" "), name)
        }
    }

    func testAFirstComponentStartingWithATildeIsNotTheHomeFolder() {
        // The preview resolves "~…" against the home folder; "./~…" is the document's own folder.
        XCTAssertEqual(ImageLink.markdown(path: ["~notes", "a.png"]), "![](./~notes/a.png)")
        XCTAssertEqual(ImageLink.markdown(path: ["assets", "~a.png"]), "![](assets/~a.png)", "only the first component matters")
    }

    private let nasty = ["a b.png", "a(b).png", "a)b(.png", "a#b.png", "a?b.png", "a%20b.png", "100%.png", "é.png", "日本.png",
                         "a&b.png", "a'b\".png", "a<b>.png", "a b (1) #x ?y %z é 日本.png", "🙂.png", "a\\b.png", "[x].png",
                         "a\u{00A0}b.png", "ünï-cödé_~.1.png"]

    func testDecodingTheLinkGivesTheComponentsBack() throws {
        for name in nasty {
            let dest = destination(ImageLink.markdown(path: ["assets", name]))
            XCTAssertEqual(dest.removingPercentEncoding, "assets/" + name, name)
        }
    }

    func testMarkdownReadsEachLinkAsOneImageWithThatDestination() throws {
        for name in nasty {
            let link = ImageLink.markdown(path: ["assets", name])
            let analysis = MarkdownAnalyzer.analyze(link + "\n")
            XCTAssertEqual(analysis.imageBlocks.count, 1, "\(name): one standalone image, so it previews")
            XCTAssertEqual(analysis.imageBlocks.first?.source, destination(link), "\(name): the parser's source is the encoded path")
            XCTAssertEqual(analysis.imageBlocks.first?.alt, "")
        }
    }

    // MARK: relative path

    func testAFileInsideTheFolder() {
        XCTAssertEqual(ImageLink.relativePath(of: ["Users", "me", "Docs", "assets", "a.png"], in: ["Users", "me", "Docs"]), ["assets", "a.png"])
        XCTAssertEqual(ImageLink.relativePath(of: ["Users", "me", "Docs", "deep", "er", "a.png"], in: ["Users", "me", "Docs"]), ["deep", "er", "a.png"])
    }

    func testAFileInTheSameFolder() {
        XCTAssertEqual(ImageLink.relativePath(of: ["Users", "me", "Docs", "a.png"], in: ["Users", "me", "Docs"]), ["a.png"])
    }

    func testAFileOutsideTheFolder() {
        XCTAssertNil(ImageLink.relativePath(of: ["Users", "me", "Desktop", "a.png"], in: ["Users", "me", "Docs"]))
        XCTAssertNil(ImageLink.relativePath(of: ["Users", "me", "a.png"], in: ["Users", "me", "Docs"]), "a parent's file is outside")
        XCTAssertNil(ImageLink.relativePath(of: ["a.png"], in: ["Users", "me", "Docs"]))
    }

    func testASiblingThatSharesAPrefixIsNotInside() {
        XCTAssertNil(ImageLink.relativePath(of: ["Docs2", "a.png"], in: ["Docs"]), "/Docs2 is not under /Docs")
        XCTAssertNil(ImageLink.relativePath(of: ["Users", "me", "Docs-old", "a.png"], in: ["Users", "me", "Docs"]))
        XCTAssertEqual(ImageLink.relativePath(of: ["Docs", "a.png"], in: ["Docs"]), ["a.png"])
    }

    func testTheFolderItselfIsNotInsideItself() {
        XCTAssertNil(ImageLink.relativePath(of: ["Users", "me", "Docs"], in: ["Users", "me", "Docs"]))
    }

    func testTheRootFolder() {
        XCTAssertEqual(ImageLink.relativePath(of: ["a.png"], in: []), ["a.png"], "everything is inside the root")
    }

    func testCaseMattersAndNormalisationDoesNot() {
        XCTAssertNil(ImageLink.relativePath(of: ["users", "me", "Docs", "a.png"], in: ["Users", "me", "Docs"]), "case differs, so: copy")
        XCTAssertEqual(ImageLink.relativePath(of: ["caf\u{00E9}", "a.png"], in: ["cafe\u{0301}"]), ["a.png"],
                       "é and e + combining accent are one name, as the file system sees it")
    }

    func testUnusableComponentsMeanOutside() {
        XCTAssertNil(ImageLink.relativePath(of: ["Docs", "..", "Other", "a.png"], in: ["Docs"]), "an unresolved .. cannot be trusted")
        XCTAssertNil(ImageLink.relativePath(of: ["Docs", ".", "a.png"], in: ["Docs"]))
        XCTAssertNil(ImageLink.relativePath(of: ["Docs", "", "a.png"], in: ["Docs"]))
        XCTAssertNil(ImageLink.relativePath(of: ["Docs", "a.png"], in: ["Docs", ".."]))
    }

    func testARelativePathFeedsTheSameEncoding() {
        let relative = ImageLink.relativePath(of: ["Docs", "My Photos", "a b.png"], in: ["Docs"])
        XCTAssertEqual(relative.map(ImageLink.markdown(path:)), "![](My%20Photos/a%20b.png)")
    }
}

// MARK: - Step 4: the shrink schedule

final class ImageShrinkTests: XCTestCase {
    private let limit = 8_000_000

    func testTheNextEdgeFollowsTheSquareRootOfTheRatioWithAMargin() {
        // 12 MB at 4000 px: pixels (and roughly bytes) go with the square of the edge, so 4000 × √(8/12) × 0.9.
        XCTAssertEqual(ImageShrink.nextLongEdge(current: 4000, bytes: 12_000_000, limit: limit), 2939)
        // Twice the limit: 3000 × √(1/2) × 0.9.
        XCTAssertEqual(ImageShrink.nextLongEdge(current: 3000, bytes: 16_000_000, limit: limit), 1909)
    }

    func testJustOverTheLimitStillGetsSmaller() {
        let next = ImageShrink.nextLongEdge(current: 3000, bytes: limit + 1, limit: limit)
        XCTAssertNotNil(next)
        XCTAssertLessThan(next!, 3000)
        XCTAssertGreaterThanOrEqual(next!, 2600, "a step of about the margin, not a collapse")
        // Even a one-pixel image of the ratio's limit shrinks by at least a pixel.
        XCTAssertEqual(ImageShrink.nextLongEdge(current: 322, bytes: limit + 1, limit: limit), 320)
    }

    func testAHugeRatioStopsAtTheFloorNotBelowIt() {
        XCTAssertEqual(ImageShrink.nextLongEdge(current: 6000, bytes: 1_000_000_000, limit: limit), 482, "125 times over: 6000 × √(1/125) × 0.9")
        XCTAssertEqual(ImageShrink.nextLongEdge(current: 6000, bytes: 100_000_000_000, limit: limit), ImageLimits.minLongEdge)
        XCTAssertEqual(ImageShrink.nextLongEdge(current: 321, bytes: 9_000_000, limit: limit), 320)
        XCTAssertEqual(ImageShrink.nextLongEdge(current: 400, bytes: 9_000_000, limit: limit), 339)
    }

    func testAtOrBelowTheFloorThereIsNoNextStep() {
        XCTAssertNil(ImageShrink.nextLongEdge(current: 320, bytes: 9_000_000, limit: limit), "320 px was the last try")
        XCTAssertNil(ImageShrink.nextLongEdge(current: 319, bytes: 9_000_000, limit: limit))
        XCTAssertNil(ImageShrink.nextLongEdge(current: 100, bytes: 9_000_000, limit: limit), "a small image that is still too big")
    }

    func testNothingToShrinkIsNotASchedule() {
        XCTAssertNil(ImageShrink.nextLongEdge(current: 4000, bytes: limit, limit: limit), "it already fits")
        XCTAssertNil(ImageShrink.nextLongEdge(current: 4000, bytes: 100, limit: limit))
        XCTAssertNil(ImageShrink.nextLongEdge(current: 4000, bytes: 9_000_000, limit: 0))
        XCTAssertNil(ImageShrink.nextLongEdge(current: 0, bytes: 9_000_000, limit: limit))
        XCTAssertNil(ImageShrink.nextLongEdge(current: -5, bytes: 9_000_000, limit: limit))
    }

    func testEveryStepIsStrictlySmallerAndNeverBelowTheFloor() {
        for current in stride(from: 321, through: 20_000, by: 37) {
            for bytes in [limit + 1, limit + 1000, 8_800_000, 10_000_000, 16_000_000, 100_000_000, 5_000_000_000] {
                let next = ImageShrink.nextLongEdge(current: current, bytes: bytes, limit: limit)
                XCTAssertNotNil(next, "current \(current), bytes \(bytes)")
                if let next {
                    XCTAssertLessThan(next, current, "current \(current), bytes \(bytes)")
                    XCTAssertGreaterThanOrEqual(next, ImageLimits.minLongEdge, "current \(current), bytes \(bytes)")
                }
            }
        }
    }

    /// Walks the schedule the way the encoder does, with `size(edge)` standing in for "encode and measure".
    private func walk(from start: Int, size: (Int) -> Int) -> [Int] {
        var edges = [start]
        var bytes = size(start)
        var guardCount = 0
        while bytes > limit, let next = ImageShrink.nextLongEdge(current: edges.last!, bytes: bytes, limit: limit) {
            edges.append(next)
            bytes = size(next)
            guardCount += 1
            XCTAssertLessThan(guardCount, 200, "the schedule must end")
            if guardCount >= 200 { break }
        }
        return edges
    }

    func testAnImageWhoseSizeFollowsItsPixelsFitsInAFewSteps() {
        // 24 MB at 6000 px, bytes ∝ edge².
        let edges = walk(from: 6000) { Int(24_000_000.0 * pow(Double($0) / 6000.0, 2)) }
        XCTAssertLessThanOrEqual(edges.count, 3, "\(edges)")
        XCTAssertTrue(zip(edges, edges.dropFirst()).allSatisfy { $0 > $1 })
    }

    func testAnImageThatNeverGetsSmallerStillEndsAtTheFloor() {
        let edges = walk(from: 20_000) { _ in 9_000_000 }                   // the encoder keeps returning the same size
        XCTAssertEqual(edges.last, ImageLimits.minLongEdge)
        XCTAssertTrue(zip(edges, edges.dropFirst()).allSatisfy { $0 > $1 }, "\(edges)")
        XCTAssertLessThanOrEqual(edges.count, 60)
    }

    func testAnImageThatShrinksSlowlyStillEnds() {
        // Bytes fall only with the edge itself (not its square): the loop needs more steps but must not stall.
        let edges = walk(from: 12_000) { $0 * 1_000 }
        XCTAssertTrue(zip(edges, edges.dropFirst()).allSatisfy { $0 > $1 }, "\(edges)")
        XCTAssertLessThanOrEqual(edges.count, 60)
    }

    func testNoisyEncodersCannotMakeItGrow() {
        var seed: UInt64 = 12345
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let edges = walk(from: 9000) { _ in 8_000_001 + next() % 40_000_000 }
        XCTAssertTrue(zip(edges, edges.dropFirst()).allSatisfy { $0 > $1 }, "\(edges)")
    }
}

// MARK: - Step 5: image or text?

final class ImagePasteRuleTests: XCTestCase {
    private func content(text: String? = nil, data: Bool = false, files: [String] = [], other: Bool = false) -> PasteboardImageContent {
        PasteboardImageContent(plainText: text, hasImageData: data, imageFileNames: files, hasOtherFiles: other)
    }

    // The named combinations of the spec's verification

    func testAScreenshotHasImageDataAndNoText() {
        XCTAssertTrue(ImagePasteRule.prefersImages(content(data: true)))
    }

    func testSafarisCopyImageCarriesTheImageAndItsURL() {
        XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "https://example.com/images/cat.jpg", data: true)))
        XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "https://example.com/render?id=7&w=200", data: true)),
                      "a URL names the image whether or not it ends in an extension")
    }

    func testAFinderCopyHasAFileAndItsNameAsText() {
        XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "photo.png", files: ["photo.png"])))
        XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "My Holiday Photo.JPEG", files: ["My Holiday Photo.JPEG"])),
                      "a name with spaces is not a URL but ends in an image extension")
    }

    func testSpreadsheetTextWithAnImagePreviewIsText() {
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "Name\tQty\nApples\t3", data: true)))
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "42", data: true)), "a single cell is still text")
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "Total", data: true)))
    }

    func testFilesWithAPDFAreNotAnImagePasteUnlessOneIsAnImage() {
        XCTAssertFalse(ImagePasteRule.prefersImages(content(other: true)), "only a PDF")
        XCTAssertTrue(ImagePasteRule.prefersImages(content(files: ["a.png"], other: true)), "an image among other files")
        XCTAssertTrue(ImagePasteRule.prefersImages(content(files: ["a.png", "b.heic"], other: true)))
    }

    func testNothingAtAll() {
        XCTAssertFalse(ImagePasteRule.prefersImages(content()))
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "just words")))
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "")))
    }

    // The rule's edges

    func testAnyOtherTextBesideAnImageWins() {
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "a caption", data: true)))
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "a caption", files: ["a.png"])))
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "https://example.com/page and more", data: true)),
                       "a space makes it not a URL; it does not end in an image extension either")
    }

    func testTextWithALineBreakIsNeverTheImagesName() {
        for text in ["a.png\nb.png", "https://x.test/a.png\nhttps://x.test/b.png", "line one\r\nphoto.png", "a\u{2028}b.png", "a\u{2029}b.png", "x\u{85}y.png"] {
            XCTAssertFalse(ImagePasteRule.prefersImages(content(text: text, data: true)), text.debugDescription)
        }
    }

    func testSurroundingWhitespaceAndATrailingNewlineDoNotCount() {
        XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "  https://example.com/cat.jpg  ", data: true)))
        XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "photo.png\n", files: ["photo.png"])))
        XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "\n", data: true)), "text that is only white space is no text")
        XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "   ", data: true)))
    }

    func testEveryImageExtensionNamesAnImageInAnyCase() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "svg", "tif", "tiff", "heic", "heif", "bmp"] {
            XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "shot one.\(ext)", data: true)), ext)
            XCTAssertTrue(ImagePasteRule.prefersImages(content(text: "shot one.\(ext.uppercased())", data: true)), ext.uppercased())
        }
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "notes.pdf", data: true)))
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "notes.md", data: true)))
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "png", data: true)), "an extension needs a dot before it")
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "photo.", data: true)))
    }

    func testAnImageIsNeededForImagesToWin() {
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "https://example.com/cat.jpg")), "a bare URL is a URL")
        XCTAssertFalse(ImagePasteRule.prefersImages(content(text: "photo.png")))
    }

    func testTheSummaryIsAPlainValue() {
        XCTAssertEqual(content(text: "a", data: true, files: ["b.png"], other: true),
                       PasteboardImageContent(plainText: "a", hasImageData: true, imageFileNames: ["b.png"], hasOtherFiles: true))
        XCTAssertEqual(PasteboardImageContent(), PasteboardImageContent(plainText: nil, hasImageData: false, imageFileNames: [], hasOtherFiles: false))
    }
}

// MARK: - Step 6: placement

final class ImagePlacementTests: XCTestCase {
    private let link = "![](assets/x.png)"
    private let link2 = "![](assets/y.png)"
    private let link3 = "![](assets/z.png)"

    /// Applies `ImagePlacement.edit` to `marked`, where `|` is the caret and `«…»` marks a selection (both removed before the
    /// edit). Returns the text after the edit with `|` where the caret ends up, or nil when the edit is refused.
    private func place(_ marked: String, links: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) -> String? {
        var text = marked
        var selection = NSRange(location: 0, length: 0)
        if let open = text.firstIndex(of: "«"), let close = text.firstIndex(of: "»"), open < close {
            let start = text[..<open].utf16.count
            let length = text[text.index(after: open)..<close].utf16.count
            text.removeSubrange(close...close)
            text.removeSubrange(open...open)
            selection = NSRange(location: start, length: length)
        } else if let bar = text.firstIndex(of: "|") {
            selection = NSRange(location: text[..<bar].utf16.count, length: 0)
            text.remove(at: bar)
        }
        let analysis = MarkdownAnalyzer.analyze(text)
        guard let edit = ImagePlacement.edit(links: links ?? [link], in: analysis, text: text, selection: selection) else { return nil }
        let applied = edit.apply(to: text)
        let ns = NSString(string: applied)
        XCTAssertLessThanOrEqual(NSMaxRange(edit.selection), ns.length, "the caret is inside the text", file: file, line: line)
        XCTAssertEqual(edit.selection.length, 0, "the caret is a caret", file: file, line: line)
        return ns.replacingCharacters(in: NSRange(location: edit.selection.location, length: 0), with: "|")
    }

    private func assertPlaces(_ before: String, _ after: String, links: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(place(before, links: links, file: file, line: line), after, "from \(before.debugDescription)", file: file, line: line)
    }

    private func assertRefused(_ before: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(place(before, file: file, line: line), "\(before.debugDescription) is refused", file: file, line: line)
    }

    // MARK: the spec's pinned table

    func testEmptyDocument() { assertPlaces("|", "\(link)\n\n|") }
    func testBlankLineBetweenParagraphs() { assertPlaces("A\n|\nB", "A\n\n\(link)\n\n|B") }
    func testStartOfALineWithTextAbove() { assertPlaces("A\n|B", "A\n\n\(link)\n\n|B") }
    func testEndOfTheLastLineWithoutANewline() { assertPlaces("A|", "A\n\n\(link)\n\n|") }
    func testMidLineSplitsTheParagraph() { assertPlaces("Hello |world", "Hello \n\n\(link)\n\n|world") }
    func testASelectionIsReplaced() { assertPlaces("Hello «world»", "Hello \n\n\(link)\n\n|") }
    func testAfterATrailingNewlineAtTheEnd() { assertPlaces("A\n|", "A\n\n\(link)\n\n|") }
    func testTwoImages() { assertPlaces("|", "\(link)\n\n\(link2)\n\n|", links: [link, link2]) }
    func testAListItemCaretAtTheEnd() { assertPlaces("- item|", "- item \(link)|") }
    func testHeadingCaretAnywhere() {
        assertPlaces("# Ti|tle\nText", "# Title\n\n\(link)\n\n|Text")
        assertPlaces("|# Title\nText", "# Title\n\n\(link)\n\n|Text")
        assertPlaces("# Title|\nText", "# Title\n\n\(link)\n\n|Text")
    }

    // MARK: the rest of the body cases

    func testThreeImages() {
        assertPlaces("A|", "A\n\n\(link)\n\n\(link2)\n\n\(link3)\n\n|", links: [link, link2, link3])
    }

    func testTheDocumentStartWithTextAfter() { assertPlaces("|Hello", "\(link)\n\n|Hello") }

    func testNoStrayBlankLinesPileUp() {
        assertPlaces("A\n\n|\n\nB", "A\n\n\(link)\n\n|B")
        assertPlaces("A\n\n|", "A\n\n\(link)\n\n|")
        assertPlaces("A\n\n|\nB", "A\n\n\(link)\n\n|B")
    }

    func testTrailingSpacesAfterTheCaretAreTaken() {
        assertPlaces("Hello |  \nWorld", "Hello \n\n\(link)\n\n|World")
        assertPlaces("Hello|\t\nWorld", "Hello\n\n\(link)\n\n|World")
    }

    func testAWhitespaceOnlyLineBeforeTheCaretCountsAsBlank() {
        assertPlaces("A\n   \n|B", "A\n   \n\(link)\n\n|B")
    }

    func testAnEmptyLineAboveNeedsNoExtraBreak() {
        assertPlaces("A\n\n|B", "A\n\n\(link)\n\n|B")
    }

    func testTextAfterAFencedBlockAndBeforeOne() {
        assertPlaces("```\ncode\n```\n|text", "```\ncode\n```\n\n\(link)\n\n|text")
        assertPlaces("Para|\n```\ncode\n```", "Para\n\n\(link)\n\n|```\ncode\n```")
    }

    func testASelectionAcrossParagraphs() {
        assertPlaces("One «two\n\nthree» four", "One \n\n\(link)\n\n| four")
    }

    func testASelectionOfWholeLinesWithTheirTerminator() {
        assertPlaces("A\n«B\n»C", "A\n\n\(link)\n\n|C")
    }

    func testUTF16OffsetsWithAnEmojiBeforeTheCaret() {
        assertPlaces("😀 Hello |world", "😀 Hello \n\n\(link)\n\n|world")
        assertPlaces("😀😀\n|B", "😀😀\n\n\(link)\n\n|B")
        assertPlaces("é日本 «🙂» end", "é日本 \n\n\(link)\n\n| end")
    }

    func testCRLFIsNotSpecialInsideTheEditor() {
        // The editor always holds "\n" (TextCoding restores CRLF on save), but a stray "\r" must not break the offsets.
        let text = "A\r\nB"
        let analysis = MarkdownAnalyzer.analyze(text)
        let edit = ImagePlacement.edit(links: [link], in: analysis, text: text, selection: NSRange(location: 1, length: 0))
        XCTAssertNotNil(edit)
        if let edit { XCTAssertEqual(edit.apply(to: text).hasPrefix("A\n\n\(link)"), true) }
    }

    // MARK: headings

    func testASetextHeadingGetsTheImageAfterItsUnderline() {
        assertPlaces("Ti|tle\n=====\nText", "Title\n=====\n\n\(link)\n\n|Text")
        assertPlaces("Title\n==|===\nText", "Title\n=====\n\n\(link)\n\n|Text")
        assertPlaces("Ti|tle\n-----\n", "Title\n-----\n\n\(link)\n\n|")
    }

    func testAMultiLineSetextHeading() {
        assertPlaces("First |line\nsecond line\n=====\nText", "First line\nsecond line\n=====\n\n\(link)\n\n|Text")
    }

    func testAHeadingFollowedByABlankLine() {
        assertPlaces("# T|\n\nText", "# T\n\n\(link)\n\n|Text")
    }

    func testAHeadingAtTheEndOfTheDocument() {
        assertPlaces("# T|", "# T\n\n\(link)\n\n|")
        assertPlaces("# T|\n", "# T\n\n\(link)\n\n|")
    }

    func testASelectionInsideAHeadingIsLeftAlone() {
        assertPlaces("# «Ti»tle\nText", "# Title\n\n\(link)\n\n|Text")
    }

    func testAnATXHeadingBeforeASetextHeadingIsItsOwnOneLine() {
        assertPlaces("# A|\nB\n---\n", "# A\n\n\(link)\n\n|B\n---\n")
    }

    func testAClosingSequenceIsStillAHeading() {
        assertPlaces("## Ti|tle ##\nText", "## Title ##\n\n\(link)\n\n|Text")
    }

    // MARK: lists and quotes

    func testListItemCases() {
        assertPlaces("- item|", "- item \(link)|")
        assertPlaces("- it|em", "- it \(link)|em")
        assertPlaces("- |item", "- \(link)|item", links: nil)
        assertPlaces("1. item|", "1. item \(link)|")
        assertPlaces("- [ ] task|", "- [ ] task \(link)|")
        assertPlaces("  - nested|", "  - nested \(link)|")
        assertPlaces("- item|\n- next", "- item \(link)|\n- next")
    }

    func testTwoLinksInAListItemAreSeparatedByOneSpace() {
        assertPlaces("- item|", "- item \(link) \(link2)|", links: [link, link2])
        assertPlaces("- item |", "- item \(link) \(link2)|", links: [link, link2])
    }

    func testNoSpaceAfterASpaceOrAtTheStartOfTheContent() {
        assertPlaces("- item |", "- item \(link)|")
        assertPlaces("- |", "- \(link)|")
        assertPlaces("> |", "> \(link)|")
    }

    func testBlockQuoteCases() {
        assertPlaces("> quoted|", "> quoted \(link)|")
        assertPlaces("> quoted|\n> more", "> quoted \(link)|\n> more")
        assertPlaces("> > deep|", "> > deep \(link)|")
        assertPlaces(">quoted|", ">quoted \(link)|")
        assertPlaces("> - item in a quote|", "> - item in a quote \(link)|")
    }

    func testASelectionInAListItemIsReplacedWithoutLineBreaks() {
        assertPlaces("- some «words» here", "- some \(link)| here")
    }

    func testAListItemSecondParagraphAndContinuationLines() {
        assertPlaces("- item\n\n  second para|", "- item\n\n  second para \(link)|")
        assertPlaces("- item\n  continued|", "- item\n  continued \(link)|")
    }

    func testNothingButTheLinksIsInsertedInAListOrQuote() {
        for marked in ["- item|", "> quoted|", "1. item|", "- [ ] task|"] {
            var text = marked; text.remove(at: text.firstIndex(of: "|")!)
            let analysis = MarkdownAnalyzer.analyze(text)
            let edit = ImagePlacement.edit(links: [link, link2], in: analysis, text: text, selection: NSRange(location: text.utf16.count, length: 0))
            XCTAssertEqual(edit?.replacement, " \(link) \(link2)", marked)
            XCTAssertFalse(edit?.replacement.contains("\n") ?? true, marked)
        }
    }

    func testACaretInTheLeadingSyntaxOfAListOrQuoteIsRefused() {
        assertRefused("|- item")
        assertRefused("-| item")
        assertRefused("|> quoted")
        assertRefused(">| quoted")
        assertRefused("  |- nested")
        assertRefused("1|. item")
        assertRefused("- [ |] task")
        assertRefused("«- it»em")
    }

    func testAHeadingInsideAQuoteIsAQuoteLine() {
        assertPlaces("> # Title|", "> # Title \(link)|")
    }

    // MARK: refused contexts (R5)

    func testFencedCodeIsRefused() {
        assertRefused("```swift\nlet x = 1|\n```")
        assertRefused("```\n|\n```")
        assertRefused("|```\ncode\n```")
        assertRefused("```\ncode\n```|")
        assertRefused("~~~\ncode|\n~~~")
        assertRefused("```mermaid\ngraph TD; A-->B|\n```")
    }

    func testAnIndentedCodeBlockIsRefused() {
        assertRefused("Para\n\n    code|\n")
    }

    func testFrontMatterIsRefused() {
        assertRefused("---\ntitle: x|\n---\nBody")
        assertRefused("«---\ntitle: x\n---\nBody»")
    }

    func testTableLinesAreRefused() {
        assertRefused("| a | b |\n|---|---|\n| 1 | 2|")
        assertRefused("| a | b|\n|---|---|\n| 1 | 2 |")
    }

    func testHTMLBlocksAndRulesAreRefused() {
        assertRefused("<div>\nhi|\n</div>")
        assertRefused("<p align=\"center\">x|</p>")
        assertRefused("A\n\n---|\n\nB")
        assertRefused("A\n\n***|\n\nB")
    }

    func testASelectionThatTouchesARefusedLineIsRefused() {
        assertRefused("Para «one\n```\ncode\n```\ntwo» end")
        assertRefused("«A\n```»\ncode\n```")
        assertRefused("Intro\n\n«| a | b |\n|---|---|\n| 1 | 2 |»")
    }

    func testASelectionThatEndsAtTheStartOfARefusedLineDoesNotTouchIt() {
        assertPlaces("Para\n«Text\n»```\ncode\n```", "Para\n\n\(link)\n\n|```\ncode\n```")
    }

    func testNothingToInsertIsRefused() {
        let analysis = MarkdownAnalyzer.analyze("A")
        XCTAssertNil(ImagePlacement.edit(links: [], in: analysis, text: "A", selection: NSRange(location: 1, length: 0)))
    }

    func testAStaleAnalysisOrSelectionIsRefused() {
        let analysis = MarkdownAnalyzer.analyze("A")
        XCTAssertNil(ImagePlacement.edit(links: [link], in: analysis, text: "AB", selection: NSRange(location: 1, length: 0)), "the analysis is of other text")
        XCTAssertNil(ImagePlacement.edit(links: [link], in: analysis, text: "A", selection: NSRange(location: 5, length: 0)))
        XCTAssertNil(ImagePlacement.edit(links: [link], in: analysis, text: "A", selection: NSRange(location: 0, length: 9)))
        XCTAssertNil(ImagePlacement.edit(links: [link], in: analysis, text: "A", selection: NSRange(location: -1, length: 0)))
    }

    // MARK: what the result looks like to the analyzer

    func testTheInsertedLinkIsAStandaloneImageThatPreviews() {
        for marked in ["|", "A|", "A\n|B", "Hello |world", "Hello «world»", "# T|itle\nText", "A\n|\nB"] {
            var text = marked
            var sel = NSRange(location: 0, length: 0)
            if let open = text.firstIndex(of: "«"), let close = text.firstIndex(of: "»") {
                sel = NSRange(location: text[..<open].utf16.count, length: text[text.index(after: open)..<close].utf16.count)
                text.removeSubrange(close...close); text.removeSubrange(open...open)
            } else if let bar = text.firstIndex(of: "|") {
                sel = NSRange(location: text[..<bar].utf16.count, length: 0); text.remove(at: bar)
            }
            let edit = ImagePlacement.edit(links: [link, link2], in: MarkdownAnalyzer.analyze(text), text: text, selection: sel)!
            let result = MarkdownAnalyzer.analyze(edit.apply(to: text))
            XCTAssertEqual(result.imageBlocks.map(\.source), ["assets/x.png", "assets/y.png"], "from \(marked.debugDescription)")
        }
    }

    func testTheCaretEndsRightAfterTheInsertedText() {
        let text = "Hello world"
        let analysis = MarkdownAnalyzer.analyze(text)
        let edit = ImagePlacement.edit(links: [link], in: analysis, text: text, selection: NSRange(location: 5, length: 0))!
        XCTAssertEqual(edit.selection, NSRange(location: edit.range.location + edit.replacement.utf16.count, length: 0))
    }

    func testTheEditReplacesOnlyTheSelectionPlusWhatItAbsorbs() {
        let text = "One two three"
        let analysis = MarkdownAnalyzer.analyze(text)
        let edit = ImagePlacement.edit(links: [link], in: analysis, text: text, selection: NSRange(location: 4, length: 3))!
        XCTAssertEqual(edit.range, NSRange(location: 4, length: 3))
    }
}
