---
type: plan
id: 2026-10-11-copy-text-from-code-blocks
intent: ./intent.md
status: in-progress    # draft | approved | in-progress | done
approved: 2026-10-11
branch: change/2026-10-11-copy-text-from-code-blocks
---

# Plan: Copy the text of a code block with one click

## Approach

`DownwriteCore` gains a small record of every code block (`CodeBlockInfo`: its line range and the text a reader would copy), built from cmark's own `CodeBlock.code` so that fence lines, the language tag and any quote or list prefix are already gone. The app target then does three things with that record: `DWLayoutManager` positions and draws a small chip at the top right of the block's card (the same way it draws the fold chevrons, from state it is given, not from text attributes), `EditorTextView.draw(_:)` paints that chip after the text so it sits on top of any code that runs underneath it, and a click is taken in `mouseDown` before the selection can change and writes plain text to the pasteboard. The non-pointer route is an Edit ▸ Copy Code Block command plus an accessibility custom action on the editor, both acting on the block that holds the caret. No styler change is needed (nothing reserves room, so nothing reflows when the chip appears), no `Palette` field is added, and nothing in `DocumentHTML`, print or export is touched.

I chose state held by the layout manager and the coordinator (like `hoveredFoldRange`) over a text attribute on the block's lines because the styler restyles only dirty lines, so an attribute that carried a block's identity would go stale when an edit above shifts the lines below it. The attribute approach also costs a styler change in the file DW-003 is going to rework.

## Decisions

These answer the intent's open questions. Each is a choice among the options the intent already names, so I kept this an enhancement and wrote no spec; say so if you would rather have one.

- **D1 · What is copied.** cmark's `CodeBlock.code` for the block with exactly one final line break removed. Blank lines inside the block are kept (`a⏎⏎` inside a fence copies as `a⏎`), tabs are kept, and an indented block loses its four-space indent but keeps any deeper relative indent (cmark's own result). The final line break goes because pasting a copied command into Terminal would otherwise run it before the person can read it; it also matches how `MermaidBlock.source` and the export already treat the last line. The clipboard gets `\n` line endings even when the file is CRLF (the editor text is always `\n`), as plain text only, with no RTF or HTML flavour.
- **D2 · When the chip shows.** While the pointer is over the block's lines, or while the block is revealed because the selection touches it (the same inclusive rule that reveals its fences, `MarkdownAnalysis.isRevealed`). Not always (a document full of blocks would be noisy), and not hover only (the caret rule gives keyboard and trackpad-free users a visible cue). A click on the chip's position when it is not showing is an ordinary click.
- **D3 · Where it sits.** Top right inside the card: 22 pt square, 6 pt in from the card's top and right edges, with its own opaque fill (the page colour), a hairline `rule` border and a `secondaryText` glyph (two overlapping rounded squares), drawn in `EditorTextView.draw(_:)` after `super.draw` so it covers whatever the first line puts under it. The cost is that a first line long enough to reach the right edge loses its last ~30 pt behind the chip while the chip shows; the alternative (the styler narrows the first line) would change wrapping and restyle when the chip appears. Colours come only from roles the themes already have (`background`, `rule`, `secondaryText`, `text`, `accent`), so the existing legibility floors cover built-in and imported themes. Not included, to match the chevrons: a tooltip and a cursor change.
- **D4 · Confirmation.** The glyph becomes a tick in `accent` for 1.5 s, then reverts, with no animation (so there is nothing for Reduce Motion to switch off). The tick state is dropped on any text change, on switching to the source view and when the window goes away. A VoiceOver announcement ("Copied code block") is posted on every copy, so the menu and accessibility routes also get feedback.
- **D5 · Which blocks.** Every code block cmark reports that has something to copy: backtick or tilde fences with or without a language, closed or unclosed, indented blocks, and blocks nested in a quote or list. A Mermaid block gets the chip only while its source shows as a code card (caret inside); it copies the diagram source, and the rendered diagram card has no chip. An empty block (no lines, or only a final line break) has no record, no chip, and the command beeps. Front matter, tables, HTML blocks and inline code are out, as the intent says.
- **D6 · Non-pointer route.** (a) Edit ▸ Copy Code Block, ⇧⌘C, acting on the block that contains the caret (`codeBlock(containing: selection.location)`, ends inclusive, the same rule as D2). No menu item in the app uses ⇧⌘C (only ⌥⌘C, Code Block, does); I will still confirm it in the running app and drop the shortcut if it clashes with a system one (the menu item stays). It beeps when the caret is not in a block, like Fold does, and, being a command on text and not the drawn chip, it still works in the source view. (b) The editor exposes an accessibility custom action "Copy Code Block" while the caret is in a block, which VoiceOver lists in its actions menu. VoiceOver speech cannot be tested in CI, so the proof is the action's presence and effect plus a manual walk-through (see Proof); the wider audit stays DW-011.
- **D7 · The click.** `mouseDown` checks the chip first, before the fold, grid and task-box paths, and swallows the click: no `super`, no caret move, no selection change, the text view takes first responder as the chevrons do, and double clicks do nothing. Copying never calls `shouldChangeText`, so there is no edit, no undo entry and the document is not marked edited. If a debounced re-analysis is pending (documents over 400 KB) the click runs it first, so the text copied is never from a stale analysis.
- **D8 · The ⌘C-of-a-selection problem.** Out of scope and unchanged, as the intent assumes. If you want it fixed, it is a separate intent (a copy override has its own decisions).
- **D9 · `FEATURE-LIST.md`.** The intent lists it as affected, but the project rule gives rows to features only and not to "small tweaks to an existing feature", and a row is added after a tagged release, never before. I have treated this as an enhancement, so this plan does not touch `FEATURE-LIST.md`. If you rule it a feature, the row is added once the tag exists.

