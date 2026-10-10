import XCTest
@testable import DownwriteCore

/// R14: what happens to each image source. File reading is the app's job and is replaced here by a closure that records what it was asked.
final class DocumentHTMLImageTests: XCTestCase {
    /// A fake disk: the sources it has, with their sizes. Anything else is not found.
    private struct Disk {
        var files: [String: DocumentHTML.LocalImage] = [:]
        var asked: [String] = []
        mutating func load(_ source: String) -> DocumentHTML.LocalImage {
            asked.append(source)
            return files[source] ?? .notFound
        }
    }

    private func image(_ bytes: Int = 100) -> DocumentHTML.LocalImage { .image(dataURI: "data:image/png;base64,AA==", byteCount: bytes) }

    private func resolve(_ sources: [String], hasFolder: Bool = true, disk: inout Disk) -> [String: DocumentHTML.ImageOutcome] {
        var d = disk
        let out = DocumentHTML.resolveImages(sources, documentHasFolder: hasFolder) { d.load($0) }
        disk = d
        return out
    }

    // MARK: The table in the spec

    func testLocalImagesAreEmbedded() {
        var disk = Disk(files: ["pic.png": image(), "../img/a%20b.png": image(), "/abs/p.jpg": image(), "~/p.jpg": image(), "file:///tmp/p.jpg": image()])
        let out = resolve(["pic.png", "../img/a%20b.png", "/abs/p.jpg", "~/p.jpg", "file:///tmp/p.jpg"], disk: &disk)
        for source in disk.files.keys { XCTAssertEqual(out[source], .embedded(dataURI: "data:image/png;base64,AA=="), source) }
        XCTAssertEqual(disk.asked, ["pic.png", "../img/a%20b.png", "/abs/p.jpg", "~/p.jpg", "file:///tmp/p.jpg"], "asked as written, in order")
    }

    func testMissingBigAndNotImageFilesAreLeftOutWithTheirReason() {
        var disk = Disk(files: ["big.png": .tooLarge, "notes.txt": .notAnImage, "folder": .notAnImage])
        let out = resolve(["missing.png", "big.png", "notes.txt", "folder"], disk: &disk)
        XCTAssertEqual(out["missing.png"], .leftOut(.notFound))
        XCTAssertEqual(out["big.png"], .leftOut(.tooLarge))
        XCTAssertEqual(out["notes.txt"], .leftOut(.notAnImage))
        XCTAssertEqual(out["folder"], .leftOut(.notAnImage))
    }

    func testASourceWithAQueryIsLookedUpAsWrittenAndIsMissingWithoutSuchAFile() {
        var disk = Disk(files: ["pic.png": image()])
        let out = resolve(["pic.png?raw=true", "pic.png#frag"], disk: &disk)
        XCTAssertEqual(disk.asked, ["pic.png?raw=true", "pic.png#frag"])
        XCTAssertEqual(out["pic.png?raw=true"], .leftOut(.notFound))
        XCTAssertEqual(out["pic.png#frag"], .leftOut(.notFound))
    }

    func testDataAndHttpsSourcesAreKeptWithoutReadingAnything() {
        var disk = Disk()
        let out = resolve(["data:image/png;base64,AAAA", "https://example.com/p.png", "HTTPS://EXAMPLE.COM/q.png"], disk: &disk)
        XCTAssertEqual(out["data:image/png;base64,AAAA"], .keep)
        XCTAssertEqual(out["https://example.com/p.png"], .keep)
        XCTAssertEqual(out["HTTPS://EXAMPLE.COM/q.png"], .keep)
        XCTAssertEqual(disk.asked, [])
    }

    func testHttpImagesAreLeftOutBecauseOfTheSecurityPolicy() {
        var disk = Disk()
        let out = resolve(["http://example.com/a.png", "HTTP://example.com/b.png"], disk: &disk)
        XCTAssertEqual(out["http://example.com/a.png"], .leftOut(.insecure))
        XCTAssertEqual(out["HTTP://example.com/b.png"], .leftOut(.insecure))
        XCTAssertEqual(disk.asked, [])
    }

    // MARK: An untitled document has no folder

