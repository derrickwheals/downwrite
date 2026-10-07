# Downwrite

A quiet, native Markdown editor for the Mac — light-weight, beautiful to type in, and happy to be your default `.md` app.

Markdown syntax **disappears while you read** and **comes back when your cursor touches it**. Click into a bold word and the asterisks fade in; move away and they vanish. Everything is built with SwiftUI + AppKit, with no Electron, no web editor and no account.

<p align="center">
  <img src="docs/screenshots/window-light.png" width="48%" alt="Downwrite in light mode">
  <img src="docs/screenshots/window-dark.png" width="48%" alt="Downwrite in dark mode">
</p>
<p align="center">
  <img src="docs/screenshots/window-light-diagram.png" width="60%" alt="A Mermaid diagram rendered inline">
</p>

<sub>Screenshots are captured automatically from the real app on a macOS 26 runner by the end-to-end self-test (see Testing).</sub>

## Features

- **Hidden syntax, Bear-style.** `**bold**`, `*italic*`, `` `code` ``, `[links](…)`, `# headings`, `> quotes`, code fences… all collapse to clean typography and re-expand around the caret.
- **CommonMark + GFM + extras.** Full CommonMark (via Apple's `swift-markdown` / cmark-gfm), plus tables, task lists (click to tick), strikethrough, autolinks, `==highlight==`, `[^footnotes]`, `$math$` styling and YAML front matter.
- **Mermaid diagrams.** Fenced ```` ```mermaid ```` blocks render as live diagrams (flowcharts, sequence, class, state, ER, Gantt, pie, journey, git graph, mind maps…). Mermaid is bundled, so it works offline. Click a diagram to edit its source; it re-renders as you type.
- **Beautiful type.** Avenir Next (default), New York, SF Pro, Charter or SF Mono, with adjustable size, line spacing and column width. A centred readable column, rounded code cards, quote bars and soft rules.
- **Light, dark or follow macOS.** Settings → Theme (or View ▸ Appearance). The Dock icon switches between light and dark artwork too.
- **Liquid Glass.** Built for macOS 26 "Tahoe" and ready for macOS 27 "Golden Gate": system toolbar and window chrome adopt Liquid Glass automatically, and the floating word-count pill uses `glassEffect`.
- **A proper Mac document app.** Tabs, Versions, autosave, Open Recent, drag-and-drop onto the Dock icon, Find (⌘F), full undo/redo. Opens and saves UTF-8 (± BOM), UTF-16 and legacy Windows-1252 files and **preserves line endings** (LF / CRLF) so it never rewrites a file's format behind your back.
- **Smart keys.** Return continues lists, tasks, numbered lists and quotes (press it twice to leave); Tab / ⇧Tab indent and outdent; paste a URL over selected text to make a link.
- **Small.** Under 10 MB on disk, most of it the bundled Mermaid engine. No network access needed except for remote images.
- **Inline images.** `![alt](path)` on its own line shows the picture below the (collapsed) Markdown.

## Keyboard shortcuts

| Action | Shortcut | Action | Shortcut |
| --- | --- | --- | --- |
| **Bold** | ⌘B | Bulleted list | ⇧⌘8 |
| *Italic* | ⌘I | Numbered list | ⇧⌘7 |
| ~~Strikethrough~~ | ⇧⌘X | Task list | ⇧⌘9 |
| ==Highlight== | ⇧⌘H | Block quote | ⇧⌘. |
| `Inline code` | ⌘E | Code block | ⌥⌘C |
| Link | ⌘K | Horizontal rule | ⌥⌘- |
| Heading 1–6 | ⌘1 … ⌘6 | Insert / format table | ⌥⌘T / ⇧⌥⌘T |
| Body text | ⌘0 | Indent / outdent | ⌘] / ⌘[ (or Tab / ⇧Tab in lists) |
| Find | ⌘F | Bigger / smaller text | ⌘= / ⌘- |

Pressing a formatting shortcut again removes the formatting. With nothing selected it wraps the word under the caret (or inserts an empty pair). Standard shortcuts (⌘Z, ⇧⌘Z, ⌘C/V/X, ⌘A, ⌘S, ⌘W, ⌘T …) work as in any Mac app. ⌘-click a link to open it.

## Requirements

- **To run:** macOS 26 (Tahoe) or later — including macOS 27 (Golden Gate).
- **To build:** Xcode 26 or later (Swift 6.2+). Command Line Tools alone are not enough because the app needs the macOS 26 SDK.

## Build and run

```bash
git clone https://github.com/derrickwheals/downwrite.git
cd downwrite

swift run Downwrite          # quick debug run (no bundle, no file associations)
swift test                   # unit + integration tests (needs a GUI session on macOS)
scripts/build-app.sh         # → dist/Downwrite.app  (release build, ad-hoc signed)
open dist/Downwrite.app
```

`scripts/build-app.sh` accepts `VERSION`, `BUILD`, `CONFIG` and `SIGN_IDENTITY` environment variables:

```bash
VERSION=1.2.0 BUILD=42 scripts/build-app.sh
```

### Install locally

```bash
cp -R dist/Downwrite.app /Applications/
```

An ad-hoc signed build runs fine on the Mac that built it. If you copy it to another Mac, macOS will quarantine it: right-click ▸ **Open** once, or run `xattr -dr com.apple.quarantine /Applications/Downwrite.app`.

### Make Downwrite your default Markdown editor

Any one of:

1. **Downwrite ▸ Make Downwrite the Default Markdown App** (or Settings ▸ Files) — macOS asks you to confirm.
2. In Finder, select any `.md` file ▸ **Get Info** (⌘I) ▸ **Open with** ▸ Downwrite ▸ **Change All…**
3. From the Terminal: Downwrite declares itself the *Owner* of `net.daringfireball.markdown` (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn`, `.mdwn`, `.mdtxt`, `.mdtext`) and an *Alternate* for plain text.

