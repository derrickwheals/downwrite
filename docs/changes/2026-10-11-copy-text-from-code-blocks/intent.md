---
type: intent
id: 2026-10-11-copy-text-from-code-blocks
title: Copy the text of a code block with one click
track: enhancement
status: accepted
raised: 2026-10-11
accepted: 2026-10-11
merged: 2026-10-11
backlog: "DW-012 (docs/ROADMAP.md#dw-012--copy-text-from-code-blocks)"
---

# Copy the text of a code block with one click

## Problem

Roadmap item DW-012. Code blocks are the part of a document people most often want to lift out whole: a shell command, a config snippet, a README example. Today the only way is to drag a selection exactly from the first character of the code to the last. While the fences are collapsed, that selection can also sweep in the hidden fence lines, because hidden syntax stays in the text and copies with it, so the pasted result carries stray backticks and a language tag. The app never writes to the pasteboard (a search of `Sources/` on 2026-10-11 finds it read only, for a URL pasted over a selection and for paste into a table cell; the one write is in the self-test), so there is no shortcut at all. GitHub and most documentation sites show a copy button at the top right of a code card for exactly this reason. (The wording of the problem comes from the roadmap, so please correct it if it is off.)

## Proposed outcome

- Each code block's card has a small copy control at its top right. Clicking it puts exactly the code on the clipboard as plain text: without the fence lines, without the language tag, and without a quote or list prefix when the block is nested in one.
- The result is the same whether the fences are collapsed or revealed because the caret is inside the block.
- After the click the control shows a brief confirmation (a tick) and then returns to normal.
- Copying does not change the document: no edit, no undo entry, and the document is not marked as edited.
- The control does not appear in the Markdown source view (⌘/), in folded lines, or in any print, PDF or HTML output.
- A person who cannot see or point at a drawn control (VoiceOver, keyboard only) has another way to do the same thing, such as an accessibility action or a menu command like Copy Code Block.
- Not in this change: copy controls for tables, front matter or inline code; syntax highlighting (DW-003); the wider accessibility audit (DW-011), which this change only feeds with the one control it adds.

## Affected users and systems

Anyone who writes READMEs, documentation, tutorials or notes with commands and snippets in them, which is most Markdown users.

Parts of the system involved (as known now, to be confirmed in the plan):

- `DownwriteCore`: `MarkdownAnalyzer.codeBlock` marks fence lines `.fence`, lines between them `.codeBlock`, and adds a `.codeBlock` span, but keeps no record of a block's code range or text (only Mermaid blocks get one, as `MermaidBlock`). A small new type saying what each block's copyable text is would live here and be tested on Linux.
- `Sources/Downwrite`: `DWLayoutManager` (the card is drawn by `drawCustomBackgrounds` from `.dwBlockBackground`, shared with tables and front matter, and the fold chevrons already draw a control through `drawFoldControls`), `EditorTextView` (pointer tracking in `updateTrackingAreas` and `mouseMoved`, clicks in `mouseDown`, `drawBackground(in:)`, accessibility), and the pasteboard write itself.
- `MarkdownStyler`, only if the card needs room for the control (see the open questions).
- `README.md` and `FEATURE-LIST.md` once it ships.

## Constraints

- Markdown and block-boundary decisions live in `DownwriteCore` and are unit-tested on Linux; the app target only draws and handles the click. Project rule.
- Keep the app light: no new dependencies.
- The control is drawn, not a subview or text, and must not touch the text storage, mark the document edited or reach the undo stack.
- Pointer movement over the card must not restyle lines or force a redraw of more than the control itself; the styler is sensitive to performance because lines are restyled as the caret moves.
- The control must read in every built-in and imported theme, in light and dark, so its colours come from the `Palette`.
- The editor's other behaviour is unchanged: ⌘C of a selection, hiding and revealing of fences, folding, the source view, overlay cards, the contents sidebar and external-change reload.
- Print, PDF and HTML output read only the document text (`DocumentHTML`), and must stay free of the control.
- Sequencing, from the roadmap: this touches `MarkdownAnalyzer`, `DWLayoutManager` and `EditorTextView`, the same files as DW-003, DW-006 and DW-007, so it should not run in parallel with any of them. It does not conflict with DW-001 (shipped), DW-002, DW-004 or DW-010.

## Open questions

1. **What exactly is copied?** The code as a reader sees it: the lines between the fences, with the fence lines, language tag and any quote or list prefix removed, which is what cmark's `CodeBlock.code` gives the HTML export. Is a trailing newline included or not? Does an indented block's indent come off?
2. **When does the control show?** Always, or only while the pointer is over the card or the caret is in the block, like the fold chevrons. Hover-only keeps the page quiet but is less discoverable, and there is no hover on a trackpad-free setup.
3. **Where does the control sit?** The card spans the text column, so the first line of a long block can run underneath the control. Does it get its own background, or does the line get room (which would need the styler)?
4. **What confirmation is shown, and for how long?**
5. **Which blocks qualify?** Fenced and indented blocks, an unclosed fence, and whether a Mermaid block's source (shown as a code card while the caret is inside it) gets the control too. What about an empty block?
6. **What is the non-pointer route?** An accessibility action on the block, a menu command (Edit or Format, with or without a shortcut), or both, and how it picks the block (the one the caret is in).
7. **Does the click move the caret or change the selection?** The roadmap assumes it is handled in `mouseDown` before the selection changes, so it should not. Confirm.
8. **Is the ⌘C-of-a-selection problem in scope?** The roadmap names it as the reason for the control, but the control does not fix it, and this intent assumes it is out of scope.

## Decision

Accepted on 2026-10-11 as an enhancement: it is a small control on cards that already exist, so there is no separate spec. The open questions above carry forward to the plan, which opens with a "Decisions" section answering them for approval. If the decisions turn out larger than expected, escalate to a spec.
