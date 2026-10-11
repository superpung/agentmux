# Observed Environment and Compatibility

Only results that were actually measured are recorded here. Concrete host addresses and container names live in `config/targets.local.json5`, which is not committed.

## Local Mac (2026-10-10)

| Item | Value |
|---|---|
| macOS | 15.5 (24F74), arm64 |
| Xcode | Not installed. Command Line Tools 16.3 (provides the MacOSX 15.4 SDK) |
| Swift | swift.org 6.4.0 toolchain in `~/Library/Developer/Toolchains` (current user only), invoked by path through `scripts/env.sh` |
| SwiftPM build engine | `--build-system native`. The default swiftbuild engine in 6.4 needs `xcstringstool`, which ships only with Xcode |
| ssh | OpenSSH 9.9p2 (system `/usr/bin/ssh`) |
| Terminal engine | libghostty-spm 2.2.2026100901, vendored (see `Vendor/libghostty-spm/VENDORED`) |

## Remote target (read-only probe, 2026-10-10)

| Item | Value |
|---|---|
| Host | Ubuntu, kernel 5.15, x86_64, 48 cores; loadavg ≈ 41 during the probe |
| SSH | Key authentication; works with `BatchMode=yes`; non-interactive stdout has no banner noise |
| Docker | 28.1.1; the SSH user is in the `docker` group, no sudo needed |
| Container | Ubuntu 24.04; default exec user is root; procps `ps`, `python3`, `jq` and `timeout` are present |
| tmux | 3.4, default socket `/tmp/tmux-0/default` |
| tmux options | `exit-unattached off`, `destroy-unattached off`, `synchronize-panes off`, `window-size latest`; no global hooks |

## Findings that affect the implementation

1. **Separators in `-F` output depend on client flags.** Without `-u`, tmux 3.4 printed tabs as `_`; with `-u`, tabs in names come through unchanged. Neither tabs nor any other character can serve as a field separator for untrusted text, so the probe fetches each text field with its own `list-*` call as `<id> <value>`.
2. **Disconnecting `docker exec` does not end the processes it started in the container.** The probe found 64 attached tmux clients; 59 of them had been idle for more than 7 days, and every one was the child of a `bash` started by `docker exec`. Consequences:
   - When the app closes a view it must explicitly `detach-client` its own client. Only dropping ssh leaves a client behind in the container.
   - The app should tag its clients (for example `docker exec -e AGENTMUX_CLIENT=<uuid>`) so that after a crash or network loss, the next connection cleans up only clients carrying its own tag.
   - `session_attached` cannot be used as a signal that someone is watching.
3. **`window-size latest`:** the most recently active client sets the window size. The app must attach with `-f ignore-size` (supported by 3.4), otherwise it changes the layout the user sees in other clients.
4. **Process evidence for agents (L1) is reliable:**
   - The pane's foreground process is `bash`; the agent is its child.
   - `/proc/<pid>/exe` tells Codex (`~/.codex/packages/standalone/releases/<ver>/bin/codex`) apart from Claude Code (`~/.local/share/claude/versions/<ver>`).
   - The agent's environment contains `TMUX_PANE`, which maps it directly to a pane.
   - The agent's environment contains `CODEX_HOME` / `CLAUDE_CONFIG_DIR`, which identifies the config directory. In use: `.codex`, `.codex-2`, `.claude-2`, `.claude-3`.
5. **A Claude Code executable can show as `(deleted)`.** This happens when an auto-update replaces the binary while it is running; detection rules must accept it.
6. **Claude Code also runs daemon, `bg-pty-host` and `bg-spare` processes, and Codex runs an `app-server` daemon.** They are not under any pane and must not be counted as pane agents.
7. **The container has about 2,800 processes and the host is heavily loaded.** A script that ran `ps` once per pid did not finish in 20 seconds. Collection must read the whole table once and analyze it locally. Also, a `timeout` on the host side only ends the docker client; commands inside the container need their own time limit.
8. **tmux can resolve a client name to a different client.** `display-message -c /dev/pts/23` returned the most recently active client (`/dev/pts/148`) instead of the stale client named `/dev/pts/23`. Never target clients by tty name; AgentMux finds its own clients by the `AGENTMUX_CLIENT` tag in `/proc/<client_pid>/environ` and sends SIGHUP to that pid.
9. **The docker exec leak is reproducible.** On the isolated test server, hanging up only the local ssh left the tagged tmux client attached in the container; `ClientRelease` with the tag removed it.
10. **Plain attach changes shared focus.** `attach-session -t %N` sets the window's active pane (and the session's current window when the pane is in another window) for every client. The `active-pane` client flag does not prevent this, and a plain client's input follows the window's shared active pane: after an external `select-pane`, typed text went to the newly selected pane. See ADR 0002.
11. **Text encoding with `-u`.** Without `-u`, a command client without a UTF-8 locale prints CJK characters as `_`; with `-u` they come through. Newlines in names are printed as a literal `\n`; tabs come through as tabs. Quotes and `$(...)` are plain text.

