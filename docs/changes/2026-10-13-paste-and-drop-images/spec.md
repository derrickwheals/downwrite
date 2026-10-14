---
type: spec
id: 2026-10-13-paste-and-drop-images
intent: ./intent.md
status: approved
approved: 2026-10-14
---

# Spec: Paste and drop images into a document

## Summary

Pasting an image (a screenshot, "Copy Image" from a browser, an image copied in Preview or Finder) or dropping image files onto the editor saves each image as a file in an `assets/` folder next to the saved document and inserts an ordinary relative Markdown image link, `![](assets/image-20261013-094112.png)`, as its own paragraph at the caret or drop point. The image then previews, prints and exports exactly like a hand-typed link. The insertion is one undoable edit; an untitled document is first offered a save; an image that is too big for the 8 MB preview cap is scaled down; and every failure or alteration is explained, never silent. Everything that is not an image pastes and drops as it does today.

## Requirements

### Triggers and what counts as an image

- **R1** — **Paste.** In a saved document, Edit ▸ Paste (⌘V) with an image on the pasteboard (decided by R3) writes the image into `assets/` (R9–R14) and inserts its link (R10, R11) in place of the selection. "Paste and Match Style" (`pasteAsPlainText`) and rich-text paste do not insert images.
- **R2** — **Drop.** Dropping onto the editor text (a drop onto a table grid cell is handled by the cell, as today) one or more image files (`public.file-url` items), image files delivered as file promises (Photos, some browsers), or raw image data (a drag from a browser that supplies PNG/TIFF but no file) does the same as R1 at the drop point (R11). While an image drag is over the editor the pointer shows the copy badge and the drop point is marked as it is for dropped text. A drag that is not an image drag (R3), including text dragged within the editor, is handled by the text view exactly as today.
- **R3** — **Image or text?** One pure rule, `ImagePasteRule.prefersImages(_:)` in Core, decides paste and drop alike from a `PasteboardImageContent` summary (plain text if any, whether image data is present, the file names of image files, whether non-image files are present). Images win when the pasteboard holds image data or image files **and** its plain text is absent, or is a single line (no line break) that names an image: it looks like a URL (`Formatter.looksLikeURL`) or ends in an image extension (`png jpg jpeg gif webp svg tif tiff heic heif bmp`). Any other plain text alongside an image (spreadsheet cells, a web selection) wins and the paste is handled as today. A pasteboard of only non-image files is not an image paste.
- **R4** — **Unchanged paths.** The following behave exactly as today and are guarded by tests: plain-text paste, rich-text paste, a URL pasted over a selection (it becomes `[selection](url)` unless R3 prefers an image, in which case the image replaces the selection), paste inside a table grid cell, paste and drop with IME marked text present, a drop of non-image files (their path is inserted as text), a drop of text, and any paste or drop in a context R5 refuses.
- **R5** — **Where it applies.** Every line the selection (or the drop point) touches must be of an allowed kind, otherwise nothing is intercepted and R4 applies. Allowed: body text, list items, block quotes, ATX and setext headings. Refused: fenced code (`.fence`, `.codeBlock`), YAML front matter, table lines (`.tableHeader/.tableDelimiter/.tableRow`), HTML blocks (`.html`) and horizontal rules. A pending debounced analysis is flushed first (`flushPendingAnalysis`), so the decision uses the current text.
- **R6** — **Folded text and source view.** The insertion is never left hidden: if the insertion point lies in text a fold hides, the fold opens first (the existing "the caret is never hidden" rule, `FoldState.revealing`). The Markdown source view (⌘/) works the same as the normal view; the card appears when the person leaves it.

### Where the files go and what the link says

