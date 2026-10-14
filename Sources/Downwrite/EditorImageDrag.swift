import AppKit
import UniformTypeIdentifiers
import DownwriteCore

/// What an image drag over the editor holds, and where it would land.
struct ImageDrag {
    var sources: [ImageSource]
    var promises: [NSFilePromiseReceiver]
    var skipped: [String]
    /// The character index under the pointer.
    var insertionIndex: Int
}

/// Dragging images onto the editor (R2, R15, R16). `EditorTextView`'s drag-destination methods ask these first and leave every drag
/// that is not an image drag to AppKit.
extension EditorCoordinator {
    /// The drag as an image drag, or nil when it is anything else: text dragged within the editor, a pasteboard `ImagePasteRule` says
    /// is not about images (a caption beside the picture, only non-image files), or a place R5 refuses. `readData: false` only looks
    /// at the types (the pointer is still moving); a drop reads the bytes.
    func imageDrag(from sender: any NSDraggingInfo, readData: Bool) -> ImageDrag? {
        guard let tv = textView, tv.window != nil else { return nil }
        if let source = sender.draggingSource as? NSView, source === tv || source.isDescendant(of: tv) { return nil }
        let pasteboard = sender.draggingPasteboard
        let read = ImageIntake.read(pasteboard, copyingData: readData)
        let promised = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        let imagePromises = promised.filter { receiver in
            receiver.fileTypes.contains { UTType($0).map { $0.conforms(to: .image) && !$0.conforms(to: .pdf) } ?? false }
        }
        var content = read.content
        var sources = read.sources
        var promises: [NSFilePromiseReceiver] = []
        var skipped = read.skippedFiles
        if !imagePromises.isEmpty {
            content.hasImageData = true
            if read.content.imageFileNames.isEmpty { sources = []; promises = imagePromises }          // the original beats a preview of it
        }
        if promised.count > imagePromises.count {
            content.hasOtherFiles = true
            skipped.append(contentsOf: Array(repeating: "a file that is not an image", count: promised.count - imagePromises.count))
        }
        guard ImagePasteRule.prefersImages(content), !sources.isEmpty || !promises.isEmpty else { return nil }
        let index = tv.characterIndexForInsertion(at: tv.convert(sender.draggingLocation, from: nil))
        guard analysis.length == tv.textStorage?.length,
              ImagePlacement.edit(links: ["![](assets/x.png)"], in: analysis, text: tv.string, selection: NSRange(location: index, length: 0)) != nil else { return nil }
        return ImageDrag(sources: sources, promises: promises, skipped: skipped, insertionIndex: index)
    }

    func isImageDrag(_ sender: any NSDraggingInfo) -> Bool { imageDrag(from: sender, readData: false) != nil }

    /// The answer to `draggingEntered` and `draggingUpdated` for an image drag: copy, with the drop point marked. nil: not one.
    func imageDragOperation(_ sender: any NSDraggingInfo) -> NSDragOperation? {
        guard let drag = imageDrag(from: sender, readData: false) else { setDropMarker(nil); return nil }
        setDropMarker(drag.insertionIndex)
        let mask = sender.draggingSourceOperationMask
        return mask.contains(.copy) ? .copy : (mask.contains(.generic) ? .generic : [])
    }

    /// The drop: the bytes are read now, the work is queued, and the pointer's character index is where the images go. nil: not an
    /// image drop (AppKit handles it, as it always did).
    func performImageDrop(_ sender: any NSDraggingInfo) -> Bool? {
        flushPendingAnalysis()
        guard let drag = imageDrag(from: sender, readData: true) else { setDropMarker(nil); return nil }
        setDropMarker(nil)
        textView?.window?.makeFirstResponder(textView)
        // AppKit lets promised files be received only while the drop is being handled; receiving is asynchronous, so the queued job
        // just waits for them.
        let promised = drag.promises.isEmpty ? nil : PromisedFiles(receivers: drag.promises, start: promiseStarter)
        let accepted = enqueueImages(kind: .drop, sources: drag.sources, promised: promised, skipped: drag.skipped,
                                     at: NSRange(location: drag.insertionIndex, length: 0))
        if !accepted { promised?.discard() }
        return accepted
    }

    // MARK: The drop marker

    /// Marks where the images would go with a bar like the caret's, redrawing only the old and the new place.
    func setDropMarker(_ index: Int?) {
        guard let tv = textView, let layout = tv.layoutManager as? DWLayoutManager, layout.dropMarkerIndex != index else { return }
        let old = layout.dropMarkerIndex
        layout.dropMarkerIndex = index
        if let styler { layout.dropMarkerColor = styler.palette.accent.nsColor }
        let origin = tv.textContainerOrigin
        for place in [old, index].compactMap({ $0 }) {
            if let box = layout.dropMarkerRect(forCharacterAt: place) { tv.setNeedsDisplay(box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -2)) }
        }
    }
}

/// The files a drag promised (Photos, some browsers), being received into a folder of their own. `init` must run while the drop is
/// being handled, because AppKit raises an exception for a promise received at any other time; the files then arrive on their own
/// and `wait()` returns once the last one is in. One file per promise; a promise that fails is counted, not fatal. The folder is
/// removed by whoever is done with the files (`discard()`).
final class PromisedFiles: @unchecked Sendable {
    /// Asks one promise to deliver its file into `destination`, calling `reader` when it has (or has failed). AppKit's
    /// `receivePromisedFiles` is the only real one; it raises an exception outside a live drop, so tests supply their own.
    typealias Starter = (_ receiver: NSFilePromiseReceiver, _ destination: URL, _ queue: OperationQueue,
                         _ reader: @escaping (URL, Error?) -> Void) -> Void

    static let appKit: Starter = { receiver, destination, queue, reader in
        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue, reader: reader)
    }

    let folder: URL
    private let lock = NSLock()
    private var urls: [URL?]
    private var failures = 0
    private var remaining: Int
    private var waiter: CheckedContinuation<(urls: [URL], failures: Int), Never>?

    init(receivers: [NSFilePromiseReceiver], start: Starter = PromisedFiles.appKit) {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("downwrite-drop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        urls = Array(repeating: nil, count: receivers.count)
        remaining = receivers.count
        let queue = OperationQueue()
        for (position, receiver) in receivers.enumerated() {
            start(receiver, folder, queue) { [self] url, error in
                arrived(position: position, url: url, error: error)
            }
        }
    }

    private func arrived(position: Int, url: URL, error: Error?) {
        lock.lock()
        if error == nil { urls[position] = url } else { failures += 1 }
        remaining -= 1
        let answer = remaining == 0 ? (urls: urls.compactMap { $0 }, failures: failures) : nil
        let waiting = answer == nil ? nil : waiter
        if answer != nil { waiter = nil }
        lock.unlock()
        if let answer, let waiting { waiting.resume(returning: answer) }
    }

    /// The received files and how many promises failed, once every promise has been answered.
    func wait() async -> (urls: [URL], failures: Int) {
        await withCheckedContinuation { continuation in
            lock.lock()
            if remaining == 0 {
                let answer = (urls: urls.compactMap { $0 }, failures: failures)
                lock.unlock()
                continuation.resume(returning: answer)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func discard() { try? FileManager.default.removeItem(at: folder) }
}
