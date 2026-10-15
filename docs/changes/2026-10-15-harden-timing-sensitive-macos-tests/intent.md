---
type: intent
id: 2026-10-15-harden-timing-sensitive-macos-tests
title: Harden timing-sensitive tests on the macOS runner
track: bug
status: accepted
raised: 2026-10-15
accepted: 2026-10-15
merged:
backlog: DW-016 (https://app.todoist.com/app/task/6hmGwrX9g6G74h5H)
---

# Harden timing-sensitive tests on the macOS runner

## Problem

Some tests in the macOS suite measure wall-clock time or wait for layout and web views to settle, and they fail intermittently on a slow macOS runner even though the code under test is correct. A failure blocks CI and, worse, the Release workflow: its `swift test` step stops the job on any failure, so one flaky test means no DMG and no release page until someone re-runs the job. Re-running the failed job passed in both v0.9.5 and v0.9.6.

Observed: the failing runs are the slow ones. The test step took about 350 to 370 s in the failing runs, against about 200 s when green. Expected: the same result on a slow runner as on a fast one.

Failures seen so far:

- `HTMLCardTests.testCardIsMeasuredAgainWhenTheColumnGetsNarrower`: "374.0 → 374.0", the card was not measured again within its 60 s wait. CI on 10 and 13 Oct, the first v0.9.5 Release run and the v0.9.6 Release run.
- `DocumentAssembleTests.testATwentyThousandLineMegabyteDocumentIsRenderedWellUnderFiveSeconds`: 7.3 s against a 5 s budget, v0.9.6 Release run. This is a Core test, so it also runs in the Linux job.
- `DocumentOutputControllerTests.testPreparingALargeDocumentForPDFNeverStallsTheMainThreadForLong`: its main-thread stall budget, in about a dozen failed runs on 10 to 13 Oct.
- `StylerTests.testLargeDocumentStylesQuickly`: 4.3 s against 3 s for the 50 caret moves, once.
- `FoldTests.testTablesAndDiagramsInsideAFoldAreHiddenReserveNothingAndComeBackInPlace`: a grid at x=62 where the text column implies 54, once, on the DW-002 merge commit. The same code had passed six runs and 20 local runs passed. This one is different in kind: its layout check polls for 8 s, so the grid stayed misplaced for the whole wait, which looks like a missed reposition after a width change rather than slowness.

Reproduction: there is none on a developer Mac. It happens only on the shared `macos-26` runner when it is slow, and a re-run of the same commit passes. Sources: CI run 38528751167 and Release runs 38335631788 and 38545051773 (GitHub Actions), 2026-10-14.

## Proposed outcome

A Release run, and a CI run, is never stopped by a test that measured the machine instead of the code. On a slow runner the five tests above give the same result as on a fast one. The performance tests still fail when the code gets meaningfully slower, and the layout tests still fail when a grid or card is really misplaced.

## Affected users and systems

The maintainer, who cuts releases: a flaky test costs a manual re-run of the Release job and delays the DMG and release page. Contributors see red CI for no reason.

Systems: the macOS test suite (`Tests/DownwriteTests`: `HTMLCardTests`, `DocumentOutputTests.swift`, `StylerTests`, `FoldTests`), one Core test that runs on both platforms (`Tests/DownwriteCoreTests/DocumentAssembleTests.swift`), and the `swift test` step of `.github/workflows/release.yml` and the macOS job in `ci.yml`.

## Constraints

- Keep the Release gate itself: the Release workflow still runs the tests and still stops on a real failure. The fix is in the tests.
- Don't just raise the numbers. The performance tests are there to catch real regressions, so a budget has to keep meaning something (for example by comparing against a baseline measured in the same run, or by counting work instead of raw seconds).
- Prefer waiting on a condition with a generous timeout over fixed sleeps.
- `DocumentAssembleTests` runs on Linux as well (`scripts/linux-test.sh`), so whatever replaces its budget has to work there too.
- The Release `swift test` step has `timeout-minutes: 10`, and the slow runs already take 350 to 370 s. The fix must not add to the test time.
- Behaviour that the tests check must not change. This item hardens tests; it does not change what the app does.

## Open questions

- The `FoldTests` failure looks like a missed reposition (a possible product defect), not a slow runner. Should it stay in this change, with a product fix if the cause is in the app, or be split off into its own item once the cause is understood? The card says to look at it separately.
- `HTMLCardTests` waited 60 s and the card was still not measured again. Is that slowness, or the same kind of missed reposition after `setFrameSize`? The answer decides whether it is a test fix or a product fix.
- With no local reproduction, what counts as proof that a test no longer flakes on a slow runner? This needs an answer in the plan.

## Decision

Accepted 2026-10-15 as a bug. The three open questions carry forward to the plan.
