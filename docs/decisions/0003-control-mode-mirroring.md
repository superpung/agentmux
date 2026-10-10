# ADR 0003: Mirror Panes over tmux Control Mode (Path B)

Date: 2026-10-10. Status: accepted; supersedes the pane-targeting part of ADR 0002.

## Context

Plain attach (path A, ADR 0002) moves the window's and session's shared focus for every client, which the user sees in their other terminals. The user chose path B: precise, side-effect-free interaction with one pane.

## Decision

- Each open view runs one control client: `ssh -T` → `docker exec -i -e AGENTMUX_CLIENT=<tag>` → `tmux -u -C attach-session -E -f ignore-size,pause-after=30 -t $S`. No tty. The client never sets window sizes, and tmux pauses a pane instead of buffering without bound when the client falls behind.
- Only the viewed pane's output is wanted. The first `%output` from any other pane turns that pane off with `refresh-client -A '%N:off'`.
- Sync: one command line `display-message` (size, cursor, modes) ; `capture-pane -e -N -a -q` (normal screen saved under an alternate screen) ; `capture-pane -e -N` (visible screen). tmux runs a line without processing pane output in between, so output before the replies is already in the capture and is dropped, and output after them is applied. The local terminal is reset and redrawn from that state, then follows live output.
- Input: `send-keys -t %N -H <hex>` with the raw bytes Ghostty produces (keys, mouse reports). Paste: ⌘V is intercepted and sent as `set-buffer -b agentmux-<tag> -- "<escaped>" ; paste-buffer -p -d`, so tmux adds bracketed-paste markers only when the program asked for them. The temporary buffer is deleted by the paste.
- The local grid is kept at the pane's size: the surface has no internal padding and its frame is the pane's columns × rows in cells. The remote size is never changed.
- Layout changes trigger a size check and a resync; `%pause` triggers continue + resync; a missing pane or `%exit` ends the view with input disabled.
- Closing a view, quitting, or the app dying closes the client's stdin; tmux control clients exit on EOF. Tagged leftovers are still released on the next connect.

## Consequences

- Selecting an agent opens its live terminal immediately, like a Mac agent console, without touching shared tmux state.
- A pane larger than the view is clipped for now; fitting by font size is future work.
- Bracketed-paste, mouse and keypad modes set before the view opened are recovered (except bracketed paste, which tmux handles on paste); other private modes are not.
