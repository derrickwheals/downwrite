---
type: plan
id: 2026-10-10-export-and-print
intent: ./intent.md
spec: ./spec.md
status: in-progress
approved: 2026-10-10
branch: change/2026-10-10-export-and-print
---

# Plan: Print a document and export it as PDF or HTML

## Approach

The renderer is pure Swift in `DownwriteCore`, in the two steps the spec fixes: `DocumentHTML.prepare` walks the swift-markdown tree and returns a sanitised body plus the list of images and diagrams the app must resolve, and `DocumentHTML.assemble` swaps in the resolved images and diagrams and wraps the result in the fixed print page. The app target only drives AppKit and WebKit: one `DocumentOutputController` per window takes a snapshot of the editor's text, resolves images and diagrams, and then either writes the HTML file or loads the page into a hidden, script-free `WKWebView` and runs a paginated `NSPrintOperation` (the print panel for Print…, a straight save for Export as PDF…). Nothing in the editor is touched except one function that moves (`slug`) and one helper that is split in two (`ImageLoader.dataURI`).

The spec's one open mechanism question (does WebKit's print engine honour CSS page-break rules for a hidden web view?) is answered by a throwaway spike in step 1, before any production code, together with a second unknown the exploration found: `docs/ci/menus.txt` shows no Print item in the File menu today, so where `CommandGroup(replacing: .printItem)` puts three items in a `DocumentGroup` app has to be seen, not assumed. If the spike finds that neither a hidden web view nor an off-screen window paginates, the work stops and the spec comes back for a decision, as the spec says.

Decisions the code exploration forced, beyond what the spec fixes:

- **The sanitiser runs once, in `prepare`, over the whole body; `assemble` only rewrites images and fills diagrams.** Raw HTML reaches the body verbatim from `HTMLBlock` and `InlineHTML` nodes, and a `<script>` can open in one inline node and close three nodes later, so only a pass over the finished body can drop "everything to the end of the block" correctly. The same tokeniser reports the `<img>` sources that survive it, which is what `Prepared.imageSources` lists, so an image inside a removed `<style>` or comment is never resolved and never shows up in the left-out sheet. The sanitiser is a hand-written tokeniser, not a regular expression, and its character-reference decoding (numeric plus the handful of named references that can form a scheme: `colon`, `Tab`, `NewLine`) is shared with the link-destination check of R12.
- **Diagram slots are sentinels that cannot be forged.** The walker writes a diagram as a private-use sentinel (`U+E000 D<n> U+E001`) and escapes any private-use character in document text as a numeric reference, so a document cannot contain a sentinel. `assemble` fills the slots after sanitising, which is why Mermaid's own `<style>` and `<svg>` survive while the document's `<style>` does not.
- **Image decisions live in Core, file reading does not.** `DocumentHTML.resolveImages(_:documentHasFolder:load:)` takes a closure that reads one local file (off the main thread, supplied by the app) and applies the R14 table, the untitled-document rule, the 64 MB budget in document order (it stops asking for files once the budget is spent, so a document with a thousand 8 MB images never reads them all) and the left-out reasons. That keeps R14 and R16 testable on Linux with a fake closure. It also avoids a trap in `ImageLoader.fileURL(for:base:)`, which resolves a relative source against the process's working directory when `base` is nil; Core answers `document not saved yet` before the app is asked.
- **`ImageLoader.dataURI(at:)` becomes a thin wrapper over a new `ImageLoader.embed(at:)`** that returns the data URI or a reason (`notFound`, `tooLarge`, `notAnImage`). The spec expected `Previews.swift` to stay as it is, but the left-out sheet needs the reason and `dataURI` returns `nil` for all three. The editor's cards keep calling `dataURI` with identical results (`ImagePreviewTests` and `HTMLCardTests` stay green untouched).
- **Heading ids come from `MarkdownAnalyzer.analyze(...).headings`, not from the walker's own text.** The editor slugs the raw title (markers and all, so `[x](u)` and a heading inside a quote have quirky slugs), and R12 says a fragment that works in the editor must work in the file. Using the analyzer's `HeadingInfo.title` agrees by construction; the walker assigns slugs by heading order and a test asserts the two counts agree on Fixture P. Fragment links are written lower-cased, as the editor lower-cases a fragment before it looks it up. If `analyze` alone costs too much of the R27 budget on a 1 MB document, step 12's measurement says so and the fallback is slicing the title from the heading's source line with the same two regular expressions.
- **Highlight and bare URLs use the analyzer's own patterns on text outside code and links**, moved into an internal `InlineExtensions` enum that `MarkdownAnalyzer` and the walker both call. Highlight is matched on the inline container's text with non-text children (code, images, HTML) replaced by one placeholder character, as the analyzer does with its protected ranges, and `<mark>` is split at element boundaries so `==a **b** c==` stays well nested. Bare URLs are matched per text node.
- **Raw HTML is not wrapped per block.** The common README pattern is `<details>`, a blank line, Markdown, a blank line, `</details>` as three blocks, and a wrapper `<div>` around each block would close the `<details>` early. The body sits in one `<main>`, so an author's unclosed tag is closed at its end. In print and PDF the sanitiser adds `open` to every `<details>` (`Target.print`), because CSS cannot reliably show the content of a closed one.
- **Timeouts race unstructured tasks.** `MermaidService.render` is a pair of continuations that ignore cancellation, so a task group (which waits for every child) would hang on a stuck renderer. The controller starts the render in a plain `Task` and races it against a sleep with a resume-once box; the diagram renderer and the 20-second limit are injected so a test can use a renderer that never returns.
- **The controller is testable without a window.** It takes `snapshot`, `renderDiagram`, `diagramTimeout`, `presentOmissions`, `presentError` and the page-loading hooks as properties with real defaults, and has non-interactive entry points (`makeHTML()`, `writeHTML(to:)`, `writePDF(to:)`) under the interactive `printDocument()`, `exportPDF()` and `exportHTML()`. The self-test and `DocumentOutputTests` drive those.

