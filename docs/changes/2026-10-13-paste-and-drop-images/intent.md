---
type: intent
id: 2026-10-13-paste-and-drop-images
title: Paste and drop images into a document
track: feature
status: accepted
raised: 2026-10-13
accepted: 2026-10-13
merged:
backlog: "DW-002 (https://app.todoist.com/app/task/6hjfjGvqJXxhJqrH)"
---

# Paste and drop images into a document

## Problem

Backlog item DW-002 (roadmap: `docs/ROADMAP.md#dw-002--paste-and-drop-images`). Images already preview inline in Downwrite, but getting one into a document is manual: save the file somewhere, then type its path into `![](…)`. Pasting a screenshot or dragging a photo in is how people actually add images, and users of other Markdown editors expect it, so the image preview feature is only half used. The card's watch-list is the starting set of hard parts: untitled documents have no folder, file naming and collisions, TIFF/HEIC conversion, and very large images.

A search of `Sources/Downwrite` on 2026-10-13 finds no image handling on the way in. The editor's text view is created with `isRichText = false` and `importsGraphics = false`, the `paste` override in `EditorTextView` only turns a URL pasted over selected text into a link, and nothing registers a drag destination (no `registerForDraggedTypes`, `draggingEntered` or `performDragOperation`). What a plain text view does today with an image on the pasteboard, or with a file dropped on it, has not been probed and is for the spec to establish. (The wording of the problem comes from the roadmap and the card, so please correct it if it is off.)

## Proposed outcome

- Pasting an image from the clipboard (a screenshot, an image copied from a browser or Preview) into a saved document saves it as an image file next to the document and inserts a Markdown image link to it at the caret. The image then previews inline exactly like one typed by hand.
- Dropping an image file (from Finder, Photos or a browser) onto the editor does the same, inserting the link where the caret would land for that drop.
- The inserted link is valid Markdown, relative to the document, so the document and its image folder can be moved or shared together and the link still resolves in other editors, on GitHub and in Downwrite's own preview, print and export.
- A new image never overwrites an existing file.
- The saved file is in a format that Markdown viewers, web browsers and Downwrite's own preview and export can show; an image that arrives as TIFF or HEIC is converted.
- The insertion is one ordinary edit: it can be undone and redone with the rest of the text, and it does not break the existing caret, fold, source-view or external-change behaviour.
- An unsaved (untitled) document and a very large image each have a defined, explainable result, not a silent failure. What that result is, is for the open questions below.
- Pasting and dropping anything that is not an image behaves as it does today, including pasting a URL over selected text to make a link.
- Not in this change (proposed, say if any should move in): cropping, resizing or annotating images, an image gallery or manager, downloading a remote image from a pasted URL, other attachment types (PDF, audio, video), and a Settings pane for the images folder unless the open questions decide otherwise.

## Affected users and systems

Anyone who writes READMEs, documentation, tutorials or notes with screenshots in them, which is most Markdown users.

Parts of the system involved (as known now, to be confirmed in the spec and plan):

- `Sources/Downwrite/EditorTextView.swift`: the `paste` override (`:359`), the `importsGraphics`/`isRichText` setup, and a new drag destination. Edits go in through `apply(TextEdit)` (`shouldChangeText` → `replaceCharacters` → `didChangeText`) so undo works.
- `EditorCoordinator` (`EditorView.swift`): already knows the document's `fileURL`, so it is where "is there a folder to write into" is decided.
- `ImageLoader` (`Previews.swift`): `fileURL(for:base:)` resolves a link to a file and `maxEmbeddedBytes` caps the embedded preview at 8 MB, so the link written has to resolve through it and the files written have to stay under it or fail in a known way.
- `DownwriteCore`: the pure parts, namely choosing a file name, resolving a collision, sanitising characters, and building the relative, percent-encoded link text. All of it unit-tested on Linux; the pasteboard, image conversion and file writing stay in the app target.
- The untitled-document path in `DownwriteApp.swift` (the `DocumentGroup` document model), for whatever the answer to the unsaved-document question turns out to be.
- Export (DW-001): `DocumentOutputController` and `DocumentHTML.resolveImages` already embed local images as `data:` URIs, so pasted images should flow through, and that has to be checked, not assumed.
- The table grid's cell text views (`TableGrid.swift`) are separate `NSTextView`s with their own `paste` and the same `importsGraphics = false`.
- `README.md` and `FEATURE-LIST.md` once it ships.

