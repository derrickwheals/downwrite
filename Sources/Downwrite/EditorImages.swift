import AppKit
import DownwriteCore

/// Pasting and dropping images into a document (DW-002). The entry points read the pasteboard and remember where the images are
/// to go; a serial queue then runs `ImageIntake.prepare` off the main thread and, back on it, inserts the links as one undoable
/// edit at the remembered place, moved through anything typed in the meantime. The reading and writing is in `ImageIntake`, the
/// placement in `ImagePlacement` (Core).

/// One paste or drop: what to add and where, as the text and the selection were when it was asked for.
struct ImageJob {
    enum Kind { case paste, drop }
    var id: Int
    var kind: Kind
    var sources: [ImageSource]
    var skippedFiles: [String]
    /// The selection (paste) or the insertion point (drop) in `snapshot`.
    var position: NSRange
    var snapshot: String
    /// An earlier job that was waiting for the same place: this one goes after what that one inserts, so a quick ⌘V⌘V keeps its order.
    var follows: Int?
}

/// Where a finished job left the text and the caret.
struct ImageInsertion {
    var text: String
    var caret: NSRange
}

extension EditorCoordinator {
    // MARK: Entry points

    /// Edit ▸ Paste with images on the pasteboard (R1, R3). Returns whether it took the paste: false leaves everything to the
    /// text view as it always was (nothing image-like, text that wins, a context R5 refuses, IME marked text).
    @discardableResult
    func pasteImages() -> Bool {
        guard let tv = textView, !tv.hasMarkedText() else { return false }
        let pasted = ImageIntake.read(imagePasteboard)
        guard ImagePasteRule.prefersImages(pasted.content), !pasted.sources.isEmpty else { return false }
        return enqueueImages(kind: .paste, sources: pasted.sources, skipped: pasted.skippedFiles, at: tv.selectedRange())
    }

    /// Whether Edit ▸ Paste should be available for what is on the pasteboard: images that win (R3) and a place R5 allows. The text
    /// view alone would disable Paste for an image-only pasteboard (it cannot read one), so ⌘V would never arrive. Only the types
    /// are looked at; no image data is copied.
    func canPasteImages() -> Bool {
        guard let tv = textView, !tv.hasMarkedText(), ImagePasteRule.prefersImages(ImageIntake.read(imagePasteboard, copyingData: false).content) else { return false }
        guard analysis.length == tv.textStorage?.length else { return true }             // an analysis that is a moment behind: let the paste decide
        return ImagePlacement.edit(links: ["![](assets/x.png)"], in: analysis, text: tv.string, selection: tv.selectedRange()) != nil
    }

    /// Remembers the place and queues the work. False when R5 refuses the place (the text is analysed afresh first).
    func enqueueImages(kind: ImageJob.Kind, sources: [ImageSource], skipped: [String], at position: NSRange) -> Bool {
        guard let tv = textView, tv.window != nil else { return false }
        flushPendingAnalysis()
        guard analysis.length == tv.textStorage?.length,
              ImagePlacement.edit(links: ["![](assets/x.png)"], in: analysis, text: tv.string, selection: position) != nil else { return false }
        watchWindowClosing(tv.window)
        let job = ImageJob(id: nextImageJobID, kind: kind, sources: sources, skippedFiles: skipped, position: position, snapshot: tv.string,
                           follows: pendingImageJobs.last.flatMap { $0.position == position ? $0.id : nil })
        nextImageJobID += 1
        pendingImageJobs.append(job)
        let previous = imageQueueTail
        imageQueueTail = Task { @MainActor [weak self] in
            await previous?.value
            await self?.runImageJob(job)
        }
        return true
    }

    /// Returns once every queued paste and drop has finished (for tests and the real-app step).
    func waitForImageWork() async {
        while let tail = imageQueueTail {
            await tail.value
            if imageQueueTail == tail { break }
        }
    }

