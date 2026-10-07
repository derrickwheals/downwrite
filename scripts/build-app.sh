#!/usr/bin/env bash
# Builds dist/Downwrite.app from the Swift package (macOS only).
#
#   scripts/build-app.sh                 # release build, ad-hoc signed (runs on this Mac)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh   # distributable signature
#   VERSION=1.2.0 BUILD=42 scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"          # "-" = ad-hoc
OUT="dist/Downwrite.app"

echo "▶ swift build ($CONFIG)"
swift build -c "$CONFIG" --product Downwrite
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▶ assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/Downwrite" "$OUT/Contents/MacOS/Downwrite"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$OUT/Contents/Info.plist"
cp Sources/Downwrite/Resources/* "$OUT/Contents/Resources/"
[ -f Packaging/AppIcon.icns ] && cp Packaging/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$OUT/Contents/PkgInfo"
plutil -lint "$OUT/Contents/Info.plist"

# Optional: compile the Icon Composer icon (light/dark/tinted variants) into an asset catalog.
if [ -d Packaging/AppIcon.icon ] && command -v xcrun >/dev/null; then
  echo "▶ compiling AppIcon.icon"
  PARTIAL="$(mktemp)"
  if xcrun actool Packaging/AppIcon.icon --compile "$OUT/Contents/Resources" --output-format human-readable-text \
       --notices --warnings --errors --output-partial-info-plist "$PARTIAL" --app-icon AppIcon \
       --include-all-app-icons --enable-on-demand-resources NO --development-region en \
       --target-device mac --minimum-deployment-target 26.0 --platform macosx >/dev/null 2>&1; then
    echo "  ✓ icon compiled"
  else
    echo "  ! actool failed — falling back to AppIcon.icns"
  fi
fi

echo "▶ codesign ($SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$OUT"
else
  codesign --force --deep --options runtime --timestamp --entitlements Packaging/Downwrite.entitlements \
           --sign "$SIGN_IDENTITY" "$OUT"
fi
codesign --verify --deep --strict "$OUT"
echo "✓ built $OUT ($VERSION, build $BUILD)"
