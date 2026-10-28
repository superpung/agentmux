# ADR 0007: Recognize Stopped Turns, and Keep Notifications in an Inbox

Date: 2026-10-28. Status: accepted. Detection was checked against live agents (a Claude `server_error`, a Claude TLS `unknown`, a Codex usage limit), each confirmed from its source record; classification and parsing are unit-tested (`AgentFaultTests`).

## Context

AgentMux notified only two transitions, a turn finishing (working → idle) and an agent starting to need the user, and only as OS banners that vanish. A turn that stopped on an API error or a usage limit looked like a normal finish, so the agent just sat idle. The user wanted these told apart and every notification kept in a list with the usual read state.

Signals available without reading the conversation:

- **Claude Code** writes an API error as an assistant record with `isApiErrorMessage: true`, an `error` code, and for limits a `quotaLimits` object. Samples from real transcripts: `rate_limit` + `apiErrorStatus: 429` + `quotaLimits.status: "rejected"` (`resetsAt`, `rateLimitType` `five_hour` / `seven_day`) is a usage limit ("You've hit your session limit · resets 4pm"); `server_error` ("Connection lost mid-response") and `unknown` ("EPROTO: The TLS handshake failed", "socket connection was closed") are transient. Only bookkeeping (`system/turn_duration`, `last-prompt`, …) follows it, so "the last assistant/user record is an API error" means the turn stopped there. Claude retries before writing one. The error record's model is `<synthetic>`, which the model reader must skip.
- **Codex** writes no errors to its rollout (only `turn_aborted` with reason `interrupted` for Esc). Its screen shows an error as a history line starting `■ ` (live sample: `■ {"type":"error","status":5xx,…}`; usage: `■ You’ve hit your usage limit …`), and Esc as `■ Conversation interrupted …`. Output lines start `• `.

## Decision

- **Probe.** For each Claude pane, the continuation-chain read that already finds the last real record also emits that record's error code and quota fields (`@@fault <pane> claude <code> <quota status> <resets at> <window> <epoch>`). For each Codex pane, the probe captures the last ~80 lines and emits the class of the last `■` line when it comes after the last `•` line: `usage_limit`, `fatal` (context window, unauthorized, 400/401/403/404, invalid request), otherwise `error`; "interrupted" is skipped. The line itself never leaves the container.
- **Classification** (`AgentFault`): usage limit, or error that is retryable (`server_error`, `unknown`, transient `rate_limit`, overloaded, timeout, Codex `error`) or not (auth, billing, invalid request, Codex `fatal`). A fault counts only while the agent is not working or waiting. `FaultTracker` reports each occurrence once: a Claude error record's time tells occurrences apart; Codex has none, so a fault is one occurrence until it clears.
- **Events.** Finished (working → idle without a fault), needs you, usage limit (with which limit and reset time), stopped on an error (with a short summary). Faults already present on a target's first refresh are recorded, not reported.
- **Inbox** (mainstream inbox pattern, like GitHub's or Linear's): every event becomes an `InboxItem` in `inbox.json` beside `settings.json` (capped at 500, newest first), shown in a popover from a toolbar bell (⌥⌘N) grouped by Today / Yesterday / Earlier. Unread dot and bold name; All / Unread filter; mark read or unread and delete on hover, swipe or right-click; Mark All as Read, Clear Read, Clear All. The Dock icon shows the unread count. A row or an OS banner opens its agent (if it still exists) and marks the item read; reading an item withdraws its banner. An event for an agent on screen arrives read and without a banner. The Settings toggle now controls banners only; the inbox always records.
- The sidebar marks a stopped agent with a red triangle (error) or a purple hourglass (usage limit); the tile header shows the same.

## Consequences

- The probe does one extra `capture-pane` per Codex pane per refresh (tmux in-memory, cheap).
- Codex detection depends on its TUI's `■` / `•` markers; a TUI change would silence it (no false positives: no marker, no fault).
- Inbox titles are the agent's name at the time; an item outlives its agent, and opening it then only marks it read.
