# Opening Terminal Hyperlinks in the Mac Browser

Status: **not implemented, deliberately dropped (2026-10-14).**

Goal: when a remote agent prints a URL in a mirrored pane, let the user open it in
the Mac's default browser. The agent runs in a container with no browser of its
own, so clicking its own hyperlink fails with
`Failed to open browser … No valid browsers detected`.

This note records why the obvious approaches do not work, what was tried and
reverted, and where to start if we revisit it — so we don't re-investigate from
scratch.

## Why a single click cannot open the link under Codex

Codex (and most TUI agents) enable **SGR mouse reporting** (mode 1006). While a
remote program has the mouse captured, Ghostty forwards every click/move to that
program as a mouse report and does **not** run its own link detection. Proven
live with `TerminalDebugLog` (categories `.actions`, `.input`):

- A ⌘-click emitted `host <- terminal "\e[<0;51;28M"` — i.e. the click, *with the
  Cmd modifier* (`mods=0x8`), was sent to Codex as an SGR mouse report.
- `callback action=mouse_over_link url=nil` throughout — Ghostty never detected a
  link under the cursor.
- `GHOSTTY_ACTION_OPEN_URL` **never fired**.

Codex then received the click and tried to launch a browser inside the container,
which is the error the user saw.

Modifier behaviour (config has `mouse-shift-capture = never`):

| Modifier | Result under Codex capture |
|---|---|
| ⇧ Shift | Ghostty handles it **locally**, but local handling = **select text**, not open a link. A shift-click just makes/extends a selection. |
| ⌘ Cmd / ⌃ Ctrl | Forwarded to Codex along with the modifier bit. Not configured as a capture bypass, so Ghostty does not treat it as a link-open gesture. |

So no single-click gesture opens a link while Codex holds the mouse. This is by
design in the embedded build, not a bug we can patch from the app side.

## Open-source reference

Real **Ghostty.app** *does* open links on ⌘-click even when a TUI app (vim, less,
Codex) has mouse reporting on: its core checks link detection when the mouse
modifiers match the link mods and emits the open-URL action instead of forwarding
the click.

We use **vendored, embedded `libghostty-spm`** (`Vendor/libghostty-spm/VENDORED`).
That link-detection path is not triggered here while the remote app captures the
mouse (`mouse_over_link` stayed `nil`). The C core ships as a **prebuilt binary**
(`GhosttyKit.xcframework`), so this behaviour cannot be changed by editing the
vendored Swift sources, and it cannot be verified without repeated manual GUI
testing on the Mac.

## What was built and reverted

Two approaches were implemented and then fully reverted (uncommitted — not in git
history, so reconstruct from this note):

1. **Delegate hook for `GHOSTTY_ACTION_OPEN_URL`.** A vendored patch added
   `TerminalViewState.onOpenURL: ((String, TerminalOpenURLKind) -> Void)?` and made
   the state conform to `TerminalSurfaceOpenURLDelegate`
   (`terminalDidRequestOpenURL`). `PaneTerminal` set
   `state.onOpenURL = { url, _ in PaneTerminal.openOnHost(url) }`, where
   `openOnHost` opens `http`/`https`/`mailto` only via `NSWorkspace.shared.open`.
   The wiring is correct and would work in a pane that is **not** capturing the
   mouse (e.g. a plain shell), but the delegate **never fires under Codex
   capture**, so it does nothing for the actual use case. Lived behind
   `Vendor/patches/open-url.patch` + `scripts/vendor-libghostty.sh`.

2. **Right-click "Open Link in Browser" on the selection.** In
   `PasteInterceptingTerminalView.menu(for:)`, read the copy-on-select selection
   from the pasteboard and, when it is a single `http`/`https`/`mailto` URL, add an
   "Open Link in Browser" item that calls `openOnHost`. The right-click path is
   local (Ghostty shows the selection context menu and does not forward the click
   when `hasSelection()` is true), so this mechanically works. It was dropped
   because:
   - Gesture is **three steps**: Shift-drag-select the URL → right-click → Open.
     Not the single click the user wanted.
   - The URL detector was too strict: a URL that **soft-wraps** across pane rows
     brings whitespace/newlines into the selection and was rejected, so the menu
     showed only "Copy". (Fixable with `NSDataDetector`, but the gesture stays
     clunky.)
   - **OSC 8 hyperlinks** (visible text like "在线预览" with a hidden href) select
     the visible text, not the href, so they cannot be resolved from the
     selection at all.

## If we revisit

Ranked by expected payoff:

1. **Right-click menu, robust detection.** Keep approach 2 but detect the URL with
   `NSDataDetector(types: .link)` over the selection with newlines stripped. Lowest
   effort, reliable, but clunky gesture. Does not handle OSC 8.
2. **App-side click interceptor.** In `PasteInterceptingTerminalView.mouseDown`,
   on a chosen modifier, resolve the URL from the terminal grid at the click point
   (needs a point→cell→text path that the embedded surface does not currently
   expose) and open it locally, swallowing the event so Codex never sees it. True
   single click; highest effort and uncertain without a grid-text API.
3. **Port Ghostty's capture-bypass link open** into the vendored core. Blocked:
   the core is a prebuilt `xcframework`; would need rebuilding GhosttyKit.

## Security note

A link a remote agent printed is **not fully trusted**: an OSC 8 href can differ
from its visible text. Any implementation must restrict the opened scheme to
`http`/`https`/`mailto` and never hand `file:`, shell, or custom-scheme URLs to the
local launcher.
