---
type: review
id: 2026-10-18-editor-view-jumps-while-typing
plan: ./plan.md
reviewed: 2026-10-22
base: main
head: 6be42f8124be813386a63d5ba8e281fdde0a6d9a
reproven:               # not yet: see Proof status
pr:
---

# Review: Editor view jumps while typing

## Summary

Important: 2 (fixed 2, disputed 0, open 0) · Nits: 3 (fixed 2, open 1)

Findings 1 to 4 are from a fresh-context subagent that took no part in the build; finding 5 was found afterwards, from the local e2e run. The subagent reviewed against `REVIEW.md`'s three passes (bugs, security, conventions) over `git diff main...HEAD` (merge base `1c42102`). Security: nothing found. In the bugs pass the reviewer checked that styling a detached copy gives the same attributes as styling in place (the line functions read only the text, never existing attributes), the run-boundary and pending-stretch logic in `StyleDiff`, value equality of every attribute the styler sets, and that `scrollTarget` laying out the whole container costs nothing extra under contiguous layout. Those held.

## Findings

| # | Category | Severity | Location | Finding | Failure scenario | Status |
|---|---|---|---|---|---|---|
| 1 | Bugs | Important | `Tests/DownwriteTests/StylerTests.swift` (`testRestylingCostsLittleMoreThanStyling`) | The cost test's "styling alone" baseline went through the public `styleAll(storage:)`, which makes the same detached copy and runs the same `StyleDiff.apply`, so the test could not see the copy or the comparison get slower. | Add eight `storage.attributes(at:)` lookups per character to `StyleDiff.apply`: both sides of the ratio grow, the ratio stays near 1, and the test passes while every keystroke in a 180 KB document gets slower. | fixed |
| 2 | Conventions | Nit | `Tests/DownwriteTests/TypingStabilityTests.swift:6` | The header comment says the stillness tests guard the restyle; after the amendment they guard contiguous layout, and the edited-range and no-op tests guard the diff. | M1 (whole-document write put back) passed every stillness test; a maintainer trusting the comment would think those tests protect the restyle. | fixed |
| 3 | Conventions | Nit | `Tests/DownwriteTests/StylerTests.swift` (`keystroke < 0.25`) | The absolute keystroke budget was a guess ("perhaps 200 ms on a Mac") with no local measurement. | `scripts/ci-local.sh` runs without `CI` set, so the budget applies there; a keystroke measured 0.477 s on the maintainer's Mac, so the test would have failed with nothing wrong in the code. | fixed |
| 4 | Conventions | Nit | `Sources/Downwrite/SelfTestTyping.swift:53` and `:113` | The excursion rule and its trace type are written twice (app self-test and `Harness.swift`). | A change to the rule or tolerance in one is not carried to the other, so the e2e step and the unit tests disagree on the same trace. | open |
| 5 | Bugs | Important | `Sources/Downwrite/SelfTestTyping.swift` (`typingWalkthrough`, source view) | When ⌘/ does not reach the View menu, the step's fallback `coordinator.setSourceMode(true)` is undone at the next update by SwiftUI's `sourceMode` state (still false), so the "source view" keys are typed into the formatted editor and reported as the source view's. | ⌘/ fails in a session where SwiftUI's focused scene is unresolved (as in other checks on a local run): the first key shows height 41343.5→36482.0 and an edit `{0, 111004}` (the switch and its revert), and the later keys report PASS with the formatted editor's height. | fixed |

### What fixing 1 found

With an honest baseline the copy and the comparison cost about as much as the styling: restyle of an unchanged 180 KB document 0.302 s against 0.148 s, **ratio 2.04**, not the 1.07 recorded in the plan's Deviations. A keystroke is still cheaper than before the change (0.477 s against 0.707 s with the old whole-document write added, the emulated old cost). The bounds were recalibrated from that measurement (restyle at most 3× the styling, a keystroke at most the emulated old cost, under 1 s when `CI` is unset). The eight-lookup mutation now fails the test (ratio 9.1) and was reverted. `plan.md` Deviations records all of this.

For the maintainer to decide, not a defect: the diff adds roughly the cost of the styling to every keystroke (about 0.15 s of CPU on a 180 KB document on this Mac), which buys not invalidating the layout. It is cheaper than the old behaviour, so it does not breach "typing no slower", but there is room to cut it (for example by diffing only the lines the analysis says changed) if a very large document ever feels slow.

## Disputed

None.

## Fed back to CLAUDE.md

- A cost-ratio test's baseline must exclude the cost under test: run the mutation that makes the cost worse and see the test fail before recording a ratio, and measure an absolute budget on a Mac instead of estimating it (finding 1; added with the maintainer's agreement, 2026-10-22).

## Proof status

The plan's Proof, re-run after the fixes on a Mac (macOS 27.0.1), on commit `2f9fb59` (finding 5's fix came after it):

| Command | Result |
|---|---|
| `swift test --filter 'TypingStabilityTests\|StyleDiffTests\|StylerTests'` | passed, 50 tests, 0 failures |
| `swift test` (inside `scripts/ci-local.sh`) | 0 failures, 0 `error:` lines |
| `scripts/ci-local.sh` | **e2e failed**: 35 checks when the agent ran it from its own shell (nearly every keystroke and click check), 10 when the maintainer ran it from a desktop terminal |
| `scripts/linux-test.sh` | not re-run (no Core code changed on this branch) |

The 10 failures of the maintainer's desktop run: six SwiftUI-focus checks (⌘/ three times, Keep on Top twice, the fold commands), three theme-library checks (Appearance tab 633 pt against 620; the list-screenshot themes; "nothing is left in the library"), and `typing: a edits only its own paragraph (source view)`. The first nine are local-only failures recorded in the agent's notes from earlier changes (the maintainer's 8 imported themes, and SwiftUI's focused scene not resolving in a local run); the CI job for the PR head is the arbiter for them. The tenth is finding 5: it is the same ⌘/ failure showing through this change's step. The step now reports `typing: the source view is showing` instead of recording the formatted editor as the source view.

**Not proven:** `ALL CHECKS PASSED` for the e2e with the finding 5 change, and the source-view half of step 8e on a run where ⌘/ works. The last CI run that had both is `896dbe6` (code identical to the earlier head); the finding 1 and 5 changes touch only tests, the self-test and an access level (`MarkdownStyler.styleAll(into:)`). `reproven` stays blank until a CI run on the new head passes.
