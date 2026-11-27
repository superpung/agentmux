# ADR 0023: Pin the Ghostty DisplayLink Deadlock Fix

Date: 2026-11-27. Status: accepted.

## Context

macOS recorded a 13-second AgentMux hang while a terminal view was being
destroyed. Every sample of the main thread ended in `ghostty_surface_free`,
waiting for Ghostty's renderer thread. Every renderer sample was blocked in
`CVDisplayLink::stop()`, and the process had two live CoreVideo display-link
threads. This matches Ghostty's display-reconfiguration race: starting or
stopping a display link off the main thread can race CoreVideo and leave
`CVDisplayLinkStop` waiting indefinitely.

The previously pinned engine artifact, `35a81a980`, predates Ghostty commit
`81598385d608dda4946093d6d6a234d204a2f225`, which moves display-link start and
stop work to the main thread. Moving `ghostty_surface_free` onto an AgentMux
background queue would only hide the hang as a permanently leaked renderer and
would make surface lifetime harder to reason about.

## Decision

- Pin libghostty-spm tag `2.2.2026112401` (wrapper commit
  `df874b7f276f03e6341199af49a8c040fc045251`) and its Ghostty binary artifact
  `56de3f0f6786`. That artifact contains the upstream display-link fix.
- Keep surface destruction synchronous on the main thread, as required by the
  fixed engine's AppKit lifecycle.
- Keep the AgentMux environment-lifetime patch. Remove the old local resource
  lookup patch because this wrapper version implements the same signed-app
  lookup upstream.
- Extend the packaged-app smoke check to create, exercise and destroy 24 real
  Ghostty surfaces while posting screen-change notifications. The check runs
  in a disposable process with a timeout, so a renderer teardown deadlock fails
  verification instead of shipping. It also checks the version string in the
  final executable against the engine commit recorded in `VENDORED`, preventing
  a stale SwiftPM artifact from silently restoring the vulnerable engine.

## Consequences

The fix addresses the observed lock cycle at its source and continues to free
terminal resources normally. Future Ghostty upgrades remain explicit through
`scripts/vendor-libghostty.sh`; they must retain the packaged surface teardown
smoke test and the environment patch must apply without fuzz or rejects.
