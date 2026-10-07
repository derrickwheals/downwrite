// swift-tools-version: 6.0
import PackageDescription

// DownwriteCore is pure Swift (Foundation + swift-markdown) so its logic can be
// built and tested on Linux CI as well as macOS. The app target is macOS-only.
var products: [Product] = [
    .library(name: "DownwriteCore", targets: ["DownwriteCore"]),
]

var targets: [Target] = [
    .target(
        name: "DownwriteCore",
        dependencies: [.product(name: "Markdown", package: "swift-markdown")]
    ),
    .testTarget(name: "DownwriteCoreTests", dependencies: ["DownwriteCore"]),
]

#if os(macOS)
products += [.executable(name: "Downwrite", targets: ["Downwrite"])]
targets += [
    .executableTarget(
        name: "Downwrite",
        dependencies: ["DownwriteCore"],
        resources: [.copy("Resources")]
    ),
    .testTarget(name: "DownwriteTests", dependencies: ["Downwrite", "DownwriteCore"]),
]
#endif

let package = Package(
    name: "Downwrite",
    platforms: [.macOS("26.0")],
    products: products,
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.9.0")),
    ],
    targets: targets,
    swiftLanguageModes: [.v5]
)
