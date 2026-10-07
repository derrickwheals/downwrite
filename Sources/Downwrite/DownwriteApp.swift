import SwiftUI
import AppKit
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

    private var settings: EditorSettings {
        EditorSettings(font: FontChoice(rawValue: fontRaw) ?? .avenirNext, size: fontSize, lineHeight: lineHeight, width: width,
                       spellCheck: spellCheck)
    }

    var body: some View {
        EditorView(text: $document.text, settings: settings, fileURL: fileURL)
            .ignoresSafeArea()
            .overlay(alignment: .bottomTrailing) {
                StatusPill(text: document.text)
                    .padding(16)
                    .allowsHitTesting(false)
            }
            .frame(minWidth: 420, minHeight: 320)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        FormatMenuItems()
                    } label: {
                        Label("Format", systemImage: "textformat")
                    }
                    .help("Format")
                }
            }
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
    static func indent() { NSApp.sendAction(#selector(EditorTextView.dwIndent(_:)), to: nil, from: nil) }
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
            Divider()
            Button("Indent") { Responder.indent() }.keyboardShortcut("]", modifiers: .command)
            Button("Outdent") { Responder.outdent() }.keyboardShortcut("[", modifiers: .command)
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

    var body: some Commands {
        CommandGroup(after: .toolbar) {
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

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.theme) private var theme = ThemeChoice.system.rawValue
    @AppStorage(Prefs.font) private var font = FontChoice.avenirNext.rawValue
    @AppStorage(Prefs.fontSize) private var fontSize = 17.0
    @AppStorage(Prefs.lineHeight) private var lineHeight = 1.45
    @AppStorage(Prefs.width) private var width = 720.0
    @AppStorage(Prefs.spellCheck) private var spellCheck = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Section("Typography") {
                Picker("Font", selection: $font) {
                    ForEach(FontChoice.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $fontSize, in: 12...28, step: 1)
                        Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Line spacing") {
                    HStack {
                        Slider(value: $lineHeight, in: 1.1...2.0, step: 0.05)
                        Text(String(format: "%.2f×", lineHeight)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Text width") {
                    HStack {
                        Slider(value: $width, in: 480...1100, step: 20)
                        Text("\(Int(width)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Section("Writing") {
                Toggle("Check spelling while typing", isOn: $spellCheck)
            }
            Section("Files") {
                Button("Make Downwrite the Default Markdown App") {
                    Task { message = await DefaultHandler.claim() }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
