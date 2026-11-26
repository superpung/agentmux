#!/bin/sh
# Vendors libghostty-spm at a tag, with local resource lookup and host runtime
# integration patches.
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

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WORK/src/Package.swift" "$WORK/src/LICENSE" "$WORK/src/Sources" "$WORK/src/Tests" "$DEST/"

mkdir -p "$DEST/Sources/GhosttyHostEnvironment/include"
patch -s -p1 -d "$DEST" < "$ROOT/Vendor/patches/ghostty-host-environment.patch"

TERMINAL="$DEST/Sources/GhosttyTerminal"
grep -rl -e 'Bundle\.module' -e 'bundle: \.module' "$TERMINAL" | while read -r f; do
  sed -i '' -e 's/Bundle\.module/Bundle.ghosttyTerminalResources/g' \
            -e 's/bundle: \.module/bundle: .ghosttyTerminalResources/g' "$f"
done
cp "$ROOT/Vendor/patches/Bundle+GhosttyTerminalResources.swift" "$TERMINAL/Configuration/"

printf 'tag=%s\ncommit=%s\npatch=Vendor/patches/Bundle+GhosttyTerminalResources.swift\npatch=Vendor/patches/ghostty-host-environment.patch\n' \
  "$TAG" "$COMMIT" > "$DEST/VENDORED"
echo "Vendored libghostty-spm $TAG ($COMMIT)"
