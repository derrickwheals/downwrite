---
type: plan
id: 2026-10-22-table-swallows-following-lines
intent: ./intent.md
status: in-progress    # draft | approved | in-progress | done
approved: 2026-10-22
branch: change/2026-10-22-table-swallows-following-lines
---

# Plan: Table swallows the text typed straight under it

## Approach

A table ends where the person stopped writing rows. `TableTails` (new, Core) holds the one rule and the one parse that applies it, and both the analyzer and the export call it, so the editor and the paper agree by construction (as `CalloutSyntax` does for callouts). The parse is done twice only when it has to be: parse the text as today, find every `Table` node at any depth, and for each one look at the lines after its delimiter row. The first line that is not a row under the rule is a *break line*. If there are none, that first parse is the result. If there are, the text is parsed again with a blank line inserted before each break line, which is exactly "as if a blank line separated them": cmark then ends the table there and reads what follows as ordinary blocks, with all its usual consequences (a paragraph, a setext heading over `---`, a second table whose header is the last pipeless line). The inserted line carries the break line's own leading run of spaces, tabs and `>` so that inside a quote or list item it stays in the container. The analysis keeps working in *original* coordinates: `TableTails.parse` returns the list of inserted lines, and `MarkdownAnalyzer`'s single choke point for cmark ranges (`range(of:)`) maps a parsed line number back to the original line, so no span, marker, line style or table range moves, and the text in the editor is never touched.

The alternative would be to keep cmark's over-long `Table` node and trim it inside `MarkdownAnalyzer.table(_:_:)`, restyling the swallowed rows as paragraphs. That is smaller, but the swallowed lines would be parsed as table cells rather than as the paragraph they are in the document (inline constructs across lines, a following `---`, a header-less second table), and the export would need its own copy. Re-parsing keeps one source of truth: cmark.

## Decisions (the intent's open questions, answered 2026-10-22)

- **D1, what is a row.** A line under the delimiter row is a row only if its first character is `|`, after the leading run of spaces, tabs and `>` (the container prefix) has been skipped. **Refinement, agreed by the product owner 2026-10-22:** that holds when the table's *delimiter row* starts with `|` (every table Downwrite writes, and almost all that are typed). A GFM table whose delimiter has no leading pipe (`a | b` / `- | -` / `1 | 2`) is written without outer pipes, so its rows are rows when they contain at least one unescaped `|` (a backslash escapes the next character, as in `TableModel.cellSlices`); a line with no pipe is still text. Without this the constraint "tables GFM accepts must not change" would break for that style. A row without a leading pipe under a pipe-led table (`a | b`, or a pipeless row in a one-column table) becomes text. The product owner's choice; it changes how some valid GFM files render.
- **D2, export and print** follow the editor: `DocumentHTML.prepare` parses through `TableTails`.
- **D3, grid and source editing paths** keep their behaviour and are made to agree with the rule. Return and Tab at the last cell still append a row; leaving the grid downwards puts the caret at the start of the text below and adds no blank line (the existing `tight` case of `exitAfter`); Backspace at the start of the line below a grid still goes into the last cell (the guard keys on position only); the source-shown table and Format Table use the same rule so they never include the text.
- **D4, quotes and list items**: the rule applies to every table. The inserted line carries the break line's prefix (above).

## Reproduction

Reproduced. A throwaway Core test (deleted, never committed) analysed the card's sample, `| Column 1 | Column 2 | Column 3 |`, its delimiter row, `| | | |`, then `sxasdasdas`, `sadasd` and a long paragraph, a blank line and `After.`. Result on `main`: one table, `firstLine 0`, `lastLine 5`, `isGrid true`, `rowCount 5` (header plus `| | | |` plus the three text lines), so the grid draws the text as rows with empty cells in columns 2 and 3. The cause is as the intent says: cmark-gfm ends a table only at a blank line or another block start, and the analyzer takes the `Table` node's range as given. Not reproduced in the running app; the Todoist screenshots show the same grid.

## Files that change

- `Sources/DownwriteCore/TableTails.swift` (new) — the row rule (`isRow`), the table length of a list of lines (`tableLength(of:)`, used by Format Table), and `parse(_:options:)`: first parse, scan of `Table` nodes at any depth, insertion of blank lines, re-parse until no new break line appears (each pass adds at least one, so it ends), and the line map (`originalLine(_:)`). Returns the document, the text that was parsed, the inserted lines and the number of passes.
- `Sources/DownwriteCore/MarkdownAnalyzer.swift` — `run()` parses through `TableTails`; `range(of:)` maps cmark line numbers back through the map. `table(_:_:)` needs no change: the `Table` node is already the right length, so `rowCount == 1 + body.childCount` holds.
- `Sources/DownwriteCore/DocumentHTML.swift` — `prepare` parses the footnote-protected text through `TableTails` and gives `DocumentRenderer` a `SourceText` of the text that was parsed (its `isLoose` check compares cmark line numbers).
- `Sources/DownwriteCore/TableFormatter.swift` — `tableLines` trims the contiguous pipe lines to `TableTails.tableLength(of:)` and returns nil when the caret is on a trimmed line.
- `Sources/DownwriteCore/TableEditing.swift` — comment only: "otherwise the next line would become one of its rows" now holds for pipe-led lines.
- `Tests/DownwriteCoreTests/TableTailsTests.swift` (new), `TableModelTests.swift`, `TableAndMiscTests.swift`, `DocumentHTMLTests.swift` — see Proof.
- `Tests/DownwriteTests/TableGridTests.swift`, `StylerTests.swift` — grid and styling in a real text view.
- `CLAUDE.md` — one architecture bullet: the table-end rule, `TableTails`, the line map, and "a pipeless line under a pipe-led table is text" (so the next agent does not "fix" it back to GFM).

