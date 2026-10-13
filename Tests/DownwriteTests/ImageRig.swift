import XCTest
import AppKit
import ImageIO
@testable import Downwrite
import DownwriteCore

/// What a rig's coordinator reported.
final class ImageRecorder {
    var notices: [(title: String, message: String)] = []
    var announcements: [String] = []
}

/// A saved document in a temporary folder, an editor on it, a private pasteboard and a fixed clock: the setup the paste and drop
/// tests share.
@MainActor
class ImageRigTestCase: XCTestCase {
    let fm = FileManager.default
    let pastedName = "image-20261013-094112.png"

    @MainActor
    struct Rig {
        let h: EditorHarness
        let folder: URL
        let doc: URL
        let pb: NSPasteboard
        let rec: ImageRecorder
        var assets: URL { folder.appendingPathComponent("assets") }
        var text: String { h.textView.string }
    }

    func rig(_ text: String, selection: NSRange? = nil, saved: Bool = true) throws -> Rig {
        let root = fm.temporaryDirectory.appendingPathComponent("downwrite-paste-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Notes", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { [fm] in
            if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in walker { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            }
            try? fm.removeItem(at: root)
        }
        let doc = folder.appendingPathComponent("doc.md")
        try text.write(to: doc, atomically: true, encoding: .utf8)
        let h = EditorHarness(text: text, fileURL: saved ? doc : nil)
        h.window.makeKeyAndOrderFront(nil)
        h.window.makeFirstResponder(h.textView)
        let pb = NSPasteboard(name: NSPasteboard.Name("downwrite.test.imageflow.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        pb.clearContents()
        let rec = ImageRecorder()
        let c = h.coordinator
        c.imagePasteboard = pb
        c.imageTimeZone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let fixed = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 41, second: 12))!
        c.imageClock = { fixed }
        c.onImageNotice = { rec.notices.append(($0, $1)) }
        c.onAnnouncement = { rec.announcements.append($0) }
        h.select(selection?.location ?? text.utf16.count, selection?.length ?? 0)
        return Rig(h: h, folder: folder, doc: doc, pb: pb, rec: rec)
    }

    func putPNG(_ pb: NSPasteboard, _ data: Data = ImageFixtures.png()) {
        pb.clearContents()
        pb.setData(data, forType: .png)
    }

    func files(_ r: Rig) -> [String] { ((try? fm.contentsOfDirectory(atPath: r.assets.path)) ?? []).sorted() }

    func link(_ name: String) -> String { "![](assets/\(name))" }
}
