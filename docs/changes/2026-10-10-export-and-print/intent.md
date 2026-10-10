---
type: intent
id: 2026-10-10-export-and-print
title: Print a document and export it as PDF or HTML
track: feature
status: accepted
raised: 2026-10-10
accepted: 2026-10-10
merged: 2026-10-10
backlog: "DW-001 (docs/ROADMAP.md#dw-001--export-and-print)"
---

# Print a document and export it as PDF or HTML

## Problem

Roadmap item DW-001. A Markdown document is usually written so that someone else can read it, but today the only way to get a document out of Downwrite is to hand over the `.md` file itself. There is no Print command and no export to PDF or HTML: the File menu has Share but nothing else for output (`docs/ci/menus.txt`, captured 2026-10-08), and a search of `Sources/` finds no print or export code. Anyone who needs a printed page, a PDF to send, or an HTML page to publish has to open the file in another tool for the last step. People hit this in their first week. (The wording of the problem comes from the roadmap, so please correct it if it is off.)

## Proposed outcome

- **File ▸ Print…** (⌘P) prints the document as a reader would see it, laid out as rendered Markdown rather than as raw text and not as the editor happens to look right now. The standard macOS print panel is used, so Save as PDF from it also works.
- **File ▸ Export as PDF…** asks for a name and location and writes a PDF of the same rendering.
- **File ▸ Export as HTML…** asks for a name and location and writes a single HTML file that opens correctly in a browser, on this Mac or another.
- The output shows the whole document in a print-friendly light style, whatever theme the window is in. Folded sections are included and the Markdown source view (⌘/) makes no difference.
- The output reproduces what the editor can render: headings, paragraphs and inline formatting, lists and nested lists, task checkboxes (ticked or not), block quotes, rules, links, tables, fenced code, images, Mermaid diagrams and the HTML blocks that the editor renders.
- Printing or exporting does not change the document: no edit, no undo entry, no fold or caret change, and the file on disk is untouched. An unsaved or untitled document exports its current text, not what was last saved.
- Not in this change: Word (`.docx`). It is a different size of job (no library, so a new dependency or hand-written OOXML) and is deferred. Export of pasted images, syntax highlighting and typeset math is complete only once DW-002, DW-003 and DW-004 ship, and is not part of this change.

## Affected users and systems

People who write in Downwrite and then share, print or publish the result, and anyone who has stayed with another editor because of this.

Parts of the system involved (as known now, to be confirmed in the spec):

- `Sources/Downwrite/DownwriteApp.swift`: the `.commands` list, where new File menu items would live (there is no File-menu command group today; `FormatCommands`, `ViewCommands`, `WindowCommands` and `AppCommands` are the pattern), and the per-window focused values that give a command the front document.
- `DownwriteCore`: `MarkdownAnalyzer` / `MarkdownAnalysis` (spans, line styles, tables, task boxes, `htmlBlocks`, Mermaid blocks) as the source of what a document contains, and `HTMLSupport` (`page(body:style:)`, local image inlining helpers) and `MermaidSupport`, which already build locked-down pages for cards. Where the HTML for a whole document comes from is a spec question.
- `Sources/Downwrite`: `MermaidService` (SVG from a hidden `WKWebView`), `DiagramView` / `DiagramOverlay` (the HTML card path and its `data:` image inlining via `ImageLoader`), `EditorCoordinator` (the current text and the document's location), `Typography` / `Palette` (what to use or ignore for a print style).
- Release notes, `README.md` and `FEATURE-LIST.md` once it ships.

## Constraints

- Markdown and rendering decisions live in `DownwriteCore` and are unit-tested on Linux. The app target only drives AppKit and WebKit (print operation, save panel, web view). Project rule.
- Keep the app light: no new dependencies. The bundled Mermaid already in the app is reused, not duplicated.
- Output must not run scripts from the document or fetch remote content beyond what the editor already allows for an HTML block (the card page allows `https:` and `data:` images only, with page JavaScript off).
- Mermaid rendering is asynchronous, so output must not be produced with blank diagrams that are still rendering.
- Local images must still appear in the output and the 8 MB per-image inlining cap used for cards is the precedent. What happens above the cap is for the spec.
- The editor's behaviour is unchanged: hiding syntax, folding, the source view, overlays, external-change reload, the contents sidebar and the existing Share item.
- Must handle a long document without freezing the window, and printed or PDF output must paginate sensibly (no table row, code block line or image cut in half where it can be avoided).
- The app is not sandboxed, so writing the exported file wherever the user chooses is allowed.

## Open questions

1. **Is Word (`.docx`) really out of this change?** The roadmap suggests Print, PDF and HTML as the first slice with Word deferred. Confirm, or say if Word is wanted now.
2. **What does the print style look like?** One fixed light style (own fonts, margins, sizes), or does it follow the user's typography settings (font, size, line spacing) and light theme choice? Page size and margins: the print panel's, or fixed?
3. **Is the exported HTML one self-contained file?** That means CSS inline and local images embedded (a large file for a heavy document), versus a file with images left as relative links that break when the file moves. What about remote `https:` images (embed, or leave as links)?
4. **How are Mermaid diagrams written to HTML?** Inline SVG is the natural reading, but confirm. What shows when a diagram's source is invalid (the editor shows an error card)?
5. **What happens to raw HTML in the document?** The editor drops `<script>` and `<style>` and renders the rest in a locked-down page. Should the exported HTML file do the same, or carry the HTML as written?
6. **Export names and untitled documents.** Default file name from the document name (and `Untitled` when unsaved), and where the save panel opens.
7. **Anything beyond the basics for PDF and HTML?** Selection only, a table of contents, PDF bookmarks from headings, working links, page numbers. Assumed out of scope unless you say otherwise.

## Decision

Accepted on 2026-10-10. The open questions above carry forward to the spec.
