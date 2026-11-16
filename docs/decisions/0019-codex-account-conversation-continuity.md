# Codex account conversation continuity

Date: 2026-11-16

## Evidence

In a shared Linux container, `.codex-3/sessions` correctly resolved to
`.codex/sessions`, but the independent `state_5.sqlite` databases mapped the
same thread id to different rollouts. The source server held the newer writer-suffixed file while the target
index retained the old file. Paginated history also lives in SQLite; a shared
sessions directory cannot establish runtime continuity.

Native Codex 0.169.0 reproduces this with disposable conversations: resuming by
id uses the selected database's path, even when both accounts share sessions.
The native server can retain its writer after the TUI disconnects. Its unload
timer is server-wide: a per-resume override does not reliably release an already
loaded thread. Native archive/unarchive closes that thread and restores its
unarchived state without stopping the shared daemon.

## Decision

Treat the source runtime as authoritative. The switch verifies process ancestry
against the tmux pane root, identifies the actual open rollout from structural
metadata, and checks its exact index entry. It excludes spawned subagents and
refuses ambiguous primary conversations rather than guessing by file mtime.
Idle servers may close SQLite connections, so a declared state directory is
accepted only when its thread entry matches the verified live rollout.

The selected account supplies `CODEX_HOME`; `sqlite_home` continues to point at
the source state directory. This preserves native indexes, paginated history,
goals and other resumable runtime state together. AgentMux does not rewrite or
merge databases. `AGENTMUX_CODEX_SQLITE_HOME` carries the state directory across
later account changes. A dedicated `--no-daemon` server bypasses the target's
possibly stale loaded thread. Other target conversations retain their existing
servers and state.

For a shared source daemon, a metadata-only local Unix WebSocket connection
verifies the exact thread/path before the TUI is stopped. After the TUI exits,
AgentMux unsubscribes its handoff connection, uses native
archive/unarchive to close the old thread and restore its unarchived state, and
waits for the previous writer to release the file. The new TUI
must have the selected account, original thread id and state-directory marker,
and its runtime must open the source database and the indexed rollout. Typing a
launch command is not success. Failure restores the original command when the
pane has no replacement Codex process; it never types over a running agent.

Account switching remains an explicit operation. Background polling does not
perform a handoff. Identity and connection failures leave the old TUI running.
Later failures are reported explicitly and restore the original command when
possible. Ordinary manual Codex launches keep their own configuration semantics.

## Validation

Python regressions exercise duplicate ids, symlinked sessions, live-file
selection, subagents, ambiguous ownership, stale launch ids, PID reuse, command
quoting, repeated account changes and failure reporting. Opt-in Linux tests
use the actual Codex binary with disposable accounts and conversations, without
real credentials or model requests. They reproduce the wrong-index failure, verify
native history continuity, exercise the shared server's writer release, and
switch a real TUI to another account and back on the isolated `agentmux-test`
tmux socket. Real-agent verification is metadata-only.
