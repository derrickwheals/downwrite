import Foundation

enum AppResources {
    /// Looks in the app bundle's Resources first (packaged app), then the SwiftPM resource bundle (dev builds, tests).
    static func url(_ name: String, _ ext: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        if let u = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") { return u }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
