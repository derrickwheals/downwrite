---
type: plan
id: 2026-10-15-harden-timing-sensitive-macos-tests
intent: ./intent.md
status: in-progress    # draft | approved | in-progress | done
approved: 2026-10-15
branch: change/2026-10-15-harden-timing-sensitive-macos-tests
---

# Plan: Harden timing-sensitive tests on the macOS runner

## Approach

The five tests are three different problems, so each gets its own fix, and none of them touches the app. **Two performance tests** (`DocumentAssembleTests` R27, `StylerTests.testLargeDocumentStylesQuickly`) compare wall-clock seconds with a fixed budget, so they measure the machine. I reproduced both failures on this Mac by starving the CPU, and they get a baseline measured in the same run instead: the thread's CPU time (descheduling does not count), and a ratio. The Assemble test asserts that a 4× larger document costs at most 8× the time (a linear pass costs 4.2 to 4.4×, a quadratic one 16×). The Styler test asserts that the median caret move costs at most a quarter of one full restyle of the same document (15× today; a regression to restyling everything on every move costs 1×). The old absolute budgets stay for a developer Mac (no `CI` variable), measured in CPU time, because a regression there is real and the machine is known. **Two layout tests** (`FoldTests`, `HTMLCardTests`) wait for geometry to settle. The Fold failure has the signature of the vertical scroller: this scroll view is in legacy style (it asks for overlay and does not get it), the scroller takes 17 pt when the document outgrows the window (900 → 883, text inset 90 → 82), and a grid placed before that sits 8 pt to the right: x=62 against 54, the numbers in the failed run. Those two tests pin the scroller off so the column width cannot change under them, and a new dedicated test keeps the "grid follows the column when the scroller comes and goes" behaviour guarded. Both get failure messages that report the geometry, so a further failure names its cause. **The stall test** was already hardened on 13 Oct (`daca1a0`) and has no recorded failure since, so its assertion stays; only its fixed 120 s wait for the printing step changes, because that is the first thing to break under a 5× slowdown.

The alternative, raising the numbers, would leave the performance tests unable to fail on a fast machine and still flaky on a slower one.

## Reproduction

**Performance tests: reproduced.** On an idle Mac (10 cores) the five tests take 0.2 to 3.5 s and pass. With 50 busy loops competing for the CPU (about 5×), the two performance tests fail with the CI signature:

| Test | Idle | 50 busy loops | CI failure |
|---|---|---|---|
| Assemble, 22,004 lines | 1.17 s | **8.03 s** vs 5 s | 7.3 s vs 5 s |
| Styler, 50 caret moves | 0.8 s whole test | **3.38 s** vs 3 s | 4.3 s vs 3 s |

With 14 busy loops (about 1.4×), three loops of all five tests passed, so ordinary contention is not enough; it takes a runner about 5× slower. Recipe (bash; stop the loops afterwards): `caffeinate -d -t 600 & for i in $(seq 50); do (while :; do :; done) & done`, then `swift test --skip-build --filter '<test>'`, then `kill $(jobs -p)`.

**Stall test: not a current failure.** The six runs I read that failed its stall limit (38130377652 to 38336708608, 11 to 13 Oct, 0.28 to 0.47 s against 0.25 s) all came before `daca1a0` (13 Oct 03:03Z), which made the CI limit half the preparation time. Of the 18 CI and Release runs after it, three failed (an end-to-end callout check, the Fold test, and v0.9.6 Release attempt 1, whose log can no longer be fetched; the intent names HTMLCard and Assemble for it), and none for this test as far as the logs show. With `CI=1` and 50 busy loops the stall assertion holds (1.69 s of 8.96 s preparing, limit 4.5 s), but the test fails at `rig.finish(timeout: 120)` because the whole export took 123 s.

**Fold test: not reproduced, mechanism identified.** The failed run (38528751167, `FoldTests.swift:349`, the first check, before any fold) reported `grid 0 starts at x=62.0 but the text column implies x=54.0`. Here the scroll view's `scrollerStyle` is raw value 0 (legacy) although `EditorTextView.make()` sets `.overlay`, and the fold fixture is 1,402 pt tall in a 760 pt window, so the scroller is shown: clip and text view 883 wide, inset 82, grid x 54. Without it they are 900, 90 and 62. So 62 is the grid placed before the scroller appeared and 54 is the column after it; the grid was not moved in the 8 s wait. A probe that took the scroller away and brought it back (900 → 883) showed the grid stale for one run-loop turn and aligned again well inside the 8 s wait, so I could not make the app miss the reposition. That is why this plan treats it as a test problem and says what would change that (Decision 1).

