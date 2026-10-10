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

## Configuration

The app reads `AGENTMUX_CONFIG`, or `~/Library/Application Support/AgentMux/targets.json5`. The format is `config/targets.example.json5`. Targets with `access: "observe"` are only listed and probed; terminals open on `interact` and `test` targets.

## Development tool

```sh
.build/arm64-apple-macosx/debug/agentmux-cli probe [target-id ...]     # read-only inventory and agent detection
.build/arm64-apple-macosx/debug/agentmux-cli clients <target-id>       # read-only client list with AgentMux tags
.build/arm64-apple-macosx/debug/agentmux-cli attach-test <target-id> <pane> [--type TEXT]   # test targets only
.build/arm64-apple-macosx/debug/agentmux-cli release-orphans <target-id>                   # test targets only
```

Scripted app check: `AGENTMUX_OPEN=<target>/<pane> AGENTMUX_SMOKE_INPUT=<text> AGENTMUX_SMOKE_DUMP=<file>` opens the pane, pastes the text, writes the visible screen to the file and quits.

## Layout

```text
Sources/CPTY/          forkpty + execve (C)
Sources/AgentMuxCore/  config, remote commands, tmux inventory, agent detection, attach/release
Sources/AgentMux/      macOS app (SwiftUI + AppKit + GhosttyTerminal)
Sources/agentmux-cli/  development tool for the remote path
Tests/                 swift-testing unit tests
Vendor/libghostty-spm/ pinned terminal engine with one resource-lookup patch
config/                local target config (*.local.json5 is not committed)
docs/                  requirements, decision records, observed compatibility
```

## Status

- Read-only inventory of configured targets over one ssh connection per refresh, with agent detection from process evidence (type, version, config directory, confidence) and task titles from the agents' terminal titles. Activity (working / waiting) is not detected yet.
- Native macOS window: `NavigationSplitView`, a sidebar `List` grouped by working directory with native selection and search, a standard titlebar, toolbar and status bars.
- Selecting an agent or pane on an `interact` / `test` target opens a live mirror over tmux control mode on a per-view grouped session: the agent's window is softly resized to fill the view at a readable font (kitty-style, self-healing, no restore), input and paste go to that pane only, and the user's current window / window list are untouched (ADR 0003, ADR 0004). At most 4 mirrors stay open at once.
- Not done yet: activity detection, notifications, connection multiplexing, diagnostics export, OSC 52 clipboard policy.
