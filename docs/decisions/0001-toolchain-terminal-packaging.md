# ADR 0001: Toolchain, Terminal Engine and Packaging

Date: 2026-10-10. Status: accepted.

## Context

The app originally targeted the user's own Mac only (it is now also distributed as a public release; see the Licensing note below). The user wants a small disk footprint, no Xcode, and libghostty-spm as the terminal engine. libghostty-spm requires Swift 6.2+. This Mac runs macOS 15.5, for which Apple only offers Command Line Tools 16.4 (Swift 6.1). Xcode 26 and CLT 26 require macOS 15.6+.

## Decision

- **Toolchain:** the official swift.org Swift 6.4.0 toolchain, installed for the current user only (4.9 GB). The system default `swift` is unchanged. The SDK still comes from the CLT (MacOSX 15.4).
- **Build engine:** the SwiftPM native build engine. The default swiftbuild engine in 6.4 needs `xcstringstool` from Xcode. Native is marked deprecated in 6.4, but the toolchain is pinned at 6.4.0.
- **Terminal:** `GhosttyTerminal` from libghostty-spm with the `.inMemory` backend. The PTY and the `/usr/bin/ssh` process are owned by this project's `PTYProcess` (`forkpty` in C), so argv, backpressure and precise disconnects stay under our control.
- **Dependency pinning:** libghostty-spm is vendored as source in `Vendor/libghostty-spm` with one patch. SwiftPM's generated `Bundle.module` only looks for resource bundles at the `.app` root, where codesign rejects unsealed content; the patch makes GhosttyTerminal look in `Contents/Resources` first. Upgrade with `scripts/vendor-libghostty.sh <tag>`.
- **Packaging:** `scripts/bundle-app.sh` assembles `build/AgentMux.app` and signs it ad hoc; `codesign --verify --strict` passes.
- **Licensing:** (updated 2026-10-21) AgentMux is now distributed as a public GitHub release, so the original "personal use, no distribution" assumption no longer holds. Third-party components are used under their own licenses and listed in `THIRD_PARTY_NOTICES.md`; reused or adapted code records its source there.

## Consequences

- No Xcode is needed. There are no SwiftUI previews or Instruments; profiling uses `sample`, `leaks`, `footprint` and `vmmap`.
- If the Mac later moves to macOS 15.6+ with CLT 26, the per-user toolchain (4.9 GB) can be removed and the build can switch back to Apple's toolchain.
