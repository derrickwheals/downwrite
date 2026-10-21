---
type: plan
id: 2026-10-18-editor-view-jumps-while-typing
intent: ./intent.md
status: in-progress    # draft | approved | in-progress | done
approved: 2026-10-18
branch: claude/ecstatic-brown-ca43xe
---

# Plan: Editor view jumps while typing

## Approach

Every edit runs `textDidChange` → `reanalyze()` → `restyleAll()` → `MarkdownStyler.styleAll` (or `styleSource` in the source view), and both begin with `storage.setAttributes(…, range: <the whole document>)`. NSTextStorage reports that as an attribute edit over the whole text, so the layout manager throws away the layout of the entire document on every key. With `allowsNonContiguousLayout = true` the part that is not laid out again straight away is estimated, the text view's height is recomputed from the estimate, the clip view clamps its scroll position to the new, smaller height, and layout then grows the view back. That is a shrink and a recovery of both the view's height and the scroll position inside one keystroke, which fits the flash, the scroll bar appearing on every character, and "worse at the end of a long document" (the clamp only bites when the view is scrolled close to its end). I measured all of this (see Reproduction).

The fix is to make the restyle write only what changed. `styleAll` and `styleSource` keep their signatures but style a detached `NSTextStorage` holding the same text, and a new `StyleDiff.apply` copies onto the real storage only the attribute runs that differ, inside one begin/endEditing (and not at all when nothing differs). The final attributes are exactly what the whole-storage write produced, so nothing visible changes; a keystroke in plain text writes zero runs, a keystroke that really changes a line's look (a heading marker, an emphasis pair, a fence) invalidates just those lines. `EditorView`, the overlays, the layout manager and Core are not touched.

The alternatives, and why not: **contiguous layout** (`allowsNonContiguousLayout = false`) also removes the shift in the probe, but then every full invalidation needs the whole document laid out again before the text view can size itself, on every key; I did not time it, and I expect it to trade a flash for a stall on a long document, and it changes how a file opens. **Freezing the clip view's origin during the restyle** (a clip view subclass) hides the scroll jump but not the height dip, which still moves the scroll bar, and still throws the whole layout away on every key. **Restyling only the edited line** needs a second way of knowing which other lines changed look; the diff finds that by construction.

## Reproduction

**Reproduced in the test harness, not in the real app.** I used a throwaway test (deleted, never committed): 300 plain paragraphs of 60 words (about 93,000 characters), an `EditorHarness` (960 × 760 window, 720 pt column, 17 pt Avenir Next, legacy scroller), caret and scroll position at the end, and a recorder on `NSView.boundsDidChangeNotification` (the clip view) and `NSView.frameDidChangeNotification` (the text view) that logs values in the order they happen inside one call. Notifications are posted synchronously, so a transient that is gone by the end of the call still shows.

| Case (one key each) | Text view height | Scroll position (clip y) |
|---|---|---|
| Formatted editor, caret at end; `a`, `b`, Space, repeated Space; through `insertText` and through a real `keyDown` event (identical) | 23,308.5 → **22,260.5** → 23,308.5 | 22,554.5 → **21,810.5** → 22,520 to 22,536.5 → 22,554.5 |
| Source view (⌘/), caret at end | 23,017 → **21,825** → 23,017 | 22,262.5 → **21,305** → 22,246.5 → 22,262.5 |
| Caret near the top (offset 2,000) | no change after the first key | none |
| Text view's delegate detached (typing, no analysis or restyle) | none | none |
| `restyleAll()` alone, nothing typed (three calls in a row) | 24,063 → 22,197 → 23,212, then the same dip and recovery each time | 23,309 → 21,747 → 22,406.5 → 22,457.5, then 22,457.5 each time |
| Whole document laid out first (50,114.5 tall), then one key | 50,114.5 → 22,260.5 → 23,308.5 | 49,360.5 → … → 22,554.5, and it **stays** there |
| `allowsNonContiguousLayout = false` | 50,114.5, no change while typing | none |
| Restyle replaced by the diff, emulated in the probe (0 runs written per key) | none | none |

So: the shift is in every key, Space included, in both views, only near the end of a long document; typing alone does not cause it, the restyle does; and the text view's height is an estimate (24,063 against a true 50,114) that the whole-document invalidation keeps resetting. On `main`, one key also reports an attribute edit over `{0, 93476}` (the whole document) next to the one-character edit, and so does `restyleAll()` alone; that is the signal the tests below use, and it does not depend on the scroller style.

