---
type: review
id: 2026-10-10-export-and-print
plan: ./plan.md
reviewed: 2026-10-10
base: main
head: 5db9295f7b3b2bf4194536d6da9ae5e7a04e16dc
reproven: ff1bca3d5b1885ec68717d0f43e090e6dd7e2311
pr: https://github.com/derrickwheals/downwrite/pull/17
---

# Review: Print a document and export it as PDF or HTML

## Summary

Important: 2 (fixed 2, disputed 0, open 0) · Nits: 5 (fixed 2, open 3)

The review was done by a general-purpose subagent that took no part in the build, in the three passes `REVIEW.md` names (bugs, security, conventions), over `git diff main...HEAD` at `5db9295`, with `plan.md`, `spec.md`, `intent.md` and `CLAUDE.md` as the reference. It was read-only: it ran no build, test, app or Docker. I checked each finding against the code before acting on it, and measured finding 2 in a real PDF (the squashed image came out 0.88 wide over tall against a true 0.29 before the fix).

The security pass found no way past the HTML sanitiser, the link policy or the page's Content-Security-Policy. Its one security finding was in how local images are read (finding 1).

## Findings

| # | Category | Severity | Location | Finding | Failure scenario | Status |
|---|---|---|---|---|---|---|
| 1 | Security | Important | `Sources/Downwrite/Previews.swift:232` (`ImageLoader.embed`, called from `DocumentOutput.swift:196`) | An image was recognised by the extension of the link's own name alone, so any file reachable through a symlink or a renamed file was embedded as `data:image/…;base64,<raw bytes>`. | A cloned folder holds `docs/banner.png`, a symlink to `~/.ssh/id_ed25519`; the README says `![](docs/banner.png)`; Export as HTML writes the key into the shareable file as base64 and the image just looks broken. Fixed: the bytes are checked (an SVG must contain `<svg`, anything else must open in ImageIO) and the 8,000,000-byte limit is read from the link's target. Tests: a renamed text file, a symlink to a secret, a symlink to a real image and to an oversized one, and a dangling link. | fixed |
| 2 | Bugs | Important | `Sources/DownwriteCore/PrintStyle.swift:40,62` | `img{max-width:100%;height:auto}` plus `max-height:15cm` clamps only the height of an `<img>` that has its own `width`, so the picture is squashed rather than scaled to fit (R19). | README HTML `<img src="screenshot.png" width="600">` with a tall portrait screenshot: the box becomes 600 wide by about 567 high and the picture is drawn almost square in the PDF and in a browser's print. Fixed with `object-fit: contain` on print images. Test: a 400 by 1400 image with `width="500"` through a real print operation, shape measured on the PDF (fails without the fix, 0.88 against 0.29). | fixed |
| 3 | Bugs | Nit | `Sources/DownwriteCore/DocumentAssemble.swift:87,113` | The diagram safety regex `[\s"'/]on[a-z]+\s*=` and `javascript:` also match inside text nodes, so a harmless label is refused. | A sequence diagram `A->>B: set online = true` is replaced by "Diagram could not be rendered: the diagram output was not safe to include" plus its source. Left alone on purpose: a check limited to tags has to agree with the browser's own reading of a hostile tag (an unquoted value holding a quote, a `>` inside a quoted value, a tag that never closes), and a false refusal costs a degraded diagram while a false pass would be a hole. I tried the tag-scoped form and reverted it for that reason. | open |
| 4 | Bugs | Nit | `Sources/DownwriteCore/PrintStyle.swift:76` | Flex-grow weight rules existed for the first 16 columns only. | A 20-column table of 4-character cells prints with columns 17 to 20 about a quarter of the width of the rest and broken mid-word. Fixed: rules for 32 columns, and a table wider than that carries no weights (equal columns). Test: 32 and 33 columns. | fixed |
| 5 | Bugs | Nit | `Sources/DownwriteCore/DocumentImages.swift:40`, `DocumentAssemble.swift:45` | The 64 MB budget (R14) counts each distinct source once, but every `<img>` that uses it carries the full data URI. | One 8 MB image shown 40 times is about 430 MB of base64 HTML in memory, plus copies for the file data and the web view. Not fixed: closing it means either charging the budget by use (and refusing an image that would cross the line, which changes R14's wording "once this much is held no more are read") or sharing one copy through CSS; that is a spec decision. | open |
| 6 | Bugs | Nit | `Sources/DownwriteCore/DocumentHTML.swift:70` (`protectFootnoteDefinitions`) | Only `[^n]:` lines at columns 0 to 3 outside fences are protected; cmark also takes them as link reference definitions inside a block quote or a list item. | `> [^1]: Note.` or `- [^1]: https://x.test` is swallowed and the output has an empty `<blockquote>` or `<li>`: the text is gone, against R11's "shown as typed". Not fixed: it needs the same marker-aware line walk the list and quote handling already do, and the case is rare. | open |
| 7 | Conventions | Nit | `docs/changes/2026-10-10-export-and-print/plan.md:111,193` | Two defects in the plan: literal `\n` between bullets on one line, and a sentence saying the plan is left `in-progress` while the frontmatter says `done`. | The Deviations section rendered three bullets as one broken line, and the Open section contradicted its own frontmatter. Fixed (also the escaped quotes in the step 14 bullet). | fixed |

## Proof re-run after the fixes

On `ff1bca3`: `scripts/linux-test.sh`'s job, run as one process per test class (one per test for a class that stalls in Docker), gave 533 Core tests, 0 failed, 0 stalled. `scripts/ci-local.sh --no-e2e` (build, the macOS `swift test`, packaging) gave 892 test cases (533 Core, 359 app), 0 failures, and a packaged `dist/Downwrite.app`.

The real-app end-to-end run was NOT re-run validly: the login session was locked when it started (`CGSSessionScreenIsLocked`), so the app was never active and every check that needs a key window failed (21 failures: shortcuts, checkbox clicks, source view, Keep on Top, the two File-menu enablement checks, the fold focus check, plus the three that also fail on `main`). The 180 checks that do not need focus passed, including 27 of the 29 export checks. The last valid run, with the display unlocked and before these fixes, was 216 pass and 5 fail (the three on `main` and the two R2 menu checks); the fixes touch the print stylesheet, the table markup, and how a local image is read, not the menu or the controller. The `ALL CHECKS PASSED` line the plan's last proof command looks for has not appeared in this change's runs because of those five known failures. A person should re-run `scripts/ci-local.sh --yes` on an unlocked desktop (or let the macos-26 CI job do it) before merging.

## Disputed

None.

## Known open, not a review finding

R2 (the three File items do not grey out while a preparation is under way or with only Settings frontmost) is recorded in `plan.md` under "Open" and was excluded from this review's brief. The plan is `done` with it open, at the owner's instruction. A second command while preparing is already refused by the controller (unit-tested); only the greyed-out look is missing.

## Fed back to CLAUDE.md

- A file's name is not proof of its type: when bytes leave the machine (export), check the bytes and the symlink target as well as the extension (`ImageLoader.embed`).
- CSS `max-height` with `height:auto` squashes an element that has its own width: add `object-fit: contain` and measure the shape in a real PDF, not in the CSS.
