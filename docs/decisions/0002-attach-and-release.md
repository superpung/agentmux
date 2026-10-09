# ADR 0002: Attaching to Existing Panes and Releasing Clients

Date: 2026-10-10. Status: accepted for M0–M2; revisit before path B.

## Context

The app attaches to existing tmux targets with `ssh -tt` → `docker exec -it` → `tmux attach-session` (path A in the requirements). Experiments on an isolated tmux 3.4 server (see `docs/compatibility.md`) showed:

- Docker keeps processes started by `docker exec` alive after the client disconnects, so a closed view would leave its tmux client attached forever.
- tmux can resolve a client's tty name to a different client, so `detach-client -t /dev/pts/N` is not safe for stale clients.
- `attach-session -t %N` changes the window's shared active pane, and the session's current window when needed. A plain client's input follows the shared active pane, so focus cannot be restored for other clients without redirecting our own input.

## Decision

- Every attach sets `AGENTMUX_CLIENT=<random tag>` on the `docker exec` process. Closing a view first releases the client carrying that tag (SIGHUP to the verified pid; tmux treats it as a lost terminal), then hangs up the local ssh. If the host is unreachable, only the local ssh ends, and the next connection releases tagged clients that no live view owns.
- Attach uses `-E` (no environment update) and `-f ignore-size,active-pane`; never `-d`.
- Path A targets a pane with `attach-session -t %N`. The UI must state that this switches the window's current pane, and the session's current window if needed, for every client. It must not claim the view is isolated.
- Precise, side-effect-free pane input is left to path B (control mode, `send-keys -t %N`), which never touches shared focus.

## Consequences

- No client leaks from normal closes; crashes and network loss are cleaned up on reconnect, and only clients carrying the AgentMux tag are touched.
- Until path B, entering a pane from the app can move another client's view. An alternative is a temporary grouped session per view (`new-session -t`, `destroy-unattached on`), which isolates the current window but still shares the active pane and creates a visible session; it needs the user's approval before use on a real server.
