# ADR 0012: Open Remote Files in Mac Apps

Date: 2026-10-30. Status: accepted.

Checked so far:
- `LocalCopies` has unit tests: naming, the read-only copy, reuse and replacement, pruning.
- The app lists were read from LaunchServices on the development Mac for pptx, docx, xlsx, Markdown, Python, extensionless and unknown-extension files.
- The toolbar button and its download spinner were captured in a separate test app.

The context menu and opening a file in an app must be checked by hand; AgentMux itself is never driven by automation.

## Context

The Files window previews many formats. A preview is not the app, though. A deck needs PowerPoint to present, and a spreadsheet needs Excel to filter.

Before this change, the only way to get there was Download… to a place the user picks, then opening the file from Finder.

## Decision

The **file context menu** gets two entries, as in Finder:
- "Open in *app*", using the default app for the file's kind.
- An "Open With" submenu: the default app, the other apps that open the kind (one per bundle identifier, by name), and Other… for any app.

The **window toolbar** gets the same control for the file in the preview, as a split button. A click opens the file in the default app, and the arrow lists the others.

- A kind no app claims (an unknown extension) has no default. It lists the apps that open any file, and the button asks for an app.
- App lists come from LaunchServices (`NSWorkspace.urlsForApplications(toOpen:)`) and are cached for a minute.

**The file goes to the app through a local copy** (`LocalCopies`):
- The file is fetched with the same read-only download as Download… and drag out (up to 50 MB, `RemoteFileService.downloadByteCap`). A spinner shows meanwhile.
- The copy is kept in `~/Library/Caches/AgentMux/Opened/<key>/<name>`. The key is derived from the target and remote path, so the app shows the remote name, and two files with the same name never share a copy.
- Opening a file again replaces the copy only if the content changed. An app may still have the unchanged copy open.
- The first open after launch deletes copies not used for 7 days.
- **Copies are read-only (0444)**, with no write-back. An app opens the copy read-only; saving makes a new file elsewhere on the Mac.
  - A writable copy in a cache folder would look like the remote file. Edits saved to it would quietly stay on the Mac, or be pruned a week later.
  - Writing back would be a remote write that no click asked for. The remote file may also have changed meanwhile, for example by an agent working on it.
  - Upload (or a drag in) remains the explicit way to put a changed file back.

## Consequences

- Large files over the 50 MB download cap can't be opened this way, just as they can't be downloaded.
- An app that already has the copy open keeps its version when the remote file changes. Reopening it in that app brings the open window forward rather than reloading the file.