**What this does not show.** Whether a frame is painted between the two states on the maintainer's Mac (the harness cannot see painting, and the shift here is about 750 pt because this document's estimate is badly off; the maintainer sees one line). Why only Space is visible: in the harness Space is no different from any other key, so something that paints in between on Space is a guess I have not tested. The overlay scroller (the harness and the CI runner get a legacy one). And it is not a bare TextKit 1 view: it is Downwrite's own text view with the pipeline disconnected, which is close enough to say typing alone is still. The plan does not depend on the Space question: with nothing invalidated there is no intermediate state to paint on any key.

**Which release introduced it** (intent, open question 1): none to find. `storage.setAttributes(baseAttributes(), range: all)` and the `styleSource` equivalent are in v0.9.0, `restyleAll` and `allowsNonContiguousLayout = true` are in the first commit (`d9be286`), and the scroll view settings have not changed since. It was noticed on a longer document, not introduced by one release. Trying an older build would only repeat the probe.

## Decisions

Each is a choice for you to approve with the plan.

1. **The fix is in what the restyle writes, not in the layout settings** (the approach above). If you would rather try contiguous layout first, step 1's tests and a timing of a large document would show whether I am right to expect a stall; I have not measured it.
2. **The proof has two halves, and one cannot be automated.** Automated: no attribute edit outside the typed line, and no excursion of the view's height or scroll position inside a keystroke (formatted and source, end and middle, letter and Space, `insertText` and `keyDown`). Not automated: that the flash is gone on your Mac with the real overlay scroller (the tests and CI run a legacy one). That is a hand check by you on a build (step 8) and the change is not finished without it. If the flash is still there with zero attribute edits on a keystroke, I stop and report with the real-app step's output, rather than guess at a second cause (Space-specific behaviour in AppKit on macOS 27 would be one).
3. **A real-app self-test step is included** (step 6, `SelfTestTyping.swift`, run by `scripts/ci-local.sh`): real key events through the packaged app's window, the same recorder, the Mac's own scroller style written into the report, and the attribute edits per key. It is also the instrument that would show a Space-specific attribute edit if AppKit makes one in the real app but not in the harness. Drop step 6 if you want the e2e left alone; the hand check then carries the real-app half alone.
4. **No older release is tried** (see Reproduction).
5. **Track stays bug.** The expected behaviour is already defined in the intent ("typing never moves the text on screen except to keep the caret in view"); nothing here needs a spec.

## Files that change

App (macOS):

- `Sources/Downwrite/StyleDiff.swift` (new) — `StyleDiff.apply(_ styled: NSAttributedString, to storage: NSTextStorage) -> Int`: walks the runs of `styled`, compares each with the storage's attributes over the same range (`NSDictionary.isEqual`; `CheckboxMark`, `FoldMark` and `CalloutMark` already implement value equality), collects the differing ranges and writes them with `setAttributes` in one begin/endEditing, none at all when nothing differs. Returns the number of runs written. Falls back to a whole write if the lengths differ.
- `Sources/Downwrite/MarkdownStyler.swift` — `styleAll` (`:99`) and `styleSource` (`:233`) style a detached `NSTextStorage(string:)` and call `StyleDiff.apply`; everything else in the file (`style(lines:)`, `applyLine`, `styleCell`) is unchanged. `applyLine`, `lineLook`, `firstVisibleCharacter` and `keepLineMetrics` read only the text of the storage they are given, which the copy shares.
- `Sources/Downwrite/SelfTestTyping.swift` (new) and `Sources/Downwrite/SelfTest.swift` — the real-app step, called after 8d (`imagePasteWalkthrough`), before folding; `--selftest-typing-only` for development, like the others.
- `CLAUDE.md` — one architecture rule (the restyle writes only what changed, and why) and one gotcha (a whole-storage `setAttributes` per edit moves the view), in the same commit as the code that makes them true.

Tests (macOS):

- `Tests/DownwriteTests/Harness.swift` — `GeometryRecorder` (clip origin and text view height in the order they change, and the largest excursion beyond the start and end values), `EditorHarness.type(_:viaKeyEvent:)`, and a long-plain-text builder.
- `Tests/DownwriteTests/TypingStabilityTests.swift` (new) — the tests under Proof.
- `Tests/DownwriteTests/StyleDiffTests.swift` (new) — the diff on its own.
- `Tests/DownwriteTests/StylerTests.swift` — one cost-ratio test for the restyle (`TIMING:` line, DW-016 pattern). `testLargeDocumentStylesQuickly` stays as it is unless its ratio moves (step 5).

