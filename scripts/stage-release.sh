#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Prepare an Air TV Display release for upload to iadev.net/air-tv-display/.
# Adapted from ~/git/mac-resource-monitor/scripts/stage-release.sh.
#
# Given the notarized DMG from scripts/make-dmg.sh, this:
#   1. copies it to the versioned name AirTVDisplay-vX.Y.Z.dmg
#   2. EdDSA-signs it with Sparkle's sign_update (private key from the login Keychain, account
#      "ed25519", the key SUPublicEDKey pins; shared by all of Mike's apps, never in the repo)
#   3. rewrites deploy/updates/appcast.xml: enclosure url, sparkle:version (CFBundleVersion),
#      sparkle:shortVersionString, length, edSignature, pubDate
#   4. stages the versioned DMG + appcast.xml + web.config + website/index.html +
#      website/screenshot.png into dist/upload/ (website/ is the single source of truth for
#      the landing page; the DMG name and version labels in index.html are rewritten to this
#      release on the way)
#
# Then: ./deploy/pack-for-lymedeploy.sh (or upload dist/upload/ by hand and purge the
# Cloudflare cache for appcast.xml).
#
# Usage: scripts/stage-release.sh [path/to/Some.dmg]   (default: "dist/Air TV Display.dmg")
set -euo pipefail

cd "$(dirname "$0")/.."

SRC_DMG="${1:-dist/Air TV Display.dmg}"
[ -f "$SRC_DMG" ] || { echo "!! DMG not found: $SRC_DMG (run scripts/make-dmg.sh first)" >&2; exit 1; }
[ -f "website/index.html" ] || { echo "!! website/index.html not found" >&2; exit 1; }
[ -f "website/screenshot.png" ] || { echo "!! website/screenshot.png not found" >&2; exit 1; }

APPCAST="deploy/updates/appcast.xml"
UPLOAD="dist/upload"
PLIST="AirTVDisplay/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DMG_NAME="AirTVDisplay-v$VERSION.dmg"
VERSIONED_DMG="dist/$DMG_NAME"
FEED_URL="https://iadev.net/air-tv-display/$DMG_NAME"

# A DMG that isn't Developer ID signed and notarized would install fine via Sparkle but fail
# Gatekeeper for anyone downloading it, so refuse to stage one.
if ! codesign -dv "$SRC_DMG" 2>&1 | grep -q '^Authority=Developer ID Application'; then
    echo "!! $SRC_DMG is not Developer ID signed. Build it on the Mac Studio with" >&2
    echo "   SIGN_ID=... NOTARIZE_PROFILE=... scripts/make-dmg.sh (see CLAUDE.md, Release)." >&2
    [ "${ALLOW_UNSIGNED:-0}" = 1 ] || exit 1
    echo "   ALLOW_UNSIGNED=1: continuing anyway (local dry run only, never upload this)." >&2
fi

echo "==> Staging release v$VERSION (build $BUILD)"
cp "$SRC_DMG" "$VERSIONED_DMG"
SIZE="$(stat -f%z "$VERSIONED_DMG")"

# Sparkle's sign_update ships in the SwiftPM artifacts Xcode downloaded into build/.
SIGN_TOOL="$(find build/SourcePackages/artifacts -name sign_update -type f -not -path '*/old_dsa_scripts/*' 2>/dev/null | head -1)"
[ -n "$SIGN_TOOL" ] || { echo "!! sign_update not found under build/SourcePackages; run scripts/make-dmg.sh first" >&2; exit 1; }

# sign_update reads the private key from the login Keychain; without it there is nothing to sign
# with, which is expected anywhere but the Mac Studio.
if ! SIGN_OUT="$("$SIGN_TOOL" "$VERSIONED_DMG" 2>&1)"; then
    echo "!! sign_update could not EdDSA-sign the DMG:" >&2
    echo "$SIGN_OUT" | sed 's/^/   /' >&2
    echo "   The Sparkle private key (login Keychain, service https://sparkle-project.org, account" >&2
    echo "   ed25519) lives on the Mac Studio. Run this there from a logged-in session (the" >&2
    echo "   keychain is locked over SSH). Nothing was changed; appcast.xml is untouched." >&2
    exit 1
fi
ED_SIG="$(echo "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] || { echo "!! could not extract edSignature from: $SIGN_OUT" >&2; exit 1; }

PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"

echo "==> Rewriting $APPCAST (length $SIZE)"
python3 - "$APPCAST" "$FEED_URL" "$BUILD" "$VERSION" "$ED_SIG" "$SIZE" "$PUBDATE" <<'PY'
import sys, re
path, url, build, short, sig, size, pubdate = sys.argv[1:8]
x = open(path).read()
x = re.sub(r'url="[^"]*"',                        f'url="{url}"', x)
x = re.sub(r'sparkle:version="[^"]*"',            f'sparkle:version="{build}"', x)
x = re.sub(r'sparkle:shortVersionString="[^"]*"', f'sparkle:shortVersionString="{short}"', x)
x = re.sub(r'sparkle:edSignature="[^"]*"',        f'sparkle:edSignature="{sig}"', x)
x = re.sub(r'length="[^"]*"',                     f'length="{size}"', x)
x = re.sub(r'<title>Air TV Display [^<]*</title>', f'<title>Air TV Display {short}</title>', x)
x = re.sub(r'<pubDate>[^<]*</pubDate>',           f'<pubDate>{pubdate}</pubDate>', x)
open(path, 'w').write(x)
PY

echo "==> Staging upload folder: $UPLOAD"
rm -rf "$UPLOAD"; mkdir -p "$UPLOAD"
cp "$VERSIONED_DMG" "$APPCAST" deploy/updates/web.config website/screenshot.png "$UPLOAD/"
# Landing page: rewrite the DMG filename + version labels to this release so the download
# button and version text track the release without a manual edit.
sed -e "s|AirTVDisplay-v[0-9][0-9.]*\.dmg|$DMG_NAME|g" \
    -e "s|v[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}|v$VERSION|g" \
    website/index.html > "$UPLOAD/index.html"

echo ""
echo "Done. Staged in $UPLOAD/ :"
ls -lh "$UPLOAD/" | awk 'NR>1{print "    " $9 "  (" $5 ")"}'
echo ""
echo "Release notes: edit the <description> in $APPCAST if you haven't, then re-run this script."
echo "Next: ./deploy/pack-for-lymedeploy.sh to push this release through LymeDeploy."
echo "Fallback: upload everything in $UPLOAD/ to iadev.net/air-tv-display/ and purge the"
echo "Cloudflare cache for appcast.xml (both iadev.net and www.iadev.net)."