- **R7** — **Images folder.** Files go in a folder named `assets` in the document's own folder (a fixed name; no setting). It is created on first use. If `assets` exists and is a folder, it is used (a symbolic link to a folder counts). If it exists and is not a folder, or cannot be created or written, that is a failure (R21).
- **R8** — **Never overwrite.** A file is created exclusively; if the name is taken, the next free name is used (`name-2.png`, `name-3.png`, …). Identical bytes are not detected or reused. Nothing Downwrite does ever deletes or replaces an existing file.
- **R9** — **Names.** A pasted image (pasteboard data) is named `image-YYYYMMDD-HHMMSS.<ext>` from the local time. A dropped or Finder-copied file keeps its own name: the stem has every character that is not a letter, a digit, `.`, `_` or `-` replaced by `-` (spaces, `/ : ( ) [ ] # ? % & " '` and control characters included), runs of `-` collapsed, leading `.` and `-` removed, normalised to NFC and cut to 60 characters; an empty stem becomes `image`. Letters of any script are kept. The extension is the saved format's canonical one in lower case (`png jpg gif webp svg`).
- **R10** — **The link.** `![](assets/<name>)`: empty alt text, a path relative to the document, `/` between segments, and each segment percent-encoded except for letters (any script), digits and `- . _ ~`. So a space is `%20`, `(` `)` are `%28 %29`, `#` `?` `%` are `%23 %3F %25`. The angle-bracket form `<…>` is never used. The link resolves through `ImageLoader.fileURL(for:base:)` to the file written (tests include a name with a space, parentheses, `#`, `%`, `é` and `日本`). The `.md` file contains nothing else new.
- **R11** — **Placement.** The links go in as their own paragraphs (a blank line before and after, none added where one already exists) so the inline preview applies, and the caret ends immediately after the inserted text. The exact edits are pinned by the table under *Behaviour details*; they are produced by `ImagePlacement.edit` in Core. Several images give one paragraph each, in order. In a list item or block quote the links are inserted at the caret with no line breaks, separated by one space. In a heading the links go in their own paragraph after the heading, and the selection is not replaced.

### Formats, metadata and size

