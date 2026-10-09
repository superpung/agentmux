# AgentMux

A Mac console for remote coding agents: it reaches existing tmux sessions through SSH → `docker exec`, shows where every Codex / Claude Code instance runs, and opens the real terminal it lives in. Requirements: `docs/requirements.md`.

## Build

Requires `~/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain` (see `docs/decisions/0001-toolchain-terminal-packaging.md`). Xcode is not needed.

```sh
. scripts/env.sh
swiftpm build              # debug build
swiftpm test               # unit tests
scripts/bundle-app.sh      # build and sign build/AgentMux.app
open build/AgentMux.app
```

## Layout

```text
Sources/CPTY/          forkpty + execve (C)
Sources/AgentMuxCore/  transport, target adapters, tmux parsing, domain model (no UI)
Sources/AgentMux/      macOS app (SwiftUI + AppKit + GhosttyTerminal)
Tests/                 swift-testing unit tests
Vendor/libghostty-spm/ pinned terminal engine with one resource-lookup patch
config/                local target config (*.local.json5 is not committed)
docs/                  requirements, decision records, observed compatibility
```

## Status

M0 in progress: toolchain, terminal engine and local PTY work. The remote side has only been probed read-only.
