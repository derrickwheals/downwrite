# Review policy

Every change is reviewed against this policy before its PR is opened. The review is done by a fresh-context reviewer that did not write the code. A human merges. The agent that wrote the change never approves it.

## Passes

Run each pass separately over the full diff against the base branch, with the change's `plan.md` (and `spec.md`, if any) as the reference for intended behaviour.

1. **Bugs.** Logic errors, unhandled edge cases, broken error handling, wrong behaviour relative to the spec or plan, and missing or ineffective tests for the changed behaviour.
2. **Security.** Secrets in code or logs, injection, unsafe deserialisation, missing input validation at trust boundaries, overly broad permissions, and unsafe file or network access.
3. **Conventions.** Departures from `CLAUDE.md` and from the surrounding code's patterns, plus dead code, and scope creep beyond `plan.md`.

## Severity

- **Important**: would cause incorrect behaviour, data loss, a security exposure, or a failing or misleading test, or leaves the change not doing what its plan says. Important findings must be fixed or explicitly waived by a human before merge.
- **Nit**: style, naming or minor simplifications. Report at most **5** nits per review, choosing the most valuable.

## Not in scope for review

- Re-litigating decisions recorded as approved in `spec.md` or `plan.md`. Raise these as a new intent instead.
- Formatting that the linter already enforces.

## Project-specific checks

- The test command is `scripts/linux-test.sh` (Core, on Linux) and `swift test` (everything, on macOS). Both must pass.
- Markdown and editing logic lives in `DownwriteCore` (pure Swift, no AppKit/SwiftUI) and ships with unit tests. The app target only maps results onto AppKit.
- Offsets are UTF-16 (`NSRange`) everywhere; flag any mixing with `String.Index`.
- Core code must build on Linux: no `x as NSString`, and no reliance on Darwin-only Foundation behaviour.
- The editor stays on TextKit 1: nothing touches `textView.textLayoutManager`.
- UI changes come with `StylerTests`/`EditorBehaviourTests` updates and, where drawing changes, pixel checks like `DrawingTests`.
- No new dependency without a strong reason, and any added or upgraded dependency is GPL-3.0-compatible and recorded in `THIRD-PARTY-NOTICES.md` and `ThirdParty/`.
- Behaviour documented in `CLAUDE.md` (architecture rules) is updated in the same change when the design moves.