12. **Control mode details (tmux 3.4).** `tmux -C` works over `docker exec -i` without a tty and exits when stdin closes, leaving no client. Every command in a `;`-separated line gets its own `%begin`/`%end` reply, and the line stops at the first `%error`. Arguments starting with `%` must be quoted. In double-quoted words, `\$`, `\"`, `\\`, `\n` and `\t` read back verbatim. `send-keys -H` delivers raw bytes including UTF-8. There is no format for bracketed-paste mode; `paste-buffer -p` uses the pane's real mode.

## Verified on the test server (`-L agentmux-test`)

| Test | Result |
|---|---|
| Attach to `%0`, type `echo agentmux-ok-你好` | Text and output appear in `%0` |
| Close with release | 1 client released; no client left; ssh exits |
| Hang up ssh only | Tagged client stays; `release-orphans` releases it |
| T-06 hostile session / window names | Parsed verbatim; nothing executed |
| Duplicate `%0` on two servers | Kept apart by target (socket) |
| Control-mode mirror of `%0` while `%1` is the window's active pane | Typed text and output in `%0`; `%1` stays active; current window unchanged |
| Paste of two lines into bash | One bracketed paste, not executed line by line |
| Close mirror / quit app | No client and no buffer left |
| App mirror of a 50×29 pane | Local grid exactly 50×29 |
| App resizes remote window to fill the view | `resize-window -x -y` forces the pane to the view's grid (even with the user's other clients attached) |
| App fills the view via a grouped session | `tmux -C new-session -t <session>` shares windows with its own current window/size; `refresh-client -C` soft-sizes the agent's window only |
| Grouped session isolation (verified on real server) | user's current window (@27) and window list (0-5,7) unchanged while viewing; opt stays `latest` |
| `destroy-unattached on` cleanup | grouped session auto-destroys when the control client leaves or the app dies (pipes close -> ssh exits); 0 leftover after quit |
| `select-window -t %pane` | resolves to the pane's window |

## Activity detection (screen rules, 2026-10-11)

Observed from real agent panes (captured read-only with `capture-pane -p`):

- **Codex** idle/ready: the status line reads `… · Ready · Context N% left · weekly …` and the input box is `› <placeholder>`. Working shows `Esc to interrupt`.
- **Claude Code** idle/ready: a finished turn shows `✻ <verb> for Xs · done <time>`, the input box `❯` between two rules, and the footer `⏵⏵ auto mode on`. Working (verified 2026-10-11, Claude 2.1.293) shows a spinner line `✽ <Verb>ing… (23m 36s · ↓ 7.6k tokens)` and running tool lines `… (8m 1s)` — a Unicode ellipsis then a parenthesised elapsed time — but **no** `esc to interrupt` in the captured screen, and the input box `❯` is present even while working. So working must be tested before idle, and the earlier `esc to interrupt`-only rule was wrong.

Rules (`ActivityDetector`) are conservative and **checked working-first**: `working` from the spinner/elapsed pattern `…\s*\(\d+[hms]` (verified for Claude) or an `esc to interrupt` hint (tentative, esp. for Codex which had no live working capture); `idle` from Codex `Ready` or Claude's input box when not working; everything else is `unknown`. Approval and mid-turn waiting-input states are deliberately NOT guessed — the spec forbids false "done"/approval alerts, and real fixtures of those states have not been captured yet. Screens are collected as a base64 tail (last 24 lines) of each agent pane in the inventory probe (one round-trip).

