# Render inline HTML in the editor

When in "formatted view", the editor should render any html that is place inline within the document. 

The editor draws everything itself and there’s no web view for HTML. Rendering some HTML would also need a decision about what’s safe to render. Need to start with a short plan covering which tags to support and how to render them.