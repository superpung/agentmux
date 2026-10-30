# ADR 0014: Files Follow Remote Changes

Date: 2026-10-30. Status: accepted.

Checked against host 204 and its container xp01, read-only:
- A watch session answered each check in 8 to 10 ms after a 0.4 to 0.5 s start, and saw `/var/log/syslog` change from one check to the next while its folder stayed the same.
- Over 30 checks, the loop and its `stat` calls used 0.12 s of CPU in the container, and the `docker exec` client 0.05 s, mostly at start: about 5 ms a check.
- Killing the watching process with `kill -9` left nothing behind: the loop and its `docker exec` client were gone within 2 s, and no local ssh remained.
- The loop is unit-tested under `/bin/sh` and `/bin/dash` with a GNU `stat` shim: stamps for a file, a folder and a missing path; a rewrite and a new folder entry change them; closing its input ends it.

## Context

A Files window read the file shown once, when it was picked, and listed a folder when it was opened. A file an agent kept writing (a report, a log) stayed as it was until the user picked it again.

The plain way to notice changes is to poll with the app's usual remote call: a new ssh connection, `docker inspect`, and a `docker exec` per call. Measured on 204, one such call costs:
- about 0.3 s of the host's CPU (sshd, the docker CLIs, dockerd, containerd);
- 0.1 s of the Mac's;
- 0.55 s of wall time.

Every 2 s, that is 15% of a core on the host and 5% on the Mac for each open preview.

A push from the container (inotify) would need a resident watcher process there. A process started by `docker exec` outlives its client, so a dropped connection could leave watchers behind, as VS Code's helpers did.

## Decision

**One long-lived session per Files window** (`RemoteWatch`):
- The session is `ssh -T` → `docker exec -i` → `sh -c`, running a loop that answers each request on its stdin with one stamp a path: inode, size and modification time (`stat -c '%i %s %y'`), or `-` for a path it can't read.
- The script comes as the `-c` argument, so stdin stays free for requests.
- There is no `docker inspect`, since no identity line is needed.

**It can't outlive the app:**
- The loop ends when its stdin closes: the window closed, the app quit or crashed, the connection dropped. tmux's control clients rely on the same EOF.
- `timeout 600` ends it in any case. The window then starts a new session on its next check.
- A check unanswered for 10 s ends the session.
- A failed session is retried after 15 s.
- Writes to the session's pipe can't raise SIGPIPE in the app.

**Checking** (`FileWatcher`):
- While the window is on screen (its occlusion state, so not when minimized, hidden or fully covered), it checks the shown file and the listed folder once a second.
- A changed stamp reloads that part. Changes that keep coming reload at most every 3 s, since a reload is a full remote read.
- A folder's stamp changes when entries are added, removed or renamed, not when a file in it is rewritten. The size column of a rewritten file updates on the next listing.

**Reloading in place:**
- The preview keeps showing the file while the new version is read, and replaces it only if it differs. A failed reread keeps what is shown.
- A text preview (code, Markdown, CSV) keeps the reader's place. At the end it follows new lines, as `tail -f`; otherwise the line at the top stays there.
- Pictures already fetched are reused, so they don't flash back to placeholders. A regenerated picture with the same name shows when the file is picked again.

## Consequences

- An open Files window holds one ssh connection and one idle `sh` in its container. While the window is visible, the window costs about 5 ms of the host's CPU each second, plus a full read when something changed.
- PDF, Quick Look and web previews reload from the top. Only text previews keep their place.
- A Mac app opened on a file's copy (ADR 0012) does not follow changes; opening the file again refreshes the copy.
