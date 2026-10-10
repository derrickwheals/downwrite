import Foundation

/// A whole Markdown document as one HTML page, for printing and for export (R4: it depends on the text and the files the text refers to,
/// never on the window).
public enum DocumentHTML {
    /// Where the page is going. `print` is the paginated path (Print… and Export as PDF…): every `<details>` is open and the style has no
    /// column of its own. `screen` is the HTML file read in a browser.
    public enum Target: Sendable {
        case screen, print
    }
}
