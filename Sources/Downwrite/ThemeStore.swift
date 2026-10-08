import AppKit
import DownwriteCore

/// The colour themes the person has imported from VS Code theme files. Each is converted once (`VSCodeTheme.convert`) and kept
/// as a small `StoredTheme` JSON file in `~/Library/Application Support/Downwrite/Themes`, so it keeps working whatever
/// happens to the original file.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    /// Built-in and imported themes, for the pickers and for resolving the chosen ids.
    @Published private(set) var library = ThemeLibrary()
    /// Bumped whenever the library changes, so open editors repaint even when the chosen id did not (a theme re-imported).
    @Published private(set) var revision = 0
    /// Where the themes live. Tests point it at a temporary folder.
    var directory: URL

    /// Files bigger than this are not theme files.
    static let maximumFileSize = 5_000_000

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        reload()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downwrite", isDirectory: true).appendingPathComponent("Themes", isDirectory: true)
    }

    struct ImportResult {
        let theme: ThemeDefinition
        /// What the importer had to guess or could not use.
        let warnings: [String]
        /// An imported theme with the same name and appearance was replaced.
        let replaced: Bool
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case tooLarge
        case damaged

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "The file could not be read (\(why))."
            case .tooLarge: return "The file is too large to be a colour theme."
            case .damaged: return "The converted theme could not be saved."
            }
        }
    }

    /// Reads the themes folder again (themes that cannot be read are skipped).
    func reload() {
        var found: [ThemeDefinition] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(StoredTheme.self, from: data),
                  let definition = stored.definition() else { continue }
            found.append(definition)
        }
        library = ThemeLibrary(imported: found)
        revision += 1
    }

    /// Converts a VS Code theme file and adds it to the library (replacing one with the same name and appearance).
    @discardableResult
    func importTheme(from url: URL) throws -> ImportResult {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ImportError.unreadable(error.localizedDescription) }
        guard data.count <= Self.maximumFileSize else { throw ImportError.tooLarge }
        let base = url.deletingLastPathComponent()
        let converted = try VSCodeTheme.convert(TextCoding.decode(data).text, fallbackName: url.deletingPathExtension().lastPathComponent) { include in
            // `include` paths are relative to the including file.
            let target = URL(fileURLWithPath: include, relativeTo: base).standardizedFileURL
            guard let included = try? Data(contentsOf: target), included.count <= Self.maximumFileSize else { return nil }
            return TextCoding.decode(included).text
        }
        let id = StoredTheme.identifier(name: converted.name, appearance: converted.appearance)
        let stored = StoredTheme(id: id, name: converted.name, appearance: converted.appearance, source: url.lastPathComponent, palette: converted.palette)
        guard let definition = stored.definition() else { throw ImportError.damaged }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(id).json")
        let replaced = FileManager.default.fileExists(atPath: file.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: file, options: .atomic)
        reload()
        return ImportResult(theme: definition, warnings: converted.warnings, replaced: replaced)
    }

    func remove(id: String) {
        guard id.hasPrefix("custom-") else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        reload()
    }
}
