#!/bin/sh
# Builds AgentMux and assembles an ad-hoc signed build/AgentMux.app.
#
# Usage: scripts/bundle-app.sh [debug|release]
set -eu
CONFIG="${1:-debug}"
# Marketing version baked into Info.plist; the release workflow sets this from
# the git tag, dev builds get the default.
VERSION="${AGENTMUX_VERSION:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. scripts/env.sh

swiftpm build -c "$CONFIG"
BIN="$("$SWIFT" build --build-system native -c "$CONFIG" --show-bin-path 2>/dev/null)"

APP="$ROOT/build/AgentMux.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AgentMux" "$APP/Contents/MacOS/AgentMux"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp Resources/Icons/*.svg "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AgentMux</string>
  <key>CFBundleIdentifier</key><string>local.agentmux</string>
  <key>CFBundleName</key><string>AgentMux</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "$APP"
