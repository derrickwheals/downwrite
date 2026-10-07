import AppKit
import UniformTypeIdentifiers

/// Applies the theme preference and keeps the Dock icon in step with the system appearance.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var defaultsObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeChoice.applyCurrent()
        AppIcon.apply()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeChoice.applyCurrent() }
        }
        if SelfTest.arguments == nil, !UserDefaults.standard.bool(forKey: "hasShownWelcome") {
            UserDefaults.standard.set(true, forKey: "hasShownWelcome")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                WelcomeDocument.open()
            }
        }
        if SelfTest.arguments != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await SelfTest.run()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppIcon.apply() }
        }
    }

    /// New windows are created by the document system; nothing to do when the last one closes except quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Swaps the Dock icon between the light and dark artwork to match the macOS appearance.
enum AppIcon {
    @MainActor
    static func apply() {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        if let image = image(dark: dark) { NSApp.applicationIconImage = image }
    }

    static func image(dark: Bool) -> NSImage? {
        guard let url = AppResources.url(dark ? "AppIcon-dark" : "AppIcon-light", "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// "Make Downwrite the default app for Markdown files."
enum DefaultHandler {
    static let markdownTypeIdentifiers = ["net.daringfireball.markdown", "public.markdown"]

    @MainActor
    static func claim() async -> String {
        var done = 0
        var failures: [String] = []
        let bundleURL = Bundle.main.bundleURL
        var types = markdownTypeIdentifiers.compactMap { UTType($0) }
        if let byExtension = UTType(filenameExtension: "md") { types.append(byExtension) }
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type)
                done += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if done > 0 { return "Downwrite is now the default app for Markdown files." }
        return "Couldn't change the default app: " + (failures.first ?? "unknown error")
    }
}
