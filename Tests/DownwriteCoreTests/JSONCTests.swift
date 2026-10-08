import XCTest
@testable import DownwriteCore

final class JSONCTests: XCTestCase {
    func testLineAndBlockCommentsAreRemoved() throws {
        let text = """
        {
          // a line comment
          "a": 1, /* inline */ "b": [1, 2, /* x */ 3],
          /* multi
             line */
          "c": "ok"
        }
        """
        let o = try JSONC.object(from: text)
        XCTAssertEqual(o["a"] as? Int, 1)
        XCTAssertEqual(o["b"] as? [Int], [1, 2, 3])
        XCTAssertEqual(o["c"] as? String, "ok")
    }

    func testCommentMarkersInsideStringsSurvive() throws {
        let o = try JSONC.object(from: #"{"url": "https://example.com/a//b", "glob": "/* not a comment */", "q": "say \"// hi\""}"#)
        XCTAssertEqual(o["url"] as? String, "https://example.com/a//b")
        XCTAssertEqual(o["glob"] as? String, "/* not a comment */")
        XCTAssertEqual(o["q"] as? String, "say \"// hi\"")
    }

    func testTrailingCommasAreAccepted() throws {
        let o = try JSONC.object(from: """
        { "list": [1, 2, 3,], "nested": { "k": "v", }, }
        """)
        XCTAssertEqual(o["list"] as? [Int], [1, 2, 3])
        XCTAssertEqual((o["nested"] as? [String: String])?["k"], "v")
    }

    func testACommaInsideAStringBeforeABracketIsKept() throws {
        let o = try JSONC.object(from: #"{"s": "a,]", "t": "b,}"}"#)
        XCTAssertEqual(o["s"] as? String, "a,]")
        XCTAssertEqual(o["t"] as? String, "b,}")
    }

    func testByteOrderMarkAndCRLF() throws {
        let o = try JSONC.object(from: "\u{FEFF}{\r\n  // c\r\n  \"a\": 1\r\n}\r\n")
        XCTAssertEqual(o["a"] as? Int, 1)
    }

    func testPlainJSONIsUnchanged() throws {
        let json = #"{"a":[1,2,{"b":null}],"c":"d"}"#
        XCTAssertEqual(JSONC.sanitize(json), json)
    }

    func testErrors() {
        XCTAssertThrowsError(try JSONC.object(from: "{ not json"))
        XCTAssertThrowsError(try JSONC.object(from: "[1, 2]")) { XCTAssertEqual($0 as? JSONC.ParseError, .notAnObject) }
        XCTAssertThrowsError(try JSONC.object(from: ""))
        XCTAssertThrowsError(try JSONC.object(from: "{ \"a\": 1 /* never closed }"))
    }

    func testEscapedBackslashBeforeAQuote() throws {
        let o = try JSONC.object(from: #"{"p": "C:\\", "q": 2} // trailing"#)
        XCTAssertEqual(o["p"] as? String, "C:\\")
        XCTAssertEqual(o["q"] as? Int, 2)
    }
}
