<div align="center">

# AgentMux

**A native Mac console for your remote AI coding agents.**

Monitor every Claude Code and Codex agent running in tmux on your servers — all
in one window. See what each one is working on, how much of its context and rate
limits it has used, and open the real terminal it lives in.

English | [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/superpung/agentmux?sort=semver)](https://github.com/superpung/agentmux/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/superpung/agentmux/total)](https://github.com/superpung/agentmux/releases)
![Platform](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-black?logo=apple)

</div>

<!-- Screenshots go in docs/screenshots/ and are embedded here once available. -->

## Why

AI coding agents increasingly run on remote machines — in containers, over SSH,
inside tmux, often several at once across projects and accounts. Checking on them
means SSHing in, attaching to the right tmux pane, and squinting at a status
line. AgentMux turns that into one native Mac window: it discovers the agents,
shows their status at a glance, and lets you drop into the real terminal when you
need to.

AgentMux **observes** — it never changes your servers, tmux sessions, or agents
unless you explicitly open a terminal and type into it.

## Features

- **One window for every agent.** Claude Code and Codex instances across multiple
  SSH hosts and Docker containers, grouped by working directory, with search.
- **Auto-discovery.** Point AgentMux at a host; it finds the containers and lets
  you pick which to monitor.
- **Fleet dashboard.** Per-account usage (5-hour and 7-day limits with reset
  countdowns), agent counts, and activity, plus host/container CPU, memory and GPU.
- **Usage at a glance.** Context window %, 5h / 7d rate limits, and the model and
  reasoning effort each agent is using, right in the status bar.
- **Activity detection.** Working / idle, read from session logs (structural
  fields only — never conversation content).
- **Live terminal mirror.** Open the actual tmux pane an agent runs in, softly
  resized to fit at a readable font. Your keystrokes and paste go to that pane
  only; your own tmux clients stay untouched.
- **Launch & resume agents.** Start a new Claude Code or Codex agent, or resume an
  existing session, in a directory you choose.
- **Account-aware.** The same login is merged across config directories and
  containers, so usage is counted once per account.
- **File browser & preview.** Browse the remote working directory with
  syntax-highlighted previews.
- **Privacy-first.** AgentMux reads only structural status and metadata. It never
  reads conversation content, tokens, or credentials.

## Requirements

- A Mac with **Apple Silicon**, running **macOS 14 or later**.
- **SSH access** to your host(s). AgentMux authenticates through `ssh` and
  `ssh-agent` — it handles no passwords or keys itself. An `~/.ssh/config` alias
  or `user@host` is all it needs.
- On the remote side: **tmux**, optionally **Docker**, and your agents running
  inside tmux.
- For Claude usage metrics (context / 5h / 7d), install the status-line sidecar
  (see [Configuration](#configuration)).

## Install

1. Download the latest `AgentMux-x.y.z-macos-arm64.zip` from the
   [**Releases**](https://github.com/superpung/agentmux/releases/latest) page.
2. Unzip it and move **AgentMux.app** to `/Applications`.
3. The app is ad-hoc signed, not notarized, so macOS Gatekeeper will warn on
   first launch. Either right-click the app and choose **Open**, or clear the
   quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AgentMux.app
   ```

Prefer to build from source? See [docs/development.md](docs/development.md).

## Configuration

Everything is configured in the app's **Settings** window (saved to
`~/Library/Application Support/AgentMux/settings.json`):

1. **Hosts** tab — add an SSH destination (an `~/.ssh/config` alias, or
   `user@host`).
2. **Containers** tab — pick which auto-discovered containers to monitor.

To see Claude context and rate-limit usage, install the status-line sidecar in
each container. It renders Claude's normal status line and additionally writes a
small JSON file AgentMux reads:

```sh
# copy scripts/agentmux-statusline.sh into the container, then point
# Claude Code's statusLine setting at it (see the script's header).
```

Codex usage is read from its rollout automatically — no extra setup.

## How it works

Each refresh makes **one read-only SSH connection** that runs an inventory script
(`ps`, `tmux list-*`, a few `jq` reads). Agents are detected from process
evidence. Opening an agent attaches a live view over tmux control mode on a
private, per-view grouped session, so your own tmux clients and layout are never
disturbed. Only structural status is ever read — never the conversation.

More detail in [docs/development.md](docs/development.md) and
[docs/](docs/).

## Privacy & security

- **Observe-only by default.** No changes to your servers, containers, tmux, or
  agent files. The one exception is a terminal you explicitly open and type into.
- **No conversation content.** Only structural log fields (event type, token
  counts, timestamps) are read — never message text.
- **No secrets.** Tokens and credentials are never read. Account de-duplication
  uses only non-secret account id fields.

## Development

Build instructions, the CLI tool, source layout, and architecture notes are in
[docs/development.md](docs/development.md).

## License

AgentMux is a personal project. Bundled third-party components and their licenses
are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
