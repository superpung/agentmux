#!/bin/sh
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg.
# Run after editing the SVG; the .icns is committed so the build needs no renderer.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. scripts/env.sh

SVG="Resources/AppIcon.svg"
ICNS="Resources/AppIcon.icns"
TMP="$(mktemp -d)"
SET="$TMP/AgentMux.iconset"

# AppKit won't link under the swift interpreter, so compile a tiny binary first.
"${SWIFT}c" -sdk "$(xcrun --show-sdk-path)" -O -o "$TMP/make-icon" scripts/make-icon.swift
"$TMP/make-icon" "$SVG" "$SET"
iconutil -c icns -o "$ICNS" "$SET"
rm -rf "$TMP"
echo "$ICNS"
