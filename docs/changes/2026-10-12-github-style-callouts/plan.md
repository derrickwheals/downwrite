---
type: plan
id: 2026-10-12-github-style-callouts
intent: ./intent.md
spec: ./spec.md
status: in-progress    # draft | approved | in-progress | done
approved: 2026-10-13
branch: change/2026-10-12-github-style-callouts
---

# Plan: GitHub-style callouts

## Approach

One recogniser in `DownwriteCore`, `CalloutSyntax.match(_:in:)`, takes a swift-markdown `BlockQuote` and the `SourceText` the tree was parsed from and returns the callout's kind, the range of `[!TYPE]` plus the whitespace after it, and the range of the title, or nil. `MarkdownAnalyzer.blockQuote` calls it to record a `CalloutInfo`, a marker that hides while the caret is away from its line, and a title span. `DocumentRenderer` calls the same function on the same node type to write the callout's HTML, so the editor and the export cannot disagree (R5) and one parity test pins it. The colours are a pure function of a `Palette` (`Palette.calloutColor`), so no stored field changes and imported themes get callouts for free (R15). The app target then does what it already does for task checkboxes: the styler puts a `CalloutMark` on the hidden marker's first character (plus a kern when there is a title), and `DWLayoutManager` draws the icon and type name there and draws the first level of the bar in the callout colour. Reveal reuses `Marker.reveal` (the marker line) exactly like the line's `>`, so `selectionChanged` gets no new restyle path.

I chose this over deriving callouts in the styler alone because the spec needs the same decision in the export and in Linux tests, and over a label view laid over the text because every other drawn thing (checkbox, chevron, code card) is drawn by the layout manager from a text attribute, which keeps folding, the source view and theme changes working without new code.

## Decisions

The spec leaves these to the plan. A spike with swift-markdown 0.9 (a scratch package outside the repo, 2026-10-12) and a GitHub probe (`gh api markdown`) settled the facts they rest on.