Not changed: `TableModel`, `TableOverlay`, `TableGrid`, the styler, `EditorView` and every other app file. They read `analysis.tables` and `LineStyle`, which are now right.

## Order of work

- [x] 1. On the branch, write the failing tests first: the card's sample (table has 2 rows, the three text lines are `.body` lines, the paragraph is not in `tables`), the row-rule cases, the export, Format Table, and the grid and styler cases. Confirm each fails on `main` for the right reason. Commit.
- [x] 2. `TableTails.swift`: the rule and `tableLength(of:)`, with their unit tests green on their own. Commit.
- [x] 3. `TableTails.parse` and the line map, wired into `MarkdownAnalyzer.run()` and `range(of:)`. The analyzer tests go green; run the whole Core suite to prove nothing else moved. Commit.
- [ ] 4. `DocumentHTML.prepare` through `TableTails`; export tests green. Commit.
- [ ] 5. `TableFormatter.tableLines` trimmed; the Format Table tests green. Commit.
- [ ] 6. App tests green (`TableGridTests`, `StylerTests`) with no app code change; if one needs code, the plan changes first (Deviations). Commit.
- [ ] 7. `CLAUDE.md` bullet and the `TableEditing` comment. Run the full proof below, then the hand check, then update the plan's Deviations. Commit.

## Risks

