---
type: spec
id: 2026-10-10-export-and-print
intent: ./intent.md
status: approved
approved: 2026-10-10
---

# Spec: Print a document and export it as PDF or HTML

## Summary

The File menu gets **Print…** (⌘P), **Export as PDF…** and **Export as HTML…**. All three output the same thing: the whole document, as a reader would see it, in one fixed light print style that does not depend on the window's theme, fonts, folds or source view. A new pure-Swift renderer in `DownwriteCore` turns the document text into HTML in two steps (prepare, then assemble once the app has resolved local images and Mermaid diagrams). The app target then either saves that page as one self-contained `.html` file, or loads it into a hidden, script-free web view and runs a paginated print operation (the print panel for Print…, a straight save-to-file for Export as PDF…). The document, its undo history, its folds and its file on disk are never touched.

## Requirements

"The output" means whatever Print…, the PDF and the HTML file show. "Print" or "print/PDF" means the paginated path (Print… and Export as PDF…), "the HTML file" means Export as HTML…. A "left-out image" is one the output could not include (R14).

### Commands

- **R1** — The File menu shows three new items together, in this order, where Print belongs: **Print…** (⌘P), **Export as PDF…** and **Export as HTML…** (no shortcuts on the two exports). Every existing File item, including Share, is unchanged and keeps its order. The items are present in the main menu from launch, so `menus.txt` (the self-test's menu dump) lists them.
- **R2** — The three items are enabled when a document window is frontmost and are disabled when there is none (for example only Settings is open). While one window is preparing output (R25) the three items are disabled for that window only; other windows are unaffected. The source view, folds, selection and the contents sidebar do not disable them.
- **R3** — The output is made from the text the editor holds at the moment the command is chosen: unsaved edits are included, an untitled document is output as it stands, and the file on disk is never read for its text. Edits made after the command was chosen do not appear in that output.
- **R4** — The output depends only on that text, the document's display name, the document's folder (to find local images, R14) and the files and diagrams the text refers to. It does not depend on the theme, the appearance mode (light, dark, system), the font, size, line spacing or column-width settings, the window size, the sidebar, the source view, the folds, the caret or selection, or the scroll position. Exporting one document from a window in the Catppuccin Mocha theme with the source view on and everything folded, and from a default window, gives byte-identical HTML files.
- **R5** — Printing or exporting does not change the document. The text storage, the undo stack, the document's edited flag, the caret and selection, the folds, the scroll position, the source-view switch and the file on disk (byte for byte) are exactly as before. The only file written is the one the user chose in the save panel (or the print job's own destination).

### What the output contains

