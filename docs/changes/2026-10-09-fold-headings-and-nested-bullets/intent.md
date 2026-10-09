---
type: intent
id: 2026-10-09-fold-headings-and-nested-bullets
title: Fold and unfold content under headings and nested bullets
track: feature
status: accepted
raised: 2026-10-09
accepted: 2026-10-09
merged:
backlog:
---

# Fold and unfold content under headings and nested bullets

## Problem

In a long document the editor always shows everything. There is no way to tuck away a section you are not working on, so the page is long to scroll, hard to scan as an outline, and hard to restructure. The table of contents sidebar jumps to a heading but does not reduce what is on screen, and the same applies to deeply nested bullet lists. (The motivation is inferred from the request, so please correct it if it is wrong.)

## Proposed outcome

- A heading's content can be collapsed and expanded. "Content" is everything between the heading and the next heading of the same or a higher level, so folding an H2 hides its paragraphs, lists, tables and any H3 or deeper subsections, up to the next H2 (or H1). The heading line stays visible and shows that it is folded.
- A list item that has nested items under it can be collapsed and expanded the same way. The item's own line stays visible and shows that it is folded; its nested items are hidden.
- Folding changes only what is shown. The Markdown text is not modified, the document is not marked as edited, and nothing is added to the undo history.
- Folded content stays folded while the user types elsewhere in the document, and the user can always see which headings and items are folded.

## Affected users and systems

People who write long notes, outlines or documents in Downwrite and want to navigate or focus on part of them.

Parts of the system involved (as known now, to be confirmed in the spec):

- `DownwriteCore`: `MarkdownAnalyzer` / `MarkdownAnalysis` (`headings`, `HeadingInfo`; nesting of list items would be new to the analysis).
- `Sources/Downwrite`: `MarkdownStyler` (the existing 0.1 pt line collapse used for Mermaid, HTML and table sources), `DWLayoutManager` (drawing any fold control), `EditorCoordinator` / `EditorTextView` (caret and selection), the overlays (`TableOverlay`, `DiagramOverlay`) that are positioned from text geometry, the table of contents sidebar (`TOCModel`) and the source view (⌘/).
- Toolbar, View menu and keyboard commands, if any are added.

## Constraints

- Markdown and editing logic lives in `DownwriteCore` and is unit-tested on Linux. The app target only maps results onto AppKit (project rule).
- The document text must never change as a result of folding, and the file on disk must stay plain Markdown with no fold markers added.
- Tables, Mermaid diagrams, images and HTML cards inside folded content must disappear with it, and must not leave overlays stranded over other text (a known failure mode of this editor).
- The editor stays TextKit 1, and the app stays light: no new dependencies.
- Behaviour outside a fold is unchanged, including hidden Markdown syntax, task checkboxes, external-change reload, the table of contents and word count.
- Must stay responsive on long documents.

## Open questions

1. **How is folding toggled?** For example a chevron that appears beside a heading or parent bullet on hover, a keyboard shortcut for the item at the caret, View menu items, or a combination. Is there a "Fold All / Unfold All" (and by level)?
2. **Is fold state remembered?** Per session only, restored when the file is reopened (it cannot go in the `.md`, so it would have to live somewhere else), or reset on every open?
3. **Which lists fold?** Bullets only, or also numbered and task lists? Does an item whose children are a paragraph or code block, rather than nested items, count as foldable?
4. **What happens when the caret or a command lands inside folded text?** For example a find hit, a table of contents click on a heading inside a folded section, undo, select all, or typing at the end of a folded heading. Does the fold open, or does the caret move to the visible fold line?
5. **What does the source view (⌘/) show?** The whole text, or the folds as they are?
6. **How does a folded item look?** A chevron only, an ellipsis, or a count of hidden lines?
7. **What are folds attached to?** Editing above a fold, or an external reload, moves everything. Should a fold survive when its heading text is edited, or should only the structure matter?

## Decision

Accepted on 2026-10-09. The open questions above carry forward to the spec.
