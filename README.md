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

Everything is configured in the app's Settings window, written to `~/Library/Application Support/AgentMux/settings.json` (override with `AGENTMUX_SETTINGS`). Add SSH hosts in the **Hosts** tab (an `~/.ssh/config` alias or `user@host`), then pick which auto-discovered containers to monitor in the **Containers** tab. On first launch a legacy `targets.json5`, if present, is imported once.

## Development tool

A target is `<hostId>/<container>`, or a bare `<hostId>` with `--container NAME`.

```sh
.build/arm64-apple-macosx/debug/agentmux-cli probe [target ...]      # read-only inventory and agent detection
.build/arm64-apple-macosx/debug/agentmux-cli clients <target>       # read-only client list with AgentMux tags
.build/arm64-apple-macosx/debug/agentmux-cli containers <hostId>    # read-only `docker ps` on the host
.build/arm64-apple-macosx/debug/agentmux-cli attach-test <target> <pane> [--type TEXT]
.build/arm64-apple-macosx/debug/agentmux-cli release-orphans <target>
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
docs/                  requirements, decision records, observed compatibility
```

## Status

- Read-only inventory of the monitored containers over one ssh connection per refresh, with agent detection from process evidence (type, version, config directory, confidence), task titles from the agents' terminal titles, and activity (working / idle) from the session logs where available (Claude via its transcript, Codex via its rollout) with a conservative screen-rule fallback (notes in docs/compatibility.md). Only structural log fields are read, never conversation content. Approval / waiting-input states are not claimed yet.
- Native macOS window: `NavigationSplitView`, a sidebar `List` grouped by working directory with native selection and search, a standard titlebar, toolbar and status bars.
- Selecting an agent or pane opens a live mirror over tmux control mode on a per-view grouped session: the agent's window is softly resized to fill the view at a readable font (kitty-style, self-healing, no restore), input and paste go to that pane only, and the user's current window / window list are untouched (ADR 0003, ADR 0004). At most 4 mirrors stay open at once.
- Not done yet: activity detection, notifications, connection multiplexing, diagnostics export, OSC 52 clipboard policy.
