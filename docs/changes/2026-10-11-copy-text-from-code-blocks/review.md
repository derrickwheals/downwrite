---
type: review
id: 2026-10-11-copy-text-from-code-blocks
plan: ./plan.md
reviewed: 2026-10-11
base: main
head: 72544481fd88e8bfb7c1694478ddede5b19b804b
reproven:
pr: https://github.com/derrickwheals/downwrite/pull/20
---

# Review: Copy the text of a code block with one click

## Summary

Important: 0 (fixed 0, disputed 0, open 0) · Nits: 2 (both open)

The reviewer was a fresh-context `pr-review-toolkit:code-reviewer` agent that took no part in the build. It ran the three `REVIEW.md` passes separately over `git diff main...HEAD` at the head above, read every changed production file in full plus the new and changed tests, and checked each Deviation in `plan.md` against the code. It ran `swift test --filter DownwriteCoreTests.CodeBlockTests` (30 tests, 0 failures). It did not run the app-target tests (`CodeCopyTests`, `DrawingTests`), the packaged-app end-to-end, or Docker. No code was changed during the review, so nothing was re-proven; `reproven` stays blank.

Pass results: **Bugs** no findings (stale indices, the tick timer, the click path, copied-text correctness, geometry and performance, test strength and every Deviation traced). **Security** no findings (plain text to the pasteboard only; nothing leaves the machine; every test and the self-test step use a private named pasteboard; `--selftest-codecopy-only` takes no value). **Conventions** two Nits below.

## Findings

| # | Category | Severity | Location | Finding | Failure scenario | Status |
|---|---|---|---|---|---|---|
| 1 | Conventions | Nit | `CLAUDE.md:53` | The new Architecture bullet has an unmatched `*` (five on the line: `*drawn*`, `*and carries …`, `*after*`). | Rendered on GitHub, the text from "and carries `.dwBlockBackground`" to "paints it" comes out in italics and a stray literal `*` appears before "after". Fix: close the emphasis after "carries `.dwBlockBackground`", or drop it. | open |
| 2 | Conventions | Nit | `Tests/DownwriteTests/CodeCopyTests.swift:309` | `armed()` creates a uniquely named `NSPasteboard` per test and never calls `releaseGlobally()`, unlike the self-test step (`SelfTestCodeCopy.swift:42`). | Each `swift test` run leaves about 20 `downwrite.test.codecopy.<UUID>` pasteboards in the pasteboard server until logout. Fix: `addTeardownBlock { pb.releaseGlobally() }` in `armed()`. Changing it is a code change, so the whole Proof would have to be re-run. | open |

Both were verified against the files by the reviewer and again by the agent that ran the review.

## Proof and manual checks

From `plan.md` (Proof results, build stage 2026-10-11, macOS 27.0.1, Xcode 27.0) and the verifier's run; not re-run in this review.

- `swift test` (macOS): `DownwriteTests` 400 and `DownwriteCoreTests` 563, 0 failures.
- Linux (Core) by the recorded workaround, because `scripts/linux-test.sh` fails under macOS's bash 3.2 and a whole-suite process wedged: 25 of 26 classes passed whole; `FoldingTests` timed out as a class ten times in a row and then passed 62 of 62 with one test per process. All Core tests pass on Linux.
- `git diff --stat main --` over the seven print and export files prints nothing.
- End-to-end in an isolated bundle-ID copy: 248 checks passed, including all 30 `codecopy:` checks. Three checks failed and are not about this change (the Appearance tab height, 633 pt against a 620 pt limit, and two "library is empty" checks that the Mac's shared imported-theme folder breaks); no Settings or theme code is in this diff. Not proven by a run on `main`.
- **Gap to know about:** after the independent verifier (PASS) two follow-ups were made: one Core test added (`CodeBlockTests` now 30, so Core is 564 tests) and the accessibility getter no longer runs a pending analysis. `CodeBlockTests`, `CodeCopyTests` and `DrawingTests` were re-run green (85 tests), but the full suites, the Linux run and the end-to-end were not repeated after them, and the verifier was not run a second time.
- Confirmed by hand on 2026-10-11: ⇧⌘C in the running app with the caret in a code block copies the whole block, so the shortcut stays.
- **Owed by hand:** the VoiceOver walk-through (actions menu and the "Copied code block" announcement, from the action and from Edit ▸ Copy Code Block); looking at a block whose first line reaches the right edge (pixel-tested, not looked at).
- Unchanged and out of scope: the ⌘C-of-a-selection problem (D8); `FEATURE-LIST.md` (D9, a row is owed only if this is ruled a feature and tagged).

## Disputed

None.

## Fed back to CLAUDE.md

- Added to *Things Claude gets wrong here* (agreed 2026-10-11, from Nit 2): tests that create a named `NSPasteboard` must release it in a teardown (`addTeardownBlock { pb.releaseGlobally() }`), as `SelfTestCodeCopy` does. The test in `CodeCopyTests.swift` is not changed by this review (Nit 2 stays open), so it still departs from the new line.
