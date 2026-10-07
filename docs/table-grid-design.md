# Table grid — design

Tables are edited as a real grid inside the document instead of as pipes and dashes, while the file stays plain GitHub-flavoured Markdown.

## Principles

1. **The document text is the only source of truth.** The grid is a *view* of the table's Markdown. Every edit is written back as Markdown (`TableModel.markdown`) through the normal text-storage path, so save, undo, find, copy and autosave need no special cases.
2. **All table logic lives in `DownwriteCore`** (pure Swift, tested on Linux). The app target only maps the model onto AppKit.
3. **Same behaviour as the rest of the editor.** Syntax hides unless the caret is in its pair (inside cells too), the source stays in the text (collapsed, like Mermaid sources), and nothing is rewritten until you actually edit.

## Architecture

```
text ──MarkdownAnalyzer──▶ TableBlock { range, model: TableModel, cellRanges }
                                   │
              TableOverlay (one TableGridView per top-level table)
                                   │
        TableGridView ── TableCellView × (rows × columns)   (small TextKit 1 editors)
                                   │  edits
        TableOverlay.commit ─▶ EditorTextView.applyTableText ─▶ NSTextStorage ─▶ re-analysis ─▶ sync
```

| Piece | Responsibility |
| --- | --- |
| `TableModel` | Rows × columns of cell *source text*, per-column alignment. Parse (cmark-compatible cell splitting, `\|` escapes, source offsets of every cell), aligned serialisation, every command (insert / delete / move / duplicate / clear / align / sort / paste), Tab and Return navigation, and `applying(_:at:)` which returns the new model plus where focus goes. |
| `TableLayout` | Column widths that fit the text column: columns narrower than their fair share keep their natural width, the rest share what is left (long text wraps instead of squeezing short columns). |
| `TableBlock` | `MarkdownAnalyzer` output for a top-level table: its range, the parsed model and each cell's document range. The analyzer cross-checks the model against cmark's row/column counts and falls back to source view if they disagree. |
| `MarkdownAnalyzer.analyzeTableCell` | Inline analysis of one cell (bold, links, code … with real reveal ranges) so cells hide and reveal syntax like the main editor. A bare `|` is masked, block syntax is ignored. |
| `TableEditing` | Text-level edits: leave the table downwards/upwards (adds the blank line a table needs at the end of a document), delete the table. |
| `TableCellView` | One cell: an `NSTextView` with its own TextKit 1 stack, `DWLayoutManager` (code/highlight pills), per-cell styling via `MarkdownStyler.styleCell`. Handles Tab, ⇧Tab, Return, ⇧Return (`<br>`), Esc, arrows at cell edges, paste-as-grid, ⌘-click links. |
| `TableGridView` | Layout, drawing, hover/drag state, hit-testing, the context menu. Row grips on the left, column grips on top, "+" strips right and below. |
| `TableOverlay` | Creates/updates grids from the analysis, positions them over the collapsed source (same reserved-height mechanism as Mermaid cards), writes edits back, hands focus between the text view and the grids. |
| `EditorTextView.applyTableText` | The single write path. Hand-rolled undo (see below). |

## The document stays tidy

Editing a cell replaces the table's text with `TableModel.markdown`: padded, aligned columns, delimiter row carrying the alignment (`:--`, `:-:`, `--:`). Cells hold source text, so `**bold**`, links, `\|` and `<br>` round-trip exactly; typing a `|` is stored as `\|`; line breaks and tabs become spaces. Navigating without editing never changes the file.

## Interactions

| Gesture | Result |
| --- | --- |
| Click a cell / arrow keys into the table / Insert Table / find match | Focus the cell (a find match selects the matched text in its cell). |
| **Tab** / **⇧Tab** | Next / previous cell, wrapping rows; Tab in the last cell **adds a row**. ⇧Tab in the first cell leaves the table upwards. |
| **Return** | Cell below; on the last row adds a row. **⇧Return** inserts `<br>`. |
| ← → at a cell edge | Neighbouring cell (leaves the table past the first/last). ↑ ↓ on the first/last line of a cell likewise. |
| **Esc** | Leave the table (caret after it). |
| Drag a row/column grip | Reorder; blue drop line shows the target. The header row is fixed. |
| Click a grip, or right-click any cell | Menu: insert row above/below, insert column left/right, move row/column, duplicate, clear, delete row/column, column alignment, sort A→Z / Z→A, **Edit as Markdown**, delete table. Items that do not apply (e.g. delete the header row) are disabled. |
| "+" strip right / below the table | Append a column / row. |
| Paste tab-separated data or a Markdown table | Fills as many cells as it covers, growing the table. |
| Format ▸ Table | The same commands for the focused cell. |
| Backspace on the line below a table | Moves into the table instead of merging text with it. |

*Edit as Markdown* shows one table's source (monospace card) until the caret leaves it, then the grid returns.

## Undo

Typing in a cell registers **one** undo step per editing session in that cell (consecutive keystrokes are merged); every structural command — add row, move column, sort, paste, delete table — is its own step with a name. `applyTableText` suspends `NSTextView`'s own undo registration for the replacement and registers a single action that restores the table's previous Markdown (which registers the redo). After an undo the grid is rebuilt from the text.

## Layout

The source lines of a grid table collapse to 0.1 pt (like fenced Mermaid sources) and the last line reserves `paragraphSpacing` equal to the grid's height; the grid view sits in that space. Row heights come from laying each cell out at its column width, so wrapped text grows its row; revealing syntax in a cell re-measures the column. Column widths are automatic — Markdown has nowhere to store them.

## Scope and trade-offs

* **Only top-level tables** become grids. Tables inside block quotes or list items stay as Markdown source (their prefixes would complicate mapping); they behave exactly as before.
* **Whole-table rewrite on edit.** Simple and always consistent; the cost is that a hand-formatted compact table (`|a|b|`) is re-aligned the first time you edit it.
* **Cells are single-line source.** Line breaks use `<br>` (⇧Return).
* **Find** works on the Markdown text; a match inside a table focuses its cell.

## Verification

* `Tests/DownwriteCoreTests/TableModelTests.swift` — parsing, escapes (including agreement with cmark), every command, navigation, paste, layout, analyzer integration, cell analysis, leaving/deleting a table.
* `Tests/DownwriteTests/TableGridTests.swift` — real editor in a real window: collapsed source and grid frame, cell alignment, hidden syntax, typing → Markdown → one-step undo, Tab/Return/arrows, every menu action, grips, hit targets, focus hand-off, Markdown-source view, multiple tables, theme change.
* `Tests/DownwriteTests/SnapshotTests.swift` — PNGs of the grid (light, dark, drag states, source view) in `docs/screenshots/`.
* `--selftest` — the packaged app: real Tab / typing key events, menu, undo, screenshots of the table in both themes.