## Files that change

Core (`DownwriteCore`, builds and tests on Linux):

- `Sources/DownwriteCore/HeadingAnchor.swift` (new) — `HeadingAnchor.slug`, moved from `EditorCoordinator.slug`, plus `unique(_:)` for the `-1`, `-2` suffixes.
- `Sources/DownwriteCore/InlineExtensions.swift` (new) — the highlight and bare-URL patterns, and the front-matter rule (`FrontMatter.endLine(in:)`), moved out of `MarkdownAnalyzer` unchanged so both sides call one definition.
- `Sources/DownwriteCore/MarkdownAnalyzer.swift` — `maskFrontMatter` and `extensions(in:protected:)` call the shared helpers; no behaviour change (`AnalyzerTests` is the guard).
- `Sources/DownwriteCore/LinkPolicy.swift` (new) — character-reference decoding and the R12 destination check, used by the walker and the sanitiser.
- `Sources/DownwriteCore/HTMLSanitizer.swift` (new) — the tokenising sanitiser of R13, the surviving-image listing, the `<details open>` option and the image-source rewrite used by `assemble`.
- `Sources/DownwriteCore/PrintStyle.swift` (new) — the CSS of R17–R20 for both targets.
- `Sources/DownwriteCore/DocumentHTML.swift` (new) — `Target`, `Options`, `Prepared`, `prepare`, `resolveImages`, `assemble`; the walker, escaping and sentinels are in `DocumentRenderer.swift` — sentinels, SVG id rewriting, the page template, the omission summary (`summaryLines(of:limit:)`) and `OutputNaming.defaultFileName` (R24).
- `Sources/DownwriteCore/HTMLSupport.swift` — reused (`contentSecurityPolicy`, `parseTag`); no change expected.

