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

## Compatibility and decisions

- `docs/requirements.md` — full requirements.
- `docs/compatibility.md` — observed remote compatibility.
- `docs/decisions/` — architecture decision records.
- `docs/terminal-link-opening.md` — terminal link handling notes.

## Releasing

Releases are automated by `.github/workflows/release.yml`, triggered by pushing a
`v*` tag:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The workflow installs the pinned Swift toolchain, builds the release app, zips
it as `AgentMux-<version>-macos-arm64.zip`, generates release notes from the
Conventional-Commits history with [git-cliff](https://git-cliff.org) (config in
`cliff.toml`), and publishes a GitHub Release with the zip attached. Keep
`CFBundleShortVersionString` in `scripts/bundle-app.sh` in step with the tag.

Regenerate the changelog locally with:

```sh
git-cliff -o CHANGELOG.md
```
