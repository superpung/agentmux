# ADR 0008: Auto-continue an Agent Stopped by an API Error

Date: 2026-10-28. Status: accepted. The keystroke script is tested against a private local tmux server (`AgentNudgeTests`: text lands as typed plus Enter; never into a shell; placeholders are ignored, drafts are not). First live use continued two Claude agents stopped on `server_error` on 2026-10-28.

## Context

An agent whose turn stops on a transient API error (ADR 0007) waits idle until someone types. For unattended agents that can mean hours lost. The user asked for an optional automatic continue, for errors but not usage limits.

What the vendors say (2026-10):

- Claude Code retries transient failures up to 10 times with backoff before it shows an error. For an error after a block has completed ("Connection lost mid-response") it deliberately does not re-run the request, since that could execute tool calls twice; its error docs say to "reply with `continue` to have Claude pick up from its last completed block". For 500s it suggests resending ("try again"). For unattended runs it offers `CLAUDE_CODE_RETRY_WATCHDOG=1` (429/529 retried indefinitely, other transient errors ~300 tries). It has a native auto-continue for usage limits (`/config`, 2.1.234+), reportedly not firing in detached tmux.
- Codex retries requests (4) and streams (5) itself. For its built-in OpenAI provider those counts can't be changed: `merge_configured_model_providers` keeps only `model_catalog_url` from a `[model_providers.openai]` entry.
- Community tools (e.g. `claude-code-api-watchdog`) watch tmux and type `Continue` with backoff and a try cap, skipping usage limits; that one clears the input line with Ctrl-U first.

## Decision

- **Off by default**, in Settings ▸ General: on/off, the message (`continue`), tries in a row (3).
- **What.** Only retryable errors (ADR 0007). Usage limits, auth, billing and rejected requests are left alone.
- **When.** 10 s after the error, then 1 min, then 5 min. The agent already retried on its own; the first wait mainly leaves time to see it coming and cancel. A turn that finishes normally resets the count; past the last try one "stopped" item goes to the inbox. Agents already stopped when the app starts, or when the setting is turned on, are included (the first version only acted on faults that started while running, so it skipped exactly the agents the user expected it to continue).
- **Visible.** A pending try shows a ring that fills until it is sent (sidebar row, tile header, status bar), with Send Now and Cancel in the status bar and the row's menu. Cancel stops tries until that fault clears. No numbers, per the user.
- **Safe** (`AgentNudge`, one script inside the container, right before typing):
  - the pane is not a shell (a dropped-out agent would run the text as a command), else `gone`;
  - no terminal attached to that window had input in the last 30 s (`#{client_activity}`), else `busy` and retry later. Measured: a tty client's activity updates on keystrokes; a control-mode client's (AgentMux's own mirrors) only on attach, so the app also checks its mirrors' last input itself;
  - the input line is empty, else `draft` and give up for this fault. The last `❯` / `›` prompt line is read with attributes and dim text dropped: Claude's suggestion and Codex's placeholder are dim, a typed draft is not. Claude pads its prompt with a no-break space (U+00A0), which `tr -d '[:space:]'` keeps in the containers' C locale; the first version therefore took every empty Claude prompt for a draft, and the tests now run the script in the C locale with the captured bytes. Unlike Ctrl-U, this never deletes the user's text;
  - then `send-keys -l` the message, a separate Enter after 0.3 s (so the TUI takes it as typed, not pasted).
  The app checks before that the agent is still stopped on the same occurrence.
- Each send becomes an "Auto-continued" inbox item (arrives read, no banner).
- **Upstream retries.** `CLAUDE_CODE_RETRY_WATCHDOG=1` was added to the `env` of every Claude account's `settings.json` in the monitored containers, so fewer turns stop at all; AgentMux's continue then mainly covers mid-response drops, which Claude won't re-run itself.

## Consequences

- It works only while AgentMux runs, and on targets whose access allows input.
- Continuing can hit the same error again right away (reported for long Opus responses); the try cap bounds that.
- After a send, a Codex fault that is still there two minutes later counts as a new occurrence, since Codex gives errors no time to tell them apart.