**Screen rules are the brittle baseline.** They are version-dependent (the Claude working marker changed between the guessed and real form). Best practice, and what a reference project / a reference project do, is to read the CLIs' structured JSONL session logs (L3) for precise turn events and fall back to screen rules.

## Log-based activity detection (L3, 2026-10-11)

Authorized by the user to read **structural fields only** (event types), never conversation content, and never to modify agent files. The probe reduces each log to a `working` / `idle` verdict on the server; only the verdict leaves the container. `ActivityDetector.resolve` takes the Codex log verdict first, then Claude's log event, then the screen verdict.

**Claude Code.** The transcript is `$CLAUDE_CONFIG_DIR/projects/<cwd with / as ->/<session>.jsonl`. The pane's session is the `--resume <uuid>` in its cmdline (reliable per pane; newest-by-mtime is wrong when panes share a project dir). Last event `system/turn_duration` = idle (turn ended); `assistant` / `user` = working. Verified: 7 Claude panes all matched direct log reads; a working pane showed `assistant` + a running spinner at the same moment.

**Codex.** The rollout is `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`, lines `{type, payload, timestamp[, ordinal]}`. Turn state is in `event_msg` → `payload.type`: `task_started` = working, `task_complete` / `turn_aborted` = idle. Findings from real sessions (Codex 0.160–0.162, 2026-10-11):

- **Map pane → rollout by the writer's open fd.** The process appending to the rollout keeps it open, so `/proc/<pid>/fd` gives the exact file, and that process's `TMUX_PANE` gives the pane. This is exact when it applies.
- **The fd is not always held.** A `codex app-server` daemon holds its session's rollout fd (maps cleanly). A `codex resume <id>` session logs to `logs_2.sqlite` and holds **no** rollout fd. Its resume UUID does not appear in the rollout (a resume starts a new rollout id), and `session_meta.cwd` is the *original* cwd, which can differ from the process cwd (e.g. a renamed dir) — so neither resume-id nor cwd gives a reliable mapping. These panes get **no** log verdict and fall back to the screen verdict, which was verified correct (both an app-server and a resumed Codex, concurrently working, were reported working).
- **Scan from the end, not a fixed tail.** A long turn emits hundreds of `item_completed` / `token_count` / `response_item` events after its `task_started`, so a `tail -n N` window misses the boundary. The probe uses `tac | jq 'select(.type=="event_msg").payload.type' | grep -m1` to find the last boundary marker cheaply (grep stops jq at the first match from the end).

### Token usage (numbers only)

The same logs carry per-turn token usage, read as structural numbers (no message content) and shown in the detail status bar:

- **Codex** `event_msg/token_count` → `payload.info.last_token_usage.input_tokens` (current context size), `payload.info.model_context_window` (window), and `payload.rate_limits.primary.used_percent` (weekly limit). So Codex can show `ctx used / window (%)` and the rate-limit percent.
- **Claude** `assistant.message.usage` → `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` (output excluded) ≈ the current context size. The transcript does not record the window.

**How the ecosystem gets Claude usage (surveyed 2026-10-11).** The current context % and rate limits exist *precomputed* only in Claude Code's **status line** stdin JSON: `context_window.context_window_size` (200k, or 1M for extended-context models), `context_window.used_percentage`, `rate_limits.{five_hour,seven_day}.used_percentage` + `resets_at`. Reaching that stdin means configuring our command as the user's status line, which edits `~/.claude/settings.json` — off-limits. So the file-based tools do one of two things, and no tool reads context % or rate limits from a plain file:

- **ccusage** reads the local transcripts for historical **cost / token totals** (daily / session / 5-hour blocks), not the current context fill.
- **claude-hud, claude-powerline, ccstatusline, Claude-Code-Usage-Monitor, claude-pulse, …** show the live context % from the status-line JSON, and when it's absent fall back to transcript tokens ÷ an assumed 200k/1M window — exactly our method.

Our formula (`input + cache_creation + cache_read`, output excluded) and our 200k/1M inference match that fallback. Validated live: our bar read 29% at the same moment the user's own Claude Code status line read 29% (290k context). Caveat (noted by claude-pulse): transcript input tokens include the system prompt, tools, MCP and memory, while Claude Code's native context figure counts only conversation tokens, so the two can differ slightly in some states; they agreed in our check.