App (`Sources/Downwrite`, macOS only):

- `Previews.swift` — `ImageLoader.embed(at:)` returning a result with a reason; `dataURI(at:)` calls it.
- `EditorView.swift` — `EditorCoordinator.slug` is removed and its two callers use `HeadingAnchor.slug`.
- `DocumentOutput.swift` (new) — `DocumentOutputController`, the save panels, the left-out-images sheet, the failure alerts, the focused-scene-object key, the window reader.
- `PrintRenderer.swift` (new) — the hidden web view, the navigation rule, the load wait, the print info and the print operations.
- `DownwriteApp.swift` — `OutputCommands` (File ▸ Print…, Export as PDF…, Export as HTML…) added to `.commands`; `EditorScene` creates the controller as a `@StateObject`, publishes it with `.focusedSceneObject`, feeds it the live text (`document.text`), the `fileURL` and the window.
- `SelfTestExport.swift` (new), `SelfTest.swift` — a new end-to-end step before step 8 (it needs the first window, which SwiftUI resolves focused items against), behind `--selftest-export=<file>` like the fold step.

Tests, fixtures, scripts and docs:

- `Tests/Fixtures/export-demo.md` (new, Fixture P), `Tests/Fixtures/local.png` and `Tests/Fixtures/local.svg` (new, tiny; the PNG is written once with a few lines of stdlib Python). The 8,000,001-byte image is created by the tests and the walk-through, not committed.
- `Tests/DownwriteCoreTests/HeadingAnchorTests.swift`, `HTMLSanitizerTests.swift`, `PrintStyleTests.swift`, `DocumentHTMLTests.swift`, `DocumentHTMLImageTests.swift` (new).
- `Tests/DownwriteTests/DocumentOutputTests.swift` (new); `ImagePreviewTests.swift` (reason cases added); `EditorBehaviourTests.swift` (the one `EditorCoordinator.slug` call becomes `HeadingAnchor.slug`).
- `scripts/ci-local.sh`, `.github/workflows/ci.yml` — pass `--selftest-export=Tests/Fixtures/export-demo.md` next to `--selftest-fold`.
- `CLAUDE.md` — an architecture rule for output, in the style of the existing ones, and the new files in the layout notes.
- Not in this change (owed once merged and tagged, as the spec says): `README.md`, `FEATURE-LIST.md`, the release note, `docs/ROADMAP.md` status. `docs/ci/menus.txt` is refreshed by CI's `[shots]` commit, not by hand.

## Order of work