**HTMLCard test: not reproduced, cause unknown.** Locally the whole test takes 0.3 s. The failures are on the second wait (`374.0 → 374.0`, the card was not measured again after the column narrowed), not the first, and a 60 s wait did not help, so it is not patience. The same scroller feedback is possible here (a narrower column makes the card taller, the document outgrows the window, the scroller appears, the column narrows by 17 pt and the card is measured a second time), and a probe showed exactly that: the text view ended at 483 wide, not 500. I cannot show that this is the cause.

## Decisions

Each is a choice for you to approve with the plan. They answer the intent's three open questions.

1. **The Fold failure stays in this change as a test fix; the app is not touched.** The intent's constraint is that this item does not change what the app does, the numbers fit a late scroller exactly, and the app re-places the grid when I make that happen. A follow-up product item is warranted only if the new dedicated scroller test (step 6) ever fails, or the pinned Fold test still fails; its failure message will show the geometry. If you would rather the Release gate not depend on that behaviour until it is understood, say so and I will leave the dedicated test out and file the follow-up now.
2. **The HTMLCard failure is not slowness, and I am less sure of its fix than of the others.** It gets the same pinning and a failure message that asks the page itself what width it was laid out at and how tall it is (bounded to 5 s), so the next failure says whether the card never re-rendered or measured at the old width. If the repeated CI run in step 9 still fails it, I stop and report with that output rather than widening waits, and the product question becomes its own intent.
3. **What counts as proof without a local reproduction.** For the two performance tests: red then green under the 50-busy-loop recipe. For the two layout tests: no reproduction exists, so the proof is (a) the mechanism-targeted change, (b) mutation checks showing each test still fails when the app is broken, (c) 30 consecutive passes of both under load locally (step 8) and 20 on the real runner (step 9), and (d) the next normal CI runs staying green. This is evidence, not proof of absence, and the PR will say so.
4. **Relative checks are blind to a uniform slowdown on CI.** A change that makes everything 3× slower passes the ratio. The absolute budgets stay off CI, in CPU time, so a developer running `swift test` or `scripts/ci-local.sh` before pushing still gets them. If you want an absolute check on CI as well, it needs a baseline we do not have; I would not guess one.
5. **The stall test's assertion does not change.** Only the wait for the printing step does, from 120 s to 300 s. If you would rather leave that test untouched until it fails again, drop step 5.
6. **Two small workflow changes, both in `ci.yml` only.** The "Unit and integration tests" step also prints the `TIMING:` lines the reworked tests emit (so the margin on the real runner is visible when they pass), and a `[repeat]` commit-message marker, like `[shots]`, runs the layout tests 20 times and the performance tests 5 times. The repeat step is removed in step 10 and `release.yml` is not changed.

Also noted, outside this change: the Release workflow's "Run tests" step includes compiling and took 8 min 04 s and 8 min 43 s on the two v0.9.6 attempts against its `timeout-minutes: 10`. A slower day would stop the Release on the timeout instead of on a test. Moving the build to its own step, or raising the cap, is a workflow decision for you; it could be a backlog item.

## Files that change

Tests (macOS):