- **D1 · Recognition.** `CalloutSyntax.match` returns a match when: (a) `quote.parent is Document` (top level; this one test replaces the `quoteDepth`/`listDepth` conditions, so the editor and the export cannot differ on it); (b) the quote's first child is a `Paragraph` and that paragraph's first inline child is a `Text` (the spike showed `[!NOTE]` arrives as one `Text` node; a `[!note]: …` definition elsewhere turns it into a `Link`, a following `---` turns the block into a `Heading`, and five spaces make it a `CodeBlock`, so R1's prefix rules and the "not a link" rule come from cmark and no second parser is written); (c) at the paragraph's start offset the source reads `[!`, one of the five names in any ASCII case, `]`, and then the end of the line or a space or tab (so `+`, `-`, `:`, `\` and everything else fail); (d) the title is the rest of the line, trimmed, and counts only if non-blank; (e) something follows: a non-blank title, or a second block in the quote, or a second child in the paragraph (a break and a line). Step (c) reads the source, not the tree, because `[!NOTE]\` and `[!NOTE]` plus two trailing spaces give the same tree (a `LineBreak`); it also checks that the offset holds `[`, so any cmark column surprise (a tab after `>`) falls back to a plain quote and never hides the wrong characters. Case-insensitive comparison is done on UTF-16 units, not with Foundation, so Linux and macOS agree.
- **D2 · A blank `>` line before the marker is allowed.** `>`, `> [!NOTE]`, `> body` is a callout on GitHub (probed 2026-10-12: it renders a `markdown-alert`) and it satisfies R1 as written (the first block is a paragraph whose first line is the marker). It is not in the spec's table, so I add it to the corpus. Because of it `CalloutInfo.firstLine`/`lastLine` and `range` cover every line of the quote (the bar and the lookups must cover the blank line too), and the record gets a separate `markerLine`; `markerRange` and `titleRange` are as the spec says. The spec calls the first line "the marker line"; this is the only place the two differ.
- **D3 · Colours (R15, R16).** Five fixed sRGB hues of Downwrite's own: Note `#2978E0`, Tip `#29AE55`, Important `#8F51D6`, Warning `#F59F0A`, Caution `#E42532`. `calloutColor` mixes the hue 15 % toward `text`, then calls `ensuringContrast(4.5, against: background, toward: bestPole(for: background))`. Because black or white reaches at least 4.58 on any page, every colour on every page, including random imported ones, is at least 4.5; the spec's 3.0 for imported themes is met with margin and the tests assert 4.5 on both. I computed it for the six built-in themes in a scratch script: lowest contrast 4.51 (Mocha), and the closest pair (always Note and Important) is ΔE\*ab 30.9 at worst. So the "perceptibly different" metric is **CIE76 ΔE\*ab ≥ 25** between any two kinds in every built-in theme (margin of about 6). The same script on 2,000 random pages found 154 where some pair came within ΔE2000 5 because the page sits near luminance 0.18 and the colours converge on black or white; the spec accepts that (the icon and the name still tell them apart), so no distinctness test is asserted for imported themes.
- **D4 · Flags.** `StyleFlags.calloutMarker` and `.calloutTitle` take bits 30 and 31, which fills the `UInt32` word. The next flag needs `StyleFlags` and `runs(in:selection:)` widened to `UInt64`; CLAUDE.md gets a line saying so.
- **D5 · How it is drawn.** The mark goes on the first character of the hidden `[!TYPE]` marker, not on the line's first character, so it follows the text origin even with leading spaces before the `>`. That character keeps the line's real font (clear) through the existing `keepLineMetrics`, so a marker line with no title does not collapse to a sliver, and with a title its `.kern` is the label's width, measured once in the styler from the same bold font the layout manager draws with (the mark carries the font and the widths), so the title can never overlap the label. Icons are SF Symbols tinted with the callout colour (`info.circle`, `lightbulb`, `exclamationmark.bubble`, `exclamationmark.triangle`, `exclamationmark.octagon`; all five exist on this Mac): five different silhouettes, nothing to hand-draw, and R8's pairwise test renders them in one colour. Every line of a callout gets a new attribute `.dwCalloutBar` (the colour) in addition to the ordinary `.dwQuoteBarColor`; the bar loop uses it for level 1 only, so a plain quote nested in a callout keeps its own colour for the deeper bar (R7). The spec's interface sketch had `.dwQuoteBarColor` itself carry the callout colour, which cannot give the nested bar its own colour.
- **D6 · Reading R10.** A callout adds no restyle path of its own. The lines whose attributes change when the caret moves are the same lines that change for a plain quote at the same place (the line the caret leaves and the line it enters, because each line's own `> ` shows when the caret is on it), with one addition the marker brings: the marker line also swaps between the label and the literal, and that happens only when the caret is on it. The test compares a callout against an identical plain quote for every caret move, and checks that a move between body lines never touches the marker line.
- **D7 · Announcement (R14).** `EditorCoordinator` keeps `activeCallout: Int?`. `reanalyze` sets it silently (typing a marker, undo and an external reload do not announce), and `selectionChanged`, after the source-view early return, announces `"<Note> callout"` when `calloutIndex(touching: selection)` moves from nil or from another callout to a callout. It goes out through `onAnnouncement` and `NSAccessibility.post(.announcementRequested)` at medium priority, so it queues behind the line VoiceOver is reading instead of cutting it off. The copy announcement is `.high`; that one answers a user action. No VoiceOver run is possible in CI (see Proof).
- **D8 · Export markup (R18, R19).** A top-level callout writes `<blockquote class="callout callout-note">`, then `<p class="callout-title"><span class="callout-type">Note</span> My title</p>` (no space and no title text when there is no title), then the body. The first paragraph is rebuilt from its inline children: the first `Text` loses `[!TYPE]` and the whitespace after it, the children up to the first top-level `SoftBreak`/`LineBreak` become the title, and the children after that break become one body `<p>` (none if empty); the remaining blocks of the quote follow through the existing block rendering, with the heading-keep wrapper still applying (`blocks(of:)` becomes a thin wrapper over `blocks(_ kids:)`). `PrintStyle` adds `blockquote.callout-<kind>` and `.callout-<kind> .callout-title` rules in `Palette.palette(for: .light).calloutColor(kind).css`, bold, `margin:0 0 .35em` on the title; `blockquote{break-inside:avoid}` already keeps a callout whole. A plain quote's output stays byte-for-byte what `DocumentHTMLTests` assert today. One known edge: an inline element that spans the marker line and the next line (`> [!NOTE] **a`, `> b**`) cannot be split, so the export puts the whole element in the title while the editor styles only the marker line's part; pinned by a test, not fixed.
- **D9 · One corpus, one place.** `Tests/Fixtures/callouts.md` is the corpus: one `## <id> <expected>` heading per row (`callout note`, `callout warning "My title"`, `plain`), the row under it. `CalloutTests` (Linux), `CalloutEditorTests` (macOS), the real-app step and the GitHub cross-check all read that file, as `fold-demo.md` and `export-demo.md` are shared today. The one row that cannot sit in the same document is the reference definition (`[!note]: …` anywhere would turn every `[!NOTE]` in the file into a link), so it is a literal in `CalloutTests`. Headings between rows also give the fold step something to fold.
- **D10 · Docs and tree.** `FEATURE-LIST.md` is not touched (the row is owed once a tag exists, per CLAUDE.md). `docs/ROADMAP.md` has uncommitted edits of yours (the Todoist IDs) and the status change for DW-006 goes in the same file: that commit stages only its own hunk (`git add -p`) or waits until you commit yours; I will ask at that step rather than guess. The untracked `BUG-fence-in-quote-or-list-marker-line-not-hidden.md` is not touched.

## Files that change

Core (Linux-testable):

- `Sources/DownwriteCore/Callouts.swift` — new. `CalloutKind` (cases, `title`, `init?(marker:)`), `CalloutMatch`, `CalloutSyntax.match(_:in:)`, `Palette.calloutColor(_:)`.
- `Sources/DownwriteCore/Analysis.swift` — `CalloutInfo`; `MarkdownAnalysis.callouts` and one more initialiser parameter; `calloutIndex(containingLine:)`, `callout(containingLine:)`, `calloutIndex(touching:)` (binary searches like `codeBlockIndex`); `StyleFlags.calloutMarker`, `.calloutTitle`.
- `Sources/DownwriteCore/MarkdownAnalyzer.swift` — `blockQuote` calls the recogniser and records the callout, its marker (reveal = the marker line) and its title span; both `MarkdownAnalysis(` call sites pass the list (`[]` for the table-cell analysis).
- `Sources/DownwriteCore/DocumentRenderer.swift`, `DocumentHTML.swift` — the callout branch, the `blocks(_:)` split, and `DocumentRenderer(headingIDs:source:)`, with `prepare` passing `SourceText(markdown)` of the exact string cmark parsed (front matter cut, footnote definitions protected).
- `Sources/DownwriteCore/PrintStyle.swift` — the callout rules.

App (macOS):

- `Sources/Downwrite/Typography.swift` — `.dwCallout` and `.dwCalloutBar` keys; `CalloutMark` next to `CheckboxMark`.
- `Sources/Downwrite/MarkdownStyler.swift` — `lineLook` (bar attribute), `applyLine` (the mark, `keepLineMetrics`, the kern), `runAttributes` (`.calloutTitle` is bold in the callout colour).
- `Sources/Downwrite/DWLayoutManager.swift` — level-1 bar colour, `drawCalloutLabels` in `drawCustomBackgrounds`, `calloutLabelRect(forCharacterAt:)`.
- `Sources/Downwrite/CalloutIcon.swift` — new. The SF Symbol per kind, drawn in a given colour (used by the layout manager and by the pairwise test).
- `Sources/Downwrite/EditorView.swift` — `activeCallout`; `reanalyze` sets it silently; `selectionChanged` calls the announcement.
- `Sources/Downwrite/EditorCallouts.swift` — new `EditorCoordinator` extension (the `EditorCodeCopy.swift` pattern): `announceCalloutIfEntered(selection:)`.
- `Sources/Downwrite/SelfTest.swift` — a two-line hook and the `--selftest-callouts=` argument; `Sources/Downwrite/SelfTestCallout.swift` — new, the real-app step.
- `scripts/ci-local.sh`, `.github/workflows/ci.yml` — pass `--selftest-callouts="$PWD/Tests/Fixtures/callouts.md"`.

Tests and fixture:

- `Tests/Fixtures/callouts.md` — new, the corpus (D9).
- `Tests/DownwriteCoreTests/CalloutTests.swift` — new. `ThemeCatalogTests.swift`, `VSCodeThemeTests.swift`, `ThemeLibraryTests.swift`, `DocumentHTMLTests.swift`, `PrintStyleTests.swift`, `HTMLSanitizerTests.swift`, `AnalyzerTests.swift` — additions.
- `Tests/DownwriteTests/CalloutEditorTests.swift` — new. `StylerTests.swift`, `DrawingTests.swift`, `SourceViewTests.swift`, `FoldTests.swift` — additions.

Docs:

- `README.md` — a feature note that also says a title after the marker is a Downwrite extension that GitHub shows as a plain quote.
- `CLAUDE.md` — one Architecture bullet (where the recogniser, the mark and the colours live; the full flag word).
- `docs/ROADMAP.md` — DW-006 status at the workflow's gates (see D10).

Not changed on purpose: `Palette`, `ThemeDefinition`, `StoredTheme`, `Themes.swift`, `VSCodeTheme.swift` (R15); `Folding.swift`, `EditorFolding.swift` (R13); `EditorTextView.swift`; `TableOverlay`, `TableGrid`, `Previews`, `TOCSidebar`, `EditorCodeCopy`, `DocumentOutput`, `PrintRenderer`, `Package.swift`, `ThirdParty/`, `FEATURE-LIST.md`.

## Order of work

Each step is one commit, test first where the step is testable. Run `caffeinate -u -t 2; caffeinate -d &` before any macOS test run.

- [x] 1. Fixture and recogniser. Write `Tests/Fixtures/callouts.md` (the spec's whole table, the D2 row, rows for a tab after `>`, a non-BMP title, a CRLF document built in the test) and the `CalloutTests` that read it and fail; then `Callouts.swift` (`CalloutKind`, `CalloutSyntax.match`). Includes the literal reference-definition test. `swift test --filter CalloutTests` green.
- [x] 2. Analysis record. Tests first for `callouts`, `markerLine`/`markerRange`/`titleRange`, the lookups, the hidden-run flags and the inclusive reveal; then `CalloutInfo`, the two flags, the analyzer change. Add the quote ranges to the range-sanity loop in `AnalyzerTests` and a many-quotes speed test next to `testLargeDocumentPerformance`.
- [x] 3. Colours. Tests first (built-ins: contrast ≥ 4.5 and CIE76 ≥ 25, opaque, pure; the 300 random themes ≥ 4.5; a stored theme JSON from before this change loads and gets callout colours); then `Palette.calloutColor`.
- [x] 4. Export. Tests first: exact markup for the five kinds, titled and untitled, title-only, inline formatting in the title, a list and a code block in the body, a nested plain quote, a plain quote and a quote in a list unchanged, escaping and the three sentinel characters, the D8 edge, the sanitiser and the mutation harness over callout markup, `PrintStyle` rules from the light palette, and the parity test (every fixture row: `analysis.callouts` and the export agree on kind and on "is a callout"); then the renderer, `DocumentHTML` and `PrintStyle` changes.
- [x] 5. Styling. Tests first in `StylerTests`, `SourceViewTests` and `FoldTests`: the bar attributes on every callout line, deeper bar unchanged, marker characters hidden and the mark present away from the line, no mark and the literal shown with the selection on it (R9), title bold in the callout colour, plain quotes identical to today, no mark in the source view or on a folded line. Then `CalloutMark`, the keys, and the styler.
- [x] 6. Drawing. Tests first in `DrawingTests` (see Proof); then `CalloutIcon`, `drawCalloutLabels`, `calloutLabelRect(forCharacterAt:)` and the level-1 bar colour.
- [x] 7. Editor behaviour. Tests first in `CalloutEditorTests` (reveal, typing and deleting a marker, Return, the restyled-line comparison of D6, the announcement, a theme switch), then `EditorCallouts.swift` and the `EditorView.swift` hooks.
- [x] 8. Real-app step. `SelfTestCallout.swift` reads the fixture, hooks into `SelfTest.swift` like the fold and export steps (with a `--selftest-callouts-only` flag for development), plus the two CI scripts. Run it from an isolated bundle-ID copy with a fresh ID.
- [ ] 9. Docs and the full proof below. README, CLAUDE.md, the ROADMAP status (D10), `scripts/ci-local.sh --shots` once to look at the callouts in every theme.

## Risks

- A cmark column or range quirk mis-places the marker — D1(c) checks the source at the offset and falls back to a plain quote; the fixture has a tab row, a CRLF test and a non-BMP title, and the editor and export parity test runs the whole fixture.
- The kern and the drawn label disagree, so the title overlaps the label — both come from one measurement in the styler and the mark carries it; a pixel test requires the title's first glyph to start at or after the label's right edge, in every font choice the harness offers.
- A marker line with no title collapses to a sliver, or a folded callout leaves ink — the first goes through `keepLineMetrics` like an empty task item, and `FoldTests` require no mark, no ink and no bar on a folded callout.
- Moving the caret restyles more than before — there is no new path; D6's comparison against an identical plain quote fails if the callout restyles any extra line, and a test counts storage edits across a run of moves.
- The flag word is full (D4) — recorded in CLAUDE.md; nothing in this change needs a third bit.
- Colours converge on an odd imported page — accepted by R16; contrast is still guaranteed and the test asserts it on 300 random themes.
- The scratch numbers and hues are not what the Swift code computes — the tests assert the properties (4.5, 25) against the real function, so a wrong hue fails there, not by eye.
- Pixel tests on a dark page — per CLAUDE.md a dark page does not come out as its palette value in an offscreen bitmap, so the tests compare drawn pixels with a rendered page sample, not with `palette.background`.
- An inline element spanning the marker line and the next line splits differently in the editor and the export — D8, pinned by a test, not fixed.
- Docker Desktop wedges a Linux test process and `scripts/linux-test.sh` fails under macOS's bash 3.2 — use the workaround in CLAUDE.md and say so in `review.md`.
- DW-003 and DW-007 work in the same files — the roadmap already says not to run them in parallel with this; nothing else is in flight on this branch.
- Your uncommitted `docs/ROADMAP.md` edits — D10.

## Proof

Tests to add or change:

- `Tests/DownwriteCoreTests/CalloutTests.swift` — every fixture row classified as the file says (kind, and title or none); the literal reference-definition row; D2's row; CRLF and non-BMP; the three lookups; marker and title ranges and the hidden-run flags (hidden away from the line, shown with the selection on either end of the line); the colour properties; the editor/export parity.
- `Tests/DownwriteCoreTests/ThemeCatalogTests.swift`, `VSCodeThemeTests.swift` (inside `testRandomThemesAreAlwaysLegible`), `ThemeLibraryTests.swift` — callout colours on the six built-ins, 300 random themes, and a stored theme.
- `Tests/DownwriteCoreTests/DocumentHTMLTests.swift`, `HTMLSanitizerTests.swift`, `PrintStyleTests.swift` — exact markup and CSS, plain quotes unchanged, sanitiser and mutation tests over callouts.
- `Tests/DownwriteCoreTests/AnalyzerTests.swift` — ranges stay inside the text; speed with many quotes.
- `Tests/DownwriteTests/StylerTests.swift`, `SourceViewTests.swift`, `FoldTests.swift` — attributes, source view and folds.
- `Tests/DownwriteTests/DrawingTests.swift` — in every built-in theme, light and dark: the level-1 bar pixels are the callout colour and a nested plain quote's second bar is the quote colour; label pixels sit on the marker line at `calloutLabelRect`; the five icons rendered in one colour are pairwise different (at least 5 % of the icon square's pixels differ between any two; fixed from the first run if the symbols turn out closer, noted in Deviations); the title starts after the label; a theme switch changes the colours.
- `Tests/DownwriteTests/CalloutEditorTests.swift` — in a real `NSTextView`: reveal on the marker line and its return; typing a marker onto a quote turns it into a callout once a body character exists and deleting a marker character turns it back; Return at the end of the marker line continues with `> `; D6's restyled-line comparison; zero storage edits from caret moves between body lines; the announcement (text, once per entry, from one callout to another, none in the source view, none when typing); the text, the undo stack and `isDocumentEdited` untouched by moving the caret.
- `Sources/Downwrite/SelfTestCallout.swift` — in the real app with a real `NSDocument`: every fixture row classified; the caret on a marker line shows the literal and the label returns; folding the heading above a callout hides it and unfolding restores it; the source view shows plain text; screenshots in light and dark.

Must pass before the change is complete:

```
caffeinate -u -t 2; caffeinate -d &
swift test --filter DownwriteCoreTests
scripts/linux-test.sh
swift test
scripts/ci-local.sh --shots
gh api markdown -f mode=gfm -f text="$(cat Tests/Fixtures/callouts.md)" | grep -o 'class="markdown-alert markdown-alert-[a-z]*"' | wc -l
git diff --stat main -- Sources/DownwriteCore/Folding.swift Sources/DownwriteCore/TableOfContents.swift Sources/DownwriteCore/DocumentStats.swift Sources/DownwriteCore/Themes.swift Sources/DownwriteCore/VSCodeTheme.swift Sources/DownwriteCore/Palette.swift Sources/Downwrite/EditorFolding.swift Sources/Downwrite/EditorCodeCopy.swift Sources/Downwrite/EditorTextView.swift Sources/Downwrite/TableOverlay.swift Sources/Downwrite/TableGrid.swift Sources/Downwrite/Previews.swift Sources/Downwrite/TOCSidebar.swift Sources/Downwrite/DocumentOutput.swift Sources/Downwrite/PrintRenderer.swift
```

`scripts/linux-test.sh` and the isolated bundle-ID copy for `ci-local.sh` are as CLAUDE.md describes. The GitHub count must equal the number of fixture rows marked `callout` that GitHub also shows as one (every one except the titled rows, which are the deliberate difference; the build stage lists them), and the last command must print nothing (R20: those files are untouched).

Checks that cannot be automated, done by hand and recorded in `review.md` (or marked owed there):

- With VoiceOver on, move the caret into a callout and hear "Note callout" once, then into another callout, then out and back in.
- Look at the fixture in `dist/Downwrite.app` in Downwrite light and dark, Catppuccin Latte and Mocha, Radix light and dark and one imported VS Code theme, and read the five callouts by icon and name as well as colour.
- File ▸ Export as HTML… and Export as PDF… of the fixture, with the app in dark mode, a fold closed and the source view on: the same light page, callouts with a coloured bar and a name, no `[!NOTE]` text for callout rows, the literal text for plain rows.

Requirement coverage:

| Requirement | Proven by |
|---|---|
| R1, R2, R3, R4 | `CalloutTests` over `callouts.md`, the reference-definition literal, D2's row; the unchanged `DocumentHTMLTests` plain-quote assertions; existing `StylerTests`/`AnalyzerTests` quote cases |
| R5 | `CalloutTests` lookups and the editor/export parity test |
| R6, R7 | `StylerTests` (attributes, hidden marker, title look), `DrawingTests` (bar pixels, label on the marker line, title after the label, nested bar) |
| R8 | `DrawingTests` icons pairwise different; the name is drawn in the same pass |
| R9, R10 | `CalloutTests` (flags), `StylerTests` (selection on and off), `CalloutEditorTests` (D6 comparison) |
| R11 | `CalloutEditorTests` (typing, deleting, Return) |
| R12 | `SourceViewTests`; the real-app step |
| R13 | `FoldTests`; the real-app step (fold and unfold the heading above a callout) |
| R14 | `CalloutEditorTests` (announcement); VoiceOver by hand |
| R15, R16 | colour tests in `CalloutTests`, `ThemeCatalogTests`, `VSCodeThemeTests` (300 random), `ThemeLibraryTests`; the empty `git diff --stat` above for `Palette`, `Themes`, `VSCodeTheme` |
| R17 | `CalloutEditorTests` theme switch; `DrawingTests` per theme |
| R18, R19 | `DocumentHTMLTests`, `PrintStyleTests`, `HTMLSanitizerTests`; the export by hand |
| R20 | the whole existing suite in `swift test` and `ci-local.sh`; the empty `git diff --stat` above |
| Spec verification 1 to 3 | `scripts/linux-test.sh`, `swift test`, `scripts/ci-local.sh --shots` |
| Spec verification 4, 5, 7 | the three by-hand checks |
| Spec verification 6 | the `gh api markdown` command |

## Deviations

None that change what is delivered. Two notes from step 1 on how the plan's wording turned out:

- Two spec rows cannot share the fixture, not one: a reference definition elsewhere (`[!note]: https://x`) and the in-quote `> [!NOTE]: x`, which is itself a definition of `!note` (and so is `> [!NOTE]:` followed by a body line, whose destination is that line). All are literals in `CalloutTests` (`testReferenceDefinitionElsewhereMakesTheMarkerALink`, `testMarkerFollowedByColonIsADefinitionNotACallout`).
- Step 5 adds one test-support file the plan did not list, `Tests/DownwriteTests/CalloutFixture.swift`: the macOS tests cannot see `CalloutTests` (a different test target), so they read `Tests/Fixtures/callouts.md` with their own small parser, as `FoldTests` does for `fold-demo.md`. It changes how the fixture is read, not what is delivered.
- Step 6: the pixel tests in `DrawingTests` do not compare a drawn colour with its palette value, because an offscreen bitmap shifts every drawn colour (the callout blue came out about 0.23 away in summed RGB, on a light page too, not only on a dark one as CLAUDE.md says). They check that the attributes carry the exact colour (what the layout manager draws), and that a pixel is closer to the expected colour than to the alternative (callout bar against quote bar, ink against text colour). The plan's wording "a theme switch changes the colours" is met with a light-to-dark switch for pixels and an exact check of the attributes for a same-appearance switch, because Downwrite light and Catppuccin Latte derive almost the same blue from the same hue (by design; R16).
- Step 7: the Proof line "zero storage edits from caret moves between body lines" is tested as what is actually true. Moving the caret *within* a line edits no attribute at all (`testMovingTheCaretWithinALineEditsNothing`). Moving *between* body lines restyles exactly the line it leaves and the one it enters, because each line's own `> ` shows while the caret is on it, as for any quote; the marker line is never among them (`testMovingTheCaretRestylesTheSameLinesAsForAPlainQuote`, which also compares every move with an identical plain quote, D6).
- Step 8: the real-app step's source-view check says "monospaced everywhere, and no label, bar or kern" rather than "one attribute run". The corpus has an emoji in a title, and AppKit gives an emoji a fallback font of its own, so the real app reports several runs for that document (the unit test, with no emoji, still asserts exactly one). The first full run of the step from an isolated bundle-ID copy (`--selftest-callouts-only`) passed every check; screenshots `window-light-callouts.png` and `window-dark-callouts.png` were looked at.
- The GitHub cross-check in *Proof* has a known answer. `Tests/Fixtures/callouts.md` has 50 rows. Probed on 2026-10-13, GitHub shows a `markdown-alert` for 24 of them: the 23 untitled rows marked `callout`, plus `backslash` (the spec's out-of-scope difference: GitHub drops the hard break and shows a callout, Downwrite keeps a plain quote). The 8 titled rows (`title`, `title-only`, `title-tab`, `title-trailing`, `title-inline`, `title-link`, `title-marker`, `title-unicode`) are the deliberate difference: GitHub shows each as a plain quote. Every other row agrees with GitHub. So the Proof command must print 24.
