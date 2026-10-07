# CLAUDE.md — Downwrite

Native macOS Markdown editor (SwiftUI + AppKit/TextKit 1). Goal: Bear-like editing — Markdown syntax hidden unless the caret is inside the pair — as a light-weight default `.md` app. See `README.md` for the user-facing description.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/DownwriteCore` | **Pure Swift** (Foundation + swift-markdown). No AppKit/SwiftUI. Builds and tests on Linux. |
| `Sources/Downwrite` | macOS-only app target (`#if os(macOS)` in `Package.swift`). |
| `Tests/DownwriteCoreTests` | Core unit tests — run on Linux and macOS. |
| `Tests/DownwriteTests` | macOS integration tests (real `NSTextView`, WKWebView). |
| `Packaging/` | `Info.plist` (template: `__VERSION__`/`__BUILD__`), entitlements, icon artwork + `AppIcon.icon`. |
| `scripts/` | `build-app.sh`, `make-dmg.sh`, `linux-test.sh`, `generate-icons.py`. |
| `.github/workflows/` | `ci.yml` (Linux core + macOS build/test/e2e), `release.yml` (tag → DMG). |

## Commands

```bash
scripts/linux-test.sh                  # core tests in the Swift Docker image (works without a Mac)
swift test                             # macOS: everything
swift build && swift run Downwrite     # macOS: debug run
scripts/build-app.sh                   # macOS: dist/Downwrite.app
dist/Downwrite.app/Contents/MacOS/Downwrite --selftest-out=<dir> --selftest-input=<file.md>   # e2e, writes selftest-report.txt
python3 scripts/generate-icons.py      # regenerate icon artwork (needs Pillow)
```

In the cloud (Linux) container there is **no Xcode/macOS**. The app target cannot be compiled there. Workflow that works:
1. Develop and test everything in `DownwriteCore` locally with `scripts/linux-test.sh` (Docker daemon may need `dockerd &`; pull `mirror.gcr.io/library/swift:6.1-noble` if Docker Hub rate-limits).
2. Push the working branch; CI builds/tests the app on `macos-26` (Xcode 26.x, Swift 6.3). Read failures via the Actions logs (`get_job_logs` with a small `tail_lines`; the workflow already prints only error lines).
3. Put `[shots]` in a commit message to make CI commit fresh screenshots to `docs/screenshots/` (normal push to the same branch — **never** force-push or push other branches from CI or by hand). `git pull --rebase` before your next push.

## Architecture rules

- **All Markdown/editing logic belongs in `DownwriteCore`** so it is unit-testable on Linux. The app target only maps results onto AppKit.
- Offsets are **UTF-16** (`NSRange`) everywhere. cmark reports (line, UTF-8 column); `SourceText.offset(line:column:)` converts. Text in the editor always uses `\n`; `TextCoding` restores CRLF/BOM/encoding on save.
- `MarkdownAnalyzer.analyze` → immutable `MarkdownAnalysis` (spans, markers + reveal ranges, per-line `LineStyle`, links, task boxes, Mermaid blocks, tables). Selection-dependent state (`hidden` markers) is computed on demand by `runs(in:selection:)` / `hiddenMarkerIndices(selection:)`. Reveal rule: selection touches `marker.reveal` inclusive of both boundaries.
- cmark ranges are **wrong for nested emphasis sharing a delimiter run** (`***x***`, `*a **b***`); `MarkdownAnalyzer.effective(_:in:)` shifts children inward. Keep tests in `AnalyzerTests.testUnderscoreEmphasisAndTripleNesting` green.
- Formatting commands (`Formatter`, `ListEditing`, `TableFormatter`) are pure `(text, selection) -> TextEdit?`. The app applies them with `shouldChangeText` → `replaceCharacters` → `didChangeText` so undo works (`EditorTextView.apply`).
- **Hiding syntax** = 0.1 pt clear font on marker characters (`MarkdownStyler`), *not* deleting or glyph-nulling. Whole fence lines / collapsed Mermaid sources use `min/maxLineHeight = 0.1`.
- Editor is **TextKit 1** (`DWLayoutManager`, explicit `NSTextStorage/NSLayoutManager/NSTextContainer`) for predictable custom drawing (code cards, pills, quote bars, rules). Do not touch `textView.textLayoutManager` — that silently flips it to TextKit 2/1 fallback.
- Mermaid: `MermaidService` renders SVG in a hidden `WKWebView` (bundled `mermaid.min.js`, `securityLevel: strict`); `DiagramOverlay` owns one click-through `DiagramView` per block and tells the styler how much `paragraphSpacing` to reserve on the block's last line. Source collapses while the caret is outside the block.
- Resources are loaded through `AppResources.url` (app bundle first, SwiftPM `Bundle.module` fallback). `build-app.sh` flattens `Sources/Downwrite/Resources/*` into `Contents/Resources`.
- Theme = `NSApp.appearance` override from the `theme` default (`system|light|dark`); palettes live in `Palette` and are picked from the view's `effectiveAppearance`. Dock icon swaps `AppIcon-light/dark.png` by system appearance. The Finder/system icon is `Packaging/AppIcon.icon` (Icon Composer) compiled by `actool` in `build-app.sh`; it uses ONE glyph layer for all appearances (per-appearance glyph overrides were not honoured) and only the background fill changes. Regenerate everything with `scripts/generate-icons.py`.
- Swift language mode is v5 (`swiftLanguageModes: [.v5]`) to avoid strict-concurrency churn in AppKit code.

## Gotchas learned the hard way

- swift-corelibs-foundation (Linux) differs from Darwin: avoid `x as NSString` (use `NSString(string:)`), no Windows-1252 codec (hand-rolled in `TextCoding`), `String(data:encoding:.utf8)` is lossy instead of failing.
- `NSIntersectionRange`, `lineRange(for:)` etc. operate in UTF-16 — never mix with `String.Index`.
- Don't call `NSTextStorage.setAttributes` outside `begin/endEditing`, and ignore selection callbacks while styling (`isStyling` flag in `EditorCoordinator`).
- `textViewDidChangeSelection` fires *before* `textDidChange` when typing; the coordinator guards on `analysis.length == storage.length`.
- Info.plist template tokens are replaced by `build-app.sh`; `AppTests.testInfoPlistClaimsMarkdownFiles` guards the file-association keys.

## Quality bar

- Every Core change ships with unit tests; `scripts/linux-test.sh` must be green before pushing.
- Keep the app **light**: no new dependencies without a strong reason (current: swift-markdown, bundled Mermaid).
- UI changes: add/adjust `StylerTests`/`EditorBehaviourTests` and look at the CI snapshots (`SnapshotTests`, `--selftest` window captures).
