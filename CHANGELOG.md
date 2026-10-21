# Changelog

All notable changes to AgentMux are documented here.
This project follows [Conventional Commits](https://www.conventionalcommits.org).

## [0.1.0] - 2026-10-21

First public release.

### Added

- **Fleet monitoring.** A native macOS window that watches Claude Code and Codex
  agents across multiple SSH hosts and Docker containers, discovered
  automatically, grouped by working directory, with search and a stable sidebar
  order.
- **Fleet dashboard.** Per-account usage cards (5-hour and 7-day limits with
  reset countdowns), agent counts and activity, fleet-wide context and rate-limit
  badges, and a resource inspector with host/container CPU, memory, GPU, disk,
  swap, uptime and live I/O rates with sparklines.
- **Usage & model at a glance.** Context window %, 5h / 7d rate limits, and the
  model and reasoning effort each agent uses, shown in a configurable status bar
  with rolling number transitions. Claude usage comes from a bundled status-line
  sidecar script; Codex usage is read from its rollout.
- **Activity detection.** Working / idle and Codex "Action Required" surfaced from
  session logs, using structural fields only.
- **Live terminal mirror.** Opens the agent's real tmux pane over control mode on
  a private per-view grouped session, softly resized to fit at a readable font,
  with input and paste scoped to that pane and the user's own tmux clients left
  untouched. Clipboard-image paste into Claude, light/dark terminal themes, and a
  throwaway terminal (⌘T) not backed by tmux.
- **Launch & manage agents.** Start or resume Claude Code / Codex agents in a
  chosen directory, switch a Claude agent's account in place, and visualize which
  accounts share a project's sessions, from a Sessions window and command palette
  (⌘K).
- **Files.** A two-pane remote file browser with syntax-highlighted previews
  (including Markdown, PDF, SVG and CSV), upload, download and delete.
- **Menu-bar status item** with quick jump, and the selected agent's git changes
  in the inspector.

### Security & privacy

- Observe-only by default: no changes to servers, containers, tmux, or agent
  files except a terminal the user explicitly opens.
- Reads only structural status and metadata — never conversation content, tokens,
  or credentials. Account de-duplication uses only non-secret account id fields.
- Client and grouped-session cleanup is scoped to a stable per-install id, so two
  copies of AgentMux can watch the same tmux server without tearing down each
  other's views.

### Fixed

- Avoids a tmux server segfault on grouped-session teardown by never destroying a
  session while its control client is attached.
