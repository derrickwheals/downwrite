import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DownwriteCore

@main
struct DownwriteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            EditorScene(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 940, height: 740)
        .commands {
            FormatCommands()
            ViewCommands()
            WindowCommands()
            OutputCommands()
            AppCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Window content

struct EditorScene: View {
    @Binding var document: MarkdownDocument
    var fileURL: URL?

    @AppStorage(Prefs.font) private var fontRaw = FontChoice.avenirNext.rawValue
    @AppStorage(Prefs.fontSize) private var fontSize = 17.0
    @AppStorage(Prefs.lineHeight) private var lineHeight = 1.45
    @AppStorage(Prefs.width) private var width = 720.0
    @AppStorage(Prefs.spellCheck) private var spellCheck = false
    @AppStorage(Prefs.lightTheme) private var lightTheme = ThemeCatalog.defaultLightID
    @AppStorage(Prefs.darkTheme) private var darkTheme = ThemeCatalog.defaultDarkID
    @AppStorage(Prefs.showTOC) private var showTOC = false
    @StateObject private var toc = TOCModel()
    /// Print…, Export as PDF… and Export as HTML… for this window (see `DocumentOutput.swift`).
    @StateObject private var output = DocumentOutputController()
    @ObservedObject private var themeStore = ThemeStore.shared
    /// The source view is per window and starts off.
    @State private var sourceMode = false
    /// "Keep on Top" (Window menu) is per window and starts off.
    @State private var keepOnTop = false

    private var settings: EditorSettings {
        EditorSettings(font: FontChoice(rawValue: fontRaw) ?? .avenirNext, size: fontSize, lineHeight: lineHeight, width: width,
                       spellCheck: spellCheck, lightTheme: lightTheme, darkTheme: darkTheme, themeRevision: themeStore.revision)
    }

    var body: some View {
        EditorView(text: $document.text, settings: settings, fileURL: fileURL, toc: toc, sourceMode: sourceMode)
            // The editor starts *below* the toolbar/tab bar. The title bar is transparent (so the page colour runs behind the
            // toolbar), which means anything scrolled under it would show straight through.
            .ignoresSafeArea(.container, edges: [.leading, .trailing, .bottom])
            .overlay(alignment: .bottomTrailing) {
                StatusPill(text: document.text)
                    .padding(16)
                    .allowsHitTesting(false)
            }
            .inspector(isPresented: $showTOC) {
                TOCSidebar(model: toc)
                    .inspectorColumnWidth(min: 200, ideal: 250, max: 380)
            }
            .frame(minWidth: 420, minHeight: 320)
            .focusedSceneObject(output)
            .focusedSceneValue(\.sourceMode, $sourceMode)
            .focusedSceneValue(\.keepOnTop, $keepOnTop)
            .background(WindowLevelSetter(floating: keepOnTop))
            .background(WindowReader { window in configureOutput(for: window) })
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $sourceMode) {
                        Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .toggleStyle(.button)
                    .help(sourceMode ? "Back to the formatted view (⌘/)" : "Show the Markdown source (⌘/)")
                    .accessibilityIdentifier("source-toggle")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        FormatMenuItems()
                    } label: {
                        Label("Format", systemImage: "textformat")
                    }
                    .help("Format")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showTOC.toggle()
                    } label: {
                        Label("Table of Contents", systemImage: "sidebar.trailing")
                    }
                    .help(showTOC ? "Hide Table of Contents" : "Show Table of Contents")
                    .accessibilityIdentifier("toc-toggle")
                }
            }
    }
}

extension EditorScene {
    /// Tells the output controller which window it serves and how to read the document: the text as the editor holds it (not the file on
    /// disk), and the file the window is for *now* (an untitled document that is saved gets its folder from then on).
    fileprivate func configureOutput(for window: NSWindow?) {
        output.attach(window: window)
        let text = $document
        output.snapshot = { [weak window] in
            let nsDocument = window.flatMap { NSDocumentController.shared.document(for: $0) }
            let url = nsDocument?.fileURL
            return DocumentOutputController.Snapshot(text: text.wrappedValue.text, fileURL: url, displayName: url == nil ? "Untitled" : (nsDocument?.displayName ?? "Untitled"))
        }
    }
}

/// The frontmost window's source-view switch, for the View menu.
struct SourceModeKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var sourceMode: Binding<Bool>? {
        get { self[SourceModeKey.self] }
        set { self[SourceModeKey.self] = newValue }
    }
}

/// Floating word count in a Liquid Glass capsule.
struct StatusPill: View {
    let text: String

