# ADR 0005: Drag Files Between Finder and the Remote Files Browser

Date: 2026-10-27. Status: accepted. Both drag gestures were checked by hand on 2026-10-28; an AppKit drag can't be synthesized in tests.

## Context

The Files window browses a directory inside a container on a remote host, over the same ssh pipe as everything else (`RemoteFileService`). It could already upload (an open panel) and download (a "Download…" context action), and delete files. Basic file-manager actions were missing: dragging files in from Finder and out to it, New File, New Folder, Rename, and deleting a folder.

Dragging in is ordinary: Finder offers file URLs. Dragging **out** is the hard direction. The bytes are on the remote host, so the drag has to promise a file and fetch it only when, and where, the drop lands; an abandoned drag must cost nothing.

## Options considered (drag out)

1. **SwiftUI `.draggable` with a `Transferable` `FileRepresentation`.** Clean API with an async export closure. How and when SwiftUI turns it into a file Finder accepts is not documented, and it can't be checked without a real drag.
2. **SwiftUI `.onDrag` with an `NSItemProvider` file representation.** The same unknowns.
3. **AppKit `NSFilePromiseProvider` (chosen).** The documented mechanism for files that don't exist yet; the delegate's `writePromiseTo` runs only on a drop, with the destination URL chosen by the receiving app. SwiftUI has no way to start such a drag from a `List` row, so a local mouse monitor starts it (prior art: MiSTerFTP's `DragOut.swift`, MIT, credited in `THIRD_PARTY_NOTICES.md`).

## Decision

**Drag out** (`FileDragOut`, `Sources/AgentMux/Views/FileDragAndDrop.swift`):

- Each file row puts an invisible, click-through `DragOutRowView` behind it, so the controller knows where rows are. The row keeps its SwiftUI tap, hover and context menu.
- A local monitor watches left-mouse events. A press on a file row that moves 4 points becomes `beginDraggingSession` with one `NSFilePromiseProvider`; control-clicks, sheets and modal panels never start a drag.
- On the drop, the promise delegate downloads the file (`RemoteFileService.download`, read-only, up to 50 MB) and writes it to the given URL, then calls the completion handler exactly once; a failure also shows the browser's alert. The row shows a spinner meanwhile.
- The source allows `.copy` to other applications only, so a row can never be dropped back onto the browser and re-uploaded.

**Drag in:** `.onDrop(of: [.fileURL])` on the list uploads into the browsed folder, and a `DropDelegate` on each folder row uploads into that folder (the row highlights). A drop on a file row goes to the list, as in Finder.

**Uploads** (drop or the multi-select open panel) share one policy, `RemoteFileService.uploadRefusal`: regular files only (a FIFO or device would block or never end), a name the line-based listing can show, at most 50 MB. Files go one ssh session at a time; existing names are collected and confirmed together with a single Replace, never replaced silently. Results queue: a batch that finishes while another prompt is on screen waits instead of replacing it.

**File operations** are no-clobber scripts that print one marker (`@@ok`, `@@exists`, `@@missing`, `@@err …`):

- New File: `set -C` (noclobber), so a file that appears between the check and the write is not truncated.
- New Folder: `mkdir` without `-p`; an existing path is reported.
- Rename: refuses an existing destination, so it never replaces an entry or moves into a folder by accident.
- Delete folder: `rmdir` only, never recursive. A symlink to a folder is removed as a link.
- Names are checked before any write (`nameProblem`): not empty, not `.`/`..`, no `/`, no line breaks, at most 255 bytes.

## Consequences

- The scripts are tested by running them under `/bin/sh` and `/bin/dash` (`RemoteFileWriteTests`), not just by string comparison.
- Not covered yet: folders in either direction, incoming file promises (Mail attachments, Safari images), dragging several rows at once, byte-level progress and cancellation of a transfer (requirements 14.2 lists both).