    private func watchWindowClosing(_ window: NSWindow?) {
        guard imageCloseObserver == nil, let window else { return }
        imageCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.imageWindowClosed = true }
        }
    }

    // MARK: Running a job

    private func runImageJob(_ job: ImageJob) async {
        defer {
            pendingImageJobs.removeAll { $0.id == job.id }
            if pendingImageJobs.isEmpty { imageInsertions.removeAll() }
        }
        guard isImageWindowOpen else { return }

        var folder = imageDocumentFolder()
        if folder == nil {
            guard let saved = await requestImageSave() else { return }
            folder = saved.deletingLastPathComponent()
        }
        guard let folder, isImageWindowOpen else { return }

        let (now, zone, cap, prepare, sources) = (imageClock(), imageTimeZone, imageMaxBytes, imagePrepare, job.sources)
        let outcomes: [Result<PreparedImage, Error>] = await Task.detached(priority: .userInitiated) {
            sources.map { source in Result { try prepare(source, folder, now, zone, cap) } }
        }.value
        guard isImageWindowOpen, let tv = textView else { return }                    // the files stay in assets/ (R20)

        var prepared: [PreparedImage] = []
        var problems: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let image): prepared.append(image)
            case .failure(let error): problems.append((error as? ImageIntakeError)?.message ?? error.localizedDescription)
            }
        }
        guard !prepared.isEmpty else {
            notifyImages(title: "The image was not added", lines: problems + skippedLine(job))
            return
        }

        flushPendingAnalysis()
        let text = tv.string
        let position = rememberedPosition(of: job, in: text)
        guard analysis.length == text.utf16.count,
              let edit = ImagePlacement.edit(links: prepared.map(\.link), in: analysis, text: text, selection: position) else {
            // The place turned into something R5 refuses while the files were being made (P1): nothing is inserted.
            let names = prepared.map { "“\($0.fileName)”" }.joined(separator: ", ")
            notifyImages(title: "The link was not added",
                         lines: ["\(names) \(prepared.count == 1 ? "was" : "were") saved in “assets”, but the place for the link has become code, a table or something else images can't go in. Paste again where you want it."]
                            + problems + skippedLine(job))
            return
        }

        openFoldsHidingImages(at: edit.range.location)
        tv.apply(edit)
        tv.undoManager?.setActionName(actionName(for: job.kind, count: prepared.count))
        imageInsertions[job.id] = ImageInsertion(text: tv.string, caret: edit.selection)

        announceImages(prepared)
        var lines: [String] = []
        for image in prepared {
            for note in image.notes {
                switch note {
                case .scaled(let from, let to):
                    lines.append("“\(image.fileName)” was scaled from \(from) to \(to) pixels so that it previews: previews and exports take images up to 8 MB.")
                case .tooBigToPreview:
                    lines.append("“\(image.fileName)” is too big to preview (over 8 MB), so it was added as it is.")
                }
            }
        }
        notifyImages(title: problems.isEmpty ? (prepared.count == 1 ? "The image was added with changes" : "The images were added with changes")
                                              : "Not every image was added",
                     lines: lines + problems + skippedLine(job))
    }

    private var isImageWindowOpen: Bool { textView?.window != nil && !imageWindowClosed }

    /// Where the job's images go now: the remembered place moved through whatever was typed since (R20), or, for a job queued
    /// behind another at the same place, the caret that one left.
    private func rememberedPosition(of job: ImageJob, in text: String) -> NSRange {
        if let earlier = job.follows, let done = imageInsertions[earlier] {
            return TextDiff.replacement(from: done.text, to: text).map { TextDiff.map(done.caret, through: $0) } ?? done.caret
        }
        return TextDiff.replacement(from: job.snapshot, to: text).map { TextDiff.map(job.position, through: $0) } ?? job.position
    }

    /// The links are never left hidden (R6): folds hiding the place open, and so does the fold of a heading the paragraph goes
    /// in after.
    private func openFoldsHidingImages(at location: Int) {
        guard !foldState.isEmpty else { return }
        var folds = foldState.revealing(NSRange(location: location, length: 0), in: analysis)
        switch analysis.line(at: location).kind {
        case .heading, .setextUnderline:
            if let header = folds.headerFold(containing: location, in: analysis) { folds = folds.toggled(header) }
        default: break
        }
        if folds != foldState { setFoldState(folds) }
    }

    private func actionName(for kind: ImageJob.Kind, count: Int) -> String {
        switch kind {
        case .paste: count == 1 ? "Paste Image" : "Paste Images"
        case .drop: count == 1 ? "Drop Image" : "Drop Images"
        }
    }

    // MARK: Where the document lives (R17)

    /// The folder of the document in this window, taken from the `NSDocument` (which knows a save at once; SwiftUI's binding
    /// updates later) and from the coordinator's `fileURL` when there is no document. Nil: untitled.
    func imageDocumentFolder() -> URL? {
        let document = textView?.window.flatMap { NSDocumentController.shared.document(for: $0) }
        return (document?.fileURL ?? fileURL)?.deletingLastPathComponent()
    }

    /// An untitled document cannot have an images folder: the person is asked to save first (step 11 gives this its sheet).
    private func requestImageSave() async -> URL? { await requestSave?() }

    // MARK: Feedback (R21–R23)

    private func skippedLine(_ job: ImageJob) -> [String] {
        job.skippedFiles.isEmpty ? [] : ["Skipped, because \(job.skippedFiles.count == 1 ? "it is not an image" : "they are not images"): \(job.skippedFiles.joined(separator: ", "))."]
    }

    private func notifyImages(title: String, lines: [String]) {
        guard !lines.isEmpty else { return }
        let message = lines.joined(separator: "\n\n")
        if let onImageNotice { onImageNotice(title, message); return }
        guard let window = textView?.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func announceImages(_ images: [PreparedImage]) {
        let message = images.count == 1 ? "Image inserted: \(images[0].fileName)" : "\(images.count) images inserted"
        onAnnouncement?(message)
        guard let tv = textView else { return }
        NSAccessibility.post(element: tv, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
