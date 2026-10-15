---
type: review
id: 2026-10-15-harden-timing-sensitive-macos-tests
plan: ./plan.md
reviewed: 2026-10-15
base: main
head: b5a42c721ce474a46ecae17c8f97be044847df51
reproven:
pr:
---

# Review: Harden timing-sensitive tests on the macOS runner

## Summary

Important: 0 (fixed 0, disputed 0, open 0) · Nits: 3 (all open)

Reviewed by a fresh-context agent that did not take part in the build, with the three passes in `REVIEW.md` run separately (Bugs, Security, Conventions) over `git diff main...HEAD` and `plan.md` as the reference. No code changed during review, so nothing was re-proven; the proof recorded in `plan.md` and on the build card stands for `head`. `git diff main -- Sources` and `git diff main -- .github/workflows/release.yml` are both empty, and the net change to `ci.yml` is the one `TIMING:` grep line (no trace of the temporary `[repeat]` step). On the real runner (CI run 38698903822) the `TIMING:` lines printed intact in both jobs: Assemble ratio 4.1 to 4.6 against a limit of 8, Styler median-to-full-restyle ratio 0.049 to 0.060 against a limit of 0.25.

## Findings

| # | Category | Severity | Location | Finding | Failure scenario | Status |
|---|---|---|---|---|---|---|
| 1 | Bugs | Nit | `.github/workflows/ci.yml:52` (with `StylerTests.swift:224`, `DocumentAssembleTests.swift:288`) | `TIMING:` is written with `print()`, which is block-buffered when stdout is the `test.log` file, while XCTest's own lines go to stderr, so the anchored `^TIMING:` grep depends on where the buffer flushes fall. | A flush boundary falls inside a TIMING line and stderr lines splice in, leaving a cut-off `TIMING: styler move median=0.00`; or the xctest process crashes or hits the 10-minute step cap after the tests ran, and their buffered TIMING lines never reach `test.log`, which is the run where the margin is most wanted. Not seen in the 13 TIMING lines of run 38698903822. Fix: `fflush(stdout)` after each print, or write to stderr. | open |
| 2 | Conventions | Nit | `Tests/DownwriteTests/HTMLCardTests.swift:155` | The "checked precondition" asserts the width that `setFrameSize(500)` set one line above, so it can only fail if `setFrameSize` clamps; it cannot catch a column that narrows later. | If `pinColumnWidth()` stopped working (something sets `hasVerticalScroller = true` again), the column still reads 500 at line 155 and passes, then narrows to 483 only after the card has grown the document, during the 60 s wait; the cause then shows up only in the failed wait's message (which does carry `geometryReport()`). Fix: assert `!h.scroll.hasVerticalScroller` there, or check the width after the wait. | open |
| 3 | Conventions | Nit | `Tests/DownwriteCoreTests/DocumentAssembleTests.swift:279` | The test name still promises "WellUnderFiveSeconds", but on CI the only checks are the 8x ratio and a 30 s ceiling; the plan keeps the name on purpose. | A reader of a green CI run or the Release gate takes the name to mean R27's 5 s budget was enforced on the runner; a uniform 4x slowdown (up to 20 s) passes there. The doc comment explains it, the name and the XCTest output do not. Fix: rename (for example `testAMegabyteDocumentRendersInLinearTime`) or leave a `// R27` note at the call site. | open |

Security pass: no findings. The workflow edit is a constant `grep` over a local log file, with no interpolated input and no secrets.

## Disputed

None.

## Fed back to CLAUDE.md

Proposed, not added: each needs the maintainer's agreement first. None of the three Nits is a recurring mistake; these come from the build and its Deviations.

- Gotchas: Do not assert wall-clock budgets in a test that runs on the shared runner. Compare against a baseline measured in the same run (thread CPU time through `clock_gettime(CLOCK_THREAD_CPUTIME_ID)`, and a ratio such as `StylerTests.testLargeDocumentStylesQuickly`), and keep an absolute budget only when `CI` is unset.
- Gotchas: The editor's scroll view is legacy style in a test window (`EditorTextView.make()` asks for overlay and does not get it), so a vertical scroller takes 17 pt from the column once the document outgrows the window and a grid or card placed before it sits 8 pt off; a test that depends on the column width must call `EditorHarness.pinColumnWidth()`, and `TableLayoutTests.testGridFollowsTheColumnWhenTheScrollerComesAndGoes` is the one that exercises the scroller.
- Things Claude gets wrong here: A plan's claim that a test fails under a given mutation is checked by running the mutation before the plan is approved (DW-016's M3, removing `scheduleReposition()` from `setFrameSize`, failed none of the tests it was claimed to, because the layout-completion callback repositions too).