- **Every range after a table with a tail could be off by the inserted lines** — the map is applied in the one function that turns cmark positions into offsets, and the tests compare an analysis of the text with the analysis of the same text with a blank line typed in, mapped line for line (line kinds, quote and list depths, tables' first and last line, span and marker offsets after the table). A heading and a `**bold**` after the table are checked by offset.
- **Cost on every keystroke** — a document without a tail pays one extra walk over block containers (not inline nodes) and no second parse. A deterministic test, not a timing one, asserts `passes == 1` for a document whose tables have no tail and `passes == 2` for the card's sample. No wall-clock assertion (see CLAUDE.md, Gotchas).
- **Tables that GFM accepts must not change** — a corpus of cases that must give the same table before and after: missing cells, extra cells, escaped pipes, empty-cell rows, `a | b` style tables with no outer pipes, a table ended by a blank line, a heading, a quote or a fence, a table at the end of the document without a final newline, CRLF-free text (the editor always uses `\n`). Today's `TableModelTests` and `AnalyzerTests` table cases stay unchanged and green.
- **A valid GFM file now looks different** — the pipeless one-column row and `a | b` under a pipe-led table are text. That is D1; it is stated in `CLAUDE.md` and in the PR so the release note can say so.
- **Nested tables** — the inserted line is the break line's own prefix, which is right for `>` and for indentation. Tested with a quoted table, a table in a bullet item and one in a numbered item. A table inside a quote inside a list is tested once; nothing further is promised.
- **Insertion changes what follows** — "as if a blank line separated them" has side effects by design: a break line over `---` becomes a setext heading, a list stays loose in the export when a blank line now sits inside an item. Both are tested so the behaviour is deliberate, not accidental.
- **Pipe typed later** — typing `|` as the first character of the line below turns it into a row and the table grows; a test types it character by character in a real text view.
- **A plan claim that a test fails under a mutation** — none is made here. The build runs the mutations (a rule that accepts every line; a map that is not applied) and records the result in Deviations.

## Proof

Tests to add or change:

- `Tests/DownwriteCoreTests/TableTailsTests.swift`
  - `isRow`: `| a |` and `|` rows; `a`, `a | b`, `\| a` and `a \| b` are not rows under a pipe-led table; `a | b`, `a |` and `| a` are rows under a table with an unpiped delimiter, and `a` and `a \| b` are not; a `> ` and an indented prefix are skipped.
  - The card's sample: one table of two rows (header and `| | | |`), `isGrid`, and the rest of the lines `.body`. The text is unchanged.
  - Equivalence: for each case in a table of inputs, the analysis of the text equals the analysis of the same text with a blank line typed before the break line, once the blank line is taken out of the second (line kinds, depths, tables, spans and markers, offsets).
  - The no-change corpus listed under Risks.
  - Quotes, bullet and numbered items; a second table starting under the first; a break line over `---` (setext heading); a text line then a pipe row (it joins the paragraph, no new row).
  - A seeded random document of fragments (rows, text, blanks, `>`, list markers, headings, fences): the analysis never traps, every range is inside the text, and every line after the delimiter of every table satisfies an independently written oracle of the rule. 300 documents, as `VSCodeThemeTests` does.
  - `passes` is 1 without a tail and 2 with one; a tail after a second table's tail ends in 3.
- `Tests/DownwriteCoreTests/TableModelTests.swift` — `exitAfter` with text directly below (`table + "\nText\n"`: empty insertion, caret at the start of the text); `testQuotedAndListedTablesStayRawSource` still passes (a nested table is still not a grid).
- `Tests/DownwriteCoreTests/TableAndMiscTests.swift` — Format Table on a table with a `| x |` row, a pipeless text line and a text line with a pipe (`a | b`) below: only the table is rewritten, and the caret on the text line gives nil.
- `Tests/DownwriteCoreTests/DocumentHTMLTests.swift` — the card's sample exports as a two-row table followed by `<p>` text; a GFM no-outer-pipes table still exports all its rows; a table in a list item followed by text.
- `Tests/DownwriteTests/TableGridTests.swift` — in a real text view: the card's sample has one grid with two rows; text typed under the last row (inserted character by character through `insertText`) never adds a row, and typing `|` first makes it one; the text lines are visible, not collapsed (`usedRect`); Backspace at the start of the line directly under the grid still goes into the last cell, with text below it.
- `Tests/DownwriteTests/StylerTests.swift` — the tail lines are styled as body text (no monospace, no table-card attribute), and a quoted table with a tail keeps the table card on the table lines only.

Must pass before the change is complete:

```
scripts/linux-test.sh            # Core, on Linux; on macOS use the one-test-per-process runner in the Linux Core tests memory note
swift test                       # macOS: everything, including the app tests
```

Hand check (macOS, not automatable here): open the attached `test-doc.md` in the built app, put the caret outside the table, and confirm the grid has the header and the one empty row with the text as paragraphs below; type `x` under the last row of a grid table, then `|`, and watch the table take and release it; print preview the same document and compare it with the editor.

Requirement coverage (bug track, from the intent's outcome and the four decisions):

| Requirement | Proven by |
|---|---|
| Text directly under the last row is body text and the grid has only the rows written as rows | `TableTailsTests` card sample and equivalence cases; `TableGridTests` grid with two rows |
| D1, the row rule (with the unpiped-delimiter refinement) | `TableTailsTests` `isRow` cases and the oracle in the random test |
| D2, export and print follow the editor | `DocumentHTMLTests` |
| D3, grid and source editing paths agree and keep their behaviour | `TableModelTests` (`exitAfter`), `TableAndMiscTests` (Format Table), `TableGridTests` (typing, Backspace) |
| D4, quotes and list items | `TableTailsTests` nested cases; `DocumentHTMLTests` list case |
| Tables GFM accepts do not change | the no-change corpus; the existing table tests |
| The text and offsets are untouched | equivalence offsets; `TableGridTests.testTableDocumentTextRoundTripsThroughTheEditorUntouched` stays green |

## Deviations

- Step 1: the `isRow` unit cases and the `passes` count test need `TableTails` to exist, so they are written with step 2 (the rule) and step 3 (the parse) instead of step 1. The analyzer-level tests (card sample, equivalence, GFM corpus, nested, random oracle), export, Format Table, `exitAfter`, grid and styler tests are all in step 1. The two grid/styler app tests were written but not yet run on `main` (the app test target needs the whole app build); they are run in step 6.
- Step 1: the GFM no-change corpus and the quoted-table-is-never-a-grid test pass on `main` by design (they guard what must not change); the other 12 `TableTailsTests` fail on `main` for the right reason (a table swallowing the text under it).
- Step 3: two premises in the step 1 tests were wrong about cmark and were corrected, not weakened. A delimiter row `- | -` is a bullet list item to cmark, so the no-outer-pipes cases use `--- | ---`; and a lone `|` under a table is not a row to cmark (it ends the table), so it is never a break line and the typing test no longer claims it makes a row. The equivalence test also ignores the quote marker that the typed `> ` line carries (it has no counterpart in the original text).
- Step 3: `CalloutSyntax.match` reads the *parsed* text (`parsedSrc`) and its result (marker line, marker and title ranges) is mapped back to the document, because it takes cmark positions of the text it is given. The plan's `range(of:)` mapping alone would have left a callout after a table with a tail off by the inserted lines.
- Step 3 mutations (run, as the plan promised): M1, `isRow` accepts every line: 17 of the 23 `TableTailsTests` fail (card sample, equivalence, random oracle, rule cases, pass counts). M2, the line map is not applied (`original(_:)` returns its argument): the test process crashes with an index out of range in the first equivalence case.
