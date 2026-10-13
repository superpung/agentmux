// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentMux",
    platforms: [.macOS(.v14)],
    dependencies: [
        // libghostty-spm, vendored at a pinned tag with one resource-lookup
        // patch; see scripts/vendor-libghostty.sh and Vendor/libghostty-spm/VENDORED.
        // Its binary target still downloads the prebuilt GhosttyKit.xcframework.
        .package(path: "Vendor/libghostty-spm"),
        // Syntax highlighting for the file preview (highlight.js via
        // JavaScriptCore; MIT). UI target only.
        .package(url: "https://github.com/raspu/Highlightr.git", exact: "2.3.0"),
        // Rendered Markdown preview (SwiftUI-native; MIT). UI target only.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    ],
    targets: [
        // forkpty + execve. The child after fork must only make
        // async-signal-safe calls, which Swift cannot guarantee.
        .target(name: "CPTY"),
        // Domain, transport, target adapters and tmux parsing. No UI imports.
        .target(
            name: "AgentMuxCore",
            dependencies: ["CPTY"]
        ),
        .executableTarget(
            name: "AgentMux",
            dependencies: [
                "AgentMuxCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        // Development tool: read-only inventory of configured targets.
        .executableTarget(
            name: "agentmux-cli",
            dependencies: ["AgentMuxCore"]
        ),
        .testTarget(
            name: "AgentMuxCoreTests",
            dependencies: ["AgentMuxCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
