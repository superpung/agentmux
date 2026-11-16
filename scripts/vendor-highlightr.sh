#!/bin/sh
# Pin Highlightr with a safe resource lookup for signed, relocatable app bundles.
# An optional existing checkout avoids downloading an already cached dependency.
# Usage: scripts/vendor-highlightr.sh <tag> [checkout]
set -eu
TAG="${1:?usage: vendor-highlightr.sh <tag> [checkout]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SOURCE="${2:-}"
if [ -z "$SOURCE" ]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" \
    https://github.com/raspu/Highlightr.git "$WORK/source"
  SOURCE="$WORK/source"
fi
COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
EXPECTED="$(git -C "$SOURCE" rev-parse "$TAG^{commit}")"
[ "$COMMIT" = "$EXPECTED" ] || { echo "Checkout does not match $TAG" >&2; exit 1; }
DEST="$ROOT/Vendor/Highlightr"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SOURCE/Package.swift" "$SOURCE/LICENSE" "$SOURCE/src" "$DEST/"
chmod -R u+w "$DEST"
python3 - "$DEST/src/classes/Highlightr.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
source = p.read_text()
needle = 'let bundle = Bundle.module'
assert source.count(needle) == 1, 'Upstream resource lookup changed; review the patch'
p.write_text(source.replace(needle, 'guard let bundle = Bundle.highlightrResources() else { return nil }'))
PY
cp "$ROOT/Vendor/patches/Bundle+HighlightrResources.swift" "$DEST/src/classes/"
printf 'tag=%s\ncommit=%s\npatch=Vendor/patches/Bundle+HighlightrResources.swift\n' \
  "$TAG" "$COMMIT" > "$DEST/VENDORED"
echo "Vendored Highlightr $TAG ($COMMIT)"
