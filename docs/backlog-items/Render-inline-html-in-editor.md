# Render inline HTML in the editor

When in "formatted view", the editor should render any html that is place inline within the document. 

The editor draws everything itself and there’s no web view for HTML. Rendering some HTML would also need a decision about what’s safe to render. Need to start with a short plan covering which tags to support and how to render them.

## Status

- [x] Done: top-level HTML blocks render as cards under their collapsed source; `<kbd> <b> <i> <u> <s> <mark> <code> <sub> <sup> <a href>` render in-flow with their tags hidden until the caret touches them. See README → *Inline HTML* and CLAUDE.md for the design and the known limitations.
