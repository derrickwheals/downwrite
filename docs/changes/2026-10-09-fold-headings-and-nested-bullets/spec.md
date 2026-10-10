---
type: spec
id: 2026-10-09-fold-headings-and-nested-bullets
intent: ./intent.md
status: approved
approved: 2026-10-09
---

# Spec: Fold and unfold content under headings and nested bullets

## Summary

Headings and list items that have content under them get a fold control. Folding hides that content (everything up to the next heading of the same or a higher level, or everything after a list item's first paragraph) behind the heading or item line, which shows a chevron and a ⋯ chip. Folding is a display state held in memory for the window: the Markdown text, the file, the undo history and the edited flag never change, and folds stay attached to their heading or item while the document is edited. Folding is driven by a margin chevron, a chip click, and View menu commands (fold/unfold at the caret, fold/unfold all, fold to a heading level).

## Requirements

Line numbers in this document are 1-based source lines. The analyzer's own line indices are 0-based. "Header" is the part of a region that stays visible when it is folded; "hidden lines" are the source lines that disappear.

### What can fold

- **R1** — Every heading at the top level of the document (not inside a block quote or a list item), ATX (`## Title`) or setext (`Title` over `===` or `---`), is a fold region when it has content. Its hidden lines are the lines after the heading's last line (the underline, for a setext heading) up to the line before the next top-level heading whose level number is less than or equal to its own, or to the last line of the document, and at least one of them is not blank. Everything in that span hides together: paragraphs, lists, tables, code blocks, Mermaid diagrams, images, HTML, quotes, deeper headings, and headings inside quotes or list items (those never end a section). A heading with only blank lines under it is not foldable and gets no chevron.
- **R2** — Every list item (bulleted, numbered or task, at any depth, including inside a block quote) is a fold region when it has content after its first paragraph. Its header is the first paragraph with every source line that paragraph wraps over (only the item's first line when the item's first child is not a paragraph). Its hidden lines are all the remaining lines of the item through its last line: nested items, further paragraphs, code blocks, quotes, tables, and the blank lines between them. An item whose only content is its first paragraph has no region. The hidden lines of an item never include a following sibling item.
- **R3** — `MarkdownAnalysis` exposes the regions (`foldRegions`, in document order) and, for Fixture F below, reports exactly the regions in the table under *Behaviour details*: no more, no fewer, with those header and hidden lines.

### What folding does

- **R4** — Folding is a display state only. Folding, unfolding and every fold command leave the text storage, the file on disk, the undo stack and the document's edited flag untouched, and add nothing to the undo history. No fold marker is ever written to the file: a document saved with folds in place is byte-identical to what it would have been without them.
- **R5** — Hidden lines take no visible room and show nothing (no text, checkbox, pill, bar or card). The header line is followed directly by the next visible line with that line's normal spacing. The room left over is at most 1 pt per 1,000 hidden lines. (The existing 0.1 pt line collapse used for Mermaid, HTML and table sources leaves 0.1 pt per hidden line, which is 100 pt for 1,000 lines, so folds need a thinner collapse; Mermaid, HTML and table collapsing keep what they have.) The hidden text stays in the document, so copy, find, undo, the word count and the table of contents still see it.
- **R6** — Folds nest. Folding an outer region hides the inner regions with the rest of its content, and an inner region keeps its own folded or unfolded state, which shows again when the outer region is unfolded. A region hidden by another fold shows no chevron or chip.
- **R7** — Tables (grid and source), Mermaid diagrams, images and HTML cards inside hidden lines are not shown, reserve no vertical space and receive no mouse or keyboard input; they return in the right place when the fold opens. After any fold or unfold, `TableOverlay.layoutProblems()` and `DiagramOverlay.layoutProblems(analysis:)` are empty (both skip hidden blocks). A table cell that has the keyboard when its table becomes hidden gives it back to the text view, with the caret at the end of the fold's header.

### Controls and look

- **R8** — A foldable header shows a chevron in the left margin, immediately left of its first visible character (the heading text, or the list bullet or checkbox), (a) while the pointer is over that header line or the margin beside it, and (b) always while the region is folded. It points down when the region is open and right when it is folded. Clicking it toggles the fold without moving or changing the selection (except as R13 requires). The click target is at least 16 pt square and does not overlap the text.
- **R9** — A folded header also shows a ⋯ chip drawn right after the last character of the header's last line; if that line is full the chip hangs into the right margin and never wraps or covers text. Clicking the chip unfolds the region. While the selection covers any of the region's hidden text the chip is drawn in the selection colour. Chevron and chip are drawn with palette colours, behind the system selection highlight like the editor's other custom drawing, and are legible in every built-in theme and in imported themes, light and dark.
- **R10** — The View menu has these commands for the frontmost window, disabled while the source view is showing: **Fold** (⌥⌘←), **Unfold** (⌥⌘→), **Fold All** (⌥⌘⇧←), **Unfold All** (⌥⌘⇧→) and **Fold to Level ▸ Heading 1 … Heading 6** (no shortcuts). A command with nothing to act on makes the system beep, as the editor's other commands do.
- **R11** — **Fold** acts on the innermost unfolded region whose header contains the caret line or whose hidden lines contain it. When the caret line is already the header of a folded region, it acts on the next enclosing unfolded region, so repeated presses fold outwards. **Unfold** opens the folded region whose header contains the caret line; since the caret is never inside hidden text (R14), that is the only region it can apply to.
- **R12** — **Fold All** folds every region, headings and list items. **Unfold All** opens every fold. **Fold to Level N** folds every heading region of level N or deeper and opens every heading region shallower than N; list-item folds are left as they are.
- **R13** — When a command or click hides the caret (or the start of the selection), the caret moves to the end of the header of the outermost fold that now hides it, the selection collapses to it, and the header is scrolled into view if it is off screen. A selection whose ends are both visible is left alone.

### Caret and selection

- **R14** — The caret is never left inside hidden text. Arrow keys (with their ⌥ and ⌘ variants), Page Up/Down and mouse clicks step over folds: ↓ from the last line of a folded header goes to the next visible line, ↑ from the first visible line after a fold goes to the header's last line, → at the end of a folded header goes to the start of the next visible line and ← from there goes back to the end of the header, and ⌘↓ when the end of the document is hidden goes to the end of the header of the outermost fold hiding it. Vertical moves keep the column where the target line is long enough, as ordinary ↑/↓ do. With Shift, the same moves extend the selection (R17).
- **R15** — Anything else that puts the caret or the start of the selection into hidden text opens the folds that hide it, outermost first, so the caret ends up visible and scrolled into view: Find, Find Next and Replace; a click on a hidden heading in the table of contents; a `#heading` link; undo and redo; paste; leaving the source view; and edits (R16). Folds that do not hide the caret stay as they are.
- **R16** — Edits at a fold boundary: typing, deleting and pasting inside a folded header's own lines keep the fold. **Return** inside or at the end of a folded header opens that fold first, then does exactly what Return does without a fold, so the resulting text is the same either way (outliner-style "new sibling after the folded children" is not done). **Backspace** with an empty selection at the start of the first visible line after a fold, and forward **Delete** with an empty selection at the end of a folded header (and their word, line and paragraph variants), open the fold and delete nothing, the way the editor already guards the hidden source of a table: the deletion would otherwise join a visible line to hidden text the user cannot see.
- **R17** — A selection can cover folds (Select All, Shift with the arrow keys, dragging). Copy, cut, delete and typing act on the whole selection including hidden text, exactly as for every other selection in this editor (hidden syntax and collapsed Mermaid sources behave the same), the chip shows that it is covered (R9), and undo brings the text back.

### Staying attached

- **R18** — A fold belongs to its header line. After every change to the text (typing, undo and redo, paste, Replace, an external reload, an edit made in the source view) each fold moves with its header: edits before the line shift it, edits after the line leave it, and edits inside the header's own lines (including retyping all of the header's text) keep it. Return at the very start of a folded header pushes the header and its fold down a line. A fold is kept only while its line is still a foldable header after the change: changing a heading's text or level keeps the fold; a line that stops being a heading, a deleted header, or an item that loses its extra content drops the fold, and its lines show again. A fold is never transferred to different text: an edit that replaces text from before the header's first character into the header, or from the header's first character past the end of its lines (for example selecting a heading and part of what follows it and typing over it), removes the fold.
- **R19** — Typing anywhere else in the document never opens or closes a fold, except as R15, R16 and R18 describe.

