import XCTest
import AppKit
@testable import Downwrite

/// `StyleDiff.apply` on its own: it must end with the storage attribute-equal to the styled copy, and write (and report as edited) only
/// what differs.
@MainActor
final class StyleDiffTests: XCTestCase {
    private let text = "first line\nsecond line\nthird line\n"
    private let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]

    private func storage(_ attributes: [NSAttributedString.Key: Any]? = nil) -> NSTextStorage {
        NSTextStorage(string: text, attributes: attributes ?? base)
    }

    /// The ranges the storage reports as edited while `body` runs.
    private func edits(of store: NSTextStorage, during body: () -> Void) -> [NSRange] {
        let seen = Recorded<[NSRange]>([])
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: store, queue: nil) { _ in
            MainActor.assumeIsolated { seen.value.append(store.editedRange) }
        }
        body()
        NotificationCenter.default.removeObserver(token)
        return seen.value
    }

    func testIdenticalAttributesWriteNothing() {
        let store = storage(), styled = storage()
        var written = -1
        let seen = edits(of: store) { written = StyleDiff.apply(styled, to: store) }
        XCTAssertEqual(written, 0)
        XCTAssertEqual(seen, [], "no edit is even begun")
    }

    func testEqualValuesInDifferentObjectsWriteNothing() {
        let p1 = NSMutableParagraphStyle(), p2 = NSMutableParagraphStyle()
        p1.lineHeightMultiple = 1.45; p2.lineHeightMultiple = 1.45
        let store = storage(base.merging([.paragraphStyle: p1, .dwCheckbox: CheckboxMark(checked: true, side: 14, centerAboveBaseline: 4, accent: .red, outline: .gray, tick: .white)]) { a, _ in a })
        let styled = storage(base.merging([.paragraphStyle: p2, .dwCheckbox: CheckboxMark(checked: true, side: 14, centerAboveBaseline: 4, accent: .red, outline: .gray, tick: .white)]) { a, _ in a })
        XCTAssertEqual(StyleDiff.apply(styled, to: store), 0)
    }

    func testOneDifferingRunWritesOnlyThatRange() {
        let store = storage(), styled = storage()
        let second = (text as NSString).range(of: "second")
        styled.addAttribute(.foregroundColor, value: NSColor.red, range: second)
        var written = 0
        let seen = edits(of: store) { written = StyleDiff.apply(styled, to: store) }
        XCTAssertEqual(written, 1)
        XCTAssertEqual(seen, [second])
        XCTAssertTrue(store.isEqual(to: styled))
    }

    func testAnAttributeOnlyInTheStorageIsRemoved() {
        let store = storage(), styled = storage()
        let third = (text as NSString).range(of: "third line")
        store.addAttribute(.dwPill, value: NSColor.yellow, range: third)
        XCTAssertEqual(StyleDiff.apply(styled, to: store), 1)
        XCTAssertNil(store.attribute(.dwPill, at: third.location, effectiveRange: nil))
        XCTAssertTrue(store.isEqual(to: styled))
    }

    func testDifferingStretchesInsideOneStyledRunAreMergedAcrossStorageRuns() {
        let store = storage(), styled = storage()
        store.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 3))
        store.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 3, length: 3))
        let seen = edits(of: store) { XCTAssertEqual(StyleDiff.apply(styled, to: store), 1) }
        XCTAssertEqual(seen, [NSRange(location: 0, length: 6)])
        XCTAssertTrue(store.isEqual(to: styled))
    }

    /// Random run layouts on both sides, from a small pool of values so that runs often agree: the storage always ends equal to the
    /// styled copy, and a second pass writes nothing.
    func testRandomRunLayoutsEndEqual() {
        var rng = SplitMix(seed: 0xD0_24)
        let colors: [NSColor] = [.red, .blue, .textColor]
        let fonts = [NSFont.systemFont(ofSize: 14), NSFont.boldSystemFont(ofSize: 14), NSFont.systemFont(ofSize: 0.1)]
        func scramble(_ s: NSTextStorage) {
            s.beginEditing()
            for _ in 0..<Int.random(in: 0...12, using: &rng) {
                let a = Int.random(in: 0..<s.length, using: &rng), b = Int.random(in: a...s.length, using: &rng)
                let r = NSRange(location: a, length: b - a)
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: s.addAttribute(.foregroundColor, value: colors.randomElement(using: &rng)!, range: r)
                case 1: s.addAttribute(.font, value: fonts.randomElement(using: &rng)!, range: r)
                case 2: s.addAttribute(.dwPill, value: NSColor.yellow, range: r)
                default: s.removeAttribute(.dwPill, range: r)
                }
            }
            s.endEditing()
        }
        for round in 0..<300 {
            let store = storage(), styled = storage()
            scramble(store); scramble(styled)
            StyleDiff.apply(styled, to: store)
            XCTAssertTrue(store.isEqual(to: styled), "round \(round)")
            XCTAssertEqual(StyleDiff.apply(styled, to: store), 0, "round \(round): a second pass writes nothing")
        }
    }
}

/// A small deterministic generator (SplitMix64), so a failing random round can be reproduced.
private struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
