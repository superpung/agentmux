// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentMux",
    platforms: [.macOS(.v14)],
    dependencies: [
        // libghostty-spm, vendored at a pinned tag with one host environment patch.
        // See scripts/vendor-libghostty.sh and Vendor/libghostty-spm/VENDORED.
        // Its binary target still downloads the prebuilt GhosttyKit.xcframework.
        .package(path: "Vendor/libghostty-spm"),
        // Pinned source with an app-bundle resource lookup patch. See
        // scripts/vendor-highlightr.sh and Vendor/Highlightr/VENDORED.
        .package(path: "Vendor/Highlightr"),
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
