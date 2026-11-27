#!/bin/sh
# Vendors libghostty-spm at a tag, with the AgentMux host runtime patch.
#
# Usage: scripts/vendor-libghostty.sh <tag>
set -eu
TAG="${1:?usage: vendor-libghostty.sh <tag>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/libghostty-spm"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" \
  https://github.com/Lakr233/libghostty-spm.git "$WORK/src"
COMMIT="$(git -C "$WORK/src" rev-parse HEAD)"

STAGED="$WORK/staged"
mkdir -p "$STAGED"
cp -R "$WORK/src/Package.swift" "$WORK/src/LICENSE" "$WORK/src/Sources" "$WORK/src/Tests" "$STAGED/"

mkdir -p "$STAGED/Sources/GhosttyHostEnvironment/include"
patch -s -F 0 -p1 -d "$STAGED" < "$ROOT/Vendor/patches/ghostty-host-environment.patch"

ENGINE="$(sed -n 's#.*releases/download/upstream\.\([0-9a-f][0-9a-f]*\)/.*#\1#p' "$STAGED/Package.swift")"
case "$ENGINE" in
  ''|*[!0-9a-f]*) echo "Could not read the pinned Ghostty engine commit" >&2; exit 1 ;;
esac
printf 'tag=%s\ncommit=%s\nengine=%s\npatch=Vendor/patches/ghostty-host-environment.patch\n' \
  "$TAG" "$COMMIT" "$ENGINE" > "$STAGED/VENDORED"

# Keep the old tree recoverable until the prepared replacement is in place.
if [ -d "$DEST" ]; then
  mv "$DEST" "$WORK/previous"
fi
if ! mv "$STAGED" "$DEST"; then
  [ ! -d "$WORK/previous" ] || mv "$WORK/previous" "$DEST"
  exit 1
fi
echo "Vendored libghostty-spm $TAG ($COMMIT)"
