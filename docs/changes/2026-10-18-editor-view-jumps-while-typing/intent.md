---
type: intent
id: 2026-10-18-editor-view-jumps-while-typing
title: Editor view jumps while typing
track: bug
status: accepted
raised: 2026-10-18
accepted: 2026-10-18
merged: 2026-10-22
backlog: DW-024 (https://app.todoist.com/app/task/6hmwmVCQwjF47Qpq)
---

# Editor view jumps while typing

## Problem

The backlog card, in full: "Editor view jumps while typing. Potentially due to scroll bar hiding and showing." It is a p1.

Observed, as reported by the maintainer on v0.9.6 (on a Mac running a pre-release macOS 27, as noted on DW-013):

- Pressing Space makes the text flash very briefly about one line lower, then return to its original position. It is a flash, not a lasting scroll. Every Space does it, including several in a row, and no other key makes the text visibly move.
- It happens only when the document is taller than the window, so that scroll bars are needed. Making the window tall enough that they are not needed stops it. A document of plain text only is enough, and no difference with the document's length has been noticed beyond that. It is more noticeable at the end of a long document than near the top of one.
- The vertical scroll bar appears every time a character is typed, not only on Space ("Show scroll bars" is on "Automatically based on mouse or trackpad"). Setting it to "Always" made no difference.
- TextEdit (plain text, a long document, a window short enough for scroll bars) does not flash on Space. There the vertical scroll bar appears only when scrolling, and not when typing or pressing Space.
- "Check spelling while typing" is off. "Show inline predictive text" is on, and turning it off changes nothing.
- It happens in the source view (⌘/) as well as in the formatted editor.
- Which release introduced it is unknown: it was noticed on editing a longer document, and most files edited before were a few lines.

Expected: typing never moves the text on screen except to keep the caret in view, and the line being typed reflowing as it grows. Not even for a frame. The scroll bar appears when the view scrolls, as it does in TextEdit, and not because a character was typed.

There is no reproduction beyond the points above, nothing has been measured in the app, and no cause has been established.

What the reports rule out (from reading the code, none of it checked):

- The scroll bar's style as the cause: "Always" makes no difference. An overlay scroller shows when the view's position or content size changes, so the bars appearing on every character are more likely a symptom of the view's geometry changing on every keystroke than the cause of the flash.
- Spell checking and inline predictive text.
- Anything specific to the formatted editor: hidden Markdown markers, tables, diagram and image cards and folds do not exist in the source view, or in a document of plain text.
- A plain macOS regression, since TextEdit on the same Mac does not do it. (TextEdit may use TextKit 2 where Downwrite uses TextKit 1, so it is not yet a fair control.)

What is left, none of it checked:

- The restyle after every edit. A document under 400,000 UTF-16 units runs `textDidChange` → `reanalyze()` → `restyleAll()` on every edit, and `MarkdownStyler.styleAll` (formatted) and `styleSource` (source view) each begin by calling `storage.setAttributes(…)` over the whole text storage, which reports the whole document as edited so that its layout is invalidated. A text view that edits one line does not do that. The layout manager has `allowsNonContiguousLayout = true`, so the height of text that is not laid out is an estimate that is corrected as layout happens. A text view whose height is re-estimated on every key would move the scroll bar on every key, and a brief re-estimate that settles would look like a flash one line lower that returns, larger at the end of a long document. This fits the reports better than anything else so far, but it does not say why only Space is visible.
- The round trip through SwiftUI. `textDidChange` writes the `text` binding on every edit, so SwiftUI re-renders and calls `updateNSView`. TextEdit has no such step.
- What is special about Space. Nothing in the app treats the space character differently: `EditorTextView.insertText` handles only the backtick, and `insertNewline`, `insertTab`, `doCommand(by:)` and `didChangeText` have no space case. Every key may move the view a little, with Space the only one that is big enough to see.

## Proposed outcome

Typing never makes the text on screen jump or flash, in any part of a long document including the end, and pressing Space, once or repeatedly, is no different from any other key. The scroll bar appears only when the view really scrolls, as in TextEdit. This holds in the formatted editor and the source view, and whatever the system's scroll bar setting is.

## Affected users and systems

Anyone typing in a document taller than its window, most visibly at its end, in both views. The reporter's scroll bar and prediction settings make no difference.

Systems, named as far as read so far:

- `EditorCoordinator.textDidChange`, `reanalyze()` and `restyleAll()` in `Sources/Downwrite/EditorView.swift`, which run on every keystroke, with `MarkdownStyler.styleAll` and `styleSource` in `Sources/Downwrite/MarkdownStyler.swift`, which rewrite the attributes of the whole document each time.
- `EditorView.updateNSView` and the `text` binding it round-trips through.
- `EditorCoordinator.scheduleReposition()` and the layout-completion callback that calls it, with `DiagramOverlay.reposition` and `TableOverlay.reposition`, which force layout from the start of the document.
- The layout manager's `allowsNonContiguousLayout`, set in `attach`.
- `EditorTextView` in `Sources/Downwrite/EditorTextView.swift`: the text view's configuration (`insertText`, `didChangeText`, the `NSTextView` settings in `make()`), the scroll view's (`autohidesScrollers`, `scrollerStyle`, `automaticallyAdjustsContentInsets`), `setFrameSize` and `updateInsets()`.
- The scroll-to-caret path while typing, which has not been read yet.
- Existing guards: `StylerTests` (including `testLargeDocumentStylesQuickly`), `SourceViewTests`, `EditorHarness.pinColumnWidth()` and `geometryReport()` in `Tests/DownwriteTests/Harness.swift`, and `TableLayoutTests`. None of them checks that the view stays put while typing.

## Constraints

- The editor stays TextKit 1; do not touch `textView.textLayoutManager`.
- The scroll view starts below the toolbar and its top `contentInsets` stay 0 (`scrollTarget` and `TOCTests` rely on it).
- Typing must not get slower, and the caret must still scroll into view: the large-document timing tests (`StylerTests`, `DocumentAssembleTests`) stay green on the ratio-against-baseline pattern from DW-016.
- Tables, diagram and image cards, folds, the contents sidebar and the source view must keep working: a grid or card must still line up with the text, and `TableLayoutTests` and `SourceViewTests` stay green. What the source view shows (one plain monospaced run, nothing hidden) does not change.
- The look of the column (maximum content width, centred, the "Text width" setting) must not change.
- The scroll bars keep working as they do now. Hiding them, or stopping the view from scrolling, is not a fix.
- A fix must not interfere with marked text (input methods, dictation) or with undo.
- The flash lasts about a frame, so whatever shows that the fix works has to be able to see a transient shift of the text during an edit, not only where it settles. The test harness and the CI runner also get a legacy scroller whatever the Mac is set to, so the real-app behaviour is not something the automated tests decide on their own.
- No new dependencies.

## Open questions

- Which Downwrite release introduced it? Not known, so the plan can answer it by trying an older release (v0.9.5, v0.9.0) with a long document.
- Does every key move the view, with Space the only one big enough to see? The scroll bar appearing on every character suggests the geometry changes each time. The plan can measure the clip view's bounds and the text view's frame around each key.
- Does a bare TextKit 1 text view in a scroll view, with none of Downwrite's code, flash on Space? TextEdit may be TextKit 2, so it does not settle this.

## Decision

Accepted 2026-10-18 as a bug. The three open questions carry forward to the plan.
