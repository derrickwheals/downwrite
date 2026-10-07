import XCTest
@testable import DownwriteCore

final class TextCodingTests: XCTestCase {
    func testPlainUTF8() {
        let d = TextCoding.decode(Data("héllo\n# T\n".utf8))
        XCTAssertEqual(d.text, "héllo\n# T\n")
        XCTAssertEqual(d.encoding, .utf8)
        XCTAssertFalse(d.hasBOM)
        XCTAssertEqual(d.lineEnding, .lf)
    }

    func testUTF8BOMRoundTrip() {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("hi\n".utf8)
        let d = TextCoding.decode(original)
        XCTAssertTrue(d.hasBOM)
        XCTAssertEqual(d.text, "hi\n")
        XCTAssertEqual(TextCoding.encode(d.text, encoding: d.encoding, bom: d.hasBOM, lineEnding: d.lineEnding), original)
    }

    func testCRLFIsNormalisedAndRestored() {
        let original = Data("a\r\nb\r\n".utf8)
        let d = TextCoding.decode(original)
        XCTAssertEqual(d.text, "a\nb\n")
        XCTAssertEqual(d.lineEnding, .crlf)
        XCTAssertEqual(TextCoding.encode(d.text, encoding: d.encoding, bom: d.hasBOM, lineEnding: d.lineEnding), original)
    }

    func testClassicMacCR() {
        let d = TextCoding.decode(Data("a\rb\rc".utf8))
        XCTAssertEqual(d.text, "a\nb\nc")
        XCTAssertEqual(d.lineEnding, .cr)
    }

    func testUTF16Files() {
        let le = Data([0xFF, 0xFE]) + "hé\n".data(using: .utf16LittleEndian)!
        let d = TextCoding.decode(le)
        XCTAssertEqual(d.text, "hé\n")
        XCTAssertEqual(d.encoding, .utf16LittleEndian)
        XCTAssertEqual(TextCoding.encode(d.text, encoding: d.encoding, bom: d.hasBOM, lineEnding: d.lineEnding), le)
        let be = Data([0xFE, 0xFF]) + "hé".data(using: .utf16BigEndian)!
        XCTAssertEqual(TextCoding.decode(be).text, "hé")
    }

    func testLegacyEncodingFallsBackInsteadOfFailing() {
        let d = TextCoding.decode(Data([0x63, 0x61, 0x66, 0xE9]))   // "café" in Windows-1252
        XCTAssertEqual(d.text, "café")
        XCTAssertEqual(d.encoding, .windowsCP1252)
    }

    func testCP1252RoundTripIncludingSmartQuotes() {
        let original = Data([0x93, 0x68, 0x69, 0x94, 0x20, 0x80, 0xE9])   // “hi” €é
        let d = TextCoding.decode(original)
        XCTAssertEqual(d.text, "\u{201C}hi\u{201D} \u{20AC}é")
        XCTAssertEqual(TextCoding.encode(d.text, encoding: d.encoding, bom: false, lineEnding: .lf), original)
    }

    func testEmptyData() {
        XCTAssertEqual(TextCoding.decode(Data()).text, "")
    }

    func testMixedLineEndingsPrefersMajority() {
        XCTAssertEqual(TextCoding.decode(Data("a\nb\nc\r\n".utf8)).lineEnding, .lf)
        XCTAssertEqual(TextCoding.decode(Data("a\r\nb\r\nc\n".utf8)).lineEnding, .crlf)
    }
}
