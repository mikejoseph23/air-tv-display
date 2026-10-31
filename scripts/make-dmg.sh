#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build a universal (arm64 + x86_64) Release Air TV Display.app with Sparkle embedded and pack
# it into a drag-to-Applications DMG. Adapted from ~/git/mac-resource-monitor/scripts/make-dmg.sh.
#
# Signing modes:
#   default      ad-hoc signed (Gatekeeper warns on download; fine for local testing)
#   SIGN_ID=...  sign with that codesign identity (e.g. "Developer ID Application: INTERAPP
#                DEVELOPMENT, INC. (UU626VCLYW)"), adding hardened runtime + secure timestamp
#                so the artifact can be notarized.
#   NOTARIZE_PROFILE=...  after signing, submit the DMG to Apple's notary service with that
#                keychain profile (xcrun notarytool store-credentials <name>), wait, and staple
#                the ticket to the DMG and the .app. Requires SIGN_ID.
#
# Signing is inside-out: Sparkle's XPC services -> Autoupdate -> Updater.app -> Sparkle.framework
# -> libcrypto.3.dylib -> the app (with AirTVDisplay.entitlements). No --deep: it would clobber
# the XPC services' entitlements. Then run scripts/stage-release.sh to EdDSA-sign the DMG and
# rewrite the appcast.
#
# Needs the dependency prefix from scripts/setup-deps.sh.
# Output: dist/Air TV Display.app, dist/Air TV Display.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Air TV Display"
BIN_NAME="AirTVDisplay"
VOL_NAME="$APP_NAME"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
SCRATCH="$DIST/.dmg-scratch"
RW_DMG="$DIST/.rw.dmg"
ENTITLEMENTS="AirTVDisplay/AirTVDisplay.entitlements"
SRC_PLIST="AirTVDisplay/Info.plist"
DERIVED="build"
BUILT_APP="$DERIVED/Build/Products/Release/$BIN_NAME.app"

SIGN_ID="${SIGN_ID:-}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"

if [ -n "$NOTARIZE_PROFILE" ] && [ -z "$SIGN_ID" ]; then
    echo "!! NOTARIZE_PROFILE set but SIGN_ID is empty; notarization needs a Developer ID signature" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC_PLIST")"

# Ad-hoc ("-") for local runs; a real Developer ID adds hardened runtime + a secure timestamp.
if [ -n "$SIGN_ID" ]; then
    IDENT="$SIGN_ID"
    HARDEN=(--options runtime --timestamp)
else
    IDENT="-"
    HARDEN=()
fi

DEPS="${AIRTV_DEPS_PREFIX:-$HOME/.cache/airtv-deps/universal}"
if ! { lipo "$DEPS/lib/libcrypto.3.dylib" -verify_arch arm64 && lipo "$DEPS/lib/libcrypto.3.dylib" -verify_arch x86_64; } 2>/dev/null; then
    echo "!! $DEPS/lib/libcrypto.3.dylib is missing or not universal; run scripts/setup-deps.sh" >&2
    exit 1
fi

echo "==> Cleaning $DIST"
rm -rf "$APP" "$DMG" "$SCRATCH" "$RW_DMG"
mkdir -p "$DIST"

command -v xcodegen >/dev/null && xcodegen -q
echo "==> xcodebuild Release v$VERSION ($BUILD), universal"
xcodebuild -project AirTVDisplay.xcodeproj -scheme AirTVDisplay -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    AIRTV_DEPS_PREFIX="$DEPS" build -quiet
ditto "$BUILT_APP" "$APP"

for bin in "$APP/Contents/MacOS/$BIN_NAME" "$APP/Contents/Frameworks/libcrypto.3.dylib"; do
    if ! { lipo "$bin" -verify_arch arm64 && lipo "$bin" -verify_arch x86_64; }; then
        echo "!! not universal: $bin ($(lipo -archs "$bin"))" >&2
        exit 1
    fi
done

