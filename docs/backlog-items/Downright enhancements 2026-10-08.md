# Downwrite small enhancements and fixes

1. Bug: Text selection in a code block is not visible
```
test
```
2. Bug: Inline code snippets have too high a `Highlight` for the snippet background - reduce the height to just above a capital letter (same gap as between the lower highlight margin and the tails of letters like "g" and "y"
3. Enhancement: Autocomplete code block backticks (grave accents) . After typing the three backticks at the start of a new line to start a `code block`, after the third back tick is typed, it should automatically add two new line feeds and an then the three closing back ticks.
4. Enhancement: Tasks ("- [ ]") should render as clean square checkboxes with rounded corners. Clicking on the checkbox should toggle between checked and unchecked
5. Enhancement: Add a "source" view, where the raw markdown text is shown and is editable like a normal text editor. I should be able to toggle this setting from a button to the left of the text formatting button in the toolbar.
6. Enhancement: Additional theme choices. Take inspiration from Bear and https://vscodethemes.com. Just 3 or 4 light and dark themes each. Possibility to add themes using a standard JSON format like used by VS Code
7. Enhancement: Add a "Keep on top" Window menu item that keeps the current app window floating above other windows