### Where fold state lives

- **R20** — Fold state is per editor window and kept in memory only. It survives typing, undo, external reloads and the source view, and is discarded when the window closes. Every file opens fully unfolded. Nothing is written to disk and no setting is added.
- **R21** — The source view (⌘/) shows the whole text unfolded, with no chevrons or chips, and the fold commands are disabled in it. The fold state is kept and returns when the source view is left (after R15 opens any fold that hides the caret).

### Everything else, and speed

- **R22** — Unchanged outside folds: hidden Markdown syntax, task checkboxes and clicking them, external-change reload (caret and scroll kept), and Mermaid, table and HTML behaviour in unfolded content. The table of contents still lists every heading including those hidden by folds, its active row is the heading whose section holds the caret, and the word count and reading time still count hidden text.
- **R23** — Toggling one fold restyles only the lines whose visibility changes (the header and its hidden lines), never the whole document. In a 10,000-line document with 500 regions, folding or unfolding one region takes under 0.5 s and Fold All or Unfold All under 2 s in the app tests. Mapping the folds through an edit costs time linear in the number of folds.

## Out of scope

- Remembering folds after the window closes or the app quits, in any form (file-path store, scene storage). The intent allowed it; the decision here is memory only.
- Folding other things: code fences, front matter, block quotes, tables, `<details>` HTML, and headings inside quotes or list items.
- Any change to the table-of-contents sidebar: no fold state or fold controls in it, and it still lists hidden headings.
- Outliner-style editing (Return creating a sibling after folded children), moving whole sections or items, drag to reorder.
- A setting to open files folded, or fold-on-open rules.
- VoiceOver announcements of fold state (the View menu commands are the keyboard route).
- Changing how Mermaid, HTML and table sources collapse today (they keep the 0.1 pt collapse).
- Folding inside table grid cells or in the source view.

