---
type: review
id: 2026-10-13-paste-and-drop-images
plan: ./plan.md
reviewed: 2026-10-14
base: main
head: 67b884f89682a67aaa24c34dbef15704725b29d6
reproven:              # blank on purpose: see "Proof after the fixes"
pr: https://github.com/derrickwheals/downwrite/pull/23
---

# Review: Paste and drop images into a document

## Summary

Important: 2 (fixed 2, disputed 0, open 0) · Nits: 3 (fixed 2, open 1)

The review was done by a fresh-context `pr-review-toolkit:code-reviewer` agent that took no part in the build, over `git diff main...67b884f` (24 files), running the three passes in `REVIEW.md` separately. The security pass came back clean: names and paths, the `O_EXCL` write, symlink handling, size and pixel limits checked before decoding, link encoding and special files (a FIFO and a symlink to `/dev/zero` named `.png`) were each checked and nothing was found. Every finding was re-verified against the code before it was acted on. Both Important findings are fixed in `557f08a`, each with tests that failed before the fix.

## Findings

| # | Category | Severity | Location | Finding | Failure scenario | Status |
|---|---|---|---|---|---|---|
| 1 | Bugs | Important | `Sources/Downwrite/EditorView.swift:225-236` (`applyExternalText`) with `Sources/Downwrite/EditorImages.swift:172-179` | A reload from disk writes the storage directly, so it never reaches `textView(_:shouldChangeTextIn:replacementString:)`, the only place the position of a waiting paste or drop is moved (R20). | A saved, unedited document holds `Hello world`, caret at 11. A large image is pasted and takes a second to convert. Meanwhile a sync client rewrites the file as `Note: Hello world` and the watcher reloads it. The job inserts at the old offset 11: `Note: Hello\n\n![](assets/…)\n\n world`. If the pending target was a selection (`world`), the pasted image replaced the reloaded text. | fixed (`557f08a`) |
| 2 | Bugs | Important | `Sources/DownwriteCore/ImageInsertion.swift:395-400` (`headingEnd`) | Any heading line whose first non-blank character is `#` was taken for a one-line ATX heading, but CommonMark needs a space, a tab or the end of the line after one to six `#`. | `#work #meeting\n---\nNotes` is a setext heading. Pasting with the caret in the first line gave `#work #meeting\n\n![](…)\n\n---\nNotes`: the heading became a paragraph and `---` a horizontal rule. The same for `#1 priority` over `=====` and for seven `#`. | fixed (`557f08a`) |
| 3 | Bugs | Nit | `Sources/DownwriteCore/ImageInsertion.swift:343-346` | A caret strictly inside a link, an image or a callout marker is refused, but one inside inline code or emphasis is not, and the paragraph split breaks those the same way. | The caret in the middle of the inline code span in "Run `npm install` now", between npm and install. The image lands between the two words and the code span is cut in two, so both backticks show as literal text. Undo restores it. | open |
| 4 | Conventions | Nit | `Sources/Downwrite/EditorView.swift:119-121` | The doc comment for the paste and drop job queue sat directly above the `promiseStarter` comment, so the two read as one, and its last clause described per-job caret state that the verification fixes removed. | Quick Help for `promiseStarter` shows the queue description. | fixed (`557f08a`) |
| 5 | Conventions | Nit | `CLAUDE.md:55` | The bullet said `EditorTextView` has five drag overrides; it has six (entered, updated, exited, prepare, perform, concluded). Four claim an image drag and two only clear the drop marker. | Someone following the bullet changes five and misses `draggingExited` or `concludeDragOperation`, and the drop marker stays drawn after a drag leaves. | fixed (`557f08a`) |

Finding 3 is left open on purpose: splitting a paragraph at the caret is what R11 specifies, and only the three constructs above were chosen to be refused. Refusing inline code and emphasis too, or moving the insertion to the end of the span, is a small follow-up if you want it.

Related, not changed here: the analyzer makes the same wrong guess as `headingEnd` did. In `MarkdownAnalyzer.heading` a first `#` means ATX, so the editor styles `#work #meeting` over `---` as an ATX heading and leaves the `---` line as plain body. That is older than this change. It only matters for placement if the caret sits inside the `---` line itself (a caret in the middle of the dashes would split them), which is very unlikely.

## Proof after the fixes

Re-run on 2026-10-14 against `557f08a`. Before the fixes, three of the four new tests failed for the reasons in findings 1 and 2 (the fourth, a real ATX heading above `---`, is a guard that passes either way); after them, all four pass.

- `scripts/ci-local.sh --no-e2e` (build, `swift test`, package the app): green. 568 app tests and 761 Core tests, 0 failures; the app packages.
- Core tests on Linux in the `swift:6.1-noble` image, one test per process (`scripts/linux-test.sh` itself does not run under this Mac's bash 3.2, so the same image and test binary were driven by a script): 761 of 761 passed, 0 failed, 0 wedged.
- Real-app step (`ci-local.sh`'s e2e arguments, from a copy of the app with a fresh bundle id so the saved preferences are untouched), run twice: **not green**. The 37 `imagepaste:` lines have 0 failures, and they include the four checks of the move-while-open scenario that the build record said were written but not run (open from another folder, move the document with its `assets/` folder while open, force a fresh render). Both runs fail the same 10 other checks: the Appearance tab is 633 pt against the 620 limit and two imported-theme-library checks (your eight imported themes, as in the build record), and seven SwiftUI-focus checks (⌘/ four times, Keep on Top twice, the fold commands). As a control, the unfixed commit `67b884f`, built and run the same way here, fails 9 of the same 10. The tenth, "⌘/ again returns to the formatted editor (light)", is a race: the check forces the source view when the first ⌘/ is not delivered and then passes only if the second ⌘/ is. The build record saw the seven focus checks pass in a run where the desktop was in front; here the terminal was.

`reproven` is left blank on purpose: the plan says every proof command must pass, and the real-app step has not passed in full in this environment. It should be set to `557f08a` once the e2e is run in a normal desktop session, or waived by you. The move-while-open check was uncommitted when those runs were made (it was compiled into the app from the working tree); it is committed in `c3aee74`, which changes only that file and the plan's notes about it.

## Not checked by the reviewer

The reviewer could not confirm these without a desktop session or a running app, so they stay with the human.

- How `NSTextView` calls the delegate for a multi-range change (Find ▸ Replace All) while a paste is pending: if it passes ranges in pre-edit coordinates, or only the first one, the pending place would drift.
- `PromisedFiles.wait()` has no timeout. If a source app never completes a file promise, that window's image queue waits for it and every later paste and drop queues behind it.
- Whether `NSApp.currentEvent` is a drag event during a real cross-app drag (the autoscroll in `draggingUpdated` relies on it). The build record says autoscroll was checked by hand.
- Whether two drop indicators can show at once when a drag moves between a refused place, where `super.draggingUpdated` is called, and an allowed one, where it is not.

## Disputed

None.

## Fed back to CLAUDE.md

- Added to *Things Claude gets wrong here*, both approved: a tracker that follows edits through `textView(_:shouldChangeTextIn:replacementString:)` misses code that writes the storage directly (`applyExternalText`), so route those writes through the same mover and test a reload while the tracked work is pending; and a line that starts with `#` is not necessarily an ATX heading (`#tag` over `---` is setext), so decide ATX as one to six `#` followed by a blank or the end of the line and test a `#tag` line above an underline.
- Not a proposal: the architecture bullet in `CLAUDE.md` was corrected in `557f08a`; it now names the reload path and the six drag overrides.
