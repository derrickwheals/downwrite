import XCTest
@testable import DownwriteCore

final class HeadingAnchorTests: XCTestCase {
    /// The editor's slug exactly as it was before it moved to Core (`EditorCoordinator.slug`). The moved function must agree with it on
    /// every title, because a `#fragment` link that works in the editor has to work in the exported file (R12, R29).
    private func slugBeforeTheMove(_ title: String) -> String {
        let lowered = title.lowercased()
        let allowed = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
        return String(String.UnicodeScalarView(allowed)).replacingOccurrences(of: " ", with: "-")
    }

    // MARK: slug

    func testSlugOfTypicalTitles() {
        let table: [(String, String)] = [
            ("Hello, World! 2", "hello-world-2"),
            ("Introduction", "introduction"),
            ("2024 Plan", "2024-plan"),
            ("Already-hyphenated title", "already-hyphenated-title"),
            ("Under_score", "underscore"),
            ("C++ & C#", "c--c"),
        ]
        for (title, slug) in table { XCTAssertEqual(HeadingAnchor.slug(title), slug, title) }
    }

    func testSlugKeepsTheInlineSourceTheAnalyzerKeeps() {
        // `HeadingInfo.title` is the heading's inline source, so markers and link syntax are slugged as typed.
        XCTAssertEqual(HeadingAnchor.slug("Reading **this**"), "reading-this")
        XCTAssertEqual(HeadingAnchor.slug("[x](u) title"), "xu-title")
        XCTAssertEqual(HeadingAnchor.slug("`code` and ~~strike~~"), "code-and-strike")
    }

    func testSlugKeepsLettersAndMarksOfOtherScripts() {
        XCTAssertEqual(HeadingAnchor.slug("Café ünïcode"), "café-ünïcode")
        XCTAssertEqual(HeadingAnchor.slug("日本語 heading"), "日本語-heading")
        XCTAssertEqual(HeadingAnchor.slug("e\u{301}tude"), "e\u{301}tude")
        XCTAssertEqual(HeadingAnchor.slug("Emoji 🎉 time"), "emoji--time")
    }

    func testSlugDoesNotTrimOrCollapseSpaces() {
        XCTAssertEqual(HeadingAnchor.slug("a  b"), "a--b")
        XCTAssertEqual(HeadingAnchor.slug("  padded  "), "--padded--")
    }

    func testSlugOfNothingIsEmpty() {
        XCTAssertEqual(HeadingAnchor.slug(""), "")
        XCTAssertEqual(HeadingAnchor.slug("!!! ???"), "-")
        XCTAssertEqual(HeadingAnchor.slug("!!!"), "")
    }

    func testSlugAgreesWithTheEditorsOldFunction() {
        let titles = [
            "Hello, World! 2", "Reading **this**", "[x](u) title", "Café ünïcode", "日本語 heading", "e\u{301}tude", "Emoji 🎉 time",
            "  padded  ", "a  b", "C++ & C#", "Under_score", "", "!!!", "ǅungla Straße", "İstanbul", "Ωmega 5", "tab\there", "new\nline",
            "Ünï-Cödé 1.2.3", "100% sure", "a/b\\c", "<b>html</b> title", "&amp; entity", "ÀÉÎÕÜ", "ⅷ roman", "١٢٣ digits",
        ]
        for t in titles { XCTAssertEqual(HeadingAnchor.slug(t), slugBeforeTheMove(t), t.debugDescription) }
    }

    // MARK: unique

    func testFirstHeadingKeepsTheSlugAndLaterOnesGetSuffixes() {
        XCTAssertEqual(HeadingAnchor.unique(["a", "b", "a", "a"]), ["a", "b", "a-1", "a-2"])
        XCTAssertEqual(HeadingAnchor.unique(["x", "x"]), ["x", "x-1"])
        XCTAssertEqual(HeadingAnchor.unique([]), [])
    }

    func testASuffixNeverCollidesWithALiteralSlug() {
        // "Foo", "Foo", "Foo 1": the second heading takes foo-1, so the third (whose own slug is foo-1) moves on.
        XCTAssertEqual(HeadingAnchor.unique(["foo", "foo", "foo-1"]), ["foo", "foo-1", "foo-1-1"])
        // "Foo 1" first: the later duplicates of "Foo" skip the taken foo-1.
        XCTAssertEqual(HeadingAnchor.unique(["foo-1", "foo", "foo"]), ["foo-1", "foo", "foo-2"])
    }

    func testAnEmptySlugGetsNoIdAndTakesNoPart() {
        XCTAssertEqual(HeadingAnchor.unique(["", "a", "", "a"]), [nil, "a", nil, "a-1"])
    }

    func testIdsAreUniqueAndStartWithTheirSlug() {
        var generator = SystemRandomNumberGenerator()
        let pool = ["a", "b", "a-1", "b-1", "a-1-1", "", "c"]
        for _ in 0..<200 {
            let slugs = (0..<Int.random(in: 0...30, using: &generator)).map { _ in pool.randomElement(using: &generator)! }
            let ids = HeadingAnchor.unique(slugs)
            XCTAssertEqual(ids.count, slugs.count)
            let present = ids.compactMap { $0 }
            XCTAssertEqual(Set(present).count, present.count, "\(slugs) -> \(ids)")
            for (slug, id) in zip(slugs, ids) {
                if slug.isEmpty { XCTAssertNil(id) } else { XCTAssertTrue(id?.hasPrefix(slug) == true, "\(slugs) -> \(ids)") }
            }
            // The first heading with a non-empty slug always keeps it, so the editor's "first heading wins" lookup
            // and the exported file's `#fragment` agree on that heading.
            if let first = slugs.firstIndex(where: { !$0.isEmpty }) { XCTAssertEqual(ids[first], slugs[first], "\(slugs) -> \(ids)") }
        }
    }
}