## Files that change

Core (Linux-testable):

- `Sources/DownwriteCore/Analysis.swift` — new `CodeBlockInfo` (`range`, `firstLine`, `lastLine`, `text`); `MarkdownAnalysis.codeBlocks` (document order), `codeBlock(containing:)` (binary search, ends inclusive) and `codeBlock(containingLine:)`; one more initialiser parameter.
- `Sources/DownwriteCore/MarkdownAnalyzer.swift` — `codeBlock(_:_:)` records the block (its range is the `.codeBlock` span's range) with `c.code` minus its final line break, skipping empty text; both `MarkdownAnalysis(` call sites pass the list (`[]` for the table-cell analysis, which only has inline content).
- `Tests/DownwriteCoreTests/CodeBlockTests.swift` — new.
- `Tests/DownwriteCoreTests/AnalyzerTests.swift` — one speed test with many code blocks next to `testLargeDocumentPerformance`, and code-block range checks added to the existing range-sanity loop (around line 630).

App (macOS):

- `Sources/Downwrite/DWLayoutManager.swift` — `codeBlocks`, `hoveredCodeBlock`, `activeCodeBlock`, `copiedCodeBlock`, `copyControlStyle` (five `NSColor`s); `copyControlRect(forBlock:)` (container coordinates, from the block's first line fragment taller than 1 pt, so folded lines and collapsed Mermaid give `nil`); `drawCodeCopyControls(in:origin:)` for the blocks that are hovered, active or copied.
- `Sources/Downwrite/EditorCodeCopy.swift` — new `EditorCoordinator` extension (the `EditorFolding.swift` pattern): pointer-to-block lookup, hover and active updates with invalidation of the old and new chip rects only, `copyCodeBlock(at:)`, `copyCodeBlockAtCaret() -> Bool`, the tick timer, the announcement, and the `codeCopyPasteboard` seam.
- `Sources/Downwrite/EditorView.swift` — stored properties for the seam and the tick timer; `reanalyze` pushes `codeBlocks` to the layout manager (empty in the source view) and clears hover and tick; `selectionChanged` updates the active block; `refreshPalette` pushes `copyControlStyle`.
- `Sources/Downwrite/EditorFolding.swift` — `pointerMoved`/`pointerLeft` also update the code hover; the pointer-to-line lookup is shared with `foldHeader(at:)` so a mouse move does the glyph lookup once.
- `Sources/Downwrite/EditorTextView.swift` — `draw(_:)` calls `drawCodeCopyControls` after `super.draw`; `mouseDown` handles the chip first; `dwCopyCodeBlock(_:)`; the accessibility custom action.
- `Sources/Downwrite/DownwriteApp.swift` — `Responder.copyCodeBlock()` and the Edit ▸ Copy Code Block item (a `CommandGroup(after: .pasteboard)` in `FormatCommands`).
- `Sources/Downwrite/SelfTest.swift` — one real-app step (see Proof).
- `Tests/DownwriteTests/CodeCopyTests.swift` — new. `Tests/DownwriteTests/DrawingTests.swift` — pixel checks.

Docs:

- `README.md` — one line in the feature list and the shortcut table.
- `CLAUDE.md` — one Architecture bullet: where the state lives, why the chip is drawn after the text, the pasteboard seam.
- `docs/ROADMAP.md` — DW-012 status as it moves (plan approved, then released).

Not changed on purpose: `MarkdownStyler`, `Palette`, `Themes`, `DocumentHTML` and the other print and export files, `Package.swift`, `ThirdParty/`, `FEATURE-LIST.md` (D9).

## Order of work

Each step is one commit; a failing test comes first where the step is testable.

- [x] 1. Core record. Write `CodeBlockTests` first (fenced, tilde with info string, unclosed, empty and blank-only, indented, nested in a quote and in a list including a fence on the marker line, tabs, non-BMP text, Mermaid, back-to-back blocks, lookups, front matter and inline code absent); then `CodeBlockInfo`, `codeBlocks`, the lookups and the analyzer change. `swift test --filter DownwriteCoreTests` green.
- [x] 2. Core guards. The export cross-check (for the nested cases, `codeBlocks[i].text + "\n"` equals the text `DocumentHTML` puts in the matching `<pre><code>`, unescaped), the many-blocks speed test, and the range-sanity additions.
- [x] 3. Geometry and drawing. `copyControlRect(forBlock:)` and `drawCodeCopyControls` with the test-set state, the `draw(_:)` call; tests for position, size, being on top of text, tick, and every built-in theme (see Proof).
- [ ] 4. State. Coordinator hooks: hover from `pointerMoved`/`pointerLeft`, active block from `selectionChanged`, reset in `reanalyze`, empty in the source view; invalidation of chip rects only. Tests for the visibility rules and for "no restyle on pointer movement".
- [ ] 5. Click and copy. The `mouseDown` path, `codeCopyPasteboard` seam, tick timer with a shortened duration in tests, pending-debounce flush, announcement. Tests for the click, the unchanged document, and fall-through when the chip is not showing.
- [ ] 6. Command and accessibility. `dwCopyCodeBlock`, `Responder`, the menu item, the custom action. First confirm the exact `accessibilityCustomActions` override signature by compiling, and run the app to confirm ⇧⌘C is free. Tests for the command, beep, source view and action.
- [ ] 7. Real-app step in `SelfTest.swift`, README, CLAUDE.md bullet, ROADMAP status. Run the full proof below, with `--shots` once to look at the chip in light and dark.

## Risks

- A long first line runs under the chip and is hidden while the chip shows — accepted in D3; a pixel test pins that the chip is opaque, and the snapshot shows what it looks like.
- Pointer movement could restyle or redraw too much — nothing in the pointer path touches the storage; hover only invalidates the old and new chip rects, and a test counts `NSTextStorage` edit notifications across a run of moves and requires zero.
- `c.code` is now read for every block on every analysis — the many-blocks speed test uses the same bound as the existing large-document test; if it fails, the fallback is to record only the line range and compute the text on a click.
- The analysis can be older than the text for up to 150 ms in documents over 400 KB — the layout manager clamps every range to the storage length, and a click flushes the pending analysis first (D7).
- The analyzer styles a fence inside a `>` quote, or on a list-marker line (`- ```sh`), as one plain indented block: its fences stay visible and nothing hides (found by probing on 2026-10-11, see `CodeBlockTests`). The card, the chip and the copied text are still right there, because the text comes from cmark; the styling quirk is existing behaviour and not changed here, so it may deserve its own backlog item.
- Two fenced blocks with no line between them are drawn as one card (equal `dwBlockBackground` values merge), so the second block's chip sits partway down that card, at the top right of its own first line — accepted, covered by a test that only checks the chip is inside the card.
- DW-003, DW-006 and DW-007 touch the same files — the roadmap already says not to run them in parallel; this plan adds no styler change, which keeps the overlap small.
- The tests and the e2e step write to the pasteboard — both use a private named pasteboard through the seam so the person's clipboard is not overwritten, and the e2e step runs from the isolated bundle-ID copy (it shares real preferences otherwise).

## Proof

Tests to add or change:

- `Tests/DownwriteCoreTests/CodeBlockTests.swift` — what is copied for every kind of block (D1, D5), the lookups, and the cross-check against the export's code text.
- `Tests/DownwriteCoreTests/AnalyzerTests.swift` — speed with many blocks; ranges stay inside the text on the random documents.
- `Tests/DownwriteTests/CodeCopyTests.swift` — in a real `NSTextView`: the chip rect is inside the card at the top right, with fences collapsed and revealed; the chip shows on hover, with the caret inside and for a Mermaid block only while its source shows, and not in the source view, for a folded block or for a collapsed Mermaid card; a click on the chip puts exactly the code on the private pasteboard, identically with fences collapsed and revealed, leaves the selection and the text alone, posts no `didChangeText`, leaves `undoManager.canUndo` false, and a double click does nothing; a click on the card away from the chip, or on the chip's place while it is not showing, moves the caret as usual; the tick appears and clears; ⇧⌘C's action copies for a caret in a block, beeps and leaves the pasteboard alone otherwise, and works in the source view; the accessibility custom action exists only with the caret in a block and copies when performed; pointer movement causes no text-storage edits.
- `Tests/DownwriteTests/DrawingTests.swift` — pixel checks in every built-in theme, light and dark: the chip fill differs from the card, the glyph has ink, the text under the chip is covered, and the tick is drawn in the accent colour.
- `Sources/Downwrite/SelfTest.swift` step — in the real app, with a real `NSDocument`: move onto a block, capture the chip, click, read the private pasteboard, check the tick, and check `isDocumentEdited` is still false and the undo stack still empty.

Must pass before the change is complete:

```
caffeinate -u -t 2; caffeinate -d &
swift test --filter DownwriteCoreTests
scripts/linux-test.sh
swift test
scripts/ci-local.sh --shots
git diff --stat main -- Sources/DownwriteCore/DocumentHTML.swift Sources/DownwriteCore/DocumentRenderer.swift Sources/DownwriteCore/DocumentAssemble.swift Sources/DownwriteCore/HTMLSupport.swift Sources/DownwriteCore/PrintStyle.swift Sources/Downwrite/DocumentOutput.swift Sources/Downwrite/PrintRenderer.swift
```

`scripts/linux-test.sh` fails under macOS's bash 3.2 and a Docker Desktop test process can wedge (both in CLAUDE.md); if either happens, use the workaround recorded there (one test per process under a timeout, retry only a timeout) and say so in `review.md`. The last command must print nothing: no print or export file changes. Run `scripts/ci-local.sh` from the isolated bundle-ID copy.

Checks that cannot be automated, to be done by hand and recorded in `review.md` (or marked owed there):

- With VoiceOver on, open the editor's actions menu with the caret in a code block, run Copy Code Block, and hear the announcement; then the same from Edit ▸ Copy Code Block.
- Look at the chip in the light and dark `--shots` captures, including a block whose first line reaches the right edge.

Outcome coverage:

| Outcome in the intent | Proven by |
|---|---|
| Chip at the card's top right; copies exactly the code, without fences, language tag or quote or list prefix | `CodeBlockTests` (text), `CodeCopyTests` (position, click), self-test step |
| Same result collapsed or revealed | `CodeCopyTests` click with the caret outside and inside |
| Brief tick, then normal | `CodeCopyTests`, `DrawingTests` |
| Document unchanged: no edit, no undo, not marked edited | `CodeCopyTests` (no `didChangeText`, empty undo), self-test step (`isDocumentEdited`) |
| No chip in the source view, in folded lines, or in print, PDF and HTML | `CodeCopyTests`; the empty `git diff --stat` above and the unchanged `DocumentHTML` tests |
| A non-pointer way to do the same | `CodeCopyTests` (command, action) and the manual VoiceOver check |
| Everything else unchanged (⌘C, hiding, folding, source view, overlays, sidebar, reload) | the existing suites in `swift test` and `scripts/ci-local.sh` |

## Deviations

- Step 3 · `copyControlRect(forBlock:)` takes "the first line fragment taller than 1 pt that carries `.dwBlockBackground`", not just "taller than 1 pt". A collapsed Mermaid source does not give nil under the plain rule: its last fence line is 72 pt tall because it holds the diagram card's reserved space (found by a failing test). A collapsed source has no code card, and the background attribute is what makes the card get drawn, so the control now follows the card. Same intent, different test for it.
- Step 3 · `DWLayoutManager` has one more state flag than the plan lists, `pointerOnCopyControl`, and `CopyControlStyle` has a field for it (`glyphHover`, from the palette's `text`): the glyph darkens while the pointer is on the control itself. The plan named `text` among the five colours but gave it no use. Step 4 sets the flag from the pointer position.
