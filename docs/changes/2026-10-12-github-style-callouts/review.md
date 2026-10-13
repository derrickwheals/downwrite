---
type: review
id: 2026-10-12-github-style-callouts
plan: ./plan.md
reviewed: 2026-10-13
base: main
head: 8429e9eb9e0f7f11484953c461c126d1614d613a
reproven: e0bdc5edfe756e5414756ffb3a1bd3f6602a7bdb
pr: https://github.com/derrickwheals/downwrite/pull/21
---

# Review: Show GitHub-style callouts (> [!NOTE]) as callouts

## Summary

Important: 1 (fixed 1, disputed 0, open 0) · Nits: 3 (fixed 1, open 2)

The review was done by a fresh-context subagent that did not take part in the build, run as the three passes in `REVIEW.md` over `git diff main...HEAD` at `8429e9e`, with `intent.md`, `spec.md`, `plan.md`, `CLAUDE.md` and `REVIEW.md` as reference. It built the tests, ran 248 Core tests and 149 app tests on the callout-related classes (0 failures) and probed `MarkdownAnalyzer.analyze` and `DocumentHTML.prepare` on 21 hand cases (an emphasis, code span or link split across the marker line, raw HTML and a comment split across it, a hard break, a lone backslash title, a footnote reference, an image and `U+E000` in the title, a combining accent after `]`, CRLF with and without a title, a thematic break and front matter before the quote, a second marker as the body, `]` inside the title). The editor ranges and the export markup agreed in all but two, both cosmetic (finding 4 and the already recorded backslash title). I checked the one Important finding against the code and reproduced it with a failing test before fixing it.

## Findings