- **R12** — **Formats.** The saved file is always PNG, JPEG, GIF, WebP or SVG. Kept byte for byte: PNG, JPEG, GIF, WebP, SVG. Converted: TIFF, BMP and other formats ImageIO can read become PNG; HEIC and HEIF become JPEG (quality 0.9). Pasteboard data is taken in this order: PNG, JPEG, GIF, WebP, HEIC, TIFF. An animated image (more than one frame: GIF, WebP, animated PNG) is never re-encoded or flattened. PDF is not an image here. The format is decided by the bytes (`ImageFormat.sniff`), not the name, so a PNG named `.jpg` is saved as `.png`; a file whose bytes ImageIO (or the SVG check) does not accept as an image is a failure for that file (R21).
- **R13** — **Metadata is kept.** Downwrite does not remove metadata, GPS location included (the person's decision of 2026-10-13, against the recommendation to remove location). A kept file is a byte-identical copy. A converted or scaled file carries over the source's metadata where ImageIO does, and never adds any. The README says so.
- **R14** — **Size.** The saved file may not exceed `ImageLoader.maxEmbeddedBytes` (8,000,000 bytes), the limit the preview and the export embed. A still PNG, JPEG, HEIC, TIFF or BMP image whose encoded form is larger is scaled down, keeping its aspect ratio and format, by successive steps (`ImageShrink`, Core, pure) until it fits, and R22 reports the new size. If it still does not fit at a long edge of 320 px it is a failure. An animated image or an SVG larger than the cap cannot be shrunk safely, so it is copied as it is and R22 says it is too big to preview. Intake limits, so the app cannot be made to chew without end: a source over `ImageLimits.maxSourceBytes` (100,000,000) or over `ImageLimits.maxPixels` (200 million pixels) is a failure ("too large to process"); decoding for scaling goes through ImageIO's thumbnail path so the full bitmap is never held twice.

### Dropped and Finder-copied files

- **R15** — **Link in place.** An image file (R12 kind kept as is, no larger than the cap) that lies inside the document's folder or below it, comparing paths with symbolic links resolved, is not copied: the link is its path relative to the document's folder, built by `ImageLink.relativePath`, with the same encoding as R10. This includes a file already in `assets/`. Nothing is written for it. Any other image file is read and saved to `assets/` by R7–R14. A file inside the tree that needs conversion or shrinking is saved to `assets/` as a new file (the original is untouched).
- **R16** — **Several and mixed files.** Each image becomes one link in drop order. Non-image files in the same drop or paste are skipped and R22 names them. If no file is an image, R3 does not prefer images and R4 applies (the drop inserts the path as text, as today).

### Untitled documents

- **R17** — **Save first.** In a document with no file (`NSDocument.fileURL == nil`), an image paste or drop reads the image bytes immediately (the pasteboard may change) and shows a sheet on the window: "Save the document first" / "Downwrite keeps pasted and dropped images in an “assets” folder next to the document. Save this document, and the image will be added." with **Save…** (default) and **Cancel**. Save… runs the normal save panel; when the save succeeds, the held images are written and inserted as in R1/R2 at the remembered position (R20). Cancel, or cancelling the save panel, inserts and writes nothing. Images already pasted into a document that is later saved elsewhere ("Save As", move) are not moved; links are relative and the person moves `assets/` with the document.

### One edit, no side effects

- **R18** — **One undoable edit.** The links go in through `EditorTextView.apply` (`shouldChangeText` → `replaceCharacters` → `didChangeText`) as a single change, so one ⌘Z removes all of them and ⇧⌘Z puts them back. The Undo menu item reads "Undo Paste Image" or "Undo Drop Image" (plural for several). Undo never deletes a file; Redo reuses the same link and the file is still there. Deleting a link never deletes a file; orphaned files stay in `assets/`.
- **R19** — **Nothing else moves.** Writing into `assets/` does not touch the `.md` file's modification date, so the external-change watcher (`checkForExternalChange`) does not reload. Folds are carried through the insertion by the existing `TextDiff` mapping, scroll position is kept except that the insertion is scrolled into view (as `apply` does), and the source-view and table-grid state are unchanged.
- **R20** — **Stays responsive.** Reading, converting and writing happen off the main thread. Meanwhile the editor takes input normally. When the files are ready the links are inserted at the position the paste or drop targeted, moved through any edits made in the meantime (`TextDiff.map`); if the window has closed nothing is inserted. A second paste or drop in the same window while one is running waits its turn, so names and order are predictable.

### Feedback

- **R21** — **Failure.** If an image cannot be added (folder not writable or not creatable, `assets` is a file, disk full, unreadable or non-image bytes, over the intake limits, cannot be made small enough) an alert sheet says why in a sentence with the file name; nothing is inserted for that image and no partial file is left behind. With several files, the ones that succeeded are inserted (one edit) and the sheet lists the ones that failed; if none succeeded, nothing is inserted at all.
- **R22** — **Altered or skipped.** When an image was scaled down (old and new pixel size, and that the preview limit is 8 MB), is too big to preview, or non-image files were skipped, the insertion happens and an OK-only sheet says so. A plain success shows no sheet.
- **R23** — **Announcement.** Success is announced to VoiceOver as "Image inserted: image-….png" ("3 images inserted" for several) through `onAnnouncement` and `NSAccessibility` at medium priority, the same seam callouts and code copy use.

### Pipeline and docs

- **R24** — **Preview and export.** A pasted image previews inline as a card, and Print, Export as PDF and Export as HTML embed it as a `data:` URI, with no change to `ImageLoader`, `DocumentHTML` or `DocumentOutputController`. A test proves this end to end (see *Verification*); it is not assumed.
- **R25** — **Docs.** `README.md` gains a short "Images" note (how to add one, the `assets/` folder, that location metadata is kept, that very large images are scaled). `CLAUDE.md` gains an architecture bullet for this feature. `docs/ROADMAP.md` DW-002 status is updated. The `FEATURE-LIST.md` row is owed until the tag exists (CLAUDE.md, *Feature list*).

## Out of scope

- Cropping, resizing by hand, annotating, an image gallery or manager, renaming images afterwards.
- Downloading a remote image from a pasted URL; a drag that offers only a URL and no image data or file is a text drop as today.
- Other attachments: PDF, audio, video, any non-image file.
- A Settings control for the images folder, a naming template, or the size limit.
- Alt-text entry (the alt text is empty; the person types it).
- Moving or copying `assets/` on Save As or when a document is moved; fixing links after the fact.
- Deleting files (undo, deleting a link, orphan clean-up) and detecting duplicate images.
- Removing GPS or other metadata (R13).
- Pasting or dropping into a table grid cell, a code block or front matter (R4, R5).
- Linking a picture by absolute path or `file:` URL; every link written is relative.

## Design

### Interfaces

Pure, in `DownwriteCore` (Linux-testable, new file `Sources/DownwriteCore/ImageInsertion.swift`; names are the contract, signatures may be refined in the plan):

```swift
public enum ImageFormat: Sendable, Equatable { case png, jpeg, gif, webp, svg, tiff, heic, bmp, other }
extension ImageFormat {
    public static func sniff(_ bytes: [UInt8]) -> ImageFormat?        // by magic bytes / <svg, never by name
    public var saved: (format: ImageFormat, keepsBytes: Bool)         // R12
    public var fileExtension: String                                 // png jpg gif webp svg
}
public enum ImageLimits { public static let maxSourceBytes = 100_000_000; public static let maxPixels = 200_000_000; public static let minLongEdge = 320 }

public struct PasteboardImageContent: Sendable, Equatable {
    public var plainText: String?; public var hasImageData: Bool
    public var imageFileNames: [String]; public var hasOtherFiles: Bool
}
public enum ImagePasteRule { public static func prefersImages(_ content: PasteboardImageContent) -> Bool }   // R3

public enum ImageNaming {
    public static func pastedName(at date: Date, timeZone: TimeZone, fileExtension: String) -> String          // R9
    public static func droppedName(stem: String, fileExtension: String) -> String                              // R9
    public static func firstFree(_ name: String, isTaken: (String) -> Bool) -> String                          // R8
}
public enum ImageLink {
    public static let folderName = "assets"
    public static func markdown(path components: [String]) -> String                          // "![](assets/a%20b.png)"
    public static func relativePath(of file: [String], in folder: [String]) -> [String]?     // nil unless inside; components already symlink-resolved
}
public enum ImageShrink { public static func nextLongEdge(current: Int, bytes: Int, limit: Int) -> Int? }   // nil = give up (R14)

public enum ImagePlacement {
    /// nil when R5 refuses the context. Otherwise the replacement text and the caret right after it (R11).
    public static func edit(links: [String], in analysis: MarkdownAnalysis, text: String, selection: NSRange) -> TextEdit?
}
```

App target (macOS only; new files `Sources/Downwrite/ImageIntake.swift` for pasteboard reading, ImageIO conversion and the exclusive write, and `Sources/Downwrite/EditorImages.swift` for the paste/drop entry points and feedback):

- `EditorTextView.paste(_:)` asks the images path first (R3, R5, then R1), then falls through to the existing URL-over-selection code, then `super`. The pasteboard it reads is a property (`imagePasteboard`, default `.general`) so tests use a private named pasteboard; the existing URL-over-selection code reads through it too. `importsGraphics` stays `false`: Downwrite never lets AppKit embed an `NSTextAttachment`.
- `EditorTextView` overrides `draggingEntered`, `draggingUpdated`, `prepareForDragOperation` and `performDragOperation`: when R2/R3/R5 say it is an image drop, it handles it (copy operation, drop point from `characterIndexForInsertion(at:)`); otherwise it calls `super`. File promises are received into a private temporary folder that is removed afterwards.
- A single serial worker per `EditorCoordinator` (R20) runs `ImageIntake.prepare(source:, documentFolder:, now:) async throws -> PreparedImage` (bytes, final file name, link path, notes for R22) off the main thread, and the main actor applies the batch.
- Seams for tests, as elsewhere in the app: `imagePasteboard`, a clock, `presentImageNotice(title:message:)` (the alert sheet), `requestSave(for:) async -> Bool` (R17), and `onAnnouncement`.
- The Undo action name is set with `undoManager?.setActionName`.

### Data

No new stored data, preference, defaults key or file format. On disk the result is `<document folder>/assets/<name>.<ext>` plus one Markdown paragraph per image. No dependency is added; conversion and scaling use ImageIO and UniformTypeIdentifiers.

### Files and components involved

- `Sources/DownwriteCore/ImageInsertion.swift` (new) — everything pure above.
- `Sources/Downwrite/ImageIntake.swift` (new) — pasteboard to `PasteboardImageContent`, ImageIO decode, convert, shrink, exclusive atomic write (`Data.write` with `.atomic` and `.withoutOverwriting`, retrying on "file exists"), the 100 MB / 200 MP intake limits.
- `Sources/Downwrite/EditorImages.swift` (new) — coordinator extension: queue, save-first sheet, insertion at a remembered position, announcements, alert sheets.
- `Sources/Downwrite/EditorTextView.swift` — `paste` (`:359`) and the drag-destination overrides; `apply` is used as is.
- `Sources/Downwrite/EditorView.swift` — `EditorCoordinator` owns the queue and the seams; `fileURL` and `NSDocumentController.shared.document(for:)` give the document folder and untitled state; `flushPendingAnalysis` and `checkForExternalChange` are read, not changed.
- `Sources/Downwrite/Previews.swift` — `ImageLoader` is read, not changed (R24).
- `Sources/Downwrite/TableGrid.swift` — not changed (R4); a regression test pins it.
- `Tests/DownwriteCoreTests/ImageInsertionTests.swift` (new), `Tests/DownwriteTests/ImagePasteTests.swift` and `ImageDropTests.swift` (new), `Sources/Downwrite/SelfTestImagePaste.swift` (new real-app step), `Tests/Fixtures/` — the test images (PNG, JPEG, animated GIF, SVG, TIFF, HEIC, an over-cap PNG) are generated by the tests with ImageIO, not committed; only a Markdown document for the real-app step is added there.
- `README.md`, `CLAUDE.md`, `docs/ROADMAP.md` — R25.

### Behaviour details

**Placement, algorithm.** For a body line the edit replaces the selection with `prefix + links joined by "\n\n" + "\n\n"`, and the caret goes right after it. `before` is the text of the line up to the start of the replaced range and `after` the text from its end to the end of the line (terminator excluded). `prefix` is `"\n\n"` when `before` has a character other than a space or tab; otherwise `"\n"` when a previous line exists and is not blank; otherwise empty. When `after` is only spaces or tabs, the replaced range also takes in that line's own terminator and, if the next line is blank, that blank line too, so the new `"\n\n"` is the only separator and no stray blank lines pile up. In a heading the position is first moved to the end of the heading's last line and any selection is left alone. In a list item or block quote nothing but the links is inserted, each preceded by one space unless the previous character is a space or the start of the line's content.

**Placement, pinned.** `|` is the caret or selection; `⟨L⟩` is the link `![](assets/x.png)`. Each row is a unit test of `ImagePlacement.edit` (text before → text after, caret shown as `|`).

| Case | Before | After |
| --- | --- | --- |
| Empty document | `\|` | `⟨L⟩\n\n\|` |
| Blank line between paragraphs | `A\n\|\nB` | `A\n\n⟨L⟩\n\n\|B` |
| Start of a line, previous line has text | `A\n\|B` | `A\n\n⟨L⟩\n\n\|B` |
| End of the last line, no trailing newline | `A\|` | `A\n\n⟨L⟩\n\n\|` |
| Mid-line (paragraph split in two) | `Hello \|world` | `Hello \n\n⟨L⟩\n\n\|world` |
| Selection replaced | `Hello [world]` | `Hello \n\n⟨L⟩\n\n\|` |
| After a trailing newline at the end | `A\n\|` | `A\n\n⟨L⟩\n\n\|` |
| Two images | `\|` | `⟨L1⟩\n\n⟨L2⟩\n\n\|` |
| List item, caret at end | `- item\|` | `- item ⟨L⟩\|` |
| Heading, caret anywhere in it | `# Ti\|tle\nText` | `# Title\n\n⟨L⟩\n\n\|Text` |
| Code fence, front matter, table | any | `nil` (as today) |

**Baseline today (probed 2026-10-13 on macOS with a plain `NSTextView`, `isRichText = false`, `importsGraphics = false`, as the editor is built).** An image-only pasteboard (PNG, TIFF or an `NSImage`) pastes nothing (`readSelection` returns false). A pasteboard with a file URL pastes the file's absolute path as text, e.g. `/Users/…/shot one.png`. Finder's "Copy" of a file (file URL plus its name as a string) pastes the name. An image plus a string pastes the string. The view's acceptable drag types include file names, PNG, TIFF, PDF and text, so a file drop inserts its path. The registered drag types are empty until the view is in a window, so whether a raw-image-data drag is accepted today is pinned by the first drop test in the plan rather than assumed. These are the "as today" behaviours of R4.

**Where the position comes from.** Paste uses the selection. A drop uses `characterIndexForInsertion(at:)` at the drop point, with no selection to replace. The R5 check is made on the line(s) the position or selection touches. The position is remembered across the asynchronous work and across the save-first sheet by mapping it through each intervening edit with `TextDiff.map`, as `FoldState.mapped` does.

**Untitled flow.** The sheet is shown once per paste or drop. While it is up the images are held in memory (bounded by R14's intake limits). If the document gets a file but the window's `fileURL` binding has not updated yet, the folder is taken from `NSDocument.fileURL`, not from the binding.

**Failure sentences** (wording is a plan decision; the facts are required): the folder and why ("“assets” in “Notes” can't be created: the folder is read-only"), the file ("“photo.heic” isn't an image Downwrite can read"), the limit ("“scan.tif” is over the 100 MB Downwrite will process"), and the shrink floor ("“poster.png” can't be made smaller than 8 MB without becoming unreadable").

**Why own paragraph and not at the caret.** The analyzer previews an image only when it is the whole content of a top-level body line (`MarkdownAnalyzer.finish`), so a link inserted mid-sentence would be styled but never previewed. A blank line on each side also keeps the link a separate paragraph in every other renderer.

**What the shrink loop does.** Decode once through ImageIO's thumbnail path at the first target long edge, encode, measure; the next edge comes from `ImageShrink.nextLongEdge` (the previous edge scaled by the square root of `limit / bytes`, with a safety margin, always strictly smaller). It stops at the first encoding within the cap or at `minLongEdge`.

## Flags

- **Metadata kept (R13), against the recommendation.** The recommended option was to remove GPS location. The person chose to keep everything. A geotagged photo dropped into a document keeps its location in the file, and the file is published whenever the document's folder is. Recorded as a decision, not an oversight; the README states it. Revisit with a new intent if wanted (ImageIO's `kCGImageMetadataShouldExcludeGPS` copy option would do it without re-compressing).
- **Empty alt text (the *Names + alt* decision).** An image link with `![]()` is, in Downwrite's HTML export and for screen readers, a decorative image. The person chose empty alt text with no caret placement in it. This is relevant to DW-011 (accessibility audit) and to the "alt text entry" out-of-scope item.
- **"At the caret" versus "own paragraph".** The intent says the link is inserted "at the caret". Placement (R11) puts it at the caret but surrounds it with line breaks, which splits a paragraph when the caret is mid-line. Resolved by the *Placement* decision; the intent's wording is read as "at the caret position".
- **Image beats URL-over-selection.** The intent keeps "pasting a URL over selected text" unchanged, and the *Mixed paste* decision lets an image win when the only text is a URL that names it (as Safari's "Copy Image" can produce). So with a selection, a pasteboard of an image plus its URL inserts the image instead of making a link (R3, R4). A URL alone still makes a link.

## Verification

"Working" means: a person pastes or drops an image into a saved document, sees it preview with no further step, can undo it, can move the folder and the link still works, and every bad case tells them why.

**Automated** (listed in detail in the plan):

1. `scripts/linux-test.sh` is green, including `ImageInsertionTests`: every row of the placement table; `ImagePasteRule` over text/image combinations (screenshot, Safari "Copy Image" with a URL, Finder copy with a file name, spreadsheet text with an image preview, files with a PDF, no image at all); names (timestamp, sanitising, collision suffixes `-2`, `-3`, empty stem, 60-character cut, NFC); link encoding of a space, `( ) # ? % é 日本`; `relativePath` inside/outside/sibling-with-same-prefix (`/Docs` vs `/Docs2`); `ImageShrink` always strictly decreasing and ending; `ImageFormat.sniff` for each format and for a PNG named `.jpg`.
2. `swift test` on a Mac is green, including `ImagePasteTests` and `ImageDropTests`, which use a private named pasteboard (released in a teardown) and a test `NSDraggingInfo`: paste a PNG into a saved document in a temporary folder and check the file exists in `assets/`, the text has the link, the preview card exists for it, one undo removes the link and leaves the file, redo restores it, and `checkForExternalChange()` returns false afterwards; the same for a drop of two files, a file already in the tree (no file written), a HEIC (saved as `.jpg`), a TIFF pasteboard (saved as `.png`), an animated GIF (frames kept), an over-cap PNG (saved under 8,000,000 bytes, notice shown) and an over-cap animated GIF (copied, notice shown); each refused context (code fence, front matter, table line, table grid cell) leaves the text and the folder untouched; an unwritable folder and an `assets` file in the way show the failure sheet and insert nothing; an untitled document shows the save sheet and, with the save stubbed, inserts after the save and writes nothing on Cancel; typing during the work does not lose or misplace the link; the plain-text, rich-text and URL-over-selection pastes are unchanged; a folded section opens for the insertion.
3. Export: with a pasted image in a document, `DocumentHTML` prepared and assembled through `DocumentOutputController`'s image path produces an `<img src="data:image/…">` for the link (R24).
4. Real app: `dist/Downwrite.app/Contents/MacOS/Downwrite --selftest-out=<dir> --selftest-input=<Tests/Fixtures/…md>` (a new step, `SelfTestImagePaste.swift`, with its option named in the plan) pastes and drops into a real window, checks the files, the link, the card and an undo, and writes its result into `selftest-report.txt`. `scripts/ci-local.sh` passes.

**By hand** (the plan lists these as owed until done; they need a real desktop session and the Finder, Photos and Safari):

- Take a screenshot to the clipboard (⌃⌘⇧4), paste it into a saved document: it previews, the file is in `assets/`, the link reads `assets/image-….png`.
- Drag a PNG, a JPEG, a HEIC from Finder; drag a photo from Photos (file promise); drag and "Copy Image" an image from Safari; copy an image in Preview; copy a file in Finder and paste. Each previews; the HEIC arrives as `.jpg`.
- Drop a 12-megapixel photo and a 20 MB PNG: both end under 8 MB and a sheet says what changed; an animated GIF still animates in a browser.
- Paste into a new untitled document: the save sheet appears; Save… completes the paste; Cancel leaves nothing.
- Drop onto a read-only folder's document and onto a document whose folder has an `assets` file: a clear sheet, nothing inserted.
- Move the document and its `assets/` folder somewhere else and reopen: the image still previews. Open the `.md` on GitHub or in another editor: the link resolves.
- With VoiceOver on, paste an image: "Image inserted: …" is spoken.
- Print and Export as PDF/HTML: the pasted image is in the output.
