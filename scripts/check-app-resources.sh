#!/bin/sh
# Exercise the packaged code preview without access to build-directory bundles.
# Usage: scripts/check-app-resources.sh <App.app> <swiftpm-bin-directory>
set -eu
APP="${1:?usage: check-app-resources.sh <App.app> <swiftpm-bin-directory>}"
BIN="${2:?usage: check-app-resources.sh <App.app> <swiftpm-bin-directory>}"
python3 - "$APP/Contents/MacOS/AgentMux" <<'PY'
from pathlib import Path
import sys
assert b'AGENTMUX_RESOURCE_SMOKE_TEST' in Path(sys.argv[1]).read_bytes(), 'App has no resource smoke entrypoint'
PY
WORK="$(mktemp -d)"
mkdir -p "$WORK/build-resources"
cleanup() {
  for bundle in "$WORK/build-resources"/*.bundle; do
    [ -e "$bundle" ] || continue
    mv "$bundle" "$BIN/"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ditto "$APP" "$WORK/Relocated.app"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] || continue
  mv "$bundle" "$WORK/build-resources/"
done

run_check() {
  EXPECTED="$1"
  REPORT="$WORK/$EXPECTED.json"
  python3 - "$WORK/Relocated.app/Contents/MacOS/AgentMux" "$REPORT" "$EXPECTED" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
subprocess.run([sys.argv[1]], env=dict(os.environ, AGENTMUX_RESOURCE_SMOKE_TEST=sys.argv[2]),
               timeout=20, check=True)
p = Path(sys.argv[2])
report = json.loads(p.read_text())
assert report['mode'] == sys.argv[3], report
assert report['textPreserved'], report
assert [r['theme'] for r in report['variants']] == ['light', 'dark'], report
print(json.dumps(report, sort_keys=True))
PY
}

# A signed, relocated app must find the JS and themes in its own resources.
codesign --verify --strict "$WORK/Relocated.app"
run_check highlighted

# An incomplete highlighting bundle must fall back to plain text in both cases.
RESOURCES="$WORK/Relocated.app/Contents/Resources/Highlightr_Highlightr.bundle"
mv "$RESOURCES" "$WORK/Highlightr_Highlightr.bundle"
codesign --force --sign - "$WORK/Relocated.app"
run_check plain
mv "$WORK/Highlightr_Highlightr.bundle" "$RESOURCES"
rm "$RESOURCES/highlight.min.js"
codesign --force --sign - "$WORK/Relocated.app"
run_check plain