echo "==> Signing inside-out (identity: $IDENT)"
FW="$APP/Contents/Frameworks/Sparkle.framework"
FWV="$FW/Versions/$(readlink "$FW/Versions/Current")"
# XPC services keep their shipped entitlements (Downloader.xpc is sandboxed, Installer.xpc not).
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --preserve-metadata=entitlements --sign "$IDENT" "$FWV/XPCServices/Downloader.xpc"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --preserve-metadata=entitlements --sign "$IDENT" "$FWV/XPCServices/Installer.xpc"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --sign "$IDENT" "$FWV/Autoupdate"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --sign "$IDENT" "$FWV/Updater.app"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --sign "$IDENT" "$FW"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --sign "$IDENT" "$APP/Contents/Frameworks/libcrypto.3.dylib"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --entitlements "$ENTITLEMENTS" --sign "$IDENT" "$APP"
codesign --verify --deep --strict "$APP"

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "LICENSE in Resources" "[ -f '$APP/Contents/Resources/LICENSE' ]"
check "LICENSES.md in Resources" "[ -f '$APP/Contents/Resources/LICENSES.md' ]"
check "no link to the build prefix" "! otool -L '$APP/Contents/MacOS/$BIN_NAME' | grep -q '.cache/'"
check "SUFeedURL set" "/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' '$APP/Contents/Info.plist' >/dev/null"
check "launches (--selftest)" "AIRTV_PORT=\${AIRTV_PORT:-7208} '$APP/Contents/MacOS/$BIN_NAME' --selftest --selftest-seconds 1 >/dev/null 2>&1"
[ "$fail" = 0 ] || { echo "!! bundle checks failed" >&2; exit 1; }

echo "==> Building DMG"
mkdir -p "$SCRATCH/.background"
cp -R "$APP" "$SCRATCH/"
ln -s /Applications "$SCRATCH/Applications"

# Background art: 1x + @2x fused into a HiDPI TIFF so Finder draws it at the right point size.
# Compiled rather than run with `swift file.swift`, whose argv differs between toolchains.
swiftc -O -o "$DIST/.draw-dmg-background" scripts/draw-dmg-background.swift
"$DIST/.draw-dmg-background" "$SCRATCH/.background" 2>/dev/null
rm -f "$DIST/.draw-dmg-background"
tiffutil -cathidpicheck \
    "$SCRATCH/.background/background.png" \
    "$SCRATCH/.background/background@2x.png" \
    -out "$SCRATCH/.background/background.tiff" >/dev/null
rm -f "$SCRATCH/.background/background.png" "$SCRATCH/.background/background@2x.png"

# Window + icon layout (points). Must agree with draw-dmg-background.swift.
WIN_LEFT=200; WIN_TOP=120; WIN_W=600; WIN_H=400
WIN_RIGHT=$(( WIN_LEFT + WIN_W )); WIN_BOTTOM=$(( WIN_TOP + WIN_H ))
ICON_SIZE=128
APP_X=150; APP_Y=185
APPS_X=450; APPS_Y=185

hdiutil create -volname "$VOL_NAME" -srcfolder "$SCRATCH" -ov \
  -fs HFS+ -format UDRW "$RW_DMG" >/dev/null

for stale in "/Volumes/$VOL_NAME" "/Volumes/$VOL_NAME 1" "/Volumes/$VOL_NAME 2"; do
    [ -d "$stale" ] && hdiutil detach "$stale" -force -quiet 2>/dev/null || true
done

hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen >/dev/null
MOUNT="/Volumes/$VOL_NAME"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$MOUNT/$APP_NAME.app" ] && [ -e "$MOUNT/Applications" ] && break
    sleep 0.5
done

# Finder layout is cosmetic: without Automation permission (e.g. over SSH) the DMG still works,
# it just opens with Finder's default layout.
if ! osascript <<APPLESCRIPT
tell application "Finder"
    activate
    tell disk "$VOL_NAME"
        open
        delay 2
        set theWindow to container window
        tell theWindow
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set the bounds to {$WIN_LEFT, $WIN_TOP, $WIN_RIGHT, $WIN_BOTTOM}
        end tell
        delay 1
        set theViewOptions to the icon view options of theWindow
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to $ICON_SIZE
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.tiff"
        delay 1
        set position of item "$APP_NAME.app" of theWindow to {$APP_X, $APP_Y}
        set position of item "Applications" of theWindow to {$APPS_X, $APPS_Y}
        delay 2
        close theWindow
    end tell
    delay 1
end tell
APPLESCRIPT
then
    echo "   (Finder layout skipped: osascript failed; the DMG is still valid)"
fi

sync
hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$SCRATCH"

if [ -n "$SIGN_ID" ]; then
    echo "==> Signing DMG"
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
fi

if [ -n "$NOTARIZE_PROFILE" ]; then
    echo "==> Submitting DMG to Apple notary (profile: $NOTARIZE_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait
    echo "==> Stapling notarization ticket to DMG and .app"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    xcrun stapler staple "$APP"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

echo "==> Done (v$VERSION, build $BUILD)"
lipo -info "$APP/Contents/MacOS/$BIN_NAME" | sed 's/^/    /'
ls -lh "$DMG" | awk '{print "    " $0}'
