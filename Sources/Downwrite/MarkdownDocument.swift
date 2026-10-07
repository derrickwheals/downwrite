import SwiftUI
import UniformTypeIdentifiers
import DownwriteCore

extension UTType {
    /// `.md` and friends. Declared as an imported type in Info.plist so Downwrite can claim it.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// A Markdown file. Text is held with `\n` line endings; the original encoding, BOM and line endings are
/// remembered and restored on save so opening and saving never silently rewrites a file's format.
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdown, .plainText] }
    static var writableContentTypes: [UTType] { [.markdown, .plainText] }

    var text: String
    private var encoding: String.Encoding = .utf8
    private var hasBOM = false
    private var lineEnding: LineEnding = .lf

    init(text: String = "") { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let decoded = TextCoding.decode(data)
        text = decoded.text
        encoding = decoded.encoding
        hasBOM = decoded.hasBOM
        lineEnding = decoded.lineEnding
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: TextCoding.encode(text, encoding: encoding, bom: hasBOM, lineEnding: lineEnding))
    }
}
