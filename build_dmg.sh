#!/usr/bin/env bash
#
# Build Ziggy Listens (the SwiftUI app AND the in-process Swift worker, which
# compiles into the same target) and package a drag-to-install DMG (with the app
# icon as the volume icon) into ~/Documents.
#
# Run from the ziggy-notes/ root. The Xcode project lives under ui/.
#
# The app is ad-hoc signed so it launches on other Apple Silicon Macs (an
# unsigned bundle is rejected as "damaged"). It is NOT notarized, so testers
# still get a one-time Gatekeeper prompt — the bundled "READ ME FIRST.txt"
# explains how to get past it.
#
# Usage:
#   ./build_dmg.sh            # Release build (for sharing)
#   ./build_dmg.sh Debug      # Debug build
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"
cd "$UI_DIR"

CONFIG="${1:-Release}"
# Display name of the built product (PRODUCT_NAME in project.yml). The Xcode
# target/scheme/project are still "ZiggyNotes" (internal identifiers).
APP_NAME="Ziggy Listens"
SCHEME="ZiggyNotes"
PROJECT="ZiggyNotes.xcodeproj"
BUILD_DIR="$UI_DIR/.build"
PRODUCTS_DIR="$BUILD_DIR/Build/Products/$CONFIG"
APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"
DMG_OUT="$HOME/Documents/ZiggyListens.dmg"
VOL_NAME="Ziggy Listens"

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
# Sign the whole bundle (inside-out via --deep). Two reasons:
#   1. Apple Silicon refuses to launch binaries with no signature at all —
#      without this, testers get "Ziggy Listens is damaged and can't be opened".
#   2. macOS ties TCC grants (Screen Recording / Microphone) to the signing
#      identity. A STABLE identity means the permission is granted ONCE and
#      persists across rebuilds; ad-hoc (`-`) changes every build and re-prompts.
#
# We prefer the stable self-signed identity from scripts/setup-signing.sh and
# fall back to ad-hoc if it isn't installed. (Neither is notarized, so first
# launch still needs the one-time Gatekeeper "Open Anyway".)
# ----------------------------------------------------------------------------
echo "==> Signing"
ENTITLEMENTS="$UI_DIR/ZiggyNotes/ZiggyNotes.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-Ziggy Listens Self-Signed}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/ziggy-signing.keychain-db}"
SIGN_KEYCHAIN_PW="${SIGN_KEYCHAIN_PW:-ziggy-signing}"

if [[ -f "$SIGN_KEYCHAIN" ]] && security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "    using stable identity: $SIGN_IDENTITY"
  security unlock-keychain -p "$SIGN_KEYCHAIN_PW" "$SIGN_KEYCHAIN" 2>/dev/null || true
  codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"
else
  echo "    stable identity not found — using ad-hoc (Screen Recording permission"
  echo "    will reset on each rebuild). Run ./scripts/setup-signing.sh once to fix."
  codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH"
fi

if codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
  echo "    signature OK"
else
  echo "    WARN: codesign verify reported issues (app may still run)"
fi

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

# Install + first-run guide for testers (this is a test build, not notarized).
cat > "$STAGE/READ ME FIRST.txt" <<'EOF'
Ziggy Listens — install guide (test build)
==========================================

1. INSTALL
   Drag "Ziggy Listens" onto the Applications folder in this window.

2. FIRST LAUNCH (get past the Gatekeeper prompt)
   This is a test build, so it is NOT signed with a paid Apple Developer
   certificate. The first time you open it, macOS will say it "cannot verify
   the developer". This is expected. To allow it:

     • Open  System Settings > Privacy & Security
     • Scroll down to the Security section
     • Click "Open Anyway" next to Ziggy Listens, then confirm with Touch ID /
       your password.

   On macOS Sequoia the old right-click > Open shortcut no longer works — you
   must use Privacy & Security > Open Anyway.

   If instead macOS says the app is "damaged", open Terminal and run:

       xattr -dr com.apple.quarantine "/Applications/Ziggy Listens.app"

   then open the app again.

3. GRANT PERMISSIONS (asked on first run)
     • Microphone — so Ziggy can hear you.
     • Screen & System Audio Recording — so Ziggy can hear the other
       participants. After enabling this in Privacy & Security, relaunch the app.

4. CONFIGURE (Settings / Cmd-,)
     • Your Role.
     • AI Provider + API key (Anthropic or OpenAI — required).
     • Temporal: leave on the local dev server (localhost:7233) with a Temporal
       dev server running, or switch to Temporal Cloud and fill in address,
       namespace, and API key.

Then start a meeting and record. Enjoy!
EOF

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
