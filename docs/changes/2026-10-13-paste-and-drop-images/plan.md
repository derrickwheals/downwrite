---
type: plan
id: 2026-10-13-paste-and-drop-images
intent: ./intent.md
spec: ./spec.md
status: in-progress    # draft | approved | in-progress | done
approved: 2026-10-14
branch: change/2026-10-13-paste-and-drop-images
---

# Plan: Paste and drop images into a document

## Approach

Everything that can be decided without a pasteboard goes into one new Core file, `ImageInsertion.swift`, with the names the spec fixed: the image-or-text rule (`ImagePasteRule`, R3), file names and collisions (`ImageNaming`), the percent-encoded relative link and the inside-the-tree test (`ImageLink`), the shrink schedule (`ImageShrink`), format sniffing (`ImageFormat`) and the placement edit (`ImagePlacement.edit`, R5 and R11). It is built and tested first, on Linux, with the placement table from the spec as its test cases. The app target then adds two files and two small hooks. `ImageIntake.swift` turns a pasteboard or a file list into a `PasteboardImageContent` summary and, off the main thread, turns one source into a file in `assets/` (sniff, keep or convert or scale with ImageIO, exclusive atomic write). `EditorImages.swift` is a coordinator extension that owns the entry points, a serial queue, the save-first sheet, insertion and feedback. `EditorTextView` gains the image path at the top of `paste` and the drag-destination overrides; everything else falls through to today's code.

The position is remembered as an offset plus a snapshot of the text it was taken in, and mapped to the current text with `TextDiff.replacement` + `TextDiff.map` when the files are ready, the same technique `carryFolds` already uses. That is simpler and safer than observing every edit while the work runs, and it works across the save-first sheet. The files are written before the links are inserted, so the first analysis after the insertion finds the file and the card appears. `ImageLoader`, `DocumentHTML` and `DocumentOutputController` are read, not changed (R24).

## Decisions

The spec leaves these gaps. Each is a choice for you to approve with the plan.

- **P1 · The place went stale.** If, by the time the files are ready, the remembered position has moved into a context R5 refuses (the person typed a fence around it), nothing is inserted. The files stay in `assets/` and a notice lists them and says why. This keeps R5 absolute and the result explainable; the alternative (moving the links to the end of the block) is more code for a rare case.
- **P2 · Which images shrink.** R14's list is taken literally: a still PNG, JPEG, HEIC, TIFF or BMP over the cap is scaled. A GIF, WebP or SVG over the cap, still or animated, is copied as it is and R22 says it is too big to preview (ImageIO cannot write WebP and a re-encoded GIF loses its palette).
- **P3 · What "animated" means.** More than one frame in a GIF, WebP or PNG file. A multi-page TIFF or a multi-image HEIC uses its first image.
- **P4 · Reading is split at the main thread.** The pasteboard is read on the main thread at the moment of the paste (the bytes are copied at once, as R17 requires); file contents, decoding, scaling and writing run off it (R20). The intake limits are checked from the file size and the header's pixel size before any decode.
- **P5 · `requestSave` returns the saved file's URL** (`nil` for cancel), not a Bool, so the folder comes from the save itself and not from SwiftUI's binding, which updates later. The document is found with `NSDocumentController.shared.document(for: window)`, as `configureOutput` does; the folder is `document.fileURL ?? coordinator.fileURL`, and both nil means untitled.
- **P6 · Drag mechanics.** `acceptableDragTypes` is overridden to add image data, file URLs and `NSFilePromiseReceiver.readableDraggedTypes`; the operation reported for an image drag is `.copy`. Whether `super.draggingUpdated` still draws the drop-point marker once the types are extended is not known; step 7 probes it, and the fallback is a thin accent bar drawn by `DWLayoutManager` from the drop index (invalidated like the copy controls).
- **P7 · The real-app step needs no fixture.** Like `SelfTestCodeCopy`, `SelfTestImagePaste` writes its own document into the run's window and generates its images. The spec's "a Markdown document for the real-app step in `Tests/Fixtures/`" is not needed, so `ci.yml` and `ci-local.sh` do not change. The development flag is `--selftest-imagepaste-only`.
- **P8 · Wording.** Sheet titles and sentences follow the spec's examples. Undo names are "Paste Image", "Paste Images", "Drop Image" and "Drop Images". The announcement is "Image inserted: image-20261013-094112.png" or "3 images inserted".

