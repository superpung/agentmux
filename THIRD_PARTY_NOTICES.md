# Third-Party Notices

AgentMux is distributed as a prebuilt macOS app on the
[Releases](https://github.com/superpung/agentmux/releases) page. The app binary
and bundle include the following third-party components, under their respective
licenses.

| Component | Use | License |
|---|---|---|
| [libghostty-spm](https://github.com/Lakr233/libghostty-spm) 2.2.2026100901 | Terminal engine (vendored in `Vendor/libghostty-spm`, one local patch) | MIT |
| [Ghostty](https://ghostty.org) (inside the prebuilt GhosttyKit.xcframework) | Terminal emulation and rendering | MIT |
| [DisplayLink](https://github.com/Lakr233/DisplayLink) 3.0.1 | Dependency of libghostty-spm | MIT |
| [Highlightr](https://github.com/raspu/Highlightr) 2.3.0 | Syntax-highlighted file previews | MIT; bundles [highlight.js](https://github.com/highlightjs/highlight.js) (BSD-3-Clause) |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1 | Rendered Markdown previews | MIT |
| [NetworkImage](https://github.com/gonzalezreal/NetworkImage) 6.0.1 | Remote images in Markdown previews (dependency of swift-markdown-ui) | MIT |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) 0.9.0 | CommonMark parsing (dependency of swift-markdown-ui) | BSD-2-Clause |
| [LobeHub icons](https://github.com/lobehub/lobe-icons) | `Resources/Icons/claude*.svg`, `codex*.svg` | MIT |
| [Simple Icons](https://simpleicons.org) | `Resources/Icons/` OS icons | CC0 1.0 |
| [MiSTerFTP](https://github.com/Simon-nhelix/mister-ftp) | Drag-out technique adapted in `Sources/AgentMux/Views/FileDragAndDrop.swift` | MIT |

Brand names and logos belong to their owners.
