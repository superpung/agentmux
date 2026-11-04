# Using AgentMux

The [README](../README.md) lists what AgentMux does; this page covers how some of it works.

## Several agents at once

⌘-click (or ⇧-click) up to four agents in the sidebar and they share the detail area; a plain click goes back to one.

- **Layout** follows the area's shape and keeps every tile wide enough for an agent's TUI (about 80 columns) when it can. On a landscape window: two side by side, three as one tall tile beside two stacked, four as a 2×2 grid. On a portrait or narrow window they stack top to bottom. Resizing the window does not flip the layout back and forth near the switch point.
- **Cards.** Each tile is a card whose header shows the agent's icon, name, folder and container, how long it has been working or idle, and its status; zoom and close appear on hover.
- **Focus.** Keys go to one tile at a time, the one with the accent ring. Click a tile, or use ⌘] / ⌘[, to move focus. ⇧⌘↩ (or double-clicking a header) zooms the focused tile to the full area and back; the others keep running and keep their size.
- **Rearranging.** Drag a tile's header onto another tile to swap the two. Tiles move into place as they join, leave, zoom or swap; their terminals take their new size once and fade in.
- **Closing.** A tile's × (or ⌘-clicking its row again) takes it out; its mirror stays warm like any recently viewed agent.
- Each tile sizes its agent's tmux window to the tile, as the single view does with the full area. If you also have that window attached elsewhere, you see it at the tile's size while the tile is open.

## Notifications and auto-continue

The toolbar bell (⌥⌘N) opens the inbox:

| Event | When |
|---|---|
| Finished | A turn ended normally (working → idle). |
| Needs you | The agent waits for input or an approval. |
| Usage limit | The turn stopped on a usage limit; shows which one and when it resets. |
| Stopped on an error | The turn stopped on an API error after the agent's own retries. |
| Auto-continued | AgentMux sent `continue` (see below). |
| Auto-continue stopped | Tries ran out, or a try was skipped (an unsent draft) or failed. |

Items are kept across launches, newest first by day, with unread dots, an All / Unread filter, mark read or unread, delete (hover, swipe or right-click), Mark All as Read, Clear Read and Clear All. The Dock icon shows the unread count. A desktop banner appears unless that agent is on screen, in a window that is not minimized, hidden or covered; clicking a banner or a row opens the agent. Banners can be turned off in Settings; the inbox always records. A banner for an agent that needs you (or stopped on an error or a limit) and one for a finished turn play different sounds, each chosen from the Mac's alert sounds in Settings, or none.

**Done marks.** An agent whose turn finished while it was not on screen is **Done** until it is: a green check in the sidebar and tile header, a Done chip and section in the menu bar and the dashboard. Looking at an agent marks its notifications read and takes their banners out of Notification Center. Clear in the menu bar's Done section clears every mark. Done agents sort after those that need you and before working ones; one you open keeps its place until you leave it, so the row does not move away as you click it.

**How a stopped turn is recognized.** For Claude Code, the last real record of the session log is an API error: its error code and quota fields (`rate_limit` with a rejected quota is a usage limit; `server_error`, `unknown` and transient 429s are errors). For Codex, which writes no errors to its rollout, the last error line on its screen comes after its last output line; a usage-limit message is a usage limit and Esc's "Conversation interrupted" is not an error. Both are reduced to a verdict inside the container; the message text never leaves it.

**Auto-continue** (Settings ▸ General, off by default) types `continue` (configurable) into an agent stopped by a connection or server error, which is what Claude Code's own error docs advise after a dropped response. Usage limits, auth and billing errors, and rejected requests are left alone.

- **When.** 10 s after the error, then 1 min, then 5 min, up to 3 tries in a row (configurable); a turn that finishes normally resets the count. Agents already stopped when AgentMux starts, or when the setting is turned on, are included.
- **Visible.** While a try waits, the sidebar row and the tile header show a ring that fills up until it is sent, and the status bar adds **Send Now** and **Cancel** (also in the row's right-click menu). Cancel stops tries until that error clears.
- **Safe.** Right before typing, inside the container: the agent must still be stopped on the same error and still in front (never a shell); nobody may have typed into its window in the last 30 s (an attached terminal, or this app); and its input line must be empty, ignoring the agent's dimmed placeholder or suggestion. Otherwise it waits, or skips and says so in the inbox.
- It runs only while AgentMux is open.

For long unattended Claude Code runs, also set `CLAUDE_CODE_RETRY_WATCHDOG=1` in each account's `settings.json` `env`: Claude Code then retries capacity errors (429/529) indefinitely and other transient errors for hours before giving up, so fewer turns stop at all. Codex's built-in OpenAI provider does not let its retry counts be changed.

## Files

Browse the remote working directory with rich previews: syntax-highlighted code, Markdown, CSV/TSV, Jupyter notebooks, HTML, RTF, SVG, PDF and images. Markdown, notebooks and HTML pages show their pictures, from the container or the web. The file shown and the folder listed update by themselves when they change remotely. Word, Excel and PowerPoint (and Pages, Numbers, Keynote) show as Quick Look shows them, with a searchable Text form; audio and video play; `.gz` / `.bz2` / `.xz` files show what they hold, zip and tar archives their listing, other binaries a hex view. Rendered formats switch to their source; ⌘F finds in every text and PDF preview (on a page or web view it switches to the text), also while the file list has the keyboard. Links in a preview open: a web page in your browser, another file or folder in the window (at its `#heading` or `#L12` line), with Back and Forward to return. Open a file in a Mac app (PowerPoint for a deck, say) from the toolbar or its context menu; the app gets a read-only copy. Drag files in from Finder to upload or out to Finder to download, and create, rename or delete files and folders.

## Job progress

Select an agent and open its right inspector to see its jobs. Install
`scripts/agentmux-progress` as `/usr/local/bin/agentmux-progress` in the
container (Python 3, standard library only). No daemon is required.

### New commands

Run in the agent's tmux pane; its `TMUX_PANE` associates the job with that agent:

```sh
agentmux-progress --id training --label Training --unit epochs -- python train.py
agentmux-progress --pipe --id build --label Build -- make >build.log 2>build.err
```

The default PTY supports terminal progress bars. It merges stdout/stderr and
may translate line endings; it also changes terminal detection and the process
tree. Choose `--pipe` for separate, unchanged stdout/stderr bytes. Signals go to
the child process group and its exit status is preserved. A failed progress-file
write does not stop the command. Existing job-control/watchdog rules still apply.

The parser recognizes fractions, percentages, epoch/step/iter/batch counters,
tqdm ETA and `ETA mm:ss`. It is intended for one job's output. Do not wrap a
synchronizer that prints several jobs: report each job directly instead.

### Existing jobs and custom progress

Use a stable id and one writer per job. This does not restart the job:

```sh
agentmux-progress report --id experiment --label Experiment --pid 1234 \
  --phase evaluation --unit groups --current 3 --total 10 \
  --details-json '[{"id":"proof-a","label":"Proof A","current":4,"total":9,"unit":"assertions"}]'
```

On Linux, `--pid` derives the actual process start time and records its
incarnation. Otherwise pass `--started-at <Unix-seconds>` from the job's own
records. Without a known start time the app omits Elapsed. Changing phase clears
old counts and ETA; omit an unknown total, using `--clear-progress` to remove
previous counts. `--percent` is useful without counts; counts take precedence
when both are present. Use `--restart` for a new run with the same id.

Report at least every 30 seconds, even if progress has not changed:

```sh
agentmux-progress report --id experiment --heartbeat
agentmux-progress report --id experiment --state paused
agentmux-progress report --id experiment --state running
agentmux-progress report --id experiment --state done --finished-at 1793799000
# Or: --state failed --exit-code 1
```

`report --pid` records identity/start time; the reporting caller must check that
the same process is still alive. State can be `preparing`, `queued`, `running`,
`paused`, `unknown`, `done`, `failed`, `cancelled` or `stopped` (exited with an
unknown result). A missing completion file alone is not evidence of running.
The final report freezes Elapsed. Repeated heartbeats preserve terminal states.

`--source-updated-at <Unix-seconds>` records when source results last changed,
independently of the heartbeat. `--eta <seconds>` supplies a current ETA;
`--clear-eta` removes it. Automatic ETA needs observed progress over time,
recalculates as work advances and expires after 90 seconds without a new sample.

### Reading the inspector

- **Running / Preparing / Queued / Paused** is the producer's execution state.
- **Stale** means no report for over 90 seconds, not proof of a stalled process.
- **Data age** is the age of the underlying results, when supplied. A fresh
  heartbeat with unchanged data is possible and is not itself a failure.
- Counts use the producer's unit (groups, epochs, designs, etc.). **Details**
  expands subtask counts and the full status message. A group counter can stay
  unchanged while its assertions advance.
- Jobs keep a stable order. Active jobs stay visible; terminal jobs live under
  **Finished**. A structured report can name raw worker records with repeated
  `--supersedes <id>` so the same job appears once.

The wrapper writes a heartbeat every 10 seconds. Existing wrapper processes
keep their loaded version until they exit; updating the installed file changes
future launches. Progress records live in `~/.agentmux/progress`, outside the
project, or `AGENTMUX_PROGRESS_DIR`. Use `--pane` when reporting from outside
that tmux pane. Changing the progress directory requires the reader to use the
same directory.