## Design

### Interfaces

**DownwriteCore** (pure Swift, builds and tests on Linux). Names are the proposed shape; the plan may refine them but not the behaviour above.

```swift
// Analysis.swift
public struct FoldRegion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case heading(level: Int), item }
    public var kind: Kind
    /// Source lines that stay visible when folded. `headerLines.lowerBound` carries the chevron, `upperBound` the ⋯ chip.
    public var headerLines: ClosedRange<Int>
    /// Source lines that hide when folded. Never empty; at least one is not blank.
    public var hiddenLines: ClosedRange<Int>
    /// UTF-16 offset of the start of `headerLines.lowerBound`. This is the fold's identity (R18).
    public var anchor: Int
    /// The hidden characters: from the start of `hiddenLines.lowerBound` through the end (terminator included) of `hiddenLines.upperBound`.
    public var hiddenRange: NSRange
}
// MarkdownAnalysis gains: public let foldRegions: [FoldRegion]   // document order (ascending anchor)

// Folding.swift (new)
public struct FoldState: Equatable, Sendable {
    public private(set) var anchors: Set<Int>                         // header-line starts of folded regions
    public func isFolded(_ region: FoldRegion) -> Bool
    public func hiddenLineRanges(in: MarkdownAnalysis) -> [ClosedRange<Int>]   // merged, sorted; regions inside a fold add nothing
    public func foldHiding(offset: Int, in: MarkdownAnalysis) -> FoldRegion?    // outermost folded region whose hiddenRange contains offset
    public func toggled(_ region: FoldRegion) -> FoldState
    public func folding(atCaret: Int, in: MarkdownAnalysis) -> FoldState?       // R11; nil = nothing to do
    public func unfolding(atCaret: Int, in: MarkdownAnalysis) -> FoldState?
    public func foldingAll(in: MarkdownAnalysis) -> FoldState
    public func unfoldingAll() -> FoldState
    public func folding(toLevel: Int, in: MarkdownAnalysis) -> FoldState        // R12
    public func revealing(_ range: NSRange, in: MarkdownAnalysis) -> FoldState  // R15: opens the folds hiding range.location
    public func mapped(through edit: TextEdit, from old: MarkdownAnalysis, to new: MarkdownAnalysis) -> FoldState   // R18
    public func visibleOffset(from offset: Int, forward: Bool, in: MarkdownAnalysis) -> Int // R13/R14: nearest visible caret position
}
```

`mapped(through:from:to:)` takes the single replacement that turns the old text into the new (`TextDiff.replacement(from:to:)`, which the external-reload path already uses) and both analyses. For an edit replacing `[s, e)` and an anchor `a`: if `e <= a` the anchor shifts by the change in length (a pure insertion exactly at `a` shifts it only when the inserted text ends in a line break, so Return at the start of a header pushes it down while typing there does not); if `a < s` it stays; if `s < a < e` it is dropped; if `s == a < e` it is dropped when the replaced range runs past the end of that region's header lines in the old analysis and kept otherwise. After shifting, an anchor is kept only if the new analysis has a region whose anchor is that offset.