- [x] 1. Spike, throwaway and not committed: (a) load a page with a long table, tall blocks and `break-inside`/`break-after`/`thead` rules into a hidden `WKWebView` and print it with `printOperation(with:)` to a file (`jobDisposition = .save`, no panel), reading the PDF back with PDFKit; try hidden, then in an off-screen window, with margins from `NSPrintInfo` and from `@page`; check the sheet flow (`runModal(for:delegate:didRun:contextInfo:)`) and whether a failed run can be told from Cancel. (b) a stub `CommandGroup(replacing: .printItem)` with three buttons and a `@FocusedObject` enablement: where they land in File, that ⌘P reaches them, that `menus.txt` lists them, that the items grey out when `isPreparing` flips and when no document window is frontmost. Record the findings in a "Spike result" paragraph in this plan and commit that alone: `plan(2026-10-10-export-and-print): spike result`. If pagination fails in both setups, stop and ask.
- [x] 2. Test first: `HeadingAnchorTests` (the table of titles that `EditorBehaviourTests` and the editor rely on, `-1`/`-2` suffixes, collision with a literal `foo-1`, empty slug). Add `HeadingAnchor`, point the two callers and the one existing test at it, delete `EditorCoordinator.slug`.
- [x] 3. Move the front-matter rule and the highlight/bare-URL patterns into `FrontMatter` and `InlineExtensions`; `MarkdownAnalyzer` calls them. No new test needed beyond `AnalyzerTests` staying green; add a small test that `FrontMatter.endLine` agrees with the analyzer's `.frontMatter` line kinds on a few inputs.
- [x] 4. Test first: `HTMLSanitizerTests` and the link-destination table (R12 and R13: every adversarial input in the spec's list, uppercase tags, unquoted and entity-encoded handlers, `<svg onload>`, unclosed `<script>`/`<style>`, whitespace/tab/newline inside `javascript:`, `&#x6A;avascript:`, `srcset`, `xlink:href`, allowed HTML left intact, `<details open>` for print, a seeded random-mutation test that asserts no forbidden construct survives). Then `LinkPolicy` and `HTMLSanitizer`.
- [x] 5. Test first: `PrintStyleTests` (contrast of body text ≥ 7:1 the way `ThemeCatalogTests` asserts its floors, palette colours, `color-scheme: light`, 46 em column, 24 px padding, `@media print` rules including `break-inside: avoid` on `.keep`, task items, quotes, code, images and diagrams, 90% code size, the print and screen differences; no `thead` repetition is promised). Then `PrintStyle.css(for:)`.
- [x] 6. Fixture P and the walker, one commit per group, each with its tests first in `DocumentHTMLTests`: (6a) blocks, inline formatting, escaping, front matter, smart punctuation off, hard and soft breaks, and the heading keep-wrapper of R19 (`<div class="keep">` around a heading and the block that follows it, for the screen target too so the two targets differ only in the CSS; a heading that is last in its container, followed by nothing, or followed by a raw HTML block (which may open a tag that closes three blocks later) is not wrapped; the wrapper adds no element to the heading ids or the outline); (6b) lists at depth, numbered start, tight and loose, task items with CSS boxes (numbered tasks too), tables with alignment and `<br>`, fenced and indented code; (6c) links, heading ids and the `-1` rule, lower-cased fragments, highlight across element boundaries, bare URLs, never inside code; (6d) images in Markdown and HTML, raw HTML blocks and inline tags through the sanitiser, split `<details>` in three blocks, Mermaid slots, footnotes and math left as typed.
- [ ] 7. Test first: `DocumentHTMLImageTests` (every row of the spec's R14 table with a fake `load` closure, the budget stopping reads, untitled-document rule, query strings, duplicate sources resolved once). Then `resolveImages`.
- [ ] 8. Test first: `assemble` tests (head order with the CSP first and equal to `HTMLSupport.contentSecurityPolicy`, `<title>` rules, determinism, SVG id rewriting for two diagrams and the same diagram twice, the `Diagram could not be rendered: …` note plus source block, left-out images as muted alt text, `Omission` list, summary lines with `and N more`, `OutputNaming`, empty and front-matter-only documents), then `assemble` and `summaryLines`. Add the 20,000-line performance test here (it also decides the heading-id fallback of the Approach).
- [ ] 9. App: test first for `ImageLoader.embed` reasons in `ImagePreviewTests` (missing, over 8,000,000 bytes by one, a text file, an SVG, a PNG), then the refactor. `dataURI(at:)` results are unchanged.
- [ ] 10. App: `PrintRenderer`, written from the spike's findings, with `DocumentOutputTests` for the PDF path first: Fixture P gives more than one page, no table row split, no blank page, a generated document of 150 short sections has no page that ends on a heading (the Fixture P heading above the 120-row table is exempt, R19), page 1 is white with dark text, `<details>` text is in the PDF, text is selectable, page size equals the system default paper; and the lock-down tests (a script in a hand-built page does not run, a `<meta http-equiv="refresh">` and a link click do not navigate).
- [ ] 11. App: `DocumentOutputController` and `DocumentOutput.swift`: the snapshot and the three phases, the preparing flag, window-closed drop, the 20-second diagram limit with stop-after-first-timeout, the save panels (name, type, folder) and the atomic write, the alerts, the left-out sheet after completion only. Tests first in `DocumentOutputTests`: text is the unsaved text and the file on disk is not read (R3), an edit after the command is absent, the document model is untouched (R5, on a real editor harness), byte-identical HTML from a Mocha/source-view/folded window and a default one (R4), HTML loads in a fresh `WKWebView` with every image's `naturalWidth > 0` and diagrams as `<svg>`, an unwritable destination leaves no file and keeps an existing one, a renderer that never returns times out and the later diagrams are not attempted.
- [ ] 12. App: `OutputCommands`, the `EditorScene` wiring (`@StateObject`, `.focusedSceneObject`, the live-text closure, the window reader) and `DownwriteApp.commands`. The 20,000-line main-thread stall is measured here with a quick local run before the e2e depends on it; so is the heading-id cost.
- [ ] 13. End to end: `SelfTestExport.swift` and its call in `SelfTest.run()` before step 8, the CI and `ci-local.sh` arguments. Checks: the File menu lists the three items in order with ⌘P on Print…, enabled with a document window and disabled while the controller is preparing and when only Settings is frontmost, a generated 20,000-line document prepared with a main-thread stall under 250 ms, the HTML and PDF written through the entry points, an unwritable destination gives the alert text and no file, `isDocumentEdited`, `canUndo` and the file's hash unchanged, and the print operation's paper size and page count read without opening the panel.
- [ ] 14. `CLAUDE.md` rule and layout note. Run the whole proof below. Hand the walk-through (spec Verification B) to the person approving the build; do not mark anything accepted.

## Spike result

Step 1, run on 2026-10-10 (Xcode 27, Swift 6.4, system default paper A4). A throwaway harness (not committed) printed generated pages through a hidden, script-free `WKWebView` with `printOperation(with:)`, `jobDisposition = .save`, `jobSavingURL` and `showsPrintPanel = false`, and read each PDF back with PDFKit. Each CSS mechanism was tested in its own document against a control without it.

**What the print path must do.** `NSPrintOperation.run()` never returns for a web view's print operation, in all three setups tried (no window, a window never ordered in, an off-screen window ordered in). `runModal(for:delegate:didRun:contextInfo:)` works in all three and gives identical pages. So the web view stays hidden with no window, and `runModal(for:)` is given the document window (any window works). `PrintRenderer` uses only that call, for Print… and for Export as PDF… (`showsPrintPanel = false`).

**What works.** The system default paper is used (595 × 842 here). Margins of 20 mm on `NSPrintInfo` put text 56 pt from the left and 59 pt from the top; `@page { margin: 20mm }` is honoured too and is not added to the `NSPrintInfo` margins, so margins come from `NSPrintInfo` alone. Text stays text. `break-inside: avoid` (and the legacy `page-break-inside`) works: a control split 3 of 40 blocks across pages, the same document with the rule split none. Table rows were never split, with or without a rule. Long code lines wrapped (`pre-wrap` with `overflow-wrap: anywhere`) stayed inside the margin.

**What does not work.** (1) `break-after: avoid` / `page-break-after: avoid` on headings has no effect: 5 headings ended a page with it and 5 without it. A `<div>` that wraps the heading and the first block after it with `break-inside: avoid` fixes it (0 of 150 headings last on a page), but only while the heading and that block together fit on one page. When they are taller than a page WebKit ignores the wrapper (a heading before a 140-row table still ended page 1). (2) A table's `<thead>` is not repeated on later pages: in four configurations (default, `display: table-header-group`, separated borders, with row rules) 4 of 5 table pages had no header. R19 asks for both, so R19 as written is not fully deliverable with this print engine. This is put to the person approving the build; no code that depends on it is written until it is settled.

**Other findings.** A closed `<details>` at the end of a document produced an empty last page; with `open` it did not, which supports R20, and step 10 adds a "no blank page" assertion. A failed save cannot be trusted to say so: with a destination directory that does not exist `didRun` is `true` and no file is written; with a read-only directory it is `false`; Cancel in the panel also gives `false`. So the controller prints to a temporary file, checks that it exists and is a PDF, and moves it into place (this also gives R26's atomic write); Export as PDF… treats `false` as a failure; Print… cannot tell a failure from Cancel and treats `false` as Cancel (the fallback the Risks section named), so R26's print-engine case is proven for Export as PDF… only.

**Menu.** `CommandGroup(replacing: .printItem)` in this `DocumentGroup` app puts the three items at the end of File, after Share and two dividers in a row (the stub group held no divider, so both come from the system; the real group adds none), with ⌘P on Print…; every existing File item keeps its order. Not verified: that the items follow the focused scene object (grey while `isPreparing`, grey with only Settings frontmost). The login session was locked (`CGSSessionScreenIsLocked`), the app never became key and the items stayed disabled in all four states, so the check carries to step 13 and the CI end-to-end run. The same lock may stop the WebKit tests that need the display awake.

## Risks

- **WebKit may not paginate a hidden web view as R19 needs** — step 1 finds out before anything depends on it, with an off-screen window as the first fallback and a stop-and-ask if both fail. R19's text is proven on real PDF output (PDFKit), not on the CSS strings.
- **A failed print run may be indistinguishable from Cancel in the Print… sheet** (`didRun` reports only a Bool) — step 1 looks for a way. If there is none, Print… treats a false result as Cancel and R26's print-engine case is proven for Export as PDF… only; the plan then records that as a deviation, in the commit that introduces it.
- **`CommandGroup(replacing: .printItem)` may put the items somewhere other than where Print belongs, or not at all in a `DocumentGroup` app** — step 1(b) and the e2e menu check (R1). Fallbacks are `after: .saveItem` or `after: .importExport`; the order of the three items is the part R1 pins.
- **A sanitiser bypass would put script into a file people send around** — a tokeniser instead of a regular expression, the spec's adversarial table, a seeded random-mutation test, the CSP as a second layer in the file itself (R23) and script-off plus navigation-cancelled in the print web view (R28), each tested separately so one layer failing is visible.
- **Highlight or autolink output drifting from the editor** — one definition of each pattern; the Fixture P cases (`==a **b** c==`, a URL beside `**`, `==` inside code) are the checks.
- **A stuck Mermaid renderer hanging the export** — unstructured race, resume-once box, and a never-returning renderer in the tests. After a timeout the shared renderer may stay stuck for the session, as the spec says.
- **Large documents** — `prepare` and image reading run detached; the walker applies the highlight and URL patterns only to inline containers whose text contains `==`, `http` or `www.`; images are read one at a time and stop at the budget; the 5-second Core test and the 250 ms e2e check are the gates. The Linux Foundation regular-expression engine is slower than Darwin's, which is why the Core budget is asserted on the Linux CI image and not only locally.
- **Linux differences** — no `as NSString`, no Darwin-only API in Core, no reliance on `String(format:)` locale; the Linux job in CI is the check, and `scripts/linux-test.sh` needs Homebrew's bash on this Mac (CLAUDE.md, gotchas).
- **The editor changing by accident** — new code is in new files; the three edits to existing files (`slug`, the analyzer helpers, `dataURI`) each keep their existing tests untouched except one call site; the full `swift test` run is the guard (R29).
- **WebKit tests need the display awake** — the proof commands start `caffeinate` first, as CLAUDE.md says.

## Proof

Tests to add or change:

- `Tests/DownwriteCoreTests/HeadingAnchorTests.swift` — the slug table moved from the editor, suffixes, collisions.
- `Tests/DownwriteCoreTests/HTMLSanitizerTests.swift` — R12 destinations and R13 removals, allowed HTML intact, `<details open>`, random mutation.
- `Tests/DownwriteCoreTests/PrintStyleTests.swift` — R17 and R18, and the CSS rules R19 and R20 rest on.
- `Tests/DownwriteCoreTests/DocumentHTMLTests.swift` — R6 to R13 against Fixture P and small cases, `assemble`, determinism, head order, title, SVG ids, naming, omission summary, performance.
- `Tests/DownwriteCoreTests/DocumentHTMLImageTests.swift` — R14 and the budget.
- `Tests/DownwriteTests/DocumentOutputTests.swift` — real `WKWebView` and PDFKit: R3 to R5, R19, R22, R23, R25 to R28.
- `Tests/DownwriteTests/ImagePreviewTests.swift` — reasons from `ImageLoader.embed`.
- `Sources/Downwrite/SelfTestExport.swift` — the real-app checks of spec Verification A.3.

Must pass before the change is complete:

```
scripts/linux-test.sh                      # Core on Linux (with Homebrew bash on macOS), or the Linux job in CI
caffeinate -u -t 2; caffeinate -d -t 1800 &
swift test                                 # macOS: everything, including DocumentOutputTests
scripts/ci-local.sh --yes                  # build, tests, package, real-app end to end; artifacts/summary.txt
grep -c "export" artifacts/e2e/selftest-report.txt && grep -q "ALL CHECKS PASSED" artifacts/e2e/selftest-report.txt
```

Requirement coverage:

| Requirement | Proven by |
|---|---|
| R1 | e2e (`SelfTestExport`): File menu order and ⌘P on Print…; `menus.txt` after the next CI `[shots]` run; spike 1(b) |
| R2 | `DocumentOutputTests` (`isPreparing`, per controller); e2e: enabled with a document window, disabled while preparing and with only Settings frontmost |
| R3 | `DocumentOutputTests`: unsaved and untitled text exported, disk file never read, an edit made after the command is absent |
| R4 | `DocumentOutputTests`: byte-identical HTML from a Mocha/source-view/folded window and a default one; `DocumentHTMLTests`: the Core API takes no theme or setting |
| R5 | `DocumentOutputTests` (text storage, undo, selection, folds on an editor harness); e2e (`isDocumentEdited`, `canUndo`, file hash on a real document) |
| R6 | `DocumentHTMLTests` on Fixture P: headings, paragraphs, breaks, quotes, rules, lists, start numbers, tight and loose |
| R7 | `DocumentHTMLTests`: inline elements, links, `==`, smart punctuation off, bare URLs, nothing inside code |
| R8 | `DocumentHTMLTests`: task markup for bulleted, numbered and nested items; `PrintStyleTests`: CSS box, no form control; PDF page-1 check in `DocumentOutputTests` |
| R9 | `DocumentHTMLTests`: header, rows, alignment, inline formatting, `<br>`, tables in quotes and list items |
| R10 | `DocumentHTMLTests`: escaping of `</pre><script>` in code, kept whitespace, info string hidden, inline code |
| R11 | `DocumentHTMLTests`: `Secret front matter` appears nowhere; footnotes and math as typed |
| R12 | `HTMLSanitizerTests` (destination table incl. mixed case, whitespace, `&#x6A;avascript:`); `DocumentHTMLTests` (heading ids, `-1`, lower-cased fragments); `HeadingAnchorTests` |
| R13 | `HTMLSanitizerTests`: every listed element, attribute and value, adversarial table, random mutation, allowed HTML intact |
| R14 | `DocumentHTMLImageTests` (each table row, budget, untitled); `ImagePreviewTests` (reasons); `DocumentOutputTests` (embedded images load, left-out list for Fixture P) |
| R15 | `DocumentHTMLTests` (slots, SVG ids, failure note and source); `DocumentOutputTests` (real `MermaidService` output, two identical diagrams share no id, 20-second race with a never-returning renderer, later diagrams not attempted) |
| R16 | `DocumentHTMLTests` (summary lines, ten and `and N more`); `DocumentOutputTests` (sheet only when something was left out and only after completion) |
| R17 | `PrintStyleTests`: contrast floor, palette values, font stack, sizes, `color-scheme` |
| R18 | `PrintStyleTests` (column, padding, overflow rules); `assemble` test for the viewport meta; walk-through B.5 on a narrow window |
| R19 | `DocumentOutputTests`: Fixture P PDF, page count, rows unsplit, no blank page, no heading last in a generated many-section document, wrapped code, paper and margins; `DocumentHTMLTests` (the keep-wrapper); `PrintStyleTests` (the break rules); spike 1(a) (as amended) |
| R20 | `DocumentHTMLTests` (`open` added for print, not for screen); `DocumentOutputTests` (`<details>` content in the PDF text) |
| R21 | e2e: the print operation built for the window carries the paper size and page count; walk-through B.7 for the panel itself |
| R22 | `DocumentOutputTests`: valid PDF, selectable text, default paper size, no panel shown |
| R23 | `DocumentHTMLTests` (doctype, charset, title, CSP first and equal to the constant, no script); `DocumentOutputTests` (a fresh web view with no base URL shows every image and diagram) |
| R24 | `DocumentHTMLTests` (`OutputNaming`: extensions stripped, `Untitled`, type fixed); save-panel folder and name checked in `DocumentOutputTests` through the panel factory seam |
| R25 | `DocumentOutputTests`: phases in order, no panel or file when the window closes during preparation, a second command refused while preparing; the 8-second remote-image allowance by code reading and walk-through B (no network in CI) |
| R26 | `DocumentOutputTests` and e2e: unwritable destination gives `Couldn't export` text, no partial file, existing file kept; load failure gives `Couldn't print` |
| R27 | `DocumentHTMLTests`: 20,000 lines under 5 seconds on the Linux image; e2e: main-thread stall under 250 ms |
| R28 | `DocumentOutputTests`: script-off and navigation-cancelled in the print web view; `HTMLSanitizerTests` plus the CSP check in `DocumentHTMLTests` for the file |
| R29 | the full existing suite green, `HeadingAnchorTests` holding the old slug results, `AnalyzerTests` and `ImagePreviewTests` untouched apart from added cases |

## Deviations

- **R19 narrowed (2026-10-10, step 1, at the person's choice).** The spike showed the print engine ignores `break-after: avoid` and never repeats a `<thead>`. Spec R19, Verification A.2 and B.6 were amended and the plan changed to match: headings are kept with the next block by a `.keep` wrapper only when both fit on one page, and a table header is not repeated; steps 5, 6a and 10 and the R19 coverage row now say so; the two gaps are logged under DW-001 in `docs/ROADMAP.md`. Committed with the spec amendment.
- **The walker is its own file, `DocumentRenderer.swift` (2026-10-10, step 6).** `DocumentHTML.swift` keeps the public API, `prepare`, `assemble` and `OutputNaming`; the Markdown walker, escaping and the diagram and boundary sentinels live in `DocumentRenderer.swift`. Layout only.
- **Fixture P's attack image points at `local.png`, not `x` (2026-10-10, step 6).** `<img src=x onerror=…>` keeps `src="x"` (a relative path, so it is a surviving image) and would add a fourth entry to the left-out list that the spec fixes at three. `<img src=local.png onerror=…>` still proves `onerror` is removed and adds no source.
- **A style rule and a wrapper detail from step 6 (2026-10-10).** Links are styled with `a[href]`, so an anchor whose `href` the sanitiser refused does not look like a link; a `.keep` wrapper that opens the page loses its heading's top margin. Both are in `PrintStyle` with their tests.
- **Print runs only through `runModal(for:)`, and the PDF goes through a temporary file (2026-10-10, step 1).** `NSPrintOperation.run()` hangs for a web view and `didRun` can be `true` with nothing written, so `PrintRenderer` never calls `run()` and the controller writes to a temporary file, checks it, and moves it into place. This is how, not what, so the plan's text above stays as written; the *Spike result* section holds the detail.