| # | Category | Severity | Location | Finding | Failure scenario | Status |
|---|---|---|---|---|---|---|
| 1 | Bugs | Important | `Sources/Downwrite/EditorView.swift:483` | Entering a callout from a table that is shown through "Edit as Markdown" is not announced: that branch of `selectionChanged` calls `reanalyze()`, which records the active callout silently (`syncActiveCallout`, line 310), and returns before `announceCalloutIfEntered`. | A document with a grid table followed by `> [!WARNING] Data loss` and `> body`: right-click a cell, Edit as Markdown, click into "body". Nothing reaches `onAnnouncement` or `NSAccessibility`, and the next move inside the callout is silent too because the state already matches (R14). | fixed in `e0bdc5e`: the announcement runs before the re-analysis; `testLeavingATableShownAsMarkdownIntoACalloutIsAnnounced` failed before and passes after |
| 2 | Bugs | Nit | `Sources/Downwrite/EditorView.swift:470` | The same silent recording happens in a document over 400,000 UTF-16 units, where typing debounces the re-analysis by 150 ms: a click into a callout inside that window returns at the length guard of `selectionChanged`, and the debounced `reanalyze` then records the callout silently. | Type a character in a 500,000-character document and click into a callout within 150 ms: no "Note callout". The next entry after leaving is announced. | open: not fixed, because `selectionChanged` also runs before `textDidChange` on every keystroke and cannot tell a click from typing there; recorded in `plan.md` |
| 3 | Conventions | Nit | `CLAUDE.md` (Callouts bullet) and `Sources/DownwriteCore/Callouts.swift:41` | Both say the editor and the export "cannot disagree", but `plan.md` records a case where they do (P2, the export's footnote-definition pre-parse). | The document `[^1]: n`, `[!note]: u`, `> [!NOTE] x` is a plain quote in the editor (the marker is a link) and a callout in the export; a maintainer who trusts the comment will not look there. | fixed in `e0bdc5e`: both now name the exception |
| 4 | Conventions | Nit | `Sources/DownwriteCore/Callouts.swift:81` and `Sources/DownwriteCore/DocumentRenderer.swift:171` | A title that is only an HTML comment is a title for the editor and nothing for the export. | `> [!NOTE] <!-- c -->` then `> body`: the editor gives it a title range (bold title span and the kern for the gap), the export prints the type name, a space and no title because the sanitiser drops the comment. | open: cosmetic, sits beside the recorded backslash-title difference in `plan.md` |

### Security pass

No findings. Checked: the class names and the type name come only from the fixed `CalloutKind` enum (`rawValue`, `title`), never from document text; the title goes through `inlines(of:)`, which escapes text, and `U+E000` in a title comes out as `&#xE000;`, so the reserved characters `U+E000/E001/E002` cannot be produced; all output still passes through the unchanged `HTMLSanitizer.scan`, and the new CSS only adds colours for `callout-*` classes (raw HTML in a document could already carry a `class`, so borrowing the colouring gives it no new capability); `CalloutIcon` uses system SF Symbols only; no new file or network access and no new dependency.

### What the Bugs and Conventions passes checked and found clean

Recogniser: UTF-16 offsets throughout with no `String.Index` mixing, ASCII-only case folding, a tab after `>`, CRLF, a combining mark after `]`, a marker on the last line, lazy continuation, blank `>` lines first, nested quotes and quotes in lists; `firstContent` fails safe on a wrong offset. Export title split and the two binary-search lookups. Restyle on caret moves (the same lines as a plain quote), `hiddenCallout` taking the label branch only while the marker is hidden, the first bar level only, the palette `didSet` clearing the colour cache, label geometry computed at draw time. Announcement state: silent on typing, undo, redo, an external reload and leaving the source view, never sent in the source view, not repeated inside one callout, sent on every re-entry and when going from one callout straight into another. The tests the plan promises exist and exercise the behaviour. Placement in `DownwriteCore`, Linux-buildable Core, TextKit 1 only, no new dependency, CI and `ci-local.sh` consistent, no hard-wrapped prose in the new documents. The `docs/ROADMAP.md` edits go beyond the plan but were committed on the user's say-so (build stage), so they are not flagged.

## Proof after the fix

All commands under *Proof* in `plan.md` re-run on `e0bdc5e` (`reproven` above):

- `swift test --filter DownwriteCoreTests`: 629 tests, 0 failures. `swift test`: 433 app tests (432 plus the new one) and 629 Core tests, 0 failures.
- Linux, one test per process in the `swift:6.1-noble` image as CLAUDE.md's workaround says (`scripts/linux-test.sh` does not run under macOS's bash 3.2): 629 passed, 0 failed, 0 wedged.
- GitHub count: 27, as at `beee183`, and `Tests/Fixtures/callouts.md` is unchanged since. `gh` now answers "Bad credentials (HTTP 401)" (its keyring token is invalid), so the count was run against the same `POST /markdown` endpoint with `curl`, unauthenticated, instead of through `gh api`.
- `git diff --stat main --` over the files that must not change: prints nothing.
- Real app, from copies of `dist/Downwrite.app` with fresh bundle ids (the user's own app and preferences untouched), the same arguments as `scripts/ci-local.sh`'s e2e step but without `--shots`: the second run passed 270 checks and failed the same 3 environmental ones as the build stage (the user's own imported VS Code themes), with all 22 `callouts:` checks passing. The first run failed 6 more, SwiftUI-focus checks (⌘/ three times, Keep on Top twice, the fold commands being enabled), while another app was frontmost; none is a callouts check, and the repeat run with the same binary did not fail them.

## Checks owed by hand

Not run, because nothing here can: VoiceOver says "Note callout" once on entering a callout, then for another callout and again on re-entry (the new table-source route from finding 1 included); the fixture by eye in Catppuccin Latte and Mocha, Radix light and dark and one imported VS Code theme (only Downwrite light and dark were looked at, and Caution is not in frame there); File ▸ Export as HTML… and Export as PDF… of `Tests/Fixtures/callouts.md` with the app in dark mode, a fold closed and the source view on. `FEATURE-LIST.md` gets its row once a release tag exists.

## Disputed

None.

## Fed back to CLAUDE.md

- Added under *Things Claude gets wrong here* (with the user's agreement): a `selectionChanged` branch that re-analyses and returns early skips everything after it, and `reanalyze` records per-caret state silently, so per-move work such as an announcement must run before such a return, and a test must move the caret through that branch.