## Files that change

Core (Linux-testable):

- `Sources/DownwriteCore/ImageInsertion.swift` — new: `ImageFormat` (+ `sniff`, `saved`, `fileExtension`), `ImageLimits`, `PasteboardImageContent`, `ImagePasteRule`, `ImageNaming`, `ImageLink`, `ImageShrink`, `ImagePlacement`. No Apple-only API: dates through `Calendar` with an explicit time zone, NFC through `precomposedStringWithCanonicalMapping`, percent-encoding written by hand (letters of any script stay, so `addingPercentEncoding` is not used).
- `Tests/DownwriteCoreTests/ImageInsertionTests.swift` — new.

App (macOS only):

- `Sources/Downwrite/ImageIntake.swift` — new: pasteboard and file list to `PasteboardImageContent` and source descriptions; `prepare(...)` (sniff, ImageIO keep/convert/thumbnail-scale, metadata carried over, intake limits, exclusive atomic write with next-free-name retry bounded at 10,000); file-promise receiving into a private temporary folder that is removed afterwards.
- `Sources/Downwrite/EditorImages.swift` — new: `EditorCoordinator` extension: `pasteImages()`, `dropImages(...)`, the serial queue, the remembered position, `requestSave`, insertion through `EditorTextView.apply`, fold opening, undo name, notices and announcement.
- `Sources/Downwrite/EditorView.swift` — stored properties on `EditorCoordinator` (extensions cannot hold them), next to `codeCopyPasteboard` (`:87`): `imagePasteboard`, `imageClock`, `presentImageNotice`, `requestSave`, the queue tail.
- `Sources/Downwrite/EditorTextView.swift` — `paste` (`:359`) asks the images path first and reads the URL-over-selection code's pasteboard through `imagePasteboard`; new overrides `acceptableDragTypes`, `draggingEntered`, `draggingUpdated`, `prepareForDragOperation`, `performDragOperation` (each calls `super` when it is not an image drag).
- `Sources/Downwrite/SelfTestImagePaste.swift` — new real-app step; `Sources/Downwrite/SelfTest.swift` — the `--selftest-imagepaste-only` branch (next to `:86`) and step 8d (next to `:774`).
- Unchanged and pinned by tests: `Previews.swift` (`ImageLoader`), `TableGrid.swift`, `DocumentOutput.swift`, `DocumentAssemble.swift`, `Package.swift` (no dependency), `Info.plist`.

Tests (macOS):

- `Tests/DownwriteTests/ImageIntakeTests.swift` — new: formats, conversion, scaling, metadata, limits and the exclusive write, with images generated by ImageIO (nothing committed).
- `Tests/DownwriteTests/ImagePasteTests.swift`, `ImageDropTests.swift` — new (a fake `NSDraggingInfo` lives in `ImageDropTests.swift`).
- `Tests/DownwriteTests/DocumentOutputTests.swift` — one test added for R24, using its existing rig.

Docs:

- `README.md` (an Images note), `CLAUDE.md` (an architecture bullet), `docs/ROADMAP.md` (DW-002 status). `FEATURE-LIST.md` is not touched: its row is owed until the tag exists.

## Order of work

Core first, each step a commit with its tests (test before code where it reads naturally):

