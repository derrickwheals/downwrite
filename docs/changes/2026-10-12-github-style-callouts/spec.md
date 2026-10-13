---
type: spec
id: 2026-10-12-github-style-callouts
intent: ./intent.md
status: approved
approved: 2026-10-12
---

# Spec: GitHub-style callouts

## Summary

A top-level block quote that starts with a marker line such as `> [!NOTE]` is shown as a callout: a bar in the type's colour, and on the marker line a small icon, the type name ("Note") and, if the author wrote one, a title, with the `[!NOTE]` text itself hidden while the caret is away from that line. The five GitHub types (Note, Tip, Important, Warning, Caution) are recognised in any letter case, and everything that GitHub shows as a plain quote stays a plain quote here, with one deliberate exception: a title after the marker (`> [!WARNING] Data loss`) is accepted. Print, PDF and HTML export show the same callouts from the document text alone, and the file on disk is never changed.

## Requirements

Recognition (all in `DownwriteCore`, tested on Linux)

- **R1** — A block quote is a callout when all of these hold: it is top-level (not inside another quote, a list item or a table cell); its first block is a paragraph whose first line, after the quote prefix, is the marker `[!TYPE]`, where the quote prefix is `>` with at most one space or tab after it and then at most three more spaces (four or more is an indented code line); `TYPE` is `NOTE`, `TIP`, `IMPORTANT`, `WARNING` or `CAUTION` in any ASCII letter case; the marker is plain text, not a link (a document that defines a reference named `!note` makes `[!NOTE]` a link, and the quote stays plain); and the marker is followed by the end of the line, or by spaces or tabs and then a title. Anything else after `]`, such as `+`, `-`, `:` or `\`, means it is not a marker.
- **R2** — A marker alone on its line is not enough. The quote is a callout only if something follows the marker: a non-blank title on the marker line, or at least one non-blank line later in the same quote (a following line with its own `>`, a lazy continuation line without one, or any later block such as a list or a code block). `> [!NOTE]` on its own, or followed only by empty `>` lines, is a plain quote. This is GitHub's behaviour, and it also means a quote becomes a callout the moment its first body character is typed.
- **R3** — The title is the text on the marker line after the marker and the whitespace that follows it, trimmed at the end. It is ordinary inline Markdown (emphasis, code, links) and nothing else on the marker line is special. A callout with a title and no body is a callout.
- **R4** — A quote that is not a callout is unchanged: same bar, 16 pt indent per depth, `> ` hiding, nested quotes, and a code block inside. The reference cases in *Behaviour details* are the acceptance corpus.
- **R5** — `MarkdownAnalysis` gains a record per callout (kind, whole range, marker line, the hidden marker range, the title range if any) with the same kind of lookups `codeBlocks` has (by line, by selection). The editor and the export decide what is a callout with one shared rule in `DownwriteCore`, and a test feeds the corpus to both and requires the same answer.

Editor

- **R6** — While the selection is away from the marker line, the marker line shows: the quote bar's place taken by the callout colour, then a drawn icon, the drawn type name (bold, in the callout colour), and, if there is a title, the title as real text after it (bold, in the callout colour, with inline formatting applied). The characters `[!TYPE]` and the whitespace after them are hidden (0.1 pt clear font, never deleted), so the text, undo, find and copy see the file exactly as written.
- **R7** — The first nesting level of the bar is drawn in the callout's colour for every line of the callout. A plain quote nested inside a callout keeps the ordinary quote-bar colour for its own, deeper bar. Body lines look exactly as quote lines do today (indent, text colour, hidden `> `); paragraphs, inline formatting, lists and code inside a callout behave as inside a quote.
- **R8** — The five callouts differ in more than colour: each has its own icon shape, and the type name is always drawn, so the type can be read with no colour at all. A test renders the five icons in one colour and requires them to be pairwise different.
- **R9** — While the selection touches the marker line (inclusive of both ends, the rule every other marker follows), the literal line shows: the `> ` and `[!TYPE]` in the marker colour, the drawn icon and type name not drawn, the title still styled as a title. The bar stays in the callout colour, so the quote does not flicker between plain and callout. When the selection leaves the line the label comes back.
- **R10** — Reveal is per marker line only. Moving the caret into or out of a callout re-styles that marker line and no other line, and moving it between body lines re-styles nothing for the callout.
- **R11** — Typing a marker onto an existing quote makes it a callout, and deleting or changing a character of the marker turns it back into a plain quote, on the same re-analysis that every edit already triggers. Pressing Return at the end of the marker line continues the quote with `> ` as it does today.
- **R12** — The Markdown source view (⌘/) is unchanged: plain monospaced text, with no icon, label, colour or bar.
- **R13** — A callout is not a fold region. It hides and shows with the heading it sits under: lines hidden by a fold draw no icon, label or bar, and opening the fold brings them back. Folding behaviour is otherwise unchanged.
- **R14** — When the caret moves into a callout from outside it, or from one callout into another, VoiceOver is sent an announcement "Note callout" (the type's name plus "callout"). It is not repeated while the caret stays inside the same callout, and not sent in the source view. The announcement goes through the same seam the "Copied code block" announcement uses, so a test can read it.

Colours

- **R15** — The five callout colours are derived from the page's `Palette` and add no stored field to `Palette`, `ThemeDefinition` or `StoredTheme`: an already-stored imported theme loads unchanged and gets callout colours. A function in `DownwriteCore` takes a palette and a kind and returns an opaque colour; the app turns it into an `NSColor`, so nothing in `Sources/Downwrite` picks a callout colour of its own.
- **R16** — In every built-in theme, each callout colour has a contrast ratio of at least 4.5 against the page and any two of the five are perceptibly different (the plan fixes the metric and floor from the built-in values and a test asserts it). In every imported theme, including the 300 random themes `VSCodeThemeTests` already generates, each colour has a contrast ratio of at least 3.0 against the page (two colours may converge on a page whose luminance is near 0.18, where only black or white can reach the floor; the icon and the type name still tell them apart).
- **R17** — Switching theme or appearance repaints callouts in the new theme's colours.

Export

- **R18** — Print, Export as PDF and Export as HTML show a callout as a callout: a block quote with a bar in the callout colour, a first line in the callout colour and bold weight that reads the type name followed by the title if there is one, then the body. The literal `[!NOTE]` text does not appear for a callout, and does appear unchanged for a quote that is not one. There is no icon in the export. The colours come from the fixed light palette through the same function as R15, and the output depends on the document text alone (no theme, setting, fold or source view).
- **R19** — Callout markup passes through `HTMLSanitizer` unchanged in meaning, its adversarial and random-mutation tests stay green, and a callout does not break across a printed page where it fits on one (the rule block quotes already have).

Does not change

- **R20** — The file on disk, the document's edited state, folding, the source view, table and diagram overlays, the contents sidebar, the code-block copy control, external-change reload and every plain quote behave as before. Word count and the contents sidebar are not changed by this feature.

## Out of scope

- User-defined callout types, a settings pane, and a menu command or shortcut that inserts a callout (Format ▸ Block Quote still toggles `> `).
- Obsidian's wider type set (`info`, `success`, `question`, `danger`, `bug`, `example`, `quote`…), and foldable `[!note]+` / `[!note]-` callouts. They stay plain quotes, as they do on GitHub.
- Callouts inside a list item, inside another quote, or in a table cell. GitHub does not render those either ("Alerts cannot be nested within other elements").
- A background tint behind a callout (decided: bar, icon and label only).
- Syntax highlighting (DW-003), focus mode (DW-007), and the wider accessibility audit (DW-011), which this change only feeds with the one label it draws and the announcement.
- The open bug that fence lines of a code block inside a quote never hide (`docs/backlog-items/BUG-fence-in-quote-or-list-marker-line-not-hidden.md`). A code block inside a callout behaves exactly as inside any quote today; the bug gets its own change later and fixes both.
- Icons in the export, and a `FEATURE-LIST.md` row, which is owed only once the feature is tagged in a release (see *Files and components involved*).
- Matching GitHub for `> [!NOTE]\` (a backslash after the marker). GitHub drops the hard break and still shows a callout; here it is a plain quote.

## Design

### Interfaces

Names are indicative; the plan fixes them.

`DownwriteCore`:

- `public enum CalloutKind: String, CaseIterable, Sendable` with `note, tip, important, warning, caution`; `title` ("Note", "Tip", "Important", "Warning", "Caution"); `init?(marker:)` that takes `"note"`, `"NOTE"`, `"Note"`…
- `public struct CalloutInfo: Equatable, Sendable`: `kind`, `range` (marker line start to the last line's content end), `firstLine` (the marker line) and `lastLine`, `markerRange` (`[!TYPE]` plus the whitespace after it, up to the title or the end of the line; this is what hides), `titleRange` (nil when there is no title).
- `MarkdownAnalysis.callouts: [CalloutInfo]` (document order, ranges never overlap) with `calloutIndex(containingLine:)`, `callout(containingLine:)` and `calloutIndex(touching:)` (a selection; for the announcement), binary searches like `codeBlockIndex`.
- `StyleFlags.calloutMarker` on the hidden marker (a `Marker` whose `reveal` is the marker line, exactly like the line's `>` marker, so `hiddenMarkerIndices`, `lastHidden` and the existing "restyle only the lines whose markers flipped" logic in `selectionChanged` need no change) and `StyleFlags.calloutTitle` on the title text.
- A shared recogniser (for example `CalloutSyntax`) used by both `MarkdownAnalyzer.blockQuote` and `DocumentRenderer`, so R5 holds by construction.
- `public extension Palette { func calloutColor(_ kind: CalloutKind) -> RGBA }`: five fixed hues (blue, green, purple, amber, red; Downwrite's own values, not a third-party palette, so no new licence entry), mixed toward the page's text colour and nudged with `ensuringContrast`. Pure, tested on Linux.
- `DocumentRenderer`: a callout emits `<blockquote class="callout callout-note">` whose first child is `<p class="callout-title">` (type name, then the title's inlines), then the body blocks. `PrintStyle` gains the matching rules for the five kinds.

`Sources/Downwrite`:

- `MarkdownStyler`: lines of a callout get `.dwQuoteBarColor` = the callout colour; the marker line, while its marker is hidden, gets a `.dwCallout` attribute (`CalloutMark`: kind, colour, icon, type name) on its first character. With a title, a `.kern` on that character reserves the room the icon and type name take, the way the task checkbox reserves its column; without one nothing follows on the line. `.calloutTitle` runs are bold in the callout colour. Everything stays inside `applyLine`/`lineLook`, so folded lines (`collapsedAttributes`) and the source view (`styleSource`) drop it automatically.
- `DWLayoutManager`: draws the bar's first level in the callout colour (deeper levels keep `quoteBar`) and a `drawCalloutLabels` pass in `drawCustomBackgrounds` (icon and type name at the attributed character's x, on its baseline), with `calloutLabelRect(forCharacterAt:)` for tests, like `checkboxRect`.
- `EditorCoordinator`: `selectionChanged` compares `analysis.calloutIndex(touching:)` before and after and sends the R14 announcement. No new restyle path.

### Data

No stored data and no migration. `StoredTheme` and `Palette` are unchanged (R15). Nothing is written to preferences.

### Files and components involved

- `Sources/DownwriteCore/Analysis.swift` — `CalloutKind`, `CalloutInfo`, `MarkdownAnalysis.callouts` and lookups, two `StyleFlags`.
- `Sources/DownwriteCore/MarkdownAnalyzer.swift` — `blockQuote` records callouts and their markers (only when `ctx.quoteDepth == 0 && ctx.listDepth == 0` and not `cellMode`).
- `Sources/DownwriteCore/Callouts.swift` (new) — the shared recogniser and the colour function.
- `Sources/DownwriteCore/DocumentRenderer.swift`, `PrintStyle.swift`, `HTMLSanitizer.swift` (tests only, unless `class` needs allowing) — export.
- `Sources/Downwrite/MarkdownStyler.swift`, `DWLayoutManager.swift`, `EditorView.swift` (coordinator), `EditorTextView.swift` only if the announcement needs it — the editor.
- `Tests/DownwriteCoreTests`: new `CalloutTests.swift` (corpus, lookups, colours, shared-rule parity), plus `ThemeCatalogTests`, `VSCodeThemeTests`, `DocumentHTMLTests`, `PrintStyleTests`, `HTMLSanitizerTests`.
- `Tests/DownwriteTests`: `StylerTests`, `DrawingTests` (bar colour, label, icons pairwise different, theme switch), `SourceViewTests`, `FoldTests`, a new callout editor test (reveal restyles one line, typing and deleting a marker, announcement), `AppTests` if needed.
- `Sources/Downwrite/SelfTestCallout.swift` and `Tests/Fixtures/callouts.md` (new) — the real-app step and the fixture of the corpus.
- `README.md` — a short feature note, which also says that a title after the marker is a Downwrite extension that GitHub shows as a plain quote.
- `FEATURE-LIST.md` — one row, only after the release tag exists (CLAUDE.md, Feature list). Until then the row is owed.
- `docs/ROADMAP.md` — DW-006 status, at the workflow's own gates.

### Behaviour details

Answers to the intent's open questions: (1) five types, no others, unknown types stay plain; (2) any letter case yes, a title yes, foldable no (plain, as on GitHub); (3) marker on the first line of the first paragraph only, a title allowed, top level only, an empty callout is a plain quote; (4) bar, icon, type name and title in the callout colour, no tint, colours derived from the page with no new `Palette` fields, which is how imported VS Code themes get them; (5) the marker line only; (6) a callout is not a fold region; (7) export is in this change, without icons; (8) the fence-in-quote bug stays separate.

The corpus below was run through GitHub's own renderer (`gh api markdown`, `mode=gfm`) on 2026-10-12 and the Downwrite result is what R1 to R3 produce. "Differs" marks the cases where Downwrite deliberately does not match GitHub. These become the cases of `CalloutTests` and the lines of `Tests/Fixtures/callouts.md`.

| Input (each followed by a body line `> body` unless stated) | GitHub | Downwrite |
| --- | --- | --- |
| `> [!NOTE]` | callout | callout, "Note" |
| `> [!note]`, `> [!Note]` | callout | callout |
| `>[!NOTE]` and `>body` (no space) | callout | callout |
| `>  [!NOTE]` (two spaces), `>    [!NOTE]` (four spaces in all) | callout | callout |
| `>     [!NOTE]` (five spaces: indented code) | plain | plain |
| `> [!NOTE]` with trailing spaces | callout | callout |
| `> [!NOTE]` then `>` then `> body` | callout | callout |
| `> [!NOTE]` then `body` (lazy continuation) | callout | callout |
| `> [!NOTE]` then a list, or a fenced code block, in the quote | callout | callout |
| `> [!NOTE]` then `> [!TIP]` then `> body` | Note callout, second marker is text | same |
| `   > [!NOTE]` (three spaces before `>`) | callout | callout |
| `> [!NOTE] My title` then `> body` | plain, marker shown | callout "Note" with title "My title" (differs) |
| `> [!NOTE] My title` alone | plain | callout with title (differs) |
| `> [!NOTE]` alone, or then only `>` | plain | plain |
| `> [!INFO]` | plain | plain |
| `> [!NOTE]+`, `> [!NOTE]-` | plain | plain |
| `> [!NOTE]: x` | plain (a reference definition) | plain |
| `> [! NOTE]` | plain | plain |
| `> **[!NOTE]**` | plain | plain |
| `> hello` then `> [!NOTE]` | plain | plain |
| `> intro`, `>`, `> [!NOTE]` | plain | plain |
| `- item`, then an indented `> [!NOTE]` | plain | plain |
| `> > [!NOTE]` | plain | plain |
| `> [!NOTE]` with `[!note]: https://x` defined elsewhere | plain (a link) | plain |
| `> [!NOTE]\` (backslash) | callout | plain (differs, out of scope) |

Other details.

- A title that is only whitespace is not a title. A title that wraps shows its wrapped lines hanging at the quote's indent, like any wrapped quote line. A title may contain `[!TIP]` or any text; only the first `[!TYPE]` on the first line is a marker.
- With a title, the room for the icon and the type name is a `.kern` on the marker line's first character, measured from the label's font, so the title starts one gap after the name. A title the author is editing is ordinary text; the caret is in it, so the marker line is revealed (R9).
- A nested plain quote inside a callout (`> > x`) keeps its deeper bar in the ordinary quote colour; the callout's own bar is level 1. Lines of a callout that carry `> > ` keep `> ` hiding as they do today.
- Hidden text is copied with the rest: ⌘C of a selection that spans the marker includes `[!NOTE]`, the same as for any hidden syntax.
- The announcement names the type, not the title ("Warning callout"); the title is read as the line's text. The literal marker is part of the text VoiceOver reads on the marker line, as every hidden marker is today. A real VoiceOver pass is owed until someone runs one (DW-011 covers the wider audit).
- Performance: recognition runs once per top-level quote during the existing analysis, using the quote's first line and its first paragraph; no extra scan of the document and no per-keystroke work beyond the analysis that already runs.
- Export title line: `<p class="callout-title">Warning Data loss</p>` with the type name in its own `<span class="callout-type">` so the two read as a name and a title; text is escaped like all document text, and the three reserved sentinel characters stay impossible in the output.

## Flags

- **A title after the marker departs from GitHub.** The intent's problem is that "the author sees something different from the reader". For `> [!WARNING] Data loss` GitHub shows a plain quote with the literal marker, while Downwrite (and its exports) show a callout. You chose this on 2026-10-12 over GitHub-exact. Everything else in the corpus matches GitHub, and the README will say titles are a Downwrite extension. The intent does not need amending: its open question 2 left titles open and its "Not in this change" list does not exclude them.
- **The type must stay readable without colour (intent).** Taking a title would have let a title replace the type name; you chose to keep the type name and add the title after it, so R6 and R8 meet the intent as written.
- **Sequencing (ROADMAP).** This change works in the styler, the analyzer and `DWLayoutManager`, so per the roadmap it must not run in parallel with DW-003 or DW-007. DW-012 (the last change in these files) is already released.
- **Working tree.** `docs/ROADMAP.md` has uncommitted edits (Todoist IDs) and `docs/backlog-items/BUG-fence-in-quote-or-list-marker-line-not-hidden.md` is untracked. Neither is touched here, and the approval commit takes `spec.md` only.

## Verification

"Working" means all of the following hold on a Mac with the display awake (`caffeinate -u -t 2`, `caffeinate -d` first, per CLAUDE.md).

1. `scripts/linux-test.sh` is green, including the new `CalloutTests` (the whole corpus above, the parity of editor and export, the lookups) and the colour tests for the six built-in themes and the 300 random imported themes.
2. `swift test` is green on macOS, including the callout editor tests (reveal re-styles exactly one line, typing and deleting a marker flips callout and plain quote, the announcement text, hidden lines draw nothing, the source view draws nothing) and `DrawingTests` (bar colour in the callout colour, the five icons pairwise different, the label's pixels sit on the marker line, a theme switch changes the colours).
3. `scripts/ci-local.sh --shots` is green, and its real-app step (`SelfTestCallout.swift`, run from an isolated-bundle-ID copy, a fresh ID each run) opens `Tests/Fixtures/callouts.md` and reports: every row of the corpus classified as the table says; the caret on a marker line shows the literal and the label returns when it leaves; folding the heading above a callout hides it and unfolding restores it; the source view shows plain text.
4. By eye, with `dist/Downwrite.app` and the fixture, in Downwrite light and dark, Catppuccin Latte and Mocha, Radix light and dark, and one imported VS Code theme: five callouts that are told apart by icon and name as well as colour; titles in bold callout colour; body text, lists and code inside read as quote text does today; plain-quote rows from the corpus look exactly as before; screenshots land in `docs/screenshots/` only through the usual `[shots]` route.
5. Export: File ▸ Export as HTML… and Export as PDF… of the fixture. The callout rows show the coloured bar, the type name and the title and not `[!NOTE]`; the plain-quote rows still show their literal text; the output is the same light page with the app in dark mode, with folds closed and with the source view on.
6. Cross-check with GitHub: `gh api markdown -f mode=gfm -f text="$(cat Tests/Fixtures/callouts.md)"` shows a `markdown-alert` for each corpus row the table marks "callout" for both, and none for the rows marked plain for both. The titled rows are the only ones where the editor shows a callout and GitHub does not.
7. VoiceOver: with VoiceOver on, moving the caret into a callout speaks "Note callout" once. If no one has run this by review time, `review.md` says it is still owed rather than claiming it.
