# ADR 0004: Fill the View by Sizing a Grouped Session

Date: 2026-10-10. Status: accepted; supersedes the sizing part of ADR 0003.

## Context

ADR 0003 mirrored a pane at its remote size and letterboxed it. A remote pane sized by the user's wide terminal (e.g. 159×43) left large blank margins in a differently-shaped window — the user rejected this ("the bottom half is empty"). The pane should fill the view at a readable font, like a normal terminal, and reflow.

**How kitty does it (for comparison).** Running `ssh host` then `tmux attach` inside kitty attaches a *normal* interactive client over a real pty. Under `window-size latest`, the window follows the most-recently-used client; when you use kitty it wins, and SIGWINCH on resize propagates naturally. kitty does **no restore** — it never sets `window-size manual`; on detach tmux recomputes the size from the remaining clients. The size is *soft* and self-healing.

AgentMux can't just be a normal client: it uses control mode to mirror one pane and target input precisely without disturbing the user's current window / active pane in their other clients.

## Options considered

Verified empirically on the real multi-client server:

1. **`resize-window -x -y` (hard size).** Reliably sizes the agent's window, but sets `window-size manual` and needs an explicit restore to `latest` on close. A crash leaves the user's real window stuck at `manual`. Rejected: crash-unsafe, touches the user's real window state.
2. **`refresh-client -C` on a shared session (soft size + move current window).** Self-healing like kitty, no restore. But `refresh-client -C` sizes the client's *current window*, and the current window is shared per session, so AgentMux would have to `select-window` to the agent's window — moving the user's other clients there — and would then fight them for focus whenever either side navigates. Rejected: focus tug-of-war.
3. **`refresh-client -C` on a grouped session (chosen).** A session created with `new-session -t <user session>` shares the same windows but has its own current window and size. AgentMux's control client focuses the agent's window and sizes it softly, in isolation.

## Decision

Each view runs its control client on a per-view **grouped session**:

- Attach with `tmux -C new-session -s agentmux-<tag> -t <user session> -f pause-after=30`. This creates a session grouped with the user's and attaches the control client to it.
- Send `set-option destroy-unattached on` so the grouped session is removed the moment the client leaves — including when the app dies and its pipes close, ending the ssh client. `kill-session` on a clean close is the prompt path; `destroy-unattached` is the crash-safety net.
- `select-window -t %pane` focuses the agent's window **in our grouped session only** (independent current window).
- The local surface fills the detail pane at a fixed readable font; its grid size is pushed with `refresh-client -C <cols>x<rows>` (debounced). This is a *soft* size on our grouped session's current window: it self-heals to the user's clients when we leave, so **no restore and no `window-size manual`**.

Only `kill-session` of our own `agentmux-<tag>` session is ever issued — never `kill-window` (which would remove a window from the whole group, including the user's session). The mirror only reads, sizes and inputs existing panes.

## Why a grouped session is safe (verified)

A session group shares the *same* window objects (same `@id`s), not copies. What is shared vs independent:

| | Shared / independent |
|---|---|
| Window list (which windows exist, order, contents, panes, processes) | shared — one set of objects |
| Current (focused) window | independent per session |
| Window size | per window, from the clients viewing it — effectively independent |
| Killing our grouped session | removes only our handle; windows survive via the user's session |

Verified on the real server: opening an agent created one `agentmux-*` session; the user's session current window (`@27`) and window list (0–5,7) were unchanged throughout; the agent's window filled the view at 88×46 with `window-size` staying `latest`; quitting auto-destroyed the grouped session, leaving zero `agentmux-*` sessions and the user's session untouched.

## Consequences

- Opening an agent fills the view at a readable font and reflows the agent, with no restore, no `manual` mode, and no crash-stickiness.
- The agent's window is resized (soft) while viewed; the user's other clients see that size only if/when they view that window, and it self-heals. The user opted into resizing the shared window.
- A per-view grouped session exists while viewing (named `agentmux-<tag>`, auto-destroyed). Creating it needs an attachable target (`interact` / `test`).
- The user's current window, window list and `window-size` option are never changed.
