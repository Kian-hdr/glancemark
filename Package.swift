// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Glancemark",
    platforms: [.macOS("27.0")],
    products: [.library(name: "GlancemarkCore", targets: ["GlancemarkCore"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3")
    ],
    targets: [
        .target(name: "CReaderHTTPS", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "GlancemarkCore", dependencies: ["CReaderHTTPS", .product(name: "Markdown", package: "swift-markdown")],
                resources: [.process("Resources/Emoji_Aliases.json"), .process("Resources/Gemoji_LICENSE.txt"),
                            .process("Resources/Gemoji_Provenance.txt"), .copy("Resources/Rich"), .copy("Resources/Highlight")]),
        .target(name: "GlancemarkEditor", dependencies: ["GlancemarkCore"], path: "App",
                exclude: ["AppearanceSettings.swift", "Credits.rtf", "Info.plist", "Main.swift", "Release.entitlements"]),
        .testTarget(name: "GlancemarkCoreTests", dependencies: ["GlancemarkCore"]),
        .testTarget(name: "GlancemarkEditorTests", dependencies: ["GlancemarkEditor", "GlancemarkCore"])
    ]
)
