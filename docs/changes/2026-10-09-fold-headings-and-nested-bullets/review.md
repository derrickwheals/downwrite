---
type: review
id: 2026-10-09-fold-headings-and-nested-bullets
plan: ./plan.md
reviewed: 2026-10-10
base: main
head: 7ba6328a19175eecdaa60d1ad39cffa464c193f8
reproven: 02fa7fa2ca966cf83ee78e037366c18729b4c434
pr: https://github.com/derrickwheals/downwrite/pull/15
---

# Review: Fold and unfold content under headings and nested bullets

## Summary

Important: 2 (fixed 2, disputed 0, open 0) · Nits: 1 (fixed 1)

The review was done by a fresh-context reviewer that did not write the code, running the three passes in `REVIEW.md` separately over the full diff against `main` (27 commits, 23 files). It found one Important bug and one Nit; the security pass had no findings. Finding 2 was found by the author while verifying finding 1, not by the reviewer, and has the same root cause. Both Important findings were reproduced on a plain `NSTextView` before being fixed, and the fix is in `2aa7bef` (`FoldState.openingBeforeDeleting` in Core, with tests that fail when the word handling or the ⌃⌫ override is switched off).

The plan's proof was re-run after the fixes and passed on `02fa7fa`, recorded as `reproven`. Locally on `2aa7bef` (the same code): `swift test` passed on its second full run (310 app tests and 335 Core tests, 0 failures; the first full run had two failures in `HTMLCardTests.testMermaidAndImageCardsAreUnaffected` and `MermaidTests.testBrokenDiagramShowsErrorCardWithoutBreakingEditor`, both Mermaid/WebKit card tests that passed alone and in the second run, and that nothing in this change touches); `scripts/build-app.sh` passed and bundled the legal files; `scripts/linux-test.sh` cannot run under this Mac's bash 3.2, so the same Docker image command was run directly, where a single process wedged and a one-process-per-class run plus a one-process-per-method run of the two classes that wedged ran all 335 Core tests with 0 failures; `scripts/ci-local.sh --shots` was not run locally, because its end-to-end step drives the packaged app with real input and writes the user's real Downwrite preferences. GitHub Actions run 38015275033 on `02fa7fa` then ran the rest: both jobs succeeded, with 645 macOS tests and 335 Linux tests at 0 failures, and the end-to-end self-test reporting ALL CHECKS PASSED (192 PASS lines, 0 FAIL, 42 of them folding), the same 192 as before the fix. The later commits on the branch only change `review.md`.

## Findings

| # | Category | Severity | Location | Finding | Failure scenario | Status |
|---|---|---|---|---|---|---|
| 1 | Bugs | Important | `Sources/Downwrite/EditorFolding.swift:275` (before the fix; the rule is now `FoldState.openingBeforeDeleting` in `Sources/DownwriteCore/Folding.swift`) | The Backspace-family guard only fires when the character just before the caret is hidden, so ⌥⌫ from just after `- ` or `## ` still deletes across the line break into hidden text, and ⌃⌫ (`deleteBackwardByDecomposingPreviousCharacter`) is not overridden at all. | Fold `- Groceries` in Fixture F (lines 27 to 30 hidden), put the caret after `- ` on `- Done` and press ⌥⌫: `deleteWordBackward` removes `Eggs.` and the line break and the text becomes `    Extra paragraph under Done`, joining a visible line to hidden text. After a folded `## Plan` that ends in a table, the caret at `## ` before `Notes` and ⌥⌫ join the table's last row to `Notes` and delete the heading marker. Reproduced on a plain `NSTextView`. | fixed in `2aa7bef` |
| 2 | Bugs | Important | `Sources/Downwrite/EditorFolding.swift:278` (before the fix) | Found by the author, not the reviewer: the forward guard has the same exact-position shape (only at the very end of the header), so ⌥⌦ from before a folded header's wordless tail still deletes into the hidden section. | `## Plan!` folded over `hidden words`, caret before the `!`, press ⌥⌦: AppKit removes `!`, the line break and `hidden`, and the text becomes `## Plan words`. Reproduced on a plain `NSTextView`. | fixed in `2aa7bef` |
| 3 | Conventions | Nit | `Sources/DownwriteCore/Folding.swift:52`, `Sources/Downwrite/EditorView.swift:89` | `FoldState.outermostFold(endingAt:)`, which the plan names as the R16 helper, had no production caller, and `EditorCoordinator.lastHidden` was widened from `private` with no user outside its file. | Someone fixes an R16 boundary bug in `outermostFold`, which the editor never calls, and ships believing it worked. | fixed in `2aa7bef` (the new guard calls `outermostFold`; `lastHidden` is `private` again) |

## Disputed

None.

## Not verified

These are things neither the reviewer nor the author could settle without the running app. They are not findings, because no failure was shown.

- Margin repaint after an edit: `reanalyze` sets `hoveredFoldRange = nil` (`Sources/Downwrite/EditorView.swift:273`) without invalidating the margin band, so a hover chevron might leave a ghost when lines shift under a pointer that has not moved. It depends on whether TextKit 1 invalidates the inset margin on re-layout.
- The greying of the five fold menu items in the source view, and a fold command while a table cell's own text view is first responder. Both need a live SwiftUI focused scene. The plan records the greying as checked by hand.
- The find bar's own Replace All path (recorded in the plan as not machine-verified).
- The reviewer did not read `SelfTestFold.swift` past its setup, and spot-checked only R7, R13, R14, R16, R20 and R23 in the plan's coverage table.

## Fed back to CLAUDE.md

One line, added with the user's agreement under "Things Claude gets wrong here": "Guards on editing commands are decided by what AppKit does, not by the spec's wording: the word deletes (⌥⌫, ⌥⌦) skip punctuation and line breaks and ⌃⌫ is its own selector, so probe a plain `NSTextView` first, guard every variant, and test each one."
