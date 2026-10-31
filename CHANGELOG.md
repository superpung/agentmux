# Changelog

All notable changes to AgentMux are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org) (before 1.0, a minor version adds
features and may change behavior; a patch version only fixes). Commits follow
[Conventional Commits](https://www.conventionalcommits.org).

## [Unreleased]

### Added

- **Done marks.** An agent that finished while you were not looking is marked
  Done (a green check) until you look at it, in the sidebar, the dashboard and
  the menu bar, which gets a Done section with Clear. Done agents sort right
  after those that need you, and the dashboard's list of them is now Active.
- **Working time.** A working agent shows for how long it has been working,
  kept across restarts.
- **Files follow remote changes.** While a Files window is on screen, the file
  shown and the folder listed update by themselves within about a second of
  changing remotely. A text preview keeps your place, and follows new lines
  when you are at the end, as `tail -f`.

### Changed

- **Rows.** In the sidebar a row's time sits at its top right and its status
  mark at its bottom right, as Mail sets a message's date. In the menu bar and
  the dashboard the time comes last, in a fixed width, so times and chips line
  up. An open view is a small gray dot on the agent's icon, where it was a
  green dot beside the time.
- Green in an agent's status means done only: the idle chip is gray.
- **Hover and motion.** Buttons without a border (in Files, Sessions, the
  inbox, Settings, tiles, the status bar and the menu bar) show a rounded wash
  under the pointer; agent rows in the menu bar and the dashboard highlight;
  controls shown on hover wait a moment before coming and going. Status marks,
  chips, spinners, loading states and lists change with a short fade.
- A notification banner is skipped only while its agent is in a window that is
  on screen; being selected in a hidden or covered window no longer counts.
  Looking at an agent marks its notifications read.

## [0.3.0] - 2026-10-30

### Added

- **Several agents side by side.** ⌘-click or ⇧-click up to four agents in the
  sidebar and they share the detail area; a plain click goes back to one.
- **Launch page.** Every past Claude Code and Codex conversation in a container,
  newest first with a preview of its last message, resumable under any of the
  container's accounts in a new or an existing tmux session.
- **Codex account switching** in place, as for Claude, resuming the same
  conversation.
- **Stopped turns and an inbox.** A turn that stopped on an API error or a usage
  limit is recognized and notified, and notifications are kept in an inbox.
- **Auto-continue** (Settings ▸ General, off by default). An agent whose turn
  stopped on a retryable API error is sent "continue", up to three tries in a
  row while it makes no progress. Usage limits, auth and billing errors and
  rejected requests are left alone.
- **Retrying.** An agent waiting out an API retry shows as Retrying.
- **Diffs in the inspector.** Changed files with their added and removed lines,
  each expandable to its diff.
- **Terminal font size** in Settings, kept across restarts; zooming a pane
  remembers its size.
- **Files:**
  - Drag files in from Finder to upload and out to Finder to download; New
    File, New Folder, Rename, and deleting an empty folder.
  - Each Files window stays on its own folder whichever agent is selected.
  - ⌘F in every text and PDF preview, also while the file list has the
    keyboard. Rendered forms switch to their source.
  - Links in previews open: a web page in the browser, another file or folder
    in the window (at its `#heading` or `#L12` line), with Back and Forward.
  - Previews of Word, Excel and PowerPoint (as Quick Look shows them, with a
    searchable Text form), Pages, Numbers and Keynote, audio and video,
    Jupyter notebooks with their plots, HTML pages (scripts off), the text in
    `.gz`, `.bz2` and `.xz` files, zip and tar listings, and other binaries as
    hex.
  - Open a file in a Mac app (PowerPoint for a deck, say) from its context
    menu or the toolbar; the app gets a read-only copy.
  - Markdown, notebook and HTML previews show their pictures, from the
    container or the web, badges included.

### Changed

- Markdown and CSV/TSV previews are drawn as text instead of SwiftUI views:
  long files open and scroll smoothly, and swift-markdown-ui and its two
  dependencies are gone.

### Fixed

- Downloads and previews of files over about 3 MB were cut off.
- A Claude agent idle at its prompt could show as working, and one waiting out
  an API retry as idle.
- An agent started without a `--resume` id could show the session of another
  agent in the same directory: its last-active time and state.
- Codex sessions lost their rollout (last active, usage, model) when the
  sessions directory is a symlink, or when the session started without a
  resume id next to another in the same directory.
- After an API error the model showed as `<synthetic>`.
- Mouse reports from a mirrored pane were typed into a bare shell once its
  agent had exited.
- Opening a throwaway terminal switched every terminal to the system
  appearance instead of the terminal theme.
- The Accounts page left /tmp scratch projects shared between accounts
  unfolded.

## [0.2.3] - 2026-10-22

### Added

- **Job progress.** `agentmux-progress` runs a long command unchanged (through a
  pty, keeping its exit code and signals) and reads tqdm, epoch, percent and
  ETA progress from its output; the inspector shows each of an agent's jobs
  with elapsed time and ETA.
- The time until each 5-hour and 7-day limit resets, in the status bar and the
  in-container status line.

### Changed

- One terminal theme for every terminal instead of one per agent.
- The ctx, 5h and 7d labels are chips, and the status line's low-usage bar is
  a clearer green.

### Fixed

- A terminal opened before its agent appeared kept the default theme.
- A Codex session served by a daemonized app-server lost its rollout (last
  active, usage, model).
- The throwaway terminal's shell ran without a UTF-8 locale.

## [0.2.2] - 2026-10-22

### Added

- A terminal font setting listing the installed monospaced fonts. The
  hard-coded SF Mono fell back to a proportional font on Macs without it.

### Changed

- Filler copy removed from the interface.

## [0.2.1] - 2026-10-21

### Fixed

- A terminal could attach to another view's mirror session instead of the
  agent's own and freeze once that mirror went away.

## [0.2.0] - 2026-10-21

### Added

- An app icon.
- Releases are built and published from version tags.

### Changed

- The interface is built on the native system colors.

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

[Unreleased]: https://github.com/superpung/agentmux/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/superpung/agentmux/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/superpung/agentmux/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/superpung/agentmux/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/superpung/agentmux/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/superpung/agentmux/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/superpung/agentmux/releases/tag/v0.1.0