- `Tests/DownwriteTests/Harness.swift` — add `cpuSeconds(_:)` (the calling thread's CPU time through `clock_gettime(CLOCK_THREAD_CPUTIME_ID)`), `EditorHarness.pinColumnWidth()` (no vertical scroller, tile) and `EditorHarness.geometryReport()` (window, screen, scroll, clip and text view widths, scroller style and visibility, grid frames) for failure messages.
- `Tests/DownwriteTests/StylerTests.swift` — `testLargeDocumentStylesQuickly` (`:205`): median caret move against a full `restyleAll()`, `TIMING:` line, absolute assertions off CI in CPU time, the 10 s initial-style assertion unchanged.
- `Tests/DownwriteTests/FoldTests.swift` — `fixtureHarness` (`:277`) pins the column; `layoutProblems` (`:286`) appends `geometryReport()` to what it returns.
- `Tests/DownwriteTests/HTMLCardTests.swift` — `testCardIsMeasuredAgainWhenTheColumnGetsNarrower` (`:129`): pinned column, a checked precondition (the text view really is 500 wide after the resize), and the page's own width and height in the failure message.
- `Tests/DownwriteTests/TableLayoutTests.swift` — new `testGridFollowsTheColumnWhenTheScrollerComesAndGoes` next to `testSqueezingTheColumnKeepsGridsAligned` (`:41`).
- `Tests/DownwriteTests/DocumentOutputTests.swift` — `testPreparingALargeDocumentForPDF…` (`:899`): `rig.finish(timeout: 300)` and a comment saying why.

Tests (Core, also run on Linux):

- `Tests/DownwriteCoreTests/DocumentAssembleTests.swift` — `testATwentyThousandLineMegabyteDocumentIsRenderedWellUnderFiveSeconds` (`:237`): a private `cpuSeconds` and the scaling assertion; the output assertions (`> 500,000` characters, 20 image sources, 20,000+ lines, 900,000+ bytes) are unchanged.

Workflow:

- `.github/workflows/ci.yml` — print `TIMING:` lines from `test.log` in the test step; a temporary `[repeat]` step (removed in step 10). `release.yml` is not changed.

Docs:

- `docs/changes/2026-10-15-harden-timing-sensitive-macos-tests/plan.md` (this file), `review.md` (at review).
- `CLAUDE.md` — at review, two lines under *Gotchas*: do not assert wall-clock budgets (use thread CPU time and a ratio), and the scroll view is legacy style here (17 pt) so a test that depends on the column width must pin it. Not part of the build.

No file under `Sources/` changes.

## Order of work

Each step is one commit on the branch; tests that can fail first come before the change that fixes them.

- [x] 1. Branch `change/2026-10-15-harden-timing-sensitive-macos-tests` from `main`. Add the helpers to `Harness.swift` (`cpuSeconds`, `pinColumnWidth`, `geometryReport`) and a private `cpuSeconds` in `DocumentAssembleTests.swift`. No test changes yet. `swift build --build-tests` passes.
- [ ] 2. Re-run the 50-busy-loop recipe on the untouched tests and put the numbers in this commit message (an empty commit): Assemble and Styler fail, as in Reproduction. This is the "red".
- [ ] 3. Assemble: replace the wall-clock budget with the scaling check. The 250-section document (5,504 lines) is timed twice in CPU seconds and the smaller time kept; the 1,000-section document once; assert `big <= 8 × small`, and `big < 30` always, and `big < 5` when `CI` is unset. Print `TIMING: assemble big=… small=… ratio=…`. Runs on Linux too.
- [ ] 4. Styler: time `restyleAll()` twice (keep the smaller) after the initial style; time each of the 50 caret moves in CPU seconds; assert `median(move) <= fullRestyle / 4`, and `sum(moves) < 3` when `CI` is unset. Print `TIMING: styler move median=… full restyle=… ratio=…`.
- [ ] 5. Stall: `rig.finish(timeout: 300)` at `:899`, with a comment that the printing step took 123 s at 5× slowdown and is not what R27 limits.
- [ ] 6. Fold and the dedicated test: `fixtureHarness` calls `pinColumnWidth()`; `layoutProblems` returns the geometry report with the problems. Add `testGridFollowsTheColumnWhenTheScrollerComesAndGoes` (unpinned harness on the fold fixture; wait for it to settle; hide the scroller and tile; settle; show it and tile; assert `layoutProblems()` empties within 8 s, with the report in the message).
- [ ] 7. HTMLCard: `pinColumnWidth()`, assert `h.textView.frame.width` is within 1 pt of 500 after the resize before waiting, and on a failed wait ask the card's page for `innerWidth` and `#dw-root` height (5 s limit) and include them with `geometryReport()`.
- [ ] 8. Local proof, no commit unless it finds something: mutations M1 to M4 from the Proof table (each applied, the named tests shown failing, then reverted and `git diff -- Sources` shown empty); then the Assemble, Styler, Fold, HTMLCard and TableLayout tests under the 50-busy-loop recipe, the Styler and Assemble ones once and the three layout ones 30 times each; then the stall test once with `CI=1`.
- [ ] 9. `ci.yml`: print `TIMING:` lines, add the temporary `[repeat]` step. Push the branch with `[repeat]` in the message and read the run. If either layout test fails in the repeats, stop, post the diagnostics to the card and ask you how to proceed (Decision 2).
- [ ] 10. Remove the `[repeat]` step. Update *Deviations* below for anything that departed from this plan, in the same commit as the departure.

## Risks

- **The ratio and the median are less sensitive to a uniform slowdown on CI** — the absolute budgets stay off CI in CPU time, so a developer's pre-push run still has them, and the mutation checks below show the relative checks catch the regressions they are for (Decision 4).
- **Thread CPU time assumes the work runs on the test's thread** — true today for `prepare`/`assemble` and for caret moves on the main thread. If the work goes parallel, CPU time undercounts both sides; the ratio stays meaningful, and the comment in each test says so. `CLOCK_THREAD_CPUTIME_ID` must work in the Swift Docker image: step 3 is checked with `scripts/linux-test.sh` before anything else.
- **Pinning the scroller makes the Fold and HTMLCard tests exercise less** — the scroller behaviour moves to the dedicated test, and `TableLayoutTests` already covers width changes. The dedicated test can itself flake if the app has a rare missed reposition; that is the evidence the follow-up needs, and Decision 1 lets you opt out.
- **The HTMLCard cause is not established** — step 7 may reduce the rate without removing it. The plan does not claim otherwise, and step 9 is a stop-and-ask point rather than a retry loop.
- **The new checks add test time** — about 0.8 s on a Mac (two 0.27 s runs of the small document, two 0.15 s restyles), about 5 s on the runner, roughly 1% of the step. I did not trade other tests away to offset it.
- **Mutation checks edit app code on purpose** — each is reverted before the commit; step 8 and the verifier check `git diff -- Sources` is empty.
- **Busy loops left running** — every recipe starts them in a shell that kills them on exit, and the verifier checks `pgrep` afterwards.

## Proof

Tests to add or change:

- `DocumentAssembleTests.testATwentyThousandLineMegabyteDocumentIsRenderedWellUnderFiveSeconds` — a 4× document costs at most 8× the CPU time (idle: 4.2 to 4.4×), with an absolute CPU-time budget off CI. Fails on a quadratic pass, passes at 5× contention.
- `StylerTests.testLargeDocumentStylesQuickly` — the median caret move costs at most a quarter of a full restyle (idle: 1/15). Fails if a caret move restyles everything, passes at 5× contention.
- `TableLayoutTests.testGridFollowsTheColumnWhenTheScrollerComesAndGoes` — a grid placed with the scroller hidden is aligned again within 8 s of the scroller returning.
- `FoldTests.testTablesAndDiagramsInsideAFoldAreHiddenReserveNothingAndComeBackInPlace` and `HTMLCardTests.testCardIsMeasuredAgainWhenTheColumnGetsNarrower` — same assertions as today on a column whose width is constant, with the geometry in the failure message.
- `DocumentOutputControllerTests.testPreparingALargeDocumentForPDFNeverStallsTheMainThreadForLong` — same assertions; the wait is 300 s.

Must pass before the change is complete:

```
scripts/linux-test.sh                 # Core, including the reworked Assemble test (per-process fallback in memory if Docker wedges)
swift build --build-tests && swift test
scripts/ci-local.sh --no-e2e
git diff main -- Sources              # empty
```

Under load (bash; loops killed afterwards): with 50 busy loops, the Assemble, Styler, Fold, HTMLCard and TableLayout tests pass; the stall test passes with `CI=1`.

Intent outcomes against proof:

| Outcome in the intent | Proven by |
|---|---|
| A run is never stopped by a test that measured the machine | Step 2 red and step 3/4 green at 50 busy loops; 30 runs of each layout test under load locally (step 8) and 20 on the runner (step 9); the next normal CI runs |
| The performance tests still fail when the code gets meaningfully slower | Mutation M1: an O(n²) pass over the lines in `DocumentHTML.assemble` fails the Assemble test. Mutation M2: `restyleAll()` called from `EditorCoordinator.selectionChanged` fails the Styler test. Both reverted |
| The layout tests still fail when a grid or card is really misplaced | Mutation M3: remove `coordinator?.scheduleReposition()` from `EditorTextView.setFrameSize` (`:83`) and the dedicated scroller test, `testSqueezingTheColumnKeepsGridsAligned` and the HTMLCard test fail. Reverted |
| The Release gate is kept | `release.yml` and the `swift test` step are unchanged; `git diff main -- .github/workflows/release.yml` is empty |
| The fix does not add to the test time | Measured in the step 3 and 4 commit messages: about +0.8 s on a Mac |

## Deviations

None yet. Filled during build, one line per departure, in the same commit as the code that departs.
