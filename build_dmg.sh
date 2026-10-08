#!/usr/bin/env bash
#
# Build Ziggy Notes (the SwiftUI app AND the in-process Swift worker, which
# compiles into the same target) and package a drag-to-install DMG (with the app
# icon as the volume icon) into ~/Documents.
#
# Run from the ziggy-notes/ root. The Xcode project lives under ui/.
#
# Usage:
#   ./build_dmg.sh            # Debug build
#   ./build_dmg.sh Release    # Release build
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"
cd "$UI_DIR"

CONFIG="${1:-Debug}"
APP_NAME="Ziggy Notes"
SCHEME="ZiggyNotes"
PROJECT="ZiggyNotes.xcodeproj"
BUILD_DIR="$UI_DIR/.build"
PRODUCTS_DIR="$BUILD_DIR/Build/Products/$CONFIG"
APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"
DMG_OUT="$HOME/Documents/ZiggyNotes.dmg"
VOL_NAME="Ziggy Notes"

echo "==> Generating Xcode project"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
else
  echo "    xcodegen not found; using existing $PROJECT"
fi

echo "==> Building ($CONFIG)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: built app not found at: $APP_PATH" >&2
  exit 1
fi
echo "    built: $APP_PATH"

# ----------------------------------------------------------------------------
# Build an .icns for the DMG volume icon from the AppIcon asset PNGs.
# ----------------------------------------------------------------------------
echo "==> Creating volume icon"
ICON_SRC="$UI_DIR/ZiggyNotes/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/ZiggyNotes.iconset"
mkdir -p "$ICONSET"

# Map appiconset filenames -> iconutil's required names.
cp "$ICON_SRC/icon_16.png"      "$ICONSET/icon_16x16.png"
cp "$ICON_SRC/icon_16@2x.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICON_SRC/icon_32.png"      "$ICONSET/icon_32x32.png"
cp "$ICON_SRC/icon_32@2x.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICON_SRC/icon_128.png"     "$ICONSET/icon_128x128.png"
cp "$ICON_SRC/icon_128@2x.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICON_SRC/icon_256.png"     "$ICONSET/icon_256x256.png"
cp "$ICON_SRC/icon_256@2x.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICON_SRC/icon_512.png"     "$ICONSET/icon_512x512.png"
cp "$ICON_SRC/icon_512@2x.png"  "$ICONSET/icon_512x512@2x.png"

ICNS="$WORK/VolumeIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

# ----------------------------------------------------------------------------
# Stage the DMG contents: the app + a symlink to /Applications.
# ----------------------------------------------------------------------------
echo "==> Staging DMG contents"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# ----------------------------------------------------------------------------
# Create a read-write DMG, set the volume icon, then convert to compressed.
# ----------------------------------------------------------------------------
echo "==> Building DMG"
TMP_DMG="$WORK/rw.dmg"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDRW \
  -ov "$TMP_DMG" >/dev/null

MOUNT_DIR="$WORK/mnt"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$TMP_DMG" -nobrowse -noverify -noautoopen -mountpoint "$MOUNT_DIR" >/dev/null

cp "$ICNS" "$MOUNT_DIR/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT_DIR" || true
fi
sync
hdiutil detach "$MOUNT_DIR" >/dev/null

mkdir -p "$(dirname "$DMG_OUT")"
rm -f "$DMG_OUT"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null

echo "==> Done"
echo "    DMG: $DMG_OUT"
open -R "$DMG_OUT" 2>/dev/null || true