## Constraints

- Markdown and path/name decisions live in `DownwriteCore` and are unit-tested on Linux; the app target only handles the pasteboard, the drag, image conversion and the file write. Project rule.
- Offsets are UTF-16, and text in the editor always uses `\n`.
- Keep the app light: no new dependencies. Image conversion and resizing use what macOS already provides (ImageIO/AppKit).
- The app is not sandboxed, so writing next to the document is possible; it must still write only where the person can see from the inserted link that it went, and never over an existing file.
- The document on disk stays plain Markdown with an ordinary image link. Nothing Downwrite-specific is added to the `.md` file.
- The link must resolve through `ImageLoader.fileURL(for:base:)`, including for names with spaces, parentheses or non-ASCII characters.
- Reading, converting and writing a large image must not freeze the editor.
- Existing paste behaviour is unchanged for everything that is not an image: plain text, rich text, a URL over a selection, and pasting inside the table grid.
- Writing an image file into the document's folder must not trigger the external-change reload of the document itself (that watches the `.md` file's modification date).
- Tests that need a pasteboard use a private named one and release it in a teardown, never `NSPasteboard.general`, so the person's own clipboard is left alone.
- Sequencing, from the roadmap: DW-002 lives in `EditorTextView` and `ImageLoader`, so it can run beside DW-010 and DW-004 and has no clash with the shipped DW-006. DW-001's export of images is already in.

## Open questions

1. **Untitled documents.** An unsaved document has no folder. Ask to save first, hold the image in a temporary place and move it when the document is saved (and what the link says in the meantime), or refuse with a message? What if the document later saves somewhere else, or is never saved? What about a document in a read-only location?
2. **Where do the images go?** A fixed `assets/` folder next to the document, the document's own folder, a folder named after the document, or a choice in Settings? Is the folder created on the first image? What does the link look like (`![](assets/name.png)`)?
3. **File names and the link's alt text.** A timestamp ("Pasted image 2026-10-13 09.41.12.png"), the dropped file's own name, or something else? How is a collision resolved (a numeric suffix, or reuse the existing file when the bytes are identical)? Which characters are replaced? Is the alt text empty, the file's name, or left for the person to type (and the caret placed there)?
4. **Dropped files.** Copy into the images folder, or link to the original when it is already inside the document's folder tree? What about several files at once (one link each, on separate lines?), a file that is not an image, and a drop from the same folder?
5. **Formats.** Which pasteboard and file types count (PNG, TIFF, JPEG, HEIC, GIF, PDF, SVG, WebP)? Which are kept as they are and which converted, and to what (PNG for screenshots, JPEG for photos)? An animated GIF must not be flattened. Is metadata such as location in a photo's EXIF kept or stripped?
6. **Very large images.** The inline preview embeds files only up to 8 MB. For a 12-megapixel photo or a Retina screenshot, do we keep the original, re-encode, scale down to a maximum size, or warn? What is the limit, and is it a number the person can see?
7. **What wins on a mixed pasteboard?** Copying from a web page, Pages or a spreadsheet puts text and an image on the pasteboard together; copying a file in Finder puts a file URL and its name. When both a usable text and an image are present, which does Paste insert? And what does pasting an image over a selection do (replace it, or use the selected text as the alt text)?
8. **Where does it apply?** Inside a fenced code block, front matter, a table cell, a folded section, and the Markdown source view (⌘/). Should an image link ever be inserted into those, or should paste behave as today there?
9. **Undo and clean-up.** Undo removes the link, but should it also remove the file just written? Deleting a link later never deletes files (assumed). Orphaned files are left alone?
10. **Failure and feedback.** The folder cannot be written, the disk is full, or the image cannot be read: what does the person see, and is nothing inserted? Is there an announcement for VoiceOver when an image is inserted (this change would feed DW-011, the accessibility audit)?

## Decision

Accepted on 2026-10-13 as a feature, so the next stage is the spec. The open questions above carry forward to it, and the spec answers them for approval.
