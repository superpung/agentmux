# Changelog

All notable changes to AgentMux are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org) (before 1.0, a minor version adds
features and may change behavior; a patch version only fixes). Commits follow
[Conventional Commits](https://www.conventionalcommits.org).

## [Unreleased]

### Added

- Enable **Auto** in an agent's bottom status bar to choose a recognized
  one-time Yes after a five-second countdown. Cancel or type in the terminal to
  skip the request. Auto is off by default for every agent and resets on app
  restart, account switching or agent replacement.

### Fixed

- Visible agents show **Needs approval** as soon as AgentMux recognizes the
  approval dialog, even if the agent's session status has yet to catch up.
- Claude's own expiry timer, background repaints and local Command shortcuts
  no longer interrupt supported approval countdowns. A change to the command
  or approval options still requires a fresh check.

## [0.4.5] - 2026-11-17

### Fixed

- Long-lived terminal and file-watch readers release temporary Foundation read
  buffers after each chunk instead of retaining them until the connection ends.
  This prevents memory growth proportional to cumulative terminal output; pipe
  data remains owned until its consumer has finished processing it.

## [0.4.4] - 2026-11-16

### Fixed

- Opening a code preview in a distributed app no longer crashes while locating
  Highlightr resources. The highlighter loads its bundled scripts and themes from
  `Contents/Resources` and falls back to plain text when resources are missing.
  Release checks exercise a relocated app with build resources hidden, including
  light/dark highlighting and incomplete-resource fallback.

## [0.4.3] - 2026-11-16

### Fixed

- Codex account switching preserves the source conversation's verified runtime
  state, including paginated history, even when another account's index points
  the same thread id at an older rollout. A fresh server bypasses stale caches;
  the previous writer is released and the replacement is verified before the
  switch succeeds. Ambiguous identity and duplicate open views are refused.
- An unconfigured Codex directory no longer discards valid discovered accounts
  and hides Switch Account. Codex discovery runs independently of Claude links
  and retries failed scans while a terminal is open.
- A unique live Codex thread now corrects even an explicitly supplied stale
  tmux pane, preventing reports copied from a shared daemon's environment from
  appearing under another agent. The reporter verifies process ancestry before
  writing; the app also corrects legacy running records. Original pane values
  remain available in diagnostics. Ambiguous threads keep explicit overrides.
- Progress polling selects the newest records before applying its 256-record
  budget, so accumulated history no longer hides live jobs. Custom progress
  directories register automatically and legacy live wrappers are discovered
  without restarting jobs or scanning projects. Duplicate ids use the newest
  report across sources.
- Progress details accept decimal metrics and preserve valid rows when another
  row is malformed. Producer-only ETA history is omitted from polling payloads.

## [0.4.2] - 2026-11-09

### Fixed

- Job progress from a shared Codex app-server follows the command's thread
  identity instead of the daemon's inherited tmux pane. The reader can recover
  thread metadata from older live jobs after verifying their PID start ticks.
  Explicit pane overrides survive heartbeat reports, and default Codex record
  keys are scoped to the thread to avoid cross-thread overwrites.
  Verified ownership stays with the same run after its process exits. Fresh or
  ambiguous threads still require an explicit `--pane`; the guide covers this.
- Embedded terminals report their default foreground and background to tmux
  when opened and when their theme changes, including Follow System. Agents
  launched in new sessions or windows receive the same colors before their
  first terminal query, preventing light input fills in dark terminals.
  Running TUIs that cache startup colors still need a fresh process to adopt
  a changed theme.

## [0.4.1] - 2026-11-04

### Added

- Job progress shows approximate remaining time and the estimated local finish
  date/time together. Custom reporters can use `report --estimate` to retain
  independent progress-rate histories across calls and monitor restarts.
- **Structured job reports.** Progress can carry phases, units, subtask counts,
  lifecycle states and real start/finish times. The wrapper's `--pipe` mode
  preserves stdout and stderr separately for logs and pipelines.
- **A terminal in any container.** The + in the sidebar is a menu: Launch
  Agent…, and New Terminal with each container, a throwaway shell there
  whatever is selected (⌘T still opens one in the selected agent's
  container).

### Changed

- A click on the + in the sidebar opens its menu instead of the launch sheet;
  ⌘N still launches an agent at once.

### Fixed

- Job progress distinguishes stale reports from stalled work, keeps a stable
  order, labels units, expands subtask details, shows seconds and freezes
  completed durations. Quiet jobs keep reporting heartbeats and the wrapper
  refreshes and expires ETA estimates. Counts replace stale percentages and
  phases reset old metrics.
- Job progress uses its execution state for color: running is the accent color,
  completed is green and failed is red. Completing 90% or more no longer turns
  a successful job red as a capacity meter would; subtask bars follow completion.
- The log of remote commands (~/Library/Logs/AgentMux/remote-commands.log)
  grew without end, to gigabytes; past 50 MB it now moves to
  remote-commands.1.log and starts again, keeping at most two files.
- Agents shown together that end up next to each other in the sidebar
  (as rows reorder) are highlighted as one block, without the gap and the
  rounded corners left between them.
- Auto-continue no longer holds off while the mouse moves over the agent:
  only keys and pastes count as typing into it. Mouse movement over an
  agent that tracks the mouse, as Claude Code does, put the try off by
  30 s again and again.

## [0.4.0] - 2026-11-01

### Added

- **Done marks.** An agent that finished while you were not looking is marked
  Done (a green check) until you look at it, in the sidebar, the dashboard and
  the menu bar, which gets a Done section with Clear. Done agents sort right
  after those that need you, and the dashboard's list of them is now Active.
- **Working time.** A working agent shows for how long it has been working,
  kept across restarts.
- **Two notification sounds**, one for an agent that needs you (or stopped on
  an error or a limit) and one for a finished turn, each picked from the Mac's
  alert sounds or turned off in Settings.
- **Update notifications.** A new release is announced once, in a notification
  with its highlights that opens the release page; AgentMux ▸ Check for
  Updates… checks at once. No update window and nothing installed for you; the
  daily check can be turned off in Settings.
- **Command palette** (⇧⌘P): every command with its key, filtered as you type.
  ⌘K still jumps to an agent; a leading `>` switches it to commands.
- **Keyboard shortcuts** in Settings ▸ Shortcuts (also Help ▸ Keyboard
  Shortcuts): every key the app answers to.
- **Launch from the main window.** The + in the sidebar (⌘N, or Launch Agent
  in the palette) opens the launch sheet with a container picker, starting
  fresh; once the new agent's pane is up it is selected and opened, wherever
  it was launched from.
- **Menu bar without resources.** Settings ▸ General ▸ Menu bar ▸ Container CPU
  and memory hides the containers' meters in the menu bar, which then stops
  polling them.
- **Files follow remote changes.** While a Files window is on screen, the file
  shown and the folder listed update by themselves within about a second of
  changing remotely. A text preview keeps your place, and follows new lines
  when you are at the end, as `tail -f`.

### Changed

- **Tiles are cards.** Agents side by side sit on rounded cards a little apart.
  The header shows the agent's icon, name, folder and container, its working
  or idle time and status, with zoom and close on hover. The focused tile has
  an accent ring, and dragging a header onto another tile swaps the two.
  Going from one agent to several and back, zooming, closing or swapping
  moves the cards, and the terminals fade in at their new size.
- **Rows.** In the sidebar a row's time sits at its top right and its status
  mark at its bottom right, as Mail sets a message's date. In the menu bar and
  the dashboard the time comes last, in a fixed width, so times and chips line
  up. An open view is a small gray dot on the agent's icon, where it was a
  green dot beside the time.
- Green in an agent's status means done only: the idle chip is gray.
- The Sessions window's Launch tab is now History. Refresh leaves the sidebar's
  toolbar for the +; ⌘R and the View menu keep it. ⌘N launches an agent
  instead of opening another main window.
- **The ⌘K palette** is an opaque panel with the system's highlight, and opens
  and closes with motion.
- **Hover and motion.** Buttons without a border (in Files, Sessions, the
  inbox, Settings, tiles, the status bar and the menu bar) show a rounded wash
  under the pointer; agent rows in the menu bar and the dashboard highlight;
  controls shown on hover wait a moment before coming and going. Status marks,
  chips, spinners, loading states and lists change with a short fade.
- A notification banner is skipped only while its agent is in a window that is
  on screen; being selected in a hidden or covered window no longer counts.
  Looking at an agent marks its notifications read.

### Fixed

- With a terminal focused, ⌘K, ⌘T, ⌘] / ⌘[, ⌘0, ⇧⌘F, ⇧⌘↩ and ⌘, did nothing,
  and neither did ⌘Q, ⌘W, ⌘N or ⌃⌘F: the terminal took them first. They now
  reach the menus. In a terminal, ⌘K no longer clears its screen and ⌘0 no
  longer resets its text size.
- The menu bar's list of agents could be cut short; it now takes its agents'
  height, and scrolls past about seven.
- The ⌘K palette could list an agent twice, or highlight a different agent
  than the one a message would go to.

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

- **Job progress.** `agentmux-progress` wraps a long command (through a
  pty, keeping its exit code and forwarding signals) and reads tqdm, epoch, percent and
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

[Unreleased]: https://github.com/superpung/agentmux/compare/v0.4.5...HEAD
[0.4.5]: https://github.com/superpung/agentmux/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/superpung/agentmux/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/superpung/agentmux/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/superpung/agentmux/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/superpung/agentmux/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/superpung/agentmux/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/superpung/agentmux/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/superpung/agentmux/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/superpung/agentmux/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/superpung/agentmux/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/superpung/agentmux/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/superpung/agentmux/releases/tag/v0.1.0
