#!/usr/bin/env bash
# Packs dist/Downwrite.app into dist/Downwrite-<version>.dmg (macOS only). Run scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.9.0}"
DMG="dist/Downwrite-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R dist/Downwrite.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Downwrite" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG"
