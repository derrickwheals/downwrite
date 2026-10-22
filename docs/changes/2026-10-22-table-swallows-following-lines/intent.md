---
type: intent
id: 2026-10-22-table-swallows-following-lines
title: Table swallows the text typed straight under it
track: bug
status: accepted
raised: 2026-10-22
accepted: 2026-10-22
merged: 2026-10-23
backlog: DW-025 (https://app.todoist.com/app/task/6hpvRH25xJr66Xpq)
---

# Table swallows the text typed straight under it

## Problem

When text is typed or pasted directly under a table's last row, with no blank line between, the editor draws every one of those lines as another row of the table's grid. In the sample on the card, a three-column table with one empty body row is followed by about eight lines of plain text; the grid shows each line as a row with the text in column 1 and empty cells in columns 2 and 3, and the long paragraphs wrap inside column 1. The user expects the text to be ordinary paragraphs below the table, as it looks in the raw Markdown.

Observed: the whole run of lines up to the next blank line belongs to the table. Expected: the table is only the lines that look like table rows, and what follows is body text.

Reproduction: open `test-doc.md` (attached to the card; the sample is also in the card description) in Downwrite, put the caret outside the table, and look at the rendered grid. The raw-Markdown screenshot and the rendered-grid screenshot on the card show the two views of the same text.

The cause is not a defect in the parser. GitHub Flavored Markdown defines a table as ending only at a blank line or the start of another block, so cmark-gfm, which `MarkdownAnalyzer` follows, reads each following line as a row with one cell and the rest empty. This is a deliberate choice to differ from that rule, made by the product owner when this intent was drafted.

## Proposed outcome

A line directly under a table's last row that is not itself a table row is not part of the table. It is shown as body text below the grid, in the same way as if a blank line separated them, and the grid has only the rows the person wrote as rows.

## Affected users and systems

Anyone who writes a table and keeps typing on the next line, which is easy to do because Return after the last row starts a plain line. The parts involved are the table analysis in `DownwriteCore` (`MarkdownAnalyzer`, `TableBlock`, `TableModel.parse`, the grid model that must agree with the parse) and, in the app, `TableOverlay` and the table-source styling.

## Constraints

- All Markdown and editing logic stays in `DownwriteCore`, with unit tests that run on Linux.
- Table editing in the grid, the source view, folding, the table of contents, image placement (which treats tables as no-go) and the table formatter must keep working on the shorter table.
- Offsets stay UTF-16 and the text in the editor is not rewritten: this is a change to what the analysis treats as the table, not to the text.
- Print and HTML export are rendered by a separate pass over the same document (`DocumentRenderer`). The editor and the export agreeing is a standing rule in this codebase (as for callouts), so a difference between them has to be a decision, not an accident (see the first open question).
- Tables that GFM itself accepts must not change: rows with pipes, rows missing cells, escaped pipes, and a table ended by a blank line, a heading, a quote or a fence.

## Open questions

- What counts as "not a table row"? The simplest rule is a line with no unescaped pipe. A line such as `a | b` has one, and GFM and other editors accept pipeless rows only for a one-column table. Decide the rule, including a one-column table whose rows have no pipes, and a row written with a pipe only at one end.
- The export and print follow GFM today. Should they follow the same rule as the editor (so a document looks the same on paper), or stay as they are (so a file looks the same on GitHub)? The product owner's answer to the first draft was to diverge in the editor; this question is whether the export diverges too. A document that renders differently on GitHub than here is the cost of diverging.
- What happens in the source view and in the grid's own editing (typing under the last row inside the grid, Return and Tab at the end of the last cell)? Those paths may assume the table runs to the first blank line.
- Does the same behaviour apply to the same text inside a quote or a list item, where tables are not edited as a grid but are still styled as a table?

## Decision

Accepted 2026-10-22. The open questions go to the plan.