## Deployment (distributable build)

To share Downwrite outside your own Mac you need an Apple Developer ID certificate.

```bash
# 1. Build, sign with hardened runtime + secure timestamp
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" VERSION=1.0.0 BUILD=1 scripts/build-app.sh

# 2. Package
VERSION=1.0.0 scripts/make-dmg.sh            # → dist/Downwrite-1.0.0.dmg

# 3. Notarize and staple (one-time: xcrun notarytool store-credentials "downwrite-notary" …)
xcrun notarytool submit dist/Downwrite-1.0.0.dmg --keychain-profile "downwrite-notary" --wait
xcrun stapler staple dist/Downwrite-1.0.0.dmg

# 4. Verify
spctl --assess --type open --context context:primary-signature -v dist/Downwrite-1.0.0.dmg
```

The app is **not sandboxed** (it reads sibling files for relative links and opens documents anywhere you point it). If you want to publish to the Mac App Store, add the App Sandbox entitlements (`com.apple.security.app-sandbox`, `…files.user-selected.read-write`, `…network.client` for WebKit) to `Packaging/Downwrite.entitlements` and sign with an App Store identity.

### Releases from GitHub

Pushing a tag like `v1.0.0` runs `.github/workflows/release.yml`, which builds on a `macos-26` runner, packages `Downwrite-<version>.dmg` and attaches it to a GitHub Release. If the repository has the secrets `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `DEVELOPER_ID_NAME`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` (an app-specific password), the release is Developer-ID signed and notarized; otherwise it is ad-hoc signed.

## Testing

Three layers, all run by CI on every push (see `.github/workflows/ci.yml`):

| Layer | Where | What it covers |
| --- | --- | --- |
| **Core unit tests** (`Tests/DownwriteCoreTests`) | Linux *and* macOS | The Markdown analysis engine (CommonMark/GFM structure, hidden-marker rules, Unicode/CRLF offsets, adversarial input), every formatting shortcut, list/quote continuation, tables, file encodings and line endings, palette contrast (WCAG), Mermaid helpers. |
| **App integration tests** (`Tests/DownwriteTests`) | macOS | Real `NSTextView` editor in a real window: attributes for every Markdown construct, markers hiding/revealing as the caret moves, typing, undo/redo, smart Return/Tab, paste-to-link, theme switching, Mermaid rendering of ten diagram types plus error handling, Info.plist file-association checks, and PNG snapshots for visual review. |
| **End-to-end self-test** (`Downwrite --selftest`) | macOS | Launches the *packaged app*, opens a file through the document system, presses real ⌘B/⌘I/⌘E/⌘2/⌘K key events through the real menu bar, types, saves to disk and re-reads the file, waits for a Mermaid card, flips light → dark → system theme, and screenshots the actual window. |

Run the core tests on any machine with Docker (no Mac needed):

```bash
scripts/linux-test.sh
```

Run the end-to-end test yourself:

```bash
scripts/build-app.sh
dist/Downwrite.app/Contents/MacOS/Downwrite --selftest-out=/tmp/downwrite-e2e --selftest-input="$PWD/Sources/Downwrite/Resources/Welcome.md"
cat /tmp/downwrite-e2e/selftest-report.txt
```

## Project layout

```
Sources/DownwriteCore/   Pure Swift (Foundation + swift-markdown): analysis, commands, palettes, file coding
Sources/Downwrite/       macOS app: SwiftUI shell, TextKit 1 editor, styler, Mermaid renderer, settings
Tests/DownwriteCoreTests Linux + macOS unit tests
Tests/DownwriteTests     macOS integration tests
Packaging/               Info.plist, entitlements, icon artwork
scripts/                 build-app.sh, make-dmg.sh, linux-test.sh, generate-icons.py
ThirdParty/              Third-party licences (Mermaid, MIT)
```

How it works, in one paragraph: `MarkdownAnalyzer` parses the text with cmark-gfm and produces an immutable `MarkdownAnalysis` — style spans, *marker* ranges (the syntax characters) with the range that reveals each one, and per-line block styles. `MarkdownStyler` turns that into `NSTextStorage` attributes; hidden markers get a 0.1 pt clear font so they stay in the text (copy, undo and find keep working) but take no space. When the caret moves, only the lines whose markers changed state are restyled. Mermaid blocks are rendered once in a hidden `WKWebView` to SVG and shown in a click-through card placed in vertical space reserved under the collapsed source.

## Known limitations

- Images are previewed inline when they sit on a line of their own (local paths are resolved relative to the document; `http(s)` images load from the network). Images inside a paragraph are styled but not previewed.
- Math (`$…$`, `$$…$$`) is styled, not typeset.
- Liquid Glass chrome comes from the system on macOS 26+; Downwrite deliberately keeps the writing surface opaque for legibility. Icon Composer light/dark/tinted variants are compiled with `actool` when it succeeds in `scripts/build-app.sh`; otherwise the app falls back to the bundled `.icns` (the Dock icon still switches light/dark at runtime).
- Built and tested against the macOS 26 SDK (Xcode 26.x). macOS 27 specific APIs are not required.

## Credits

Markdown parsing by [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm). Diagrams by [Mermaid](https://mermaid.js.org) (MIT, see `ThirdParty/mermaid-LICENSE.txt`).
