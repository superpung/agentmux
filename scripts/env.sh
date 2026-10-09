# Source this file: it points SWIFT at the per-user swift.org toolchain.
# CommandLineTools' xcrun ignores TOOLCHAINS, so the toolchain is called by path.
AGENTMUX_TOOLCHAIN="${AGENTMUX_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain}"
SWIFT="$AGENTMUX_TOOLCHAIN/usr/bin/swift"
if [ ! -x "$SWIFT" ]; then
  echo "Swift toolchain not found at $AGENTMUX_TOOLCHAIN" >&2
  return 1 2>/dev/null || exit 1
fi
# Swift 6.4's default "swiftbuild" engine needs xcstringstool, which ships only
# with Xcode (libghostty-spm has a .xcstrings resource). The native engine
# copies the file instead.
# Usage: swiftpm build | swiftpm test [args...]
swiftpm() { sub="$1"; shift; "$SWIFT" "$sub" --build-system native "$@"; }
