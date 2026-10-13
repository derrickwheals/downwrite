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