- [x] 1. `ImageFormat.sniff`, `saved`, `fileExtension`, `ImageLimits`: tests for PNG, JPEG, GIF, WebP, HEIC/HEIF, TIFF (both byte orders), BMP, SVG (plain, with an XML prolog, a BOM, a comment first), and bytes that are none of them.
- [x] 2. `ImageNaming`: `pastedName` (zero padding, the given time zone, not the machine's), `droppedName` (every character class in R9, NFC, 60-character cut that never splits a scalar, empty stem to `image`, leading dots), `firstFree` (`-2`, `-3`, bounded).
- [x] 3. `ImageLink`: `markdown(path:)` for a space, `( ) # ? % é 日本`, a segment per component; `relativePath` inside, outside, the same folder, the root `/Docs` against `/Docs2`, and the file being the folder itself.
- [x] 4. `ImageShrink.nextLongEdge`: strictly decreasing, always ends (`nil` at the floor), a huge ratio, a ratio near 1.
- [x] 5. `PasteboardImageContent` + `ImagePasteRule.prefersImages`: every combination named in the spec's verification (screenshot, Safari "Copy Image" with its URL, Finder copy with a file name, spreadsheet text with an image preview, files with a PDF, nothing).
- [x] 6. `ImagePlacement.edit`: each row of the spec's table as a test, then heading (selection kept), list item and block quote (spaces, no blank lines), a selection that spans body and fence (nil), setext heading, a document whose text contains an emoji before the caret (UTF-16 offsets), a trailing blank line, two and three links. Run `scripts/linux-test.sh` and commit.

App, in the order that keeps the risky unknowns early:

- [x] 7. Probe and baseline, before any change to `EditorTextView`: tests that pin what a plain editor does today (R4): image-only, file-URL, Finder-copy and URL-over-selection pastes; a text drop and a file drop; whether a raw-image drag is accepted before and after a window exists; and whether `super.draggingUpdated` marks the drop point once `acceptableDragTypes` is extended (answers P6). Record the answers in this plan's Deviations if they change the design.
- [ ] 8. `ImageIntake`: write `ImageIntakeTests` first (formats and conversions per R12; a PNG named `.jpg`; non-image bytes; metadata kept by copy, by conversion and by scaling; a rotated JPEG that shrinks and keeps its look; over-cap PNG under 8,000,000 bytes; the 320 px floor; an animated GIF and an oversize GIF/SVG copied; the source-size and pixel limits using a crafted header so nothing large is decoded; exclusive write with a pre-existing name and with two writers racing; read-only folder, `assets` as a file, `assets` as a symlink to a folder; nothing left behind after a failure), then the code.
- [ ] 9. Coordinator seams, queue and `pasteImages()` for a saved document, test first in `ImagePasteTests`: the happy path (file, link, card, one undo, redo, file kept), several images, the contexts R5 allows and refuses, fold opening, source view, typing during the work, window closed, two pastes in a row, the failure and altered notices, the announcement, `checkForExternalChange()` false afterwards.
- [ ] 10. `EditorTextView.paste` hook, plus the unchanged-path tests: plain text, rich text, "Paste and Match Style", URL over a selection, an image plus spreadsheet text, an image plus its URL (image wins), IME marked text, and a paste inside a table cell.
- [ ] 11. Untitled documents (R17): the sheet, Save… completing the paste at the remembered position, Cancel and a cancelled save panel writing nothing, a second paste queued behind the sheet, and the folder taken from the save's URL.
- [ ] 12. Drag: `acceptableDragTypes` and the four overrides; tests in `ImageDropTests` with the fake `NSDraggingInfo` for one and two files, an image already in the tree (no write, link built from the real path), one already in `assets/`, a symlink in the tree that points outside it (copied), a sibling folder with the same prefix, HEIC and TIFF, mixed files, a drop with no images (path inserted as text, as today), a text drag inside the editor, a file promise, raw image data, a drop on a preview card, and a drop into a table cell. Then the drop-point marker (P6 fallback if the probe said so).
- [ ] 13. R24: the export test in `DocumentOutputTests` (paste into a harness editor on a temporary folder, hand its text and file to the rig, export HTML, find `<img src="data:image/png`), and the preview-card test in `ImagePasteTests`.
- [ ] 14. `SelfTestImagePaste` and its two hooks: pastes and drops into the real window on a private named pasteboard, checks the files, the link, the card, a folded section, an undo, the untitled sheet and the announcement, and writes into `selftest-report.txt`.
- [ ] 15. Docs (R25): the README Images note (how to add one, `assets/`, that location metadata is kept, that very large images are scaled), the `CLAUDE.md` bullet, the ROADMAP status.
- [ ] 16. The whole proof below, then the verifier. Hand checks that need a desktop session are listed under Proof as owed until done.

## Risks

- **A drop is not delivered, or lands on the wrong view.** `NSTextView` registers its drag types only once it is in a window, the preview cards (`WKWebView`) sit over the text, and the table grid's cell views register their own. Step 7 probes the first; step 12 tests a drop on a card and into a cell; if a card swallows the drop, the overlay views are made to ignore drags (`unregisterDraggedTypes`).
- **The insertion lands in the wrong place or breaks undo.** The position goes through `TextDiff.map` over the diff of the text at paste time and now; the links go in through `apply` as one change after the files exist; tests type during the work, undo, redo and close the window mid-way. If the context became refused meanwhile, P1 applies.
- **Image handling is wrong for real files.** Thumbnails come out upright, so the copied orientation is reset to 1 or a photo would turn twice (tested with a rotated JPEG); HEIC and WebP encoders are not all present on a CI runner, so tests that need to *encode* one skip with an explicit message, and the real-app step and the hand checks carry HEIC; `Data.write(.atomic, .withoutOverwriting)` is the only exclusive write, so nothing opens a file for partial writing.
- **A hostile or odd file.** The name is sanitised to a safe stem and extension, the extension comes from the sniffed format and never from the file name, a symlink in the tree that leaves it is copied and not linked, `..` and control characters cannot reach the link, and sizes and pixel counts are checked before decoding (tests with a crafted header, so the suite never decodes a huge image).
- **The tests touch the real machine.** Pasteboards are private named ones released in a teardown (CLAUDE.md), folders are under the temporary directory and removed in teardown, `NSDocumentController` is not used by the harness (the untitled and save seams are stubs), and the real-app step runs from an isolated copy with a fresh bundle id.
- **The watcher reloads the document.** Writing into `assets/` changes that folder, not the `.md` file the watcher reads; step 9 asserts `checkForExternalChange()` is false and that the file's modification date is the same.
- **Linux tests wedge in Docker Desktop on this Mac.** Use the one-test-per-process recipe (CLAUDE.md, *Gotchas*) when `scripts/linux-test.sh` stalls.
- **R3's single-line rule is too tight or too loose.** It is one pure function with a table of cases, so a change after a hand check is a one-line edit with a test.

## Proof

Tests to add or change:

- `Tests/DownwriteCoreTests/ImageInsertionTests.swift` — steps 1 to 6: sniffing, the rule, names, links, relative paths, the shrink schedule, and every row of the placement table.
- `Tests/DownwriteTests/ImageIntakeTests.swift` — R7, R8, R12 to R14 and the failure and no-partial-file cases of R21, on real files.
- `Tests/DownwriteTests/ImagePasteTests.swift` — R1, R3 to R6, R10, R11, R17 to R23 and the unchanged paths, through a real editor in a temporary folder.
- `Tests/DownwriteTests/ImageDropTests.swift` — R2, R15, R16 and the drag-only cases.
- `Tests/DownwriteTests/DocumentOutputTests.swift` — R24, one test.
- `Sources/Downwrite/SelfTestImagePaste.swift` — the real window and menu bar, end to end.

Must pass before the change is complete:

```
scripts/linux-test.sh
swift build
swift test
scripts/build-app.sh
scripts/ci-local.sh
```

`scripts/ci-local.sh` runs the end-to-end step; run it from an isolated copy of the app with a fresh bundle id, and check `pgrep -fl Downwrite` first (CLAUDE.md, *Gotchas*).

Requirement coverage:

| Requirement | Proven by |
|---|---|
| R1 Paste | `ImagePasteTests`: a PNG on a private pasteboard writes `assets/image-….png` and inserts the link in place of the selection; "Paste and Match Style" and rich text insert no image |
| R2 Drop | `ImageDropTests`: files, two files, a file promise and raw data through the fake `NSDraggingInfo`; `.copy` reported for an image drag, `super`'s answer for a text drag; the drop-point marker (step 12) |
| R3 Image or text | `ImageInsertionTests` rule table; `ImagePasteTests` spreadsheet text with an image pastes the text, an image with its URL pastes the image |
| R4 Unchanged paths | The step 7 baseline tests, run again after the change; `ImagePasteTests` plain, rich, URL over a selection, IME marked text, table cell; `ImageDropTests` non-image files and text drops |
| R5 Where it applies | `ImageInsertionTests` placement returns nil for fence, code block, front matter, table lines, HTML and rules, and inserts in body, list, quote and headings; `ImagePasteTests` each refused context leaves text and folder untouched |
| R6 Folds and source view | `ImagePasteTests`: a folded section opens for the insertion; a paste in the source view works and the card is there after leaving it |
| R7 Images folder | `ImageIntakeTests`: created on first use, reused when present, a symlink to a folder, a file in the way, an unwritable folder |
| R8 Never overwrite | `ImageIntakeTests`: `-2` and `-3`, two writers racing, identical bytes not reused; `ImageInsertionTests` `firstFree` |
| R9 Names | `ImageInsertionTests` naming table; `ImageIntakeTests` the pasted name from the injected clock |
| R10 The link | `ImageInsertionTests` encoding table; `ImagePasteTests` the link for a space, `( )`, `#`, `%`, `é`, `日本` resolves through `ImageLoader.fileURL(for:base:)` to the file written |
| R11 Placement | `ImageInsertionTests` the spec's pinned table; `ImagePasteTests` three images give three paragraphs, the caret after the last |
| R12 Formats | `ImageInsertionTests` sniffing; `ImageIntakeTests` each format kept or converted, a PNG named `.jpg` saved as `.png`, an animated GIF's frames kept, non-image bytes refused |
| R13 Metadata | `ImageIntakeTests`: byte-identical copies; EXIF and GPS present after conversion and scaling; none added; README states it (R25) |
| R14 Size | `ImageInsertionTests` shrink schedule; `ImageIntakeTests` over-cap PNG under 8,000,000 bytes, the 320 px floor failure, an oversize animated GIF and SVG copied, the 100 MB and 200 MP limits |
| R15 Link in place | `ImageDropTests`: a file in the tree and one in `assets/` write nothing; a symlink out, a conversion and a shrink in the tree are saved to `assets/`; `ImageInsertionTests` `relativePath` |
| R16 Several and mixed | `ImageDropTests`: drop order kept, non-image files named in the notice, none left means the text path |
| R17 Untitled | `ImagePasteTests` with the `requestSave` stub: Save completes at the remembered position, Cancel and a cancelled panel write nothing, the folder comes from the saved URL |
| R18 One undoable edit | `ImagePasteTests`: one undo removes all links, redo restores them, the file stays, the menu title reads "Undo Paste Image" and "Undo Drop Image" |
| R19 Nothing else moves | `ImagePasteTests`: `checkForExternalChange()` false and the `.md` date unchanged; a fold before and after the insertion is carried; scroll position kept |
| R20 Responsive | `ImagePasteTests`: typing during a slow job keeps the typed text and puts the link at the mapped place; a closed window inserts nothing; a second paste waits and keeps order |
| R21 Failure | `ImageIntakeTests` and `ImagePasteTests`: each failure shows its sentence with the file name, inserts nothing, leaves no partial file; successes of a mixed batch are inserted |
| R22 Altered or skipped | `ImagePasteTests`: a scaled image reports old and new size, an oversize GIF says too big to preview, skipped files are named, a plain success shows no sheet |
| R23 Announcement | `ImagePasteTests`: `onAnnouncement` receives "Image inserted: …" and "3 images inserted"; `SelfTestImagePaste` posts it for real; VoiceOver speech itself is a hand check |
| R24 Preview and export | `ImagePasteTests` the card for the new link; `DocumentOutputTests` the exported HTML holds `<img src="data:image/…">` |
| R25 Docs | Review of the diff: README Images note, `CLAUDE.md` bullet, ROADMAP status; `grep -n "assets/" README.md` finds the note |

Owed until done by hand, in a real desktop session (the plan does not close while any is open): a screenshot pasted with ⌃⌘⇧4; a PNG, JPEG and HEIC dragged from Finder; a photo dragged from Photos; "Copy Image" and a drag from Safari; an image copied in Preview; a file copied in Finder and pasted; a 12-megapixel photo and a 20 MB PNG; an animated GIF in a browser; the untitled save sheet; a read-only folder and an `assets` file in the way; the document and its `assets/` folder moved and reopened, and the `.md` opened on GitHub; VoiceOver speaking the announcement; Print and Export as PDF and HTML containing the image.

## Deviations

<Filled during build. One line per departure from this plan, added in the same commit as the code that departs.>

- Step 2: `ImageNaming.firstFree` returns `String?` and takes `limit: Int = 10_000` (the spec sketched `-> String`). "Bounded" needs a way to say "gave up"; the caller reports it as a failure for that file (R21). A mark that belongs to a letter (Unicode Mn/Mc) is kept in a dropped name, so scripts such as Devanagari are not broken apart; variation selectors are not. The spec's "letter, digit" is read that way.
- Step 3: `ImageLink.markdown(path:)` puts `./` in front of a path whose first component starts with `~` (a dropped file in a folder called `~notes` in the document's folder), because `ImageLoader.fileURL` sends any source starting with `~` to the home folder; the link is still relative and still ends at the same file. `relativePath` returns nil for `.`, `..` and empty components (an unresolved path cannot be trusted; the caller copies the file).
- Step 6: three cases the spec leaves open, decided in `ImagePlacement.edit` and pinned by tests. (a) A caret or selection that starts inside the leading syntax of a list item or quote line (before the text: on the `-`, `1.`, `>` or the task box) returns nil, because a link there would break the block; R4 applies. (b) A heading inside a quote or list item is handled as that quote or list line (the link goes in at the caret), not as a heading, since a paragraph of its own cannot be made inside it. (c) A selection that ends exactly at the start of a line does not touch that line for R5. The edit's `range` can be longer than the selection: it takes in trailing blanks, the line terminator and one blank line below (the spec's algorithm), so callers must map the caret from `edit.selection`, not from the old selection.
- Step 7: the `imagePasteboard` seam (a stored property on `EditorCoordinator`, read by the URL-over-selection branch of `EditorTextView.paste`) was added in this step instead of step 10, as a pure refactor with no change in behaviour, so the baseline tests could use a private pasteboard and not the person's clipboard. Step 10 only adds the image path on top of it.
- Step 7, probe answers (P6). (1) A raw image drag (`public.png`, TIFF) is refused today, with or without a window: `draggingEntered` answers `[]` because the editor does not import graphics, even though the legacy PNG, TIFF, file-name and file-promise types are already registered once the view is in a window (and none are before). So `acceptableDragTypes` needs no extension; the four drag overrides must claim an image drag themselves, before `super`. (2) The drop-point marker cannot be observed by a test: a text drag differs from the undisturbed view by 0 bytes in an offscreen bitmap. So the plan's fallback becomes the design: for every image drag the editor draws its own thin accent bar at the drop index (`DWLayoutManager`, invalidated like the copy controls) and does not call `super` for it; non-image drags still go to `super` unchanged. A file or text drop is accepted today (`.copy`) and inserts the path or the text.