    func testARelativeSourceInAnUntitledDocumentIsLeftOutAndNeverLooked() {
        var disk = Disk(files: ["pic.png": image(), "/abs.png": image(), "~/h.png": image(), "file:///f.png": image()])
        let out = resolve(["pic.png", "../up.png", "/abs.png", "~/h.png", "file:///f.png"], hasFolder: false, disk: &disk)
        XCTAssertEqual(out["pic.png"], .leftOut(.unsavedDocument))
        XCTAssertEqual(out["../up.png"], .leftOut(.unsavedDocument))
        XCTAssertEqual(out["/abs.png"], .embedded(dataURI: "data:image/png;base64,AA=="))
        XCTAssertEqual(out["~/h.png"], .embedded(dataURI: "data:image/png;base64,AA=="))
        XCTAssertEqual(out["file:///f.png"], .embedded(dataURI: "data:image/png;base64,AA=="))
        XCTAssertEqual(disk.asked, ["/abs.png", "~/h.png", "file:///f.png"], "the working directory is never used for a relative source")
    }

    func testDataAndHttpsAreUnaffectedByAMissingFolder() {
        var disk = Disk()
        let out = resolve(["data:image/png;base64,AAAA", "https://e.test/p.png"], hasFolder: false, disk: &disk)
        XCTAssertEqual(out["data:image/png;base64,AAAA"], .keep)
        XCTAssertEqual(out["https://e.test/p.png"], .keep)
    }

    // MARK: The 64 MB budget

    func testImagesAfterSixtyFourMegabytesAreLeftOutAndNotRead() {
        var files: [String: DocumentHTML.LocalImage] = [:]
        let sources = (1...10).map { "img\($0).png" }
        for s in sources { files[s] = image(8_000_000) }
        var disk = Disk(files: files)
        let out = resolve(sources, disk: &disk)
        for s in sources.prefix(8) { XCTAssertEqual(out[s], .embedded(dataURI: "data:image/png;base64,AA=="), s) }
        XCTAssertEqual(out["img9.png"], .leftOut(.sizeLimit))
        XCTAssertEqual(out["img10.png"], .leftOut(.sizeLimit))
        XCTAssertEqual(disk.asked, Array(sources.prefix(8)), "once the budget is spent no more files are read")
    }

    func testTheImageThatCrossesTheLimitIsStillIncluded() {
        var disk = Disk(files: ["a.png": image(60_000_000), "b.png": image(7_000_000), "c.png": image(10)])
        let out = resolve(["a.png", "b.png", "c.png"], disk: &disk)
        XCTAssertEqual(out["a.png"], .embedded(dataURI: "data:image/png;base64,AA=="))
        XCTAssertEqual(out["b.png"], .embedded(dataURI: "data:image/png;base64,AA=="), "67 MB held after this one")
        XCTAssertEqual(out["c.png"], .leftOut(.sizeLimit))
    }

    func testOnlyEmbeddedImagesCountTowardsTheBudget() {
        var disk = Disk(files: ["a.png": image(63_999_999), "b.png": .tooLarge, "c.png": image(5)])
        let out = resolve(["data:image/png;base64,AAAA", "https://e.test/p.png", "missing.png", "b.png", "a.png", "c.png"], disk: &disk)
        XCTAssertEqual(out["a.png"], .embedded(dataURI: "data:image/png;base64,AA=="))
        XCTAssertEqual(out["c.png"], .embedded(dataURI: "data:image/png;base64,AA=="), "63,999,999 bytes held is still under 64,000,000")
    }

    // MARK: Order and repeats

    func testASourceListedTwiceIsResolvedOnce() {
        var disk = Disk(files: ["a.png": image()])
        _ = resolve(["a.png", "a.png", "a.png"], disk: &disk)
        XCTAssertEqual(disk.asked, ["a.png"])
    }

    func testAnUnrecognisedSourceIsLeftOutAsNotFoundWithoutReading() {
        var disk = Disk()
        let out = resolve(["ftp://e.test/a.png", "c:/p.png"], disk: &disk)
        XCTAssertEqual(out["ftp://e.test/a.png"], .leftOut(.notFound))
        XCTAssertEqual(out["c:/p.png"], .leftOut(.notFound))
        XCTAssertEqual(disk.asked, [])
    }

    func testNoSourcesNeedNoFiles() {
        var disk = Disk()
        XCTAssertEqual(resolve([], disk: &disk), [:])
    }
}
