# Bug: fences stay visible for a code block inside a quote or on a list-marker line

A fenced code block whose opening fence is not the first thing on its line is styled as a plain indented block, so its fence lines and language tag are never hidden, whether or not the caret is inside it. A top-level fence takes the fence path in the same function, and so does a fence on its own indented line inside a list item (by reading the code; I did not check either in the running editor).

## Steps

Type either of these into a document and move the caret out of the block:

````
> ```sh
> echo hi
> ```

- ```sh
  npm i
  ```
````

## Expected and actual

- **Expected:** the fence lines and the `sh` tag hide while the caret is outside the block and show while it is inside, as they do for a top-level fence (the Bear-like rule in CLAUDE.md).
- **Actual:** the backticks and the language tag stay visible all the time. The plan recorded this from probing the editor on 2026-10-11 (`docs/changes/2026-10-11-copy-text-from-code-blocks/plan.md`, Risks). I have not re-run that probe; the cause below is from reading the code.

## Cause (from reading the code)

`MarkdownAnalyzer.codeBlock` (`Sources/DownwriteCore/MarkdownAnalyzer.swift`) finds the fence with `firstNonSpace(line:)` on the block's first line. For `> ```sh` that character is the `>`, and for `- ```sh` it is the `-`, so `fenceLen` stays 0, the `guard fenceLen >= 3` fails, and the block takes the "indented code block" branch: every line becomes `.codeBlock`, and no `.fence` line kind or marker is created, so nothing is hidden.

The same early return skips the Mermaid check below it, so a ` ```mermaid ` fence in a quote or on a list-marker line is probably never recognised as a diagram either. That part I have not tried.

## Not affected

The range of the block's card, the copy button and the text it copies are right for these blocks, because they come from cmark's own `CodeBlock.code` and not from the fence detection. `CodeBlockTests.testCodeBlockInsideAQuoteHasNoQuotePrefix` and `testFenceOnTheListMarkerLine` pin that, so any fix must keep them green.

## Notes for a fix

- The fence's real column is not the first non-space character of the line: it is after the quote or list prefix. cmark's range for the block may already start at the fence, which would give the position directly (not checked). Tests for the two cases above, which also assert that the fences become `.fence` markers, belong next to the existing analyzer and styler tests.
- Logic stays in `DownwriteCore` with Linux-runnable tests (CLAUDE.md, Architecture rules). Hiding is a styler matter (`.fence` markers get the 0.1 pt clear font and whole fence lines get `min/maxLineHeight = 0.1`), so check how a hidden fence line interacts with the quote bar and the list indent before deciding what "hidden" means there.
- Raised during DW-012 (copy button), which does not depend on it. Not on the roadmap.

## Status

- [ ] Open. Found 2026-10-11, written up 2026-10-12. No intent yet.