- **R6** — The output contains the whole document, first line to last, in order, whatever is folded. Block elements: headings 1–6 (ATX and setext) with their inline formatting kept (bold, links, code), paragraphs (a hard line break is a line break, a soft break is the CommonMark space), block quotes (nested, with any content inside), thematic breaks, bulleted and numbered lists at any depth (a numbered list keeps its start number, tight and loose lists follow CommonMark), task items (R8), tables (R9), and fenced and indented code (R10).
- **R7** — Inline elements: emphasis, strong, strikethrough (`~~`), inline code, links (inline, reference, `<https://…>` and the bare `https://…` / `www.…` URLs that the editor links), images (R14), `==highlight==` as `<mark>` on the same text that the editor highlights (never inside code), and the inline HTML tags of R13. Text is shown as typed: the Markdown parse runs with smart punctuation off (the editor's own parse turns it on, because only ranges are used there), so `"quotes"`, `--` and `...` are not converted.
- **R8** — Every task item (bulleted or numbered, at any depth) starts with a drawn box before its text: empty for `[ ]`, with a tick for `[x]`. The box is drawn with CSS, not a form control, and has the same contrast on screen, on paper and in the PDF. The text of a ticked item is greyed and struck through, as the editor shows it. A numbered task item shows its number, then the box (the editor shows the raw `[ ]` there; the output shows what a reader would expect).
- **R9** — Tables render with their header row, body rows and per-column alignment, with inline formatting in cells. A `<br>` in a cell is a line break in the cell (the grid's own convention). Tables inside block quotes and list items render as tables too.
- **R10** — Code blocks (fenced or indented, at any depth) show their text exactly: HTML-escaped, with leading whitespace and blank lines kept, in a monospaced face on a light grey card. The info string is not shown. A fence whose first info word is `mermaid` is a diagram (R15). Inline code is shown in the same face with a light grey background.
- **R11** — YAML front matter (as the analyzer defines it: `---` on the first line, closed by `---` or `...`) is left out of the output entirely. Footnote markers and definitions (`[^1]`, `[^1]: …`) and `$math$` / `$$math$$` are shown as typed, as the editor shows them today (DW-004 will typeset math).
- **R12** — A link keeps its text and becomes a real link when its destination is `http:`, `https:`, `mailto:`, `tel:` or `file:`, a relative path, or a `#fragment`. Any other destination (`javascript:`, `vbscript:`, `data:`, anything unrecognised, including ones hidden behind whitespace, mixed case or character references) is shown as its link text without a link. Relative and `file:` links are left as written and only work next to the original. Every heading gets an `id` equal to the editor's heading slug, so a `#fragment` link that works in the editor works in the HTML file. When two headings share a slug, the first keeps it and later ones get `-1`, `-2` … (the editor resolves a `#fragment` to the first heading).
- **R13** — HTML in the document is kept so README-style centred images, `<details>` and badges survive, but locked down. Block HTML and inline HTML pass through a sanitiser in Core that removes: `<script>`, `<style>`, `<iframe>`, `<frame>`, `<frameset>`, `<object>`, `<embed>`, `<applet>`, `<form>`, `<link>`, `<meta>`, `<base>` and `<title>` elements (with their content for `script` and `style`), every `on…` event attribute, HTML comments, processing instructions and CDATA, every `srcset` attribute, and any `href`, `src`, `action`, `formaction` or `xlink:href` value that is not allowed by R12 (for `src`: `https:`, `data:` images and the local images the app resolves under R14). An unclosed `<script>` or `<style>` removes everything to the end of its block. `style=` attributes are kept (the editor's cards allow them under the same policy).
- **R14** — Images (Markdown `![alt](src)` anywhere, and `<img>` inside HTML) are resolved like this: a local file (relative to the document's folder, absolute, `~`, or `file:`; percent-decoding as the editor does) that is an image type WebKit shows and is at most 8,000,000 bytes is embedded in the output as a `data:` URI. A `data:` source is kept. An `https:` source is kept as a link to the image: the HTML file does not download it, and the web view used for print/PDF loads it while preparing (R25). Everything else is a left-out image and is shown as its alt text (its file name if there is no alt text), in a muted italic: a missing file, an unreadable file, a file that is not an image type, a file over 8,000,000 bytes, an `http:` source (the output's security policy, R28, allows only `https:` and embedded images), a relative source in an untitled document (it has no folder, and the process's working directory is never used), and any image once the output already holds 64 MB of embedded images in total (images are taken in document order). A source with a query or fragment (`pic.png?raw=true`) is looked up as written and is therefore left out when no such file exists.
- **R15** — Each `mermaid` fence is rendered by the app's existing `MermaidService` with the light Mermaid theme and inserted as inline SVG, centred, scaled down to fit the page width (never scaled up past its natural size) and kept whole on one page (R19). Output is never produced while a diagram is still rendering. The SVG's ids are rewritten to a deterministic prefix per diagram (`dw-d1-…`, `dw-d2-…`) so two diagrams, or the same diagram twice, never share an id and two runs give the same text. A diagram whose source is invalid, or whose renderer is unavailable, is shown as a one-line note, `Diagram could not be rendered: <reason>` (the reason is `MermaidSupport.friendlyError`'s text), followed by the Mermaid source as a code block (R10); the export still succeeds. A diagram that has not finished after 20 seconds is treated the same way (reason `timed out`), and the remaining diagrams of that export are not attempted (the shared renderer may be stuck), each shown the same way with the reason `renderer not responding`.
- **R16** — When an output has left-out images, then after the operation has finished (the file written, the PDF saved, or the print job sent or saved from the panel; not when the user cancelled) the document window shows a sheet, `Some images could not be included`, that lists up to ten of them with the reason (`file not found`, `larger than 8 MB`, `not an image`, `http images are not allowed`, `output size limit`, `document not saved yet`) and `and N more` when there are more, with an OK button. No sheet appears when nothing was left out. The output itself is complete in every other respect.

### Style and layout

- **R17** — One fixed light style, written in Core as a CSS string. A white page; text, code card, inline-code, rule, quote-bar, link and highlight colours taken from `Palette.palette(for: .light)`; a system sans-serif font stack (it names no font that ships with only some Macs); 11 pt body text on paper and 16 px on screen, line height 1.5; headings in descending sizes by level; monospaced code at 90% of body size. Body text on the page has a contrast ratio of at least 7:1 (asserted the way `ThemeCatalogTests` asserts its floors). The style declares `color-scheme: light`, so a browser in dark mode still shows the white page.
- **R18** — On screen (the HTML file in a browser), content is a single centred column of at most 46 em with 24 px of padding, images and diagrams are scaled down to the column width, wide tables scroll sideways inside their own box, and a long code line scrolls inside its card. The page declares a viewport so it is readable on a phone.
- **R19** — Print and PDF are paginated on the paper size of the print settings (the system default paper, or what the user picks in the print panel) with 20 mm margins on every side, and break pages like this: a table row, a line of text and a line of code are never split across two pages; an image, a diagram, a task item and a block quote shorter than a page are not split; one taller than a page is scaled to fit a page (images, diagrams) or broken between lines or rows (everything else); a heading is kept together with the block that follows it whenever the two fit on one page, so a page break never separates them (if the block after it is taller than a page, for example a table of 120 rows, the heading may be the last thing on a page); a table that continues onto the next page does not repeat its header row there (the print engine has no support for it, see *Amendments*); long code lines wrap inside the card instead of running off the page; widows and orphans are at least two lines.
- **R20** — In print and PDF every `<details>` is open (a closed one would hide its content on paper). In the HTML file `<details>` keep the state the author wrote and still open and close in the browser.

### The three commands

- **R21** — **Print…** prepares the output (R25) and then shows the standard macOS print panel as a sheet on the document window, with the paginated preview of R17–R20. Everything the panel offers works, including Save as PDF, Open in Preview, paper size, orientation, scale and page range. Cancel prints nothing and changes nothing.
- **R22** — **Export as PDF…** prepares the output and then shows a save panel as a sheet, for PDF files, with the default name of R24. On Save it writes a PDF of the same paginated output as Print…, without showing the print panel. The file is a valid PDF that opens in Preview, its text is selectable (not a picture), and its page size is the system default paper size.
- **R23** — **Export as HTML…** prepares the output and then shows a save panel as a sheet, for HTML files, with the default name of R24. On Save it writes one self-contained UTF-8 file: `<!doctype html>`, `<meta charset>`, a `<title>`, all CSS inline, local images embedded (R14), diagrams as inline SVG, no script, and the security policy `HTMLSupport.contentSecurityPolicy` as the first element in `<head>`. The `<title>` is the plain title of the first heading, else the document name, else `Untitled`. Apart from `https:` images and links the author wrote, the file refers to nothing on this Mac: copying it to another folder (or another Mac) and opening it in Safari or Chrome shows every embedded image, every diagram, the task boxes and the styles.
- **R24** — The save panel's default name is the document's display name without its extension (`.md`, `.markdown`, `.txt`) plus `.pdf` or `.html`; an untitled document is `Untitled`. The panel opens in the document's folder when the document is saved, and otherwise where the system opens it. The extension is fixed to the type, and overwriting an existing file is confirmed by the panel's own prompt.

### Preparing, failing, staying responsive

- **R25** — The three items work in two phases: prepare, then the panel. Preparing means: take the text (R3), render it in Core, read the images (off the main thread), render the diagrams, assemble the page, and for the paginated path load it into a hidden web view and wait until it has finished loading (remote `https:` images are given at most 8 seconds, as the editor's HTML cards are; images that have not arrived by then are shown as their alt text). Only when that is complete does the panel appear (Print…) or the save panel appear (both exports). If the window is closed during preparation, the work is dropped and no panel or file appears. A second command cannot start in a window that is preparing (R2).
- **R26** — If preparing fails (the web view cannot load the page, the print engine returns an error) or the file cannot be written (permission, disk full, volume gone), an alert on the document window says `Couldn't print` / `Couldn't export` with the system's reason. The file is written atomically, so a failure leaves no partial file and does not touch an existing file of the same name. Nothing else changes.
- **R27** — The window stays responsive while preparing: Markdown rendering and image reading do not run on the main thread, and with the display awake the main thread's longest stall during preparing a 20,000-line document with 20 images and 3 diagrams is under 250 ms. In Core, rendering a 20,000-line (about 1 MB) document takes under 5 seconds on the Linux CI image, and the three items accept documents of any size (there is no size limit on the text).

### Safety, and what stays the same

- **R28** — The output never runs a script and never leaves the page. In print/PDF the web view has page JavaScript off, cancels every navigation but its own load (the `DiagramView` rule), and has no file access. The HTML file carries a policy that allows only inline CSS, `data:` and `https:` images (the editor's card policy, unchanged), so a browser blocks scripts, frames, forms, fonts and other loads even if the sanitiser (R13) missed something. Nothing is fetched except `https:` images (R14).
- **R29** — The editor is unchanged: hiding syntax, folding, the source view, table grids and cards, task-box clicks, external-change reload, the contents sidebar, the existing File ▸ Share item, and the status pill. The only behaviour moved is the heading slug (`EditorCoordinator.slug`), which moves to Core with an identical result and is used by the editor and the output alike. All existing tests stay green.

## Out of scope

- Word (`.docx`), and any other format (RTF, EPUB, plain text, Markdown with images folded in).
- Printing or exporting the selection only, a table of contents in the output, PDF bookmarks, page numbers, running headers and footers, a cover page, watermarks.
- A **Page Setup…** item, a user-chosen margin, a choice of print style, or output that follows the Settings (font, size, theme). The style is fixed (R17).
- Syntax highlighting in code, pasted and dropped images, and typeset math. The output carries them once DW-002, DW-003 and DW-004 ship, and that work is theirs.
- Footnote rendering (numbering, a notes section, back-links) and any Markdown extension the editor does not recognise today.
- Downloading remote images into the file, a dark-mode export, or a choice between several page sizes in the Export items.
- AppleScript, Shortcuts, Services or command-line access to export (DW-010).
- Opening or revealing the file after export, remembering the last folder beyond what the save panel does, and a progress sheet or Cancel button for slow documents (the items are simply disabled while preparing).
- The `FEATURE-LIST.md` row, the README mention and the release note. They are owed once the change is merged and tagged (CLAUDE.md, *Feature list*), not part of the build.

## Design

### Interfaces

**Core** (`Sources/DownwriteCore`, pure Swift, Linux-testable). The shapes below are the contract; names inside the plan may differ if the tests say the same thing.

```swift
public enum DocumentHTML {
    public enum Target: Sendable { case screen, print }      // print: <details> opened, @page rules, wrapping code
    public struct Options: Sendable { public var target: Target; public var documentName: String }

    /// Step 1 (pure, off the main thread): Markdown -> HTML body with placeholders, plus what the app must resolve.
    public struct Prepared: Sendable {
        public var title: String                  // plain title of the first heading, else the document name, else "Untitled"
        public var imageSources: [String]         // every distinct image source (Markdown and <img>), in document order
        public var diagrams: [String]             // Mermaid sources, in document order
        // ...body with one slot per diagram, kept private to the type
    }
    public static func prepare(_ text: String, options: Options) -> Prepared

    public enum ImageOutcome: Sendable { case embedded(dataURI: String), keep, leftOut(OmissionReason) }   // keep: data: and https: sources
    public enum DiagramOutcome: Sendable { case svg(String), failed(reason: String) }
    public enum OmissionReason: String, Sendable { case notFound, tooLarge, notAnImage, insecure, sizeLimit, unsavedDocument }
    public struct Omission: Sendable { public var source: String; public var reason: OmissionReason }

    /// Step 2 (pure): the complete page and the list of left-out images.
    public static func assemble(_ p: Prepared, images: [String: ImageOutcome], diagrams: [DiagramOutcome]) -> (html: String, omissions: [Omission])
}

public enum HTMLSanitizer { public static func sanitize(_ html: String, allowImageSource: (String) -> Bool) -> String }   // R13
public enum HeadingAnchor { public static func slug(_ title: String) -> String }                                      // moved from EditorCoordinator.slug
public enum PrintStyle { public static func css(for target: DocumentHTML.Target) -> String }                          // R17-R20
```

The renderer walks the swift-markdown tree with its own `MarkupWalker` (the library's `HTMLFormatter` is not used: it writes text, code, `href` and `src` unescaped, flattens heading formatting to plain text, and passes raw HTML through, so it would break R10, R6 and R13). It parses with `.disableSmartOpts` (R7). Front matter is detected with the analyzer's own rule (one shared helper). `==highlight==` and bare-URL links use the analyzer's own patterns on text outside code and outside existing links (R7), exposed as shared helpers so the editor and the output cannot drift apart.

**App** (`Sources/Downwrite`, macOS only).

- `OutputCommands: Commands` in `DownwriteApp.swift` (added to `.commands`): `CommandGroup(replacing: .printItem)` with the three items, enabled from a focused scene object published by `EditorScene` (the pattern of `.focusedSceneValue(\.sourceMode, …)`; a `@FocusedObject` fits because the state, "preparing", changes over time).
- `DocumentOutputController` (`@MainActor`, `ObservableObject`, one per window, created by `EditorScene`): `func printDocument()`, `func exportPDF()`, `func exportHTML()`, `@Published var isPreparing`. It takes the snapshot (R3: the text, the document's `fileURL`, its display name), runs `DocumentHTML.prepare` detached, resolves images with `ImageLoader.fileURL` / `dataURI` (detached), renders diagrams through `MermaidService.shared.render(_, dark: false)` with the 20-second guard and the stop-after-first-timeout rule (R15), calls `assemble`, then hands the page to the sheet flow below. It does not call the text view and never reads the file for text.
- `PrintRenderer` (new): a hidden `WKWebView` (page JavaScript off, the `DiagramView` navigation rule, no file access, in an off-screen window if WebKit needs one for printing) that loads the print-target page and waits for it (R25); `makePrintOperation(info:)` returns `webView.printOperation(with:)` with the print info of R19. Print… runs it as a sheet on the window with the panel; Export as PDF… runs it with `jobDisposition = .save`, `jobSavingURL` set and no panel. `WKWebView.createPDF` is not used: it captures one rectangle of the page, not paginated pages.
- The HTML path writes the `assemble` result (`target: .screen`) with `Data.write(to:options:.atomic)`.
- `Responder`-style menu actions are not used; the commands call the controller directly (the print panel and save panels need the window).

### Data

None stored. No new preference, default, entitlement or `Info.plist` key; no migration. The app is not sandboxed, so writing wherever the user chooses works. A fixture, `Tests/Fixtures/export-demo.md` (Fixture P below), and a few small image fixtures are added for tests.

### Files and components involved

- `Sources/DownwriteCore/DocumentHTML.swift` (new) — `prepare`/`assemble`, the Markdown walker, escaping, placeholders, SVG id rewriting.
- `Sources/DownwriteCore/HTMLSanitizer.swift` (new) — R13, a tokenising pass (not a bare regex), unit-tested with adversarial input.
- `Sources/DownwriteCore/PrintStyle.swift` (new) — the CSS.
- `Sources/DownwriteCore/HeadingAnchor.swift` (new) — the slug, moved from `EditorView.swift:527`; `EditorCoordinator` calls it.
- `Sources/DownwriteCore/MarkdownAnalyzer.swift` — only to expose the front-matter rule and the highlight pattern as shared helpers; no behaviour change.
- `Sources/DownwriteCore/HTMLSupport.swift` — reused (`contentSecurityPolicy`, `imageSources`, `isLocalSource`, `parseTag`); small additions only if the sanitiser needs them.
- `Sources/Downwrite/DownwriteApp.swift` — `OutputCommands`, `.focusedSceneObject` in `EditorScene`.
- `Sources/Downwrite/DocumentOutput.swift` (new) — `DocumentOutputController`, the save panels, the left-out-images sheet, the failure alerts.
- `Sources/Downwrite/PrintRenderer.swift` (new) — the hidden web view and the print operation.
- `Sources/Downwrite/Previews.swift`, `Mermaid.swift` — reused as they are (`ImageLoader.fileURL`, `dataURI`, `MermaidService.render`); no change expected.
- `Sources/Downwrite/SelfTest.swift` — a new end-to-end step before step 8 (which replaces the document), driving the controller's non-interactive entry points and the real menu (the print panel itself is modal, so the self-test checks the panel's data through the print operation instead).
- `Tests/DownwriteCoreTests/DocumentHTMLTests.swift`, `HTMLSanitizerTests.swift`, `PrintStyleTests.swift`, `HeadingAnchorTests.swift` (new); `Tests/DownwriteTests/DocumentOutputTests.swift` (new, uses PDFKit, a system framework, in the test target only).
- After release: `README.md`, `FEATURE-LIST.md`, `docs/ROADMAP.md` (DW-001 status).

### Behaviour details

**Image resolution (R14).**

| Source in the document | Result in the output | Reason if left out |
| --- | --- | --- |
| `pic.png` next to a saved document, ≤ 8,000,000 bytes | embedded `data:` image | |
| `../img/a%20b.png` (percent-encoded, up the tree) | embedded when the decoded path exists | `file not found` otherwise |
| `/abs/p.jpg`, `~/p.jpg`, `file:///…/p.jpg` | embedded | |
| `big.png` over 8,000,000 bytes | alt text | `larger than 8 MB` |
| `notes.txt`, a folder, a file without an image extension | alt text | `not an image` |
| `pic.png?raw=true` and no such file | alt text | `file not found` |
| `data:image/png;base64,…` | kept | |
| `https://example.com/p.png` | kept as the link (HTML file); loaded by the web view (print/PDF) | |
| `http://example.com/p.png` | alt text | `http images are not allowed` |
| `pic.png` in an untitled document | alt text | `document not saved yet` |
| any image after 64 MB of embedded images | alt text | `output size limit` |

**Link destinations (R12).** Allowed after trimming whitespace and decoding character references, case-insensitively: the schemes `http`, `https`, `mailto`, `tel`, `file`; a destination with no scheme (a relative path or `#fragment`). Anything with another scheme, or a scheme the check cannot read, is link text only.

**Timeouts and limits.** Diagram: 20 s each, then the stop-after-first-timeout rule. Remote image load: up to 8 s for the whole page load. Embedded images: 8,000,000 bytes each, 64,000,000 bytes in total. Left-out sheet: ten entries.

**Empty and tiny documents.** An empty document prints a blank page, exports a one-page PDF and a valid HTML page with an empty body. A document that is only front matter behaves the same.

**Menu state.** The items follow the frontmost document window. A window that is preparing disables the items only while it is frontmost; switching to another window enables them there.

**While preparing.** The text and the rest of the window stay editable. Edits do not reach the output (R3). Closing the window abandons the work (R25). The user can start another preparation in another window.

**Fixture P (`Tests/Fixtures/export-demo.md`).** One document that holds every case, used by the tests and by the walk-through in *Verification*:

| Part | What it holds |
| --- | --- |
| Front matter | `title: Secret front matter` (must not appear anywhere in the output) |
| Headings | an ATX `#` with `**bold**` and a link, a setext `===`, two headings with the same text (slug and `-1`), and a heading `Reading **this**` with an in-page link `[jump](#reading-this)` |
| Text | emphasis, strong, `~~strike~~`, `==highlight==`, `` `code` ``, `<u>under</u>`, `H<sub>2</sub>O`, a bare `https://example.com`, `"straight quotes" -- ...` that must stay as typed, a hard break |
| Lists | three-level mixed bullets and numbers (a list starting at 3), a task list with ticked and unticked items and a numbered task |
| Quote | a nested block quote containing a list and a code block |
| Table | 120 rows, alignments left/centre/right, inline code and `<br>` in cells (so the PDF has several pages of table) |
| Code | a fence with `</pre><script>alert(1)</script> & <b>` inside, an indented block, a 300-character line |
| Mermaid | one valid flowchart, the same flowchart again, and one with a syntax error |
| Images | a small local PNG, a local SVG, one generated at 8,000,001 bytes (created by the test, not committed), a missing file, `![x](http://example.com/a.png)`, an `https:` image |
| HTML | a centred `<p align="center"><img src="local.png"></p>`, a `<details><summary>More</summary>…</details>`, a block with `<script>`, `<style>`, `<iframe>`, `<img src=x onerror=…>`, `<a href="javascript:…">` and an HTML comment |
| Links | `[ok](https://example.com)`, `[js](javascript:alert(1))`, `[mixed]( JaVaScRiPt:alert(1))`, `[rel](other.md)` |
| Other | `[^1]` with its definition, `$x^2$` and a `$$` block, a rule, a long paragraph so headings can land at a page end |

## Flags

- **The intent says the editor "drops `<script>` and `<style>`" in HTML blocks. The code does not quite do that.** `HTMLSupport.isRenderable` only decides that a block made of nothing but a script or style is not worth drawing; a `<style>` inside a block that is renderable is passed to the card, and the card's policy allows inline styles. R13 removes `<style>` from the output (your choice of "locked down"), so a README whose HTML block relies on its own `<style>` looks right in the editor's card and slightly different in the output. Resolved by R13 as decided; noted so it is not mistaken for a bug.
- **`http:` images.** The editor's standalone image cards load `http:` images (through `URLSession`, no policy), while the policy for HTML cards allows only `https:` and `data:`. R14 and R28 apply the stricter policy to the whole output, so a standalone `![](http://…)` shows in the editor and as alt text in the output, and the sheet tells the user why. Resolved as stricter; say if you would rather allow `http:` in print/PDF only.
- **"One self-contained file" and remote images.** An `https:` image stays a link in the HTML file, so the file is self-contained for everything local but needs the network for remote images, and the intent's "opens correctly … on another Mac" holds when that Mac is online. Resolved as decided (remote images are not downloaded); the alternative would embed them and is out of scope.
- **Numbered tasks.** The editor shows a numbered task as its number and the raw `[ ]`; R8 draws a box. A deliberate difference: a printed `[ ]` reads as a typo.
- **`Palette.palette(for: .light)` is the Downwrite light theme**, so the print style shares its colours with that theme. If that palette is retuned later the output's colours move with it (R17 pins only the 7:1 contrast floor).
- **The intent's constraint "the editor's behaviour is unchanged"** is kept (R29). The Mermaid guard is placed in the export path, not in `MermaidService`, so the editor's diagram cards behave as before (a stuck renderer still shows "Rendering…" there). One consequence: after a timeout the shared renderer may stay stuck for the rest of the session; the output says so for the remaining diagrams (R15) and Print/Export still produce a document.
- **Mechanism assumption, now answered by the plan's spike (see *Amendments*).** R19 relied on WebKit's print engine honouring CSS page-break rules when a hidden `WKWebView` is printed with `printOperation(with:)`. The SDK header says `WKWebView.createPDF` "represent[s] the bounds of the currently displayed web page", i.e. it is not paginated, which is why it is not used. If a hidden web view prints blank or ignores the rules, the plan's first step (a throwaway spike) finds out and the fallback is to host the web view in an off-screen window. If neither works, the spec comes back for a decision.

## Verification

"Working" means: the three commands exist and behave as R1–R29 say, on a document that holds every case, without changing the document.

**A. Automated (named in the plan; these are the pass/fail gates).**

1. `scripts/linux-test.sh` is green, including the new Core tests, which assert at least: every R6–R12 construct in Fixture P renders as specified; all document text, code and attribute values are escaped (`</pre><script>` in code stays inert); the front matter text `Secret front matter` appears nowhere; heading ids and the `-1` suffix; the link destination table of R12 (including mixed case, whitespace and `&#x6A;avascript:` forms); the sanitiser removes every item of R13 for a table of adversarial inputs (`<scr<script>ipt>`, uppercase tags, unquoted and entity-encoded handlers, `<svg onload>`, unclosed `<script>` and `<style>`, `<a href=" javascript:…">`, `srcset`) and leaves the allowed HTML (`<p align="center">`, `<img src>`, `<details>`) intact; `assemble` gives identical output for identical input, rewrites SVG ids per R15, and returns the `Omission` list of R14; `slug` gives the editor's old results (a table of titles); the page's `<head>` starts with the policy `<meta>` and the policy equals `HTMLSupport.contentSecurityPolicy`; the body text contrast is ≥ 7:1; and rendering a generated 20,000-line document takes under 5 seconds.
2. `swift test` on macOS is green, including `DocumentOutputTests` (real `WKWebView`, PDFKit): the Fixture P PDF has more than one page; no table row is split (for every row the text of the first and last cell are on the same page, so rows are not cut); in a generated document of many short sections no page ends on a heading line; page 1 renders with a pure white background and dark text even when the test's window is in the Mocha theme; `<details>` content is in the PDF text; the HTML output has no `<script`, `onerror`, `javascript:` or `<style>` from the document, and a fresh `WKWebView` with no base URL loads it with every embedded image's `naturalWidth > 0` and the diagrams present as `<svg>`; the output for a Mocha/dark/source-view/folded window equals the output for a default window byte for byte (R4); the left-out list for Fixture P is exactly {missing file, 8,000,001-byte image, `http:` image}; the document's text storage, undo manager (`canUndo` unchanged), edited flag, selection and fold state are unchanged after each of the three commands (R5); and a document edited after the command starts does not show the edit (R3).
3. The real-app end-to-end: `scripts/ci-local.sh` (or `dist/Downwrite.app/Contents/MacOS/Downwrite --selftest-out=<dir> --selftest-input=Tests/Fixtures/export-demo.md`) reports `PASS` for the new export step, whose checks are: the File menu lists Print…, Export as PDF… and Export as HTML… in that order and `menus.txt` shows ⌘P on Print… (R1); the items are disabled while a preparation is under way and enabled afterwards (R2); a main-thread stall under 250 ms while preparing a 20,000-line generated document (R27); writing the HTML and PDF through the controller's entry points succeeds, and a deliberately unwritable destination gives the alert text and leaves no file (R26).

**B. Real-app walk-through (done by the person approving the build, on a normal desktop session).**

1. Build and open the fixture in a folder with a sibling `local.png`: `scripts/build-app.sh && open -a dist/Downwrite.app Tests/Fixtures/export-demo.md`.
2. In the window: choose View ▸ Show Markdown Source, switch to a dark theme in Settings, fold two headings. Record `shasum -a 256 Tests/Fixtures/export-demo.md`.
3. File ▸ **Export as HTML…**, accept `export-demo.html`. Expected: no alert except the left-out sheet listing `missing.png` (file not found), the 8 MB image (larger than 8 MB) and the `http:` image; the title bar still shows no edited dot; Edit ▸ Undo is still greyed or unchanged; the `.md` hash is unchanged.
4. `grep -ci -e '<script' -e 'onerror' -e 'javascript:' export-demo.html` prints `0`; `grep -c 'Secret front matter' export-demo.html` prints `0`; `head -c 400 export-demo.html` shows `<!doctype html>` then the `Content-Security-Policy` meta before anything else in `<head>`.
5. `mkdir /tmp/elsewhere && cp export-demo.html /tmp/elsewhere/ && open -a Safari /tmp/elsewhere/export-demo.html` (and Chrome): white page whatever the browser's dark mode; the logo and the local PNG are shown; the two valid diagrams are drawn and the broken one shows `Diagram could not be rendered: …` above its source; task boxes (one ticked, one empty) are visible; `[jump](#reading-this)` scrolls; the `javascript:` links are plain text; the `<details>` opens on click; the table scrolls sideways when the window is narrow.
6. File ▸ **Export as PDF…**, accept `export-demo.pdf`. `mdls -name kMDItemNumberOfPages export-demo.pdf` shows 2 or more pages; open it in Preview: every page is white with dark text and 20 mm margins; the 120-row table runs across pages with no row cut (its header row appears once, where the table starts); code is wrapped, not clipped; no heading sits alone at the bottom of a page, except the heading directly above the 120-row table, which may; the `<details>` content is visible; text can be selected and searched (⌘F for `Mixed`).
7. File ▸ **Print…** (⌘P): a print panel sheet opens on the window with the same pages in the preview; set the paper to the other of A4/Letter and see the preview reflow; choose PDF ▸ Save as PDF and confirm it opens; press Cancel on another run and confirm nothing was written and the window is unchanged.
8. Close the window while an export of a large generated document is still preparing: no panel or file appears (R25). (R3's "edits after the command do not appear" is timing-dependent by hand and is covered by the automated check in A.2.)

## Amendments

- **2026-10-10, during the build (step 1, the spike): R19 narrowed, at the person's choice.** The plan's spike printed test pages through a hidden `WKWebView` (see *Spike result* in `plan.md`). WebKit's print engine honours `break-inside: avoid` but ignores `break-after: avoid`, and never repeats a `<thead>` on a later page. As first written, R19 required "a heading is never the last thing on a page" and "a table that continues onto the next page repeats its header row there". Asked how to proceed, the person chose to amend R19 to what the engine can do: a heading is kept with the block after it only when the two fit on one page (a keep-together wrapper), and the table header is not repeated. The two gaps are logged under DW-001 in `docs/ROADMAP.md`. Verification A.2 and B.6 were changed to match. Nothing else in R19 changed. This amendment records that decision; it is not a new approval of the spec, which the person confirms again at review.
