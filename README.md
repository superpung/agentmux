<div align="center">

<img src="docs/app-icon.png" width="120" alt="AgentMux icon" />

# AgentMux

**A native Mac console for your remote AI coding agents, with zero server-side footprint.**

Monitor every Claude Code and Codex agent running in tmux on your servers from one window, over plain SSH.

English | [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/superpung/agentmux?sort=semver)](https://github.com/superpung/agentmux/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/superpung/agentmux/total)](https://github.com/superpung/agentmux/releases)
![Platform](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-black?logo=apple)

</div>

<p align="center">
  <img src="docs/screenshots/dashboard.png" width="880" alt="AgentMux fleet dashboard" />
</p>
<p align="center">
  <img src="docs/screenshots/menu-bar.png" height="340" alt="Menu-bar extra" />
</p>

## Why

AI coding agents increasingly run on remote machines: in containers, over SSH, inside tmux, often several at once across projects and accounts. Checking on them means SSHing in, attaching to the right pane, and squinting at a status line.

AgentMux turns that into one native Mac window. It discovers your agents, shows each one's status and usage at a glance, and lets you drop into the real terminal when you need to.

What makes it different:

- **Nothing to install on your servers.** AgentMux talks over plain SSH and reads standard tmux. There is no agent, daemon, or proprietary backend to deploy on the remote side.
- **Observe by default.** Auto-refresh only ever reads structural status. It never changes your servers, tmux, or agents on its own; every change is one you explicitly make.
- **Private.** It never reads conversation content, tokens, or credentials.
- **Truly native.** A real Mac app, not a web wrapper: menu-bar extra, system notifications, keyboard-driven.

## Features

- 🪟 **One window for every agent.** Claude Code and Codex across SSH hosts and Docker containers, grouped by container, project, session, or status, with search, pinning, and rename.
- 🔎 **Auto-discovery.** Point AgentMux at a host; it finds the containers and lets you pick which to monitor.
- 📊 **Fleet dashboard.** Per-account usage (5-hour and 7-day limits with reset countdowns), agent counts and activity, and per-container CPU and memory sparklines.
- 🎛️ **Usage at a glance.** Context window %, 5h / 7d limits, and the model and reasoning effort each agent is using, in a status bar whose fields you choose.
- 🖥️ **Live terminal mirror.** Open the actual tmux pane an agent runs in, softly resized to a readable font, or pop it out into its own window. Your keystrokes go to that pane only; your own tmux clients stay untouched.
- ⌨️ **Command palette.** Press ⌘K to jump to any agent, or send a prompt straight into one.
- 🚀 **Launch, resume & switch.** Start or resume a Claude Code or Codex agent in any directory, and switch a Claude or Codex account in place, resuming the same conversation.
- 🧭 **Activity & alerts.** Working, waiting for input, or idle, read from structural session-log fields, with desktop notifications when an agent finishes or needs you.
- 🔬 **Resource inspector.** Per-agent CPU, memory and uptime, git working-tree status (branch, diff, ahead/behind), and host load, memory, disk and GPU.
- 📁 **Files.** Browse the remote working directory with rich previews (syntax-highlighted code, Markdown, CSV/TSV, SVG, PDF, images). Drag files in from Finder to upload or out to Finder to download, and create, rename or delete files and folders.
- 🧩 **tmux management.** Create or kill sessions, windows and panes, plus a throwaway shell with ⌘T.
- 📍 **Menu-bar extra.** Agent counts, urgency, live CPU and memory, and jump to any agent without opening the main window.
- 🔒 **Privacy-first.** Auto-refresh is read-only and structural, never conversation content, tokens, or credentials.

## How it compares

Every similar tool *launches* agents for you (in local git worktrees, or on its own runtime). AgentMux instead watches the ones you **already run** on remote machines:

| Capability | AgentMux | herdr | Orca | Conductor | Claude Squad | kero | Lody | herdrm | waku |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Watch already-running agents (no runtime, nothing to launch) | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | 🔶 | ❌ |
| Remote over SSH | ✅ | 🔶 | ❌ | ❌ | ❌ | ❌ | 🔶 | 🔶 | ❌ |
| Auto-discover Docker containers | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Host/container metrics, incl. GPU | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Switch Claude/Codex account in place | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Native Mac app (no Electron/TUI) | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ |

<sub>🔶 partial: remote over the tool's own runtime or daemon, not SSH; herdrm also requires adopting herdr.</sub>

Download size, native apps only, smallest first:

| App | Download |
|---|--:|
| **AgentMux** | **6.4 MB** |
| kero | 16.8 MB |
| waku | 27.6 MB |
| herdrm | 35 MB |
| Conductor | 84 MB |
| Lody | 181 MB |
| Orca | 255 MB |

## Requirements

- A Mac with **Apple Silicon**, running **macOS 14 or later**.
- **SSH access** to your host(s). AgentMux authenticates through `ssh` and `ssh-agent`; it handles no passwords or keys itself. An `~/.ssh/config` alias or `user@host` is all it needs.
- On the remote side: **tmux**, optionally **Docker**, and your agents running inside tmux.
- For Claude usage metrics (context / 5h / 7d), a one-time status-line sidecar (see [Configuration](#configuration)).

## Install

1. Download the latest `AgentMux-x.y.z-macos-arm64.zip` from the [**Releases**](https://github.com/superpung/agentmux/releases/latest) page.
2. Unzip it and move **AgentMux.app** to `/Applications`.
3. The app is ad-hoc signed and not notarized, so macOS Gatekeeper warns on first launch. Either right-click the app and choose **Open**, or clear the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AgentMux.app
   ```

Prefer to build from source? See [docs/development.md](docs/development.md).

## Configuration

Everything is set up in the app's **Settings** window:

1. **Hosts**: add an SSH destination (an `~/.ssh/config` alias, or `user@host`).
2. **Containers**: pick which auto-discovered containers to monitor.

To see Claude context and rate-limit usage, copy [`scripts/agentmux-statusline.sh`](scripts/agentmux-statusline.sh) into each container and point Claude Code's `statusLine` setting at it. Codex usage is read automatically, with no extra setup.

## How it works

Each refresh makes one read-only SSH connection that inventories processes and tmux. Opening an agent attaches a live view over tmux control mode on a private, per-view session, so your own tmux clients and layout are never disturbed. Only structural status is ever read, never the conversation.

## Privacy & security

- **Read-only auto-refresh.** Polling only inventories processes and tmux. It never changes your servers, containers, tmux, or agents.
- **You make every change.** Writes happen only when you act: opening a terminal and typing, sending a prompt, launching, resuming or switching an agent, managing tmux, or working with files.
- **No conversation content.** Only structural log fields (event type, token counts, timestamps) are read, never message text.
- **No secrets.** Tokens and credentials are never read. Account de-duplication uses only non-secret account id fields.

## Development

Build instructions, the CLI tool, source layout, and architecture notes are in [docs/development.md](docs/development.md).

## License

AgentMux is a personal project. Bundled third-party components and their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
