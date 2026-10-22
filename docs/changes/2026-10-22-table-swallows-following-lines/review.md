---
type: review
id: 2026-10-22-table-swallows-following-lines
plan: ./plan.md
reviewed: 2026-10-22
base: main
head: f10003be5593aa0db61f28adc684606f5b7c4af7
reproven: 705089d13bc15a44db9b69a59438b5f12bdd7795
pr: https://github.com/derrickwheals/downwrite/pull/26
---

# Review: Table swallows the text typed straight under it

## Summary

Important: 1 (fixed 1, disputed 0, open 0) · Nits: 2 (fixed 1, open 1)

The reviewer was a fresh-context general-purpose agent that took no part in the build. It ran the three `REVIEW.md` passes separately over `git diff main...HEAD` at the head above and read the whole diff: `TableTails.swift`, the analyzer, export, formatter and comment hunks, the `CLAUDE.md` bullet and every new or changed test. It checked its findings with throwaway probes in a copy of the repo and ran a 6000-document differential fuzz of the line map (no trap, no range outside the text). The agent that ran the review reproduced finding 1 with a failing test before fixing it.

Pass results: **Bugs** one Important (below) and one test-naming Nit; the line map, multi-pass remap, prefix handling for `>`, spaces and tabs, callout re-mapping, termination and Format Table trimming held up. **Security** no Important findings: the extra parse does not change what `HTMLSanitizer` sees and U+E000 to U+E002 do not leak; one resource-use Nit. **Conventions** no findings: Core stays pure Swift, offsets are UTF-16, no app code changed, no scope creep, no `FEATURE-LIST.md` row (a bug fix).

## Findings

| # | Category | Severity | Location | Finding | Failure scenario | Status |
|---|---|---|---|---|---|---|
| 1 | Bugs | Important | `Sources/DownwriteCore/TableTails.swift` (`breakLine(of:in:)`) | cmark starts a table's range, and its header's range, on a text line directly above the header, but `breakLine` took the delimiter row to be the line after the range's first line. | `note\n\| a \| b \|\n--- \| --- \|\n1 \| 2 \|\n` (piped header, unpiped delimiter, no tail): the delimiter row was judged a row, a blank line was inserted before it, and the table vanished from the editor and from print/PDF/HTML (`tables == []`). Also `note\na \| b\n\| - \| - \|\n\| 1 \| 2 \|\nx \| y\n`: `x \| y` stayed a row because the header's pipe style was used. Both are tables GFM accepts, which the plan says must not change. | fixed in `705089d` |
| 2 | Conventions | Nit | `Tests/DownwriteCoreTests/TableTailsTests.swift` (`breaks`) | The entry "quote with a lazy tail" has no lazy line. | A reader takes it as covering lazy continuation, which it does not. Renamed to "quote with a tail, then a blank line and more text". | fixed |
| 3 | Security | Nit | `Sources/DownwriteCore/TableTails.swift` (`parse`, the `inserted` remap) | `maxPasses = 16` bounds the parses, but each pass is a full parse plus an O(inserted × breaks) remap through `breaks.lazy.filter`. | A crafted 413 KB file of 1000 blocks, each a chain of 16 stacked tables with tails: plain parse 0.56 s, `TableTails.parse` about 12 s (debug), on every keystroke and export. Accepted by the `maxPasses` deviation in `plan.md`; merging the two sorted lists instead of filtering per element would make the remap cheaper. | open |

## Proof and manual checks

Re-run after the fix, on `705089d` (the code changed, so every command under *Proof* in `plan.md` was re-run):

- `swift test` (macOS): 592 app tests and 792 Core tests, 0 failures (`TIMING: assemble` ratio 4.2, within the 8× bound).
- Core on Linux (`mirror.gcr.io/library/swift:6.1-noble`, one test per process, 4 at a time, the Linux Core tests recipe): 792 of 792 passed, none failed or wedged. `scripts/linux-test.sh` itself was not used (macOS bash 3.2).
- The two new cases failed before the fix and pass after it.
- Hand check (print preview and typing `x` then `|` under a grid): passed 2026-10-22, reported by the maintainer, before the fix. The fix changes only which line is taken as the delimiter row when a text line sits above a table header.

## Disputed

None.

## Fed back to CLAUDE.md

- Added to *Things Claude gets wrong here* (agreed 2026-10-22, from finding 1): cmark reports a table's range, and its header's range, from a text line directly above the header, so never derive a position inside a table from `range.lowerBound`, and give every table corpus a text-line-above case.