Not changed: `EditorView.swift`, `EditorTextView.swift`, `DWLayoutManager.swift`, the overlays, `Sources/DownwriteCore`. No new dependency. `FEATURE-LIST.md` is not touched (a bug fix).

## Order of work

- [ ] 1. Branch `change/2026-10-18-editor-view-jumps-while-typing` from `main`. Add `GeometryRecorder` and the typing helpers to `Harness.swift`, then `TypingStabilityTests` with the stillness tests and the edited-range test. Also write the characterisation tests (undo, marked text, caret stays in view) and check they are green on `main`. Run the stillness tests on `main` and see them **fail** with the excursion numbers in the message; commit tests with the failure output in the message.
- [ ] 2. `StyleDiff.swift` with `StyleDiffTests` (unit: identical → 0 runs and no edit notification; one differing run → only that range; an attribute present only in storage is removed; seeded random run layouts → storage ends up attribute-equal to the styled copy). Commit.
- [ ] 3. Route `styleAll` and `styleSource` through `StyleDiff`. The step-1 stillness tests go green. Run the whole macOS suite. Then the mutation checks (below) and record the results in Deviations. Commit.
- [ ] 4. Equivalence and no-op tests: after a restyle the storage equals a fresh harness's for every fixture and after a series of edits; a second `restyleAll()` on a document with every kind of mark writes nothing. Commit.
- [ ] 5. Cost: measure per-keystroke CPU (`insertText` at the end, including analysis and restyle) on `main` and on the branch for the 180 KB document of `testLargeDocumentStylesQuickly`, record both numbers in Deviations; then the ratio test, with its constant chosen from that measurement. Re-run `testLargeDocumentStylesQuickly` and note whether its ratio moved. Commit.
- [ ] 6. `SelfTestTyping.swift` and its call in `SelfTest.swift`. Run `scripts/ci-local.sh` on a desktop session (not asleep: `caffeinate -d`). Commit.
- [ ] 7. `CLAUDE.md`. Commit.
- [ ] 8. Hand check by the maintainer on `scripts/build-app.sh`'s output (below). Not a commit; recorded in `review.md`.
- [ ] 9. Verifier agent (the build skill's last step), then `/ai-sdlc:review`.

## Risks

- **An attribute that never compares equal makes the diff rewrite its line (or the whole document) on every key, which is today's behaviour, silently.** The three mark classes have `isEqual`; `NSFont`, `NSColor` and `NSParagraphStyle` compare by value. Guard: the no-op test runs a document that contains every kind of mark the styler produces (hidden markers, bullets, task checkbox, callout, fold chevron and chip, pill, rule, quote bars, block backgrounds) and first asserts that each attribute key is really present, so it cannot pass on a plain document. Any key it finds that rewrites gets a value-equality fix.
- **The diff could skip or misplace a run** (a boundary where the storage's runs and the styled copy's runs differ). Guard: the equivalence tests compare whole attributed strings with a freshly styled harness, over every fixture and after type, delete and undo; the random-run unit test; and mutation M3.
- **A keystroke that really changes the look of many lines still invalidates them** (typing the closing fence of a long code block restyles the block). That is correct, and there the view may still move; the tests assert the correct result there, not stillness.
- **AppKit adds attributes of its own to text it inserts** (alternatives for predictive text, for instance). The whole write used to remove them on every key; the diff removes them from the runs that carry them, which are the ones just typed, so the outcome is the same and the layout cost is one paragraph. The real-app step prints the edited range per key so any such rewrite is visible.
- **Documents with tables, diagram or image cards have no automated stillness test** (their web views make a test slow and flaky). `TableOverlay.reposition` and `DiagramOverlay.reposition` call `ensureLayout` from the top of the document down to each grid or card, but they invalidate nothing, so once the restyle stops invalidating they should be quiet too. That is reasoning, not a measurement: the hand check includes a table and a diagram, and `TableLayoutTests` still guard the alignment.
- **Another cause may exist in the real app that the harness cannot show** (the overlay scroller; whatever makes Space special). Guard: Decision 2 and 3: the hand check, the real-app step, and a stop rather than a second guess.
- **Typing must not get slower.** The detached copy costs a string copy and a run comparison per key, in exchange for not re-laying out the document. Guard: step 5 measures both and the ratio test fixes the cost relative to styling alone; layout work is not in the CPU measurement, so the measurement is not a claim that typing got faster.
- **Marked text, undo.** The diff changes how `restyleAll` writes, not when it runs: `textDidChange` still returns before it while text is marked, and attribute writes were never registered with undo. Guard: the characterisation tests written green on `main` in step 1 stay green.
- **A plan that claims a test fails under a mutation has to have run it** (the DW-016 lesson). What is already checked: the stillness and edited-range tests' target behaviour is `main`'s current behaviour (the probe above), and step 1 runs the tests red on `main` before any fix. M1 to M3 are *not* run yet; step 3 runs them and Deviations records each result, and a mutation that fails no test gets a test or the claim is dropped.

## Proof

Tests to add or change:

- `TypingStabilityTests.testTypingAtTheEndOfALongDocumentNeverMovesTheView` — 300-paragraph plain document, caret and scroll at the end; keys `a`, Space, Space, `b`, Space, each through `insertText` and through a `keyDown` event; for each key the recorded clip origin and text view height never leave the interval between their values before and after the key (0.5 pt tolerance). Fails on `main` with 1,048 pt and 744 pt excursions.
- `…testTheSourceViewDoesNotMoveEither` — the same in the source view.
- `…testTypingInTheMiddleOfALongDocumentDoesNotMoveTheView` — caret near the top: no clip movement, and the height settles after the first key and stays.
- `…testAMixedMarkdownDocumentDoesNotMoveEither` — the same at the end of a long document made of headings, lists, a task, a quote, a callout and a code fence (no table, diagram or image card, which load web content and make a test slow and flaky).
- `…testAKeystrokeEditsOnlyItsOwnLine` — observes `NSTextStorage.didProcessEditingNotification`; after one letter or Space at the end, every reported edit lies inside the last paragraph. On `main` it reports `{0, 93476}`. This one does not depend on the scroller style, layout estimates or timing, so it is the check CI can always rely on.
- `…testTheCaretStaysInViewWhileTypingNewLinesAtTheEnd` — type forty lines at the end; the caret rectangle is inside the visible rectangle after each Return.
- `…testUndoAfterTypingRestoresTextAndLook`, `…testMarkedTextIsLeftAloneUntilItIsCommitted` — characterisation, green before and after.
- `…testRestylingAnUnchangedDocumentWritesNothing` — see Risks.
- `…testRestyleMatchesAFreshStyle` — for `Tests/Fixtures/callouts.md`, `fold-demo.md`, `export-demo.md` and the README, after each of: nothing, a typed letter, a backspace, an undo; the storage's attributed string equals that of a harness created from the same text and selection.
- `StyleDiffTests` — as in step 2.
- `StylerTests.testRestylingCostsLittleMoreThanStyling` — `restyleAll()` CPU time (thread CPU, DW-016 helpers) against `styleAll` into a detached storage of the same text, asserting a ratio, printing `TIMING:`; an absolute budget only when `CI` is unset.
- Real app: `SelfTestTyping` — in the packaged app's first window, a generated long plain document, real key events through the window for letters and Space in the formatted editor and the source view; asserts no excursion and no attribute edit outside the typed line; writes the scroller style, the excursions and the edited ranges into `selftest-report.txt`.

Mutation checks to run in step 3 (results go in Deviations):

- M1: put the whole-storage `setAttributes` back in `styleAll` (and separately in `styleSource`) → the stillness tests for that view and the edited-range test must fail.
- M2: make the comparison in `StyleDiff` always say "different" → the no-op test and the unit test must fail.
- M3: skip the last run (or start one character late) in `StyleDiff` → the equivalence tests must fail.

Must pass before the change is complete:

```
swift test --filter 'TypingStabilityTests|StyleDiffTests|StylerTests'
swift test
scripts/linux-test.sh
scripts/ci-local.sh        # build, all tests, package, real-app e2e: "ALL CHECKS PASSED", typing step included
```

Hand check (step 8; maintainer, on a build from `scripts/build-app.sh`, on the macOS 27 Mac where it was seen): a plain-text document well taller than the window, caret at the end; type words and several Spaces in a row. There is no flash and the vertical scroll bar does not appear while typing, in the formatted editor and in the source view (⌘/), with "Show scroll bars" on Automatically and on Always. Then scroll with the trackpad: the scroll bar still appears and works. Then the same near the top of the document, and with a heading, a list, a table and a Mermaid diagram in the document.

The intent's proposed outcome, item by item:

| Outcome | Proven by |
|---|---|
| Typing never makes the text jump or flash, in any part of a long document including the end | the four stillness tests, the edited-range test, the real-app step, the hand check |
| Space, once or repeated, is no different from any other key | the same tests with Space and repeated Space, through `keyDown` as well as `insertText`; the real-app step |
| The scroll bar appears only when the view really scrolls | hand check only; the automated runs have a legacy scroller. The real-app step records which style it ran with |
| Formatted editor and source view | a test for each, and both in the real-app step |
| Whatever the system's scroll bar setting is | hand check with Automatically and Always |
| Typing no slower; the caret still scrolls into view | step 5 and the ratio test; the caret test |
| Tables, cards, folds, sidebar and source view keep working | `TableLayoutTests`, `SourceViewTests`, `FoldTests`, `TOCTests`, `DrawingTests` and the rest of `swift test`, unchanged |
| Marked text and undo untouched | the characterisation tests |

## Deviations

- Step 1: the work is on `claude/ecstatic-brown-ca43xe` (the branch this cloud session is bound to and may push), not `change/2026-10-18-editor-view-jumps-while-typing`. The build runs in a Linux container with no Xcode, so every macOS result below (red on `main`, green after the fix, mutations, timings) is read from the CI job on this branch rather than run locally; `scripts/ci-local.sh` (step 6) is left to the maintainer's Mac.
- Step 1 result (CI run 39106087137 on `cc4e942`, tests only, no fix): 60 failures, all in `TypingStabilityTests`' stillness and edited-range tests; the caret, undo and marked-text characterisation tests passed. Per key, formatted editor at the end: clip excursion 102 pt, height excursion 428 pt (`insertText` and `keyDown` identical, Space no different from a letter); source view 705 / 902 pt; mixed Markdown 12,089 / 12,131 pt; middle of the document, height 1,167 pt (no scroll). Edited ranges: `{110630, 369}` (the key) and `{0, 110999}` (the whole document) per key, in both views. Smaller than the probe's numbers in the formatted editor because this runner's estimate is closer; the shape is the same.
- Step 5: the keystroke's "before" number is an emulation (today's keystroke followed by a whole-document attribute write, in the same test run), not a run of `main`; a run of `main` would need a second build of the old code in the same job.
- Step 3 result (CI run 39106381055 on `85432fb`, fix in): `testAKeystrokeEditsOnlyItsOwnLine`, the no-op and equivalence tests, `StyleDiffTests` and the characterisation tests pass, and the rest of the suite is unchanged (24 failures, all stillness). The excursions fell from hundreds or thousands of points to about one line, but they are not gone: formatted editor at the end, the first key scrolls 50 pt up and back, and every later key dips the text view's height by 24.7 pt (one 17 pt × 1.45 line) and back; source view 73 pt / 24.2 pt; middle of the document 49.4 pt; mixed Markdown 19.3 pt. The stillness tests are therefore still red. Mutations M1–M3 were not run (no point until the stillness tests are green).
- Diagnostic (temporary test, CI run 39107213539 on `89d5ef7`, removed again): one keystroke split into its phases on the 300-paragraph document, caret at the end. (A) AppKit's insertion with the text view's delegate removed, so no Downwrite code runs: 50 pt scroll up and back on every key, height steady. (B) the whole key: 50 pt scroll on the first key, then a 24.7 pt height dip on the third and fourth. (C) `reanalyze()` alone and (D) `restyleAll()` alone: nothing moves, nothing is written. (E) insertion without the delegate, then `reanalyze()`: the same as (B). (F) insertion without the delegate with `allowsNonContiguousLayout = false`: no excursion at all (the first key lays out the whole document, 26,515 → 50,048 pt, in one step). (G) the whole key after `ensureLayout` of the whole document, non-contiguous layout still on: a 24.7 pt height dip on every key. Each key writes only its own character (`{110999, 1}` and so on). So the remaining shift comes from AppKit's insertion under non-contiguous layout, not from the restyle; Decision 2's stop applies, and the build stops here for a decision.
- Hand check (step 8, early), maintainer, 2026-10-21, on a build of this branch with the restyle fix (`6c95054`): **the flash is still there.** The remaining one-line shift seen in the harness is visible in the real app. Next: a temporary probe (`ContiguousLayoutProbeTests`) measures, in one CI run, opening, jumping to the end and typing at the end and near the top of a 111 KB and a 180 KB document with non-contiguous layout on and off, plus the worst excursion while typing in each mode. A change of approach to contiguous layout is put to the maintainer with those numbers; it is not made without approval.

