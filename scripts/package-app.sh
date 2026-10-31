#!/bin/bash
# SPDX-License-Identifier: MIT
# Builds a Release AirTVDisplay.app, verifies the bundle and its signature, and copies it to
# dist/. Signing: ad-hoc ("-") unless SIGN_IDENTITY names a codesigning identity in the
# keychain (security find-identity -v -p codesigning). For a universal, Developer ID signed,
# notarized DMG use scripts/make-dmg.sh instead.
#
#   scripts/package-app.sh                 # ad-hoc
#   SIGN_IDENTITY="Apple Development: ..." scripts/package-app.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
identity="${SIGN_IDENTITY:--}"

command -v xcodegen >/dev/null && xcodegen -q
xcodebuild -project AirTVDisplay.xcodeproj -scheme AirTVDisplay -configuration Release \
  -derivedDataPath build build -quiet
app="build/Build/Products/Release/AirTVDisplay.app"

if [ "$identity" != "-" ]; then
  codesign --force --sign "$identity" --timestamp=none "$app/Contents/Frameworks/libcrypto.3.dylib"
  codesign --force --sign "$identity" --timestamp=none "$app"
fi

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "icon in bundle" "[ -f '$app/Contents/Resources/AppIcon.icns' ]"
check "libcrypto embedded" "[ -f '$app/Contents/Frameworks/libcrypto.3.dylib' ]"
check "links libcrypto via rpath" "otool -L '$app/Contents/MacOS/AirTVDisplay' | grep -q '@rpath/libcrypto.3.dylib'"
check "rpath -> Frameworks" "otool -l '$app/Contents/MacOS/AirTVDisplay' | grep -q '@executable_path/../Frameworks'"
check "no link to the build env" "! otool -L '$app/Contents/MacOS/AirTVDisplay' | grep -q '.cache/m0-mamba'"
check "codesign --verify --deep --strict" "codesign --verify --deep --strict '$app' 2>/dev/null"
check "launches (--selftest)" "AIRTV_PORT=\${AIRTV_PORT:-7208} '$app/Contents/MacOS/AirTVDisplay' --selftest --selftest-seconds 1 >/dev/null 2>&1"
codesign -dv "$app" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true

mkdir -p dist
rm -rf dist/AirTVDisplay.app
ditto "$app" dist/AirTVDisplay.app
echo "-> dist/AirTVDisplay.app ($(du -sh dist/AirTVDisplay.app | cut -f1))"
exit $fail
