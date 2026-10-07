# Third-party notices

Downwrite is licensed under the GNU General Public License v3.0 (see `LICENSE`). It includes the following third-party
software, each under a licence that is compatible with GPL-3.0. Their full licence texts are in `ThirdParty/` in the source
repository and in `Downwrite.app/Contents/Resources/Legal/` inside the app.

| Component | Used for | Licence | Copyright | Text |
| --- | --- | --- | --- | --- |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown parsing (Swift package, linked into the app) | Apache-2.0 | © 2021 Apple Inc. and the Swift project authors | `ThirdParty/swift-markdown-LICENSE.txt`, `ThirdParty/swift-markdown-NOTICE.txt` |
| [cmark-gfm](https://github.com/github/cmark-gfm) (via [swift-cmark](https://github.com/swiftlang/swift-cmark)) | CommonMark + GFM parser used by swift-markdown | BSD-2-Clause (with MIT components; see file) | © 2014 John MacFarlane, GitHub, Inc. and contributors | `ThirdParty/cmark-gfm-COPYING.txt` |
| [Mermaid](https://github.com/mermaid-js/mermaid) 11.17.2 | Diagram rendering (`mermaid.min.js`, bundled and run offline in a WebKit view) | MIT | © 2014 – 2022 Knut Sveidqvist | `ThirdParty/mermaid-LICENSE.txt` |

## Libraries inside the Mermaid bundle

`mermaid.min.js` is a single file that embeds Mermaid's own dependencies. Mermaid's direct dependencies (checked against
the npm registry for version 11.17.2) are licensed MIT (19), ISC (1), BSD-3-Clause (1) and DOMPurify, which is dual-licensed
`MPL-2.0 OR Apache-2.0` and is used here under Apache-2.0. All of these are GPL-3.0-compatible. Transitive dependencies of
those libraries were not audited individually; see the Mermaid project for the authoritative list.

## Compatibility note

Apache-2.0 code may be combined into a GPL-3.0 work (it is *not* compatible with GPL-2.0-only, which is one reason this
project is GPL-3.0). If a dependency is added or upgraded, update this file and `ThirdParty/`.