    var body: some View {
        let stats = text.utf16.count < 2_000_000 ? DocumentStats(text) : DocumentStats("")
        HStack(spacing: 6) {
            Text("\(stats.words) \(stats.words == 1 ? "word" : "words")")
            if stats.readingMinutes > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(stats.readingMinutes) min")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .accessibilityIdentifier("status-pill")
        .opacity(stats.words == 0 ? 0 : 1)
    }
}

// MARK: - Commands

@MainActor
enum Responder {
    static func format(_ command: FormatCommand) {
        NSApp.sendAction(#selector(EditorTextView.dwApplyFormat(_:)), to: nil, from: FormatCommandBox(command))
    }
    static func table(_ command: TableCommand) {
        NSApp.sendAction(#selector(TableGridView.dwTableCommand(_:)), to: nil, from: TableCommandBox(command))
    }
    static func indent() { NSApp.sendAction(#selector(EditorTextView.dwIndent(_:)), to: nil, from: nil) }
    static func fold() { NSApp.sendAction(#selector(EditorTextView.dwFold(_:)), to: nil, from: nil) }
    static func unfold() { NSApp.sendAction(#selector(EditorTextView.dwUnfold(_:)), to: nil, from: nil) }
    static func foldAll() { NSApp.sendAction(#selector(EditorTextView.dwFoldAll(_:)), to: nil, from: nil) }
    static func unfoldAll() { NSApp.sendAction(#selector(EditorTextView.dwUnfoldAll(_:)), to: nil, from: nil) }
    static func fold(toLevel level: Int) { NSApp.sendAction(#selector(EditorTextView.dwFoldToLevel(_:)), to: nil, from: FoldLevelBox(level)) }
    static func outdent() { NSApp.sendAction(#selector(EditorTextView.dwOutdent(_:)), to: nil, from: nil) }

    static func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
    }
}

/// Shared by the Format menu and the toolbar menu.
struct FormatMenuItems: View {
    var body: some View {
        Group {
            Button("Bold") { Responder.format(.bold) }.keyboardShortcut("b", modifiers: .command)
            Button("Italic") { Responder.format(.italic) }.keyboardShortcut("i", modifiers: .command)
            Button("Strikethrough") { Responder.format(.strikethrough) }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Highlight") { Responder.format(.highlight) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Code") { Responder.format(.inlineCode) }.keyboardShortcut("e", modifiers: .command)
            Button("Link…") { Responder.format(.link) }.keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Heading 1") { Responder.format(.heading(1)) }.keyboardShortcut("1", modifiers: .command)
            Button("Heading 2") { Responder.format(.heading(2)) }.keyboardShortcut("2", modifiers: .command)
            Button("Heading 3") { Responder.format(.heading(3)) }.keyboardShortcut("3", modifiers: .command)
            Button("Heading 4") { Responder.format(.heading(4)) }.keyboardShortcut("4", modifiers: .command)
            Button("Heading 5") { Responder.format(.heading(5)) }.keyboardShortcut("5", modifiers: .command)
            Button("Heading 6") { Responder.format(.heading(6)) }.keyboardShortcut("6", modifiers: .command)
            Button("Body Text") { Responder.format(.body) }.keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Bulleted List") { Responder.format(.bulletList) }.keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { Responder.format(.numberedList) }.keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Task List") { Responder.format(.taskList) }.keyboardShortcut("9", modifiers: [.command, .shift])
            Button("Block Quote") { Responder.format(.blockQuote) }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Code Block") { Responder.format(.codeBlock) }.keyboardShortcut("c", modifiers: [.command, .option])
        }
        Group {
            Divider()
            Button("Horizontal Rule") { Responder.format(.horizontalRule) }.keyboardShortcut("-", modifiers: [.command, .option])
            Button("Insert Table") { Responder.format(.insertTable) }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("Format Table") { Responder.format(.formatTable) }.keyboardShortcut("t", modifiers: [.command, .option, .shift])
            TableMenuItems()
            Divider()
            Button("Indent") { Responder.indent() }.keyboardShortcut("]", modifiers: .command)
            Button("Outdent") { Responder.outdent() }.keyboardShortcut("[", modifiers: .command)
        }
    }
}

/// Format ▸ Table: the same commands as the grid's right-click menu, for the cell that has focus.
struct TableMenuItems: View {
    var body: some View {
        Menu("Table") {
            Button("Insert Row Above") { Responder.table(.insertRowAbove) }
            Button("Insert Row Below") { Responder.table(.insertRowBelow) }
            Button("Insert Column Left") { Responder.table(.insertColumnLeft) }
            Button("Insert Column Right") { Responder.table(.insertColumnRight) }
            Divider()
            Button("Move Row Up") { Responder.table(.moveRowUp) }
            Button("Move Row Down") { Responder.table(.moveRowDown) }
            Button("Move Column Left") { Responder.table(.moveColumnLeft) }
            Button("Move Column Right") { Responder.table(.moveColumnRight) }
            Divider()
            Button("Duplicate Row") { Responder.table(.duplicateRow) }
            Button("Duplicate Column") { Responder.table(.duplicateColumn) }
            Button("Delete Row") { Responder.table(.deleteRow) }
            Button("Delete Column") { Responder.table(.deleteColumn) }
            Divider()
            Button("Align Column Left") { Responder.table(.align(.left)) }
            Button("Align Column Center") { Responder.table(.align(.center)) }
            Button("Align Column Right") { Responder.table(.align(.right)) }
            Button("Sort Column A → Z") { Responder.table(.sortAscending) }
            Button("Sort Column Z → A") { Responder.table(.sortDescending) }
            Divider()
            Button("Edit Table as Markdown") { Responder.table(.editAsMarkdown) }
            Button("Delete Table") { Responder.table(.deleteTable) }
        }
    }
}

struct FormatCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .textFormatting) { FormatMenuItems() }
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find…") { Responder.find(.showFindInterface) }.keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { Responder.find(.nextMatch) }.keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { Responder.find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { Responder.find(.setSearchString) }.keyboardShortcut("e", modifiers: [.command, .control])
            }
        }
    }
}

struct ViewCommands: Commands {
    @AppStorage(Prefs.theme) private var theme = ThemeChoice.system.rawValue
    @AppStorage(Prefs.fontSize) private var fontSize = 17.0
    @AppStorage(Prefs.showTOC) private var showTOC = false
    @FocusedBinding(\.sourceMode) private var sourceMode

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(sourceMode == true ? "Hide Markdown Source" : "Show Markdown Source") { sourceMode?.toggle() }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(sourceMode == nil)
            Button(showTOC ? "Hide Table of Contents" : "Show Table of Contents") { showTOC.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .control])
            Divider()
            // Folding acts on the frontmost editor and is not available while it shows the Markdown source.
            Button("Fold") { Responder.fold() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(sourceMode != false)
            Button("Unfold") { Responder.unfold() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(sourceMode != false)
            Button("Fold All") { Responder.foldAll() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift]).disabled(sourceMode != false)
            Button("Unfold All") { Responder.unfoldAll() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift]).disabled(sourceMode != false)
            Menu("Fold to Level") {
                ForEach(1...6, id: \.self) { level in Button("Heading \(level)") { Responder.fold(toLevel: level) } }
            }
            .disabled(sourceMode != false)
            Divider()
            Picker("Appearance", selection: $theme) {
                ForEach(ThemeChoice.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Divider()
            Button("Bigger Text") { fontSize = min(fontSize + 1, 36) }.keyboardShortcut("=", modifiers: .command)
            Button("Smaller Text") { fontSize = max(fontSize - 1, 11) }.keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { fontSize = 17 }.keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}

/// File ▸ Print…, Export as PDF… and Export as HTML…, together where Print belongs. They act on the frontmost document window and are
/// disabled when there is none (only Settings open) and while that window is preparing an output (R1, R2).
struct OutputCommands: Commands {
    @FocusedObject private var output: DocumentOutputController?

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            let unavailable = output == nil || output?.isPreparing == true
            Button("Print…") { output?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(unavailable)
            Button("Export as PDF…") { output?.exportPDF() }
                .disabled(unavailable)
            Button("Export as HTML…") { output?.exportHTML() }
                .disabled(unavailable)
        }
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Make Downwrite the Default Markdown App") {
                Task {
                    let message = await DefaultHandler.claim()
                    let alert = NSAlert()
                    alert.messageText = "Default Markdown App"
                    alert.informativeText = message
                    alert.runModal()
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Downwrite") { WelcomeDocument.open() }
            Link("Markdown Syntax Guide", destination: URL(string: "https://commonmark.org/help/")!)
        }
    }
}

/// Opens the bundled sample document as a fresh untitled copy in the temp directory.
@MainActor
enum WelcomeDocument {
    static func open() {
        guard let source = AppResources.url("Welcome", "md") else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Downwrite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Welcome to Downwrite.md")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
        NSDocumentController.shared.openDocument(withContentsOf: dest, display: true) { _, _, _ in }
    }
}
