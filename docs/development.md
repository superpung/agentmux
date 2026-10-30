# Development

Developer-facing notes for building, testing and extending AgentMux. For the
user-facing overview see [README.md](../README.md).

## Toolchain

AgentMux builds with the swift.org **Swift 6.4** toolchain, installed per-user
at `~/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain`. Xcode is not
required. `scripts/env.sh` points `SWIFT` at that toolchain by path (CommandLine
Tools' `xcrun` ignores `TOOLCHAINS`), and defines a `swiftpm` helper that runs
the native build engine. Override the location with `AGENTMUX_TOOLCHAIN`.

The native build engine is used on purpose: Swift 6.4's default `swiftbuild`
engine needs `xcstringstool` (ships only with Xcode) for the vendored terminal
engine's `.xcstrings` resource; the native engine copies the file instead. See
`docs/decisions/0001-toolchain-terminal-packaging.md`.

## Build and test

```sh
. scripts/env.sh
swiftpm build                 # debug build
swiftpm test                  # unit tests (swift-testing)
scripts/bundle-app.sh         # build and ad-hoc sign build/AgentMux.app (debug)
scripts/bundle-app.sh release # release build
open build/AgentMux.app
```

`scripts/bundle-app.sh` assembles `build/AgentMux.app` from the SwiftPM binary,
copies the resource bundles and icons, writes `Info.plist`, and ad-hoc signs the
result. The app is Apple Silicon only.

## CLI (development tool)

`agentmux-cli` exercises the remote path without the GUI. A target is
`<hostId>/<container>`, or a bare `<hostId>` with `--container NAME`.

```sh
.build/arm64-apple-macosx/debug/agentmux-cli probe [target ...]     # read-only inventory and agent detection
.build/arm64-apple-macosx/debug/agentmux-cli clients <target>      # read-only client list with AgentMux tags
.build/arm64-apple-macosx/debug/agentmux-cli containers <hostId>   # read-only `docker ps` on the host
.build/arm64-apple-macosx/debug/agentmux-cli attach-test <target> <pane> [--type TEXT]
.build/arm64-apple-macosx/debug/agentmux-cli release-orphans <target>
```

Scripted app check:
`AGENTMUX_OPEN=<target>/<pane> AGENTMUX_SMOKE_INPUT=<text> AGENTMUX_SMOKE_DUMP=<file>`
opens the pane, pastes the text, writes the visible screen to the file and quits.

## Source layout

```text
Sources/CPTY/          forkpty + execve (C)
Sources/AgentMuxCore/  config, remote commands, tmux inventory, agent detection, attach/release
Sources/AgentMux/      macOS app (SwiftUI + AppKit + GhosttyTerminal)
Sources/agentmux-cli/  development tool for the remote path
Tests/                 swift-testing unit tests
Vendor/libghostty-spm/ pinned terminal engine with one resource-lookup patch
docs/                  requirements, decision records, observed compatibility
```

## How it works

- **Inventory.** One read-only SSH connection per refresh runs an inventory
  script in the container (`ps`, `tmux list-*`, and a few `jq` reads of status
  sidecars). Agents are detected from process evidence (executable, arguments,
  config directory) with a confidence score. Only structural fields are read,
  never conversation content.
- **Usage.** Claude context / 5h / 7d limits come from a custom status-line
  script (`scripts/agentmux-statusline.sh`) that writes a small JSON sidecar the
  probe reads; the rate-limit data is on Claude's status-line stdin, not in any
  log. Codex limits come from its rollout, bucketed by window length. Last-active
  and model come from the transcript, not the sidecar. See
  [`decisions/`](decisions/) and the statusline sidecar notes.
- **Live view.** Selecting an agent opens a live mirror over tmux control mode on
  a per-view grouped session (`agentmux-…`): the agent's window is softly resized
  to fill the view at a readable font, input and paste are scoped to that pane,
  and the user's own tmux clients are untouched. At most four mirrors stay open at
  once. Client and grouped-session cleanup is scoped to a stable per-install id so
  two copies of AgentMux can watch the same tmux server without tearing down each
  other's views.
- **Tiles.** Several selected agents share the detail area. `TileLayout`
  (AgentMuxCore) picks the arrangement from the area's size and the terminal cell
  size, scoring each candidate by its worst tile (width up to ~100 columns counts
  most) and keeping the current one unless another is clearly better. Every
  mirror keeps one place in the view tree whether it fills the area, is a tile or
  is hidden, so switching never rebuilds a surface.
- **Claude state.** Claude Code keeps `sessions/<pid>.json` per process in its
  config dir. The probe reads its `sessionId` to find the agent's own session
  log (the newest file in a shared project dir belongs to whichever agent wrote
  last) and its `status` (`busy` / `idle` / `waiting`, reduced on the server to
  input or approval) as `@@agentstate`, which outranks the screen and log rules.
- **Retrying.** A working agent waiting out an API retry is flagged
  `@@retrying` from the bottom of its screen (Claude: "Waiting for API
  response", "will retry in", "Retrying in"; Codex: "Reconnecting...",
  "waiting to retry"; patterns in `InventoryProbe`), and shown as an orange
  "Retrying" instead of "Working".
- **Faults.** The probe emits `@@fault` per agent pane: for Claude, the error
  code and quota fields of the session log's last real record when it is an API
  error; for Codex, the class of the last `■` error line on its screen when it
  follows the last `•` output line. `AgentFault` classifies them (usage limit,
  retryable or not) and `FaultTracker` reports each occurrence once.
- **Notifications.** Activity transitions and new faults become `InboxItem`s
  (persisted in `inbox.json` beside `settings.json`), with an OS banner unless the
  agent is on screen.
- **Auto-continue.** For a retryable fault, `AppModel` schedules tries (10 s,
  1 min, 5 min; shown as a filling ring) and `AgentNudge` types the message with
  `send-keys`, after checking in the container that the agent is still in front,
  no attached terminal had input in the last 30 s, and the input line holds no
  undimmed text. AgentMux's own control-mode mirrors do not update tmux's
  `client_activity`, so the app checks their last input itself.
- **File previews.** Code, rendered Markdown (`MarkdownRenderer`, Foundation's
  parser into paragraph styles and NSTextBlocks) and CSV/TSV
  (`DelimitedTextRenderer`) all show in `PreviewTextView`, a read-only TextKit 1
  text view with the find bar; PDFs in `FindablePDFView`. `PreviewFindRelay`
  sits after the Files window in the responder chain and hands the Find menu
  to the preview while the file list has the keyboard. ADR 0009.
- **Preview links.** `PreviewLink.resolve` (core, tested) turns a clicked
  link into a web page, a place in the file, or a file or folder in the
  container, relative to the file shown. Previews hand it to the window
  through the `previewLinks` environment value; `FileBrowser` opens it and
  keeps the Back / Forward history. Headings carry GitHub slugs in the
  `.previewAnchor` attribute. ADR 0010.
- **Documents, media, archives.** `PreviewFormat` (core) decides how
  `RemoteFileService.read` reads a file: whole for Office / iWork / media (up
  to 20 MB), decompressed on the remote for `.gz` / `.bz2` / `.xz`, listed
  with python3 (else `unzip -l` / `tar -tvf`) for archives. `DocumentPreviews`
  shows them: `QuickLookPreview` and `MediaPreview` on a temporary copy,
  `DocumentText` for the searchable forms (AppKit's Word reader; `Spreadsheet`
  and `Presentation` read the OOXML through `ZipArchive`), the hex view and
  notebooks (`Notebook` → Markdown). A `FindSwitch` on a preview without find
  lets ⌘F switch to its text form. ADR 0011.

## Compatibility and decisions

- `docs/requirements.md` — full requirements.
- `docs/compatibility.md` — observed remote compatibility.
- `docs/decisions/` — architecture decision records.
- `docs/terminal-link-opening.md` — terminal link handling notes.

## Releasing

Versions follow [Semantic Versioning](https://semver.org). Before 1.0 a minor
version (0.3.0) adds features and may change behavior; a patch version (0.3.1)
only fixes. `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and is written for users: what changed for them, grouped as Added, Changed,
Fixed, Removed and Security, not a list of commit subjects.

1. As user-facing changes land, add them under `## [Unreleased]` in
   `CHANGELOG.md`. A fix to something not yet released needs no entry.
2. To release `X.Y.Z`:
   - In `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`,
     add a new empty `## [Unreleased]` above it, and update the compare links
     at the bottom.
   - Set the default `VERSION` in `scripts/bundle-app.sh` to `X.Y.Z` (it
     versions local builds; the release build takes it from the tag).
   - Commit both as `chore(release): vX.Y.Z`, then tag and push:

     ```sh
     git tag -a vX.Y.Z -m "AgentMux vX.Y.Z"
     git push origin main vX.Y.Z
     ```

`.github/workflows/release.yml` runs on the tag. It first checks that
`scripts/bundle-app.sh` defaults to the tag's version and that `CHANGELOG.md`
has an entry for it, and fails before building if not. It then installs the
pinned Swift toolchain, builds the release app, zips it as
`AgentMux-<version>-macos-arm64.zip`, and publishes a GitHub Release with the
zip attached. The release notes are the install steps, the version's
`CHANGELOG.md` entry, and a link to the full commit comparison with the
previous tag.