**App target** (`Sources/Downwrite`, macOS only). The app only maps the results above onto AppKit.

- `EditorCoordinator` owns the window's `FoldState`, maps it through each text change and reload (it keeps the previous string to diff against), applies it on every `reanalyze`, and routes the commands, clicks and caret policy.
- `PreviewState` carries the lines hidden by folds. `MarkdownStyler` gives those lines the thin collapse of R5 and marks each foldable header (chevron and chip state). `collapsedBlocks` and the reserved-height maps skip blocks inside hidden lines so no `paragraphSpacing` is reserved for a hidden card.
- `DWLayoutManager` draws the chevron and chip (before `super.drawBackground`, per the project's drawing-order rule) and exposes their rects as `checkboxRect(forCharacterAt:)` does for task boxes, so the same geometry is the click target.
- `EditorTextView` tracks the pointer for the hover chevron, handles chevron and chip clicks before the table-grid and checkbox handling in `mouseDown`, implements the movement and delete guards of R14 and R16, and offers `@objc` actions (`dwFold`, `dwUnfold`, `dwFoldAll`, `dwUnfoldAll`, `dwFoldToLevel`) reached through `Responder`, like `dwIndent`.
- `DiagramOverlay` and `TableOverlay` hide the views of blocks inside hidden lines (`TableOverlay` already has a per-grid `isHidden`) and leave them out of the reserved heights.
- `ViewCommands` adds the menu items of R10 next to Show Markdown Source and Show Table of Contents, disabled when `@FocusedBinding(\.sourceMode)` is true or nil.

### Data

No stored data, no file format change and no migration. The only new state is `FoldState.anchors: Set<Int>` (UTF-16 offsets of header-line starts) inside each `EditorCoordinator`, discarded with the window.

### Files and components involved

- `Sources/DownwriteCore/Analysis.swift` — `FoldRegion`; `MarkdownAnalysis.foldRegions` (and `[]` in the single-line table-cell analysis).
- `Sources/DownwriteCore/MarkdownAnalyzer.swift` — builds the regions: top-level headings (the builder has `ctx.quoteDepth` and `ctx.listDepth` at the point `heading(_:_:)` runs, but `HeadingInfo` does not record them) and list items (`listItem(_:_:)` sees the item's children and its first paragraph).
- `Sources/DownwriteCore/Folding.swift` (new) — `FoldState` and the caret helpers.
- `Tests/DownwriteCoreTests/FoldingTests.swift` (new) — Fixture F regions, setext, quotes and lists, `FoldState` operations, edit mapping, reveal and caret placement.
- `Sources/Downwrite/MarkdownStyler.swift`, `DWLayoutManager.swift` — hiding and drawing (R5, R8, R9).
- `Sources/Downwrite/EditorView.swift` (`EditorCoordinator`), `EditorTextView.swift` — state, commands, mouse, caret and edit guards (R10 to R21).
- `Sources/Downwrite/Previews.swift`, `TableOverlay.swift` — overlays inside folds (R7).
- `Sources/Downwrite/DownwriteApp.swift` — View menu items.
- `Sources/Downwrite/SelfTest.swift` — an end-to-end step for folds.
- `Tests/DownwriteTests/FoldTests.swift` (new) and additions to `StylerTests`/`DrawingTests` — app behaviour and pixel checks.
- `README.md`, `CLAUDE.md` — document the feature and the architecture rules it adds.

### Behaviour details

**Fixture F.** Used by the unit tests, the app tests and the walkthrough. The file has no trailing newline; line numbers are shown for reference and are not part of the file. The heading and list-item ranges cmark reports for it were checked in this repository; the table below follows from them.

````markdown
 1  # Project
 2
 3  Intro paragraph.
 4
 5  ## Plan
 6
 7  Plan text.
 8
 9  ### Tasks
10
11  - [ ] Write spec
12    - [ ] Draft
13    - [x] Review
14  - [ ] Build
15
16  | a | b |
17  | - | - |
18  | 1 | 2 |
19
20  ## Notes
21
22  ```mermaid
23  graph TD; A-->B
24  ```
25
26  - Groceries
27    - Milk
28    - Eggs
29
30      Extra paragraph under Eggs.
31  - Done
32
33  ## Empty
34
35  ## Last
36  Final line, no trailing newline
````

Regions in Fixture F (R3):

| Region | Header lines | Hidden lines | Why |
| --- | --- | --- | --- |
| `# Project` (H1) | 1 | 2–36 | no later H1, so the section runs to the end |
| `## Plan` (H2) | 5 | 6–19 | ends before `## Notes`, the next H2 |
| `### Tasks` (H3) | 9 | 10–19 | ends before `## Notes`, a higher level |
| item `Write spec` | 11 | 12–13 | its nested items |
| `## Notes` (H2) | 20 | 21–32 | ends before `## Empty`; includes the Mermaid block |
| item `Groceries` | 26 | 27–30 | its nested items and the paragraph under `Eggs` |
| item `Eggs` | 28 | 29–30 | the blank line and the extra paragraph |
| `## Last` (H2) | 35 | 36 | the final line |

Not regions: `## Empty` (only a blank line before the next heading), the items `Draft`, `Review`, `Build`, `Milk` and `Done` (no content after their first paragraph), the table, and the Mermaid block.

Other cases the unit tests must cover: a setext heading (`Title` / `=====` / `text`: header lines 1–2, hidden 3), a heading inside a block quote or a list item (not a region, and does not end the enclosing section), a numbered item and a task item with nested content, an item inside a block quote, a list item whose first child is a fenced code block, an item with a wrapped first paragraph (all wrapped lines stay in the header), a `#` line inside a code fence (not a heading), and a document with no headings.

**Fold at the caret (R11), worked through on F.** Caret on line 13 (`Review`). ⌥⌘← folds `Write spec` (the innermost region containing line 13) and the caret moves to the end of line 11 (R13). Again: the caret line is now a folded header, so `### Tasks` folds, then `## Plan`, then `# Project`, after which only line 1 and its chip are visible.

**Return at the end of a folded header (R16).** With `## Plan` folded and the caret at the end of line 5, Return opens `## Plan` and inserts a line break after the heading, the same text change as without the fold; the caret is on the new empty line, which is the first line of the section.

**Decided by default, please confirm when approving.** These were settled from the code and the intent's principles rather than asked.

- The source view shows everything (R21), because it is documented as "nothing hidden"; the folds come back afterwards.
- A fold is identified by the position of its header line, mapped through edits (R18), not by its text, so renaming a heading keeps the fold. Moving a section by cut and paste loses its folds.
- Only top-level headings fold; headings inside quotes and lists do not (R1).
- Fold All includes list items; Fold to Level leaves them alone (R12).
- Return and Backspace/Delete at a fold boundary open the fold instead of working on hidden text (R16).
- A selection that covers a fold acts on the hidden text too, and the chip shows it (R17).
- The shortcuts in R10 (⌥⌘←/→ and the Shift variants) are new; the plan checks they do not clash with existing menu key equivalents or NSTextView's key bindings.

**How the intent's open questions were resolved.** Q1 controls: R8 to R12 (the user chose margin chevron, fold/unfold at the caret, fold/unfold all, and fold to level). Q2 persistence: R20 (the user chose while the window is open). Q3 which lists: R2 (the user chose any item with extra content, which is wider than the intent's "nested items", so the intent text is unchanged because it left this open). Q4 caret in folded text: R13 to R16 (the user chose: open for jumps, step over for arrows). Q5 source view: R21 (default). Q6 look: R8, R9 (the user chose chevron and ⋯ chip). Q7 attachment: R18 (default).

## Flags

- **The existing hidden-line technique does not scale to folds.** `CLAUDE.md` documents hiding as a 0.1 pt font with `minimumLineHeight`/`maximumLineHeight` of 0.1 for whole collapsed lines. A line height of 0.1 pt leaves 0.1 pt per hidden line. Measured with a throwaway `NSLayoutManager` script: 100 hidden lines add 10 pt of blank space below the header and 1,000 add 100 pt; at 0.01 pt they add 1 pt and 10 pt; at 0.001 pt, 0.1 pt and 1 pt. This does not conflict with the intent or with a project rule, but a fold of a long section would leave a visible gap, so R5 requires a thinner collapse for folds only. The measurement used a bare layout manager, not the editor, so the plan must confirm the chosen value in the real editor (including that `DWLayoutManager`'s `lineRect.height > 1` checks still skip these lines when drawing cards and bars).

## Verification

Build the app first (`scripts/build-app.sh` writes `dist/Downwrite.app`). Save Fixture F (without the line numbers) as `/tmp/fold-demo.md`; the plan commits it as a fixture file the end-to-end step can open. Open it with `open -a dist/Downwrite.app /tmp/fold-demo.md`. Steps 1 to 13 use that one window and edit its text without saving; steps 14 and 15 start from a fresh window.

1. Everything is visible and nothing is folded; no chevrons show. The title bar shows no edited mark. Note the word count in the pill.
2. Hover the pointer over `## Plan`: a ▾ chevron appears in the left margin beside it. Move away: it disappears.
3. Click the chevron. Lines 6 to 19 vanish (the paragraph, `### Tasks`, the tasks, the table grid). `## Notes` sits directly below `## Plan` with the normal heading gap, not a visible hole. `## Plan` shows a ▸ chevron and a ⋯ chip. The word count is unchanged, the title bar still shows no edited mark, and Edit ▸ Undo is not available (no text edit was made).
4. Click the chip. The section opens and the table grid is back in place under its source, overlapping nothing.
5. Put the caret in `- [x] Review` and press ⌥⌘←. `Write spec` folds (Draft and Review vanish) and the caret is at the end of that line. Press ⌥⌘← again three times: `### Tasks`, then `## Plan`, then `# Project` fold, leaving only `# Project ▸ ⋯`. Press ⌥⌘→: `# Project` opens and `## Plan` is still folded inside it (R6).
6. Press ⌥⌘⇧← then ⌥⌘⇧→: only `# Project ▸ ⋯` shows, then everything is back with the Mermaid card and the table grid in place. Choose View ▸ Fold to Level ▸ Heading 2: `# Project` is open; `## Plan`, `## Notes` and `## Last` are folded; `## Empty` shows no chevron when hovered. Choose Unfold All.
7. Fold `## Plan`. Click at the end of `## Plan` and press ↓: the caret lands on the `## Notes` line, not in the hidden lines. Press ↑: back on the `## Plan` line. Type `x`: it appears on the `## Plan` line and the fold stays. Press ⌘Z: the `x` goes and the fold stays.
8. Fold the `Groceries` item, then fold `## Notes` (which now hides it). Press ⌘F and search for `Milk`: both folds open and the match is visible and highlighted. Fold `## Notes` again: the Mermaid card disappears with it and nothing is left over other text.
9. With `## Plan` folded, click the end of line 3 (`Intro paragraph.`), type `x`, and with the caret at the very start of line 1 press Return: `# Project` moves down one line and the `## Plan` fold is still in place.
10. Fold `## Plan`, put the caret at the end of its line and press Return: `## Plan` opens and a new empty line follows the heading with the caret on it. Press ⌘Z: the text is as it was.
11. Fold `## Plan`, put the caret at the start of `## Notes` and press Delete (backspace): `## Plan` opens and no character is deleted.
12. Fold `## Plan`. Click in the middle of line 3 and press Shift+↓ three times, so the selection runs through the `## Plan` line and ends on the `## Notes` line: the chip is drawn in the selection colour. Press ⌘C, make a new document with ⌘N and paste with ⌘V: the pasted text includes the hidden lines. Close the new document without saving and click to deselect.
13. Fold `## Plan` and press ⌘/: the source view shows all lines as plain monospaced text with no chevron or chip, and the View fold commands are greyed out. Press ⌘/ again: the fold is back.
14. Close the window and choose Don't Save. Reopen `/tmp/fold-demo.md`: it opens fully unfolded (R20). Fold `## Plan`, then run `printf '\ntail\n' >> /tmp/fold-demo.md` from a terminal: within about a second the text gains `tail` and `## Plan` is still folded (R18, R22).
15. Close the window, write Fixture F to `/tmp/fold-demo.md` again and run `shasum /tmp/fold-demo.md` to note its hash. Open it, fold and unfold several things (headings, items, Fold All, Unfold All), then press ⌘S and run `shasum` again: the hash is the same, the title bar never showed an edited mark, and Edit ▸ Undo was never available (R4).

Automated proof, all green:

- `scripts/linux-test.sh` runs `FoldingTests` (the Fixture F region table, the extra cases listed above, every `FoldState` operation, edit mapping including Return at a header's start and a replaced header, reveal and caret placement).
- `swift test` on macOS runs `FoldTests` and the extended styler and drawing tests (hidden lines have no visible room, the residual gap stays within R5 for 1,000 hidden lines, overlays hidden and no layout problems, pixel checks of the chevron and chip including the covered-selection colour, the caret never in hidden text after arrows, Find and the TOC click, the edited flag and undo stack untouched, source view round trip, external reload keeping folds, the timing bounds of R23).
- `scripts/ci-local.sh --shots` finishes with a passing `artifacts/summary.txt`, including a new end-to-end fold step in the real app and light and dark screenshots of a folded document.
