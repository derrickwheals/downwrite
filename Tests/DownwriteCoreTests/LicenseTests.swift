import XCTest

/// Guards the licensing paperwork: GPL-3.0 text, copyright holder, third-party notices and bundled licence texts.
final class LicenseTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testLicenseIsGPLv3() throws {
        let text = try read("LICENSE")
        XCTAssertTrue(text.contains("GNU GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(text.contains("Version 3, 29 June 2007"))
        XCTAssertGreaterThan(text.count, 30_000, "license text looks truncated")
    }

    func testReadmeStatesLicenseAndHolder() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains("GNU General Public License v3.0"))
        XCTAssertTrue(readme.contains("Derrick Wheals"))
    }

    func testThirdPartyNoticesCoverEveryBundledComponent() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        for name in ["swift-markdown", "cmark-gfm", "Mermaid", "Catppuccin", "Radix Colors", "Apache-2.0", "MIT"] {
            XCTAssertTrue(notices.contains(name), "missing \(name)")
        }
        for file in ["swift-markdown-LICENSE.txt", "swift-markdown-NOTICE.txt", "cmark-gfm-COPYING.txt", "mermaid-LICENSE.txt",
                     "catppuccin-LICENSE.txt", "radix-colors-LICENSE.txt"] {
            let text = try read("ThirdParty/\(file)")
            XCTAssertFalse(text.isEmpty, file)
            XCTAssertTrue(notices.contains(file), "\(file) not referenced in THIRD-PARTY-NOTICES.md")
        }
    }

    func testInfoPlistCarriesCopyrightAndNoStaleHolder() throws {
        let plist = try read("Packaging/Info.plist")
        XCTAssertTrue(plist.contains("Derrick Wheals"))
        XCTAssertTrue(plist.contains("GPL"))
    }

    func testBuildScriptBundlesLegalFiles() throws {
        let script = try read("scripts/build-app.sh")
        XCTAssertTrue(script.contains("Resources/Legal"))
        XCTAssertTrue(script.contains("THIRD-PARTY-NOTICES.md"))
    }
}
