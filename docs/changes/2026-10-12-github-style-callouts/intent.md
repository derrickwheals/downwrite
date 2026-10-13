---
type: intent
id: 2026-10-12-github-style-callouts
title: Show GitHub-style callouts (> [!NOTE]) as callouts
track: feature
status: accepted
raised: 2026-10-12
accepted: 2026-10-12
merged:
backlog: "DW-006 (docs/ROADMAP.md#dw-006--github-style-callouts)"
---

# Show GitHub-style callouts (> [!NOTE]) as callouts

## Problem

Roadmap item DW-006. `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]` and similar render as coloured callouts on GitHub and in several editors, and documentation written for GitHub uses them heavily. In Downwrite they show as a plain quote with the literal `[!NOTE]` text, so the author sees something different from the reader. A search of `Sources/` and `Tests/` on 2026-10-12 finds no callout handling: a block quote is a `.quote` span with a `quoteDepth` per line, drawn with a bar, and nothing looks at the first line's content. The same gap exists in print, PDF and HTML export, which emit a plain `<blockquote>`, so the exported page shows the literal `[!NOTE]` too. (The wording of the problem comes from the roadmap, so please correct it if it is off.)

## Proposed outcome

- A block quote whose first line is a callout marker of a supported type (for example `> [!NOTE]`) is shown as a callout: a coloured bar and a label naming the type ("Note"), with the marker text itself hidden while the caret is away from it, like other Markdown syntax. The rest of the quote is the callout's body, and paragraphs, inline formatting, lists and code inside it behave as they do inside a quote today.
- Each supported type is visibly distinct, and the type is readable from the label as well as the colour, so it does not depend on colour alone.
- While the caret is on the marker line the literal `[!NOTE]` shows so it can be edited, and when the caret leaves it the callout comes back. Typing a marker onto an existing quote turns it into a callout, and deleting it turns it back into a plain quote.
- A quote that is not a recognised callout (an unknown type, a marker that is not on the first line) is unchanged: same bar, same indent, same marker hiding.
- The file on disk is untouched and stays valid Markdown. Anywhere else (GitHub aside) it degrades to an ordinary quote.
- Print, PDF and HTML export show the callout as a callout instead of the literal marker text, in the fixed light page, from the document text alone.
- The Markdown source view (⌘/) shows the plain text as it does for everything else.
- A VoiceOver user can tell what kind of callout they are in.
- Not in this change: user-defined callout types, a settings pane for callouts, syntax highlighting (DW-003), focus mode (DW-007), and the wider accessibility audit (DW-011), which this change only feeds with whatever it draws.

## Affected users and systems

Anyone who writes READMEs, documentation or notes meant to be read on GitHub, or who opens such files from a repository, which is most Markdown users.

Parts of the system involved (as known now, to be confirmed in the spec and plan):

- `DownwriteCore`: `MarkdownAnalyzer.blockQuote` and `quoteMarkers` (quote lines and their `> ` markers), `Analysis.swift` (a record per callout and its type, the way `CodeBlockInfo` records a code block), and tests that run on Linux.
- `Palette` and `ThemeCatalog`, `VSCodeTheme.convert`: callout colours have to exist in every built-in theme and in imported VS Code themes, within the legibility floors asserted by `ThemeCatalogTests` and `VSCodeThemeTests`.
- `Sources/Downwrite`: `MarkdownStyler` (the quote branch sets the indent and the `.dwQuoteDepth` / `.dwQuoteBarColor` attributes), `DWLayoutManager` (draws the quote bar and would draw the label), and `EditorCoordinator` (reveal of the marker line).
- `DocumentRenderer`, `HTMLSanitizer` and `PrintStyle` (`DocumentHTML`): export emits `<blockquote>` today.
- Folding (`MarkdownAnalysis.foldRegions`, `FoldState`): a callout inside a folded heading or list item has to hide and reveal with it.
- `README.md` and `FEATURE-LIST.md` once it ships.

## Constraints

- Markdown and block-boundary decisions live in `DownwriteCore` and are unit-tested on Linux; the app target only draws and handles reveal. Project rule.
- Offsets are UTF-16. Hiding is the 0.1 pt clear font on marker characters, never deleting text, and the reveal rule is inclusive of both boundaries.
- Keep the app light: no new dependencies.
- Colours come from the `Palette` and must read in every built-in and imported theme, in light and dark, without breaking the existing legibility tests (including the 300 random imported themes).
- The styler is sensitive to performance because lines are restyled as the caret moves; moving the caret across a callout must not restyle more than the lines whose look changed.
- Existing quote behaviour is unchanged for anything that is not a callout: quote bar, 16 pt indent per depth, nested quotes, `> ` marker hiding, and a code block inside a quote.
- The editor's other behaviour is unchanged: folding, the source view, the table and diagram overlays, the contents sidebar, the code-block copy control and external-change reload.
- Print, PDF and HTML output may depend only on the text, the document's name and folder, and the files and diagrams the text refers to; they never read the theme, settings, folds or the source view. The sanitiser's adversarial tests stay green.
- Sequencing, from the roadmap: this touches the styler, the analyzer and `DWLayoutManager`, so it should not run in parallel with DW-003 or DW-007. It can run beside DW-002 and DW-010.

## Open questions

1. **Which types?** GitHub defines five (Note, Tip, Important, Warning, Caution). Obsidian and other editors accept many more (info, success, question, danger, bug, example, quote and so on). Five only, or a wider set, and what happens to a type that is not in the set?
2. **Which variants of the syntax?** Lower-case types (`[!note]`), a custom title after the marker (`> [!NOTE] My title`), and foldable `[!note]+` / `[!note]-`. Foldable callouts imply a collapse control and a state that is not in the file, which is a second concept. In scope, or recognised-but-ignored, or left as plain quotes?
3. **What counts as a callout?** Marker on the first line only; whether other text may follow it on that line; a callout nested inside another quote or inside a list item (HTML blocks are top-level only today); an empty callout with only the marker line.
4. **How does it look?** Bar colour and label are given; open are a background tint, an icon, and how the label gets its room (the marker line becomes the label line, or a label is drawn over it). Whether each theme gets new `Palette` fields or the colours are derived from existing roles, which decides how imported VS Code themes get callout colours.
5. **What reveals the marker?** The caret anywhere on the marker line, or anywhere in the callout, matching the Bear-like rule for other pairs.
6. **How do callouts interact with folding?** The roadmap names this as a decision. The simplest answer is that a callout is not a fold region of its own and only folds with its heading or list item.
7. **Is export in this change?** The outcome above includes it, because otherwise the reader of an exported file sees the literal marker. It could instead ship as a follow-up if the layout of a callout on the printed page turns out to be its own piece of work.
8. **What about the open bug about fences inside quotes?** `docs/backlog-items/BUG-fence-in-quote-or-list-marker-line-not-hidden.md` (not yet committed) records that a fenced code block inside a quote never hides its fence lines. A code block inside a callout is a likely thing to write, so the question is whether to fix that first, alongside, or leave it.

## Decision

Accepted on 2026-10-12 as a feature, so the next stage is the spec. The open questions above carry forward to it, and the spec answers them for approval.
