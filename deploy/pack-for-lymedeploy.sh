#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# deploy/pack-for-lymedeploy.sh
# Pack the staged dist/upload/ folder into a .nupkg and push it to LymeDeploy,
# so a release publishes through the deployment pipeline instead of by hand.
# Adapted from ~/git/mac-resource-monitor/deploy/pack-for-lymedeploy.sh.
#
# This is the bridge between scripts/stage-release.sh and LymeDeploy. Run it
# AFTER stage-release.sh has finished and staged dist/upload/.
#
#   ./scripts/stage-release.sh              # builds + stages dist/upload/
#   ./deploy/pack-for-lymedeploy.sh         # packs it, pushes it, tells you what's next
#
# What LymeDeploy does with it: the project's `publish-files` step extracts
# this package into the download folder on the target box, adding and
# replacing files but never pruning, with appcast.xml written strictly last
# and web.config protected, then purges Cloudflare's cache for the appcast.
# Project definition: deploy/deploy.yaml (AirTVDisplay.Downloads).
#
# Usage:
#   ./deploy/pack-for-lymedeploy.sh [--dry-run]
#
#   --dry-run   Build the .nupkg but don't push it, and report what would
#               have been pushed.
#
# The version is always read from AirTVDisplay/Info.plist (CFBundleShortVersionString)
# — the same source of truth stage-release.sh uses — so it can't drift from
# the staged artifacts.
#
# The push needs the 'lymedeploy' CLI on PATH, configured with a server + API
# key in ~/.lymedeploy/config.json. This script never reads that file.
set -euo pipefail

print_usage() {
    awk 'NR == 1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# ── args ─────────────────────────────────────────────────────────────────────
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "!! Unknown arg: $1 (see --help)" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."

UPLOAD="dist/upload"
PACKAGE_ID="AirTVDisplay.Downloads"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AirTVDisplay/Info.plist)"
DMG_NAME="AirTVDisplay-v$VERSION.dmg"
NUPKG="dist/$PACKAGE_ID.$VERSION.nupkg"

echo "==> Packing Air TV Display $VERSION for LymeDeploy"

# ── 1. The staged folder must exist and contain exactly the expected files ──
if [ ! -d "$UPLOAD" ]; then
    echo "!! $UPLOAD does not exist." >&2
    echo "   Run ./scripts/stage-release.sh first — it builds and stages the folder this packs." >&2
    exit 1
fi

if [ -z "$(ls -A "$UPLOAD" 2>/dev/null)" ]; then
    echo "!! $UPLOAD is empty." >&2
    echo "   Run ./scripts/stage-release.sh first — it builds and stages the folder this packs." >&2
    exit 1
fi

for required in "$DMG_NAME" appcast.xml index.html screenshot.png web.config; do
    if [ ! -f "$UPLOAD/$required" ]; then
        echo "!! $UPLOAD/$required is missing." >&2
        if [ "$required" = "$DMG_NAME" ]; then
            echo "   AirTVDisplay/Info.plist says version $VERSION, but no DMG of that name is staged." >&2
            echo "   That means stage-release.sh was not re-run after the version was bumped —" >&2
            echo "   packing now would publish a stale DMG alongside a fresh appcast." >&2
        else
            echo "   That means stage-release.sh did not finish. Re-run it rather than packing a partial release." >&2
        fi
        echo "   Staged files:" >&2
        ls -1 "$UPLOAD" | sed 's/^/     /' >&2
        exit 1
    fi
done

echo "==> Staged folder: $UPLOAD"
ls -1 "$UPLOAD" | grep -v '^\.DS_Store$' | sed 's/^/     /'

# ── 2. Build the .nupkg ──────────────────────────────────────────────────────
# Written with python's zipfile rather than `nuget pack` / `dotnet pack`:
# neither is present on the Mac, and this package has no project to pack — it
# is a folder of already-built, already-notarized artifacts. A .nupkg is just
# a zip with a .nuspec in it, and LymeDeploy reads identity from that .nuspec
# and unzips the rest.
#
# Payload files go at the ROOT of the archive, because the agent publishes the
# root of the extraction into the target directory after stripping the NuGet
# envelope ([Content_Types].xml, *.nuspec). A file in a subfolder here would
# land in a subfolder of the download directory and 404.
mkdir -p dist
rm -f "$NUPKG"

PACKAGE_ID="$PACKAGE_ID" VERSION="$VERSION" UPLOAD="$UPLOAD" NUPKG="$NUPKG" python3 <<'PYEOF'
import os, zipfile

pid = os.environ['PACKAGE_ID']
ver = os.environ['VERSION']
src = os.environ['UPLOAD']
out = os.environ['NUPKG']

nuspec = f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
  <metadata>
    <id>{pid}</id>
    <version>{ver}</version>
    <authors>Interapp Development, Inc.</authors>
    <description>Air TV Display {ver} download and auto-update artifacts (DMG, appcast.xml, landing page) published to the public download folder by LymeDeploy.</description>
  </metadata>
</package>
'''

# [Content_Types].xml is not required by LymeDeploy, which only unzips, but a
# .nupkg without it is not a valid OPC package and any other NuGet tooling
# that ever touches this file would reject it. It costs a few bytes.
content_types = '''<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="nuspec" ContentType="application/octet" />
  <Default Extension="dmg" ContentType="application/octet-stream" />
  <Default Extension="xml" ContentType="application/xml" />
  <Default Extension="html" ContentType="text/html" />
  <Default Extension="png" ContentType="image/png" />
  <Default Extension="config" ContentType="application/xml" />
</Types>
'''

names = sorted(n for n in os.listdir(src) if n != '.DS_Store' and os.path.isfile(os.path.join(src, n)))
if not names:
    raise SystemExit(f'ERROR: {src} contains no files to pack.')

# ZIP_STORED, not ZIP_DEFLATED: the payload is a notarized DMG (already
# compressed). Deflating it costs CPU and saves almost nothing.
with zipfile.ZipFile(out, 'w', zipfile.ZIP_STORED) as z:
    z.writestr(f'{pid}.nuspec', nuspec)
    z.writestr('[Content_Types].xml', content_types)
    for n in names:
        z.write(os.path.join(src, n), n)

total = sum(os.path.getsize(os.path.join(src, n)) for n in names)
print(f'     packed {len(names)} file(s), {total/1024/1024:.1f} MB payload')
PYEOF

echo "==> Wrote $NUPKG ($(du -h "$NUPKG" | cut -f1))"

# ── 3. Verify the archive round-trips before pushing it ─────────────────────
# Pushing a corrupt package is cheap to do and expensive to notice: the
# failure would surface on the agent, mid-deploy, as a confusing extraction
# error.
NUPKG="$NUPKG" python3 <<'PYEOF'
import os, zipfile
out = os.environ['NUPKG']
with zipfile.ZipFile(out) as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f'ERROR: {out} is corrupt (first bad entry: {bad}).')
    names = z.namelist()
    if not any(n.endswith('.nuspec') for n in names):
        raise SystemExit('ERROR: no .nuspec in the package — LymeDeploy could not read its identity.')
    nested = [n for n in names if '/' in n]
    if nested:
        raise SystemExit(f'ERROR: payload files must be at the archive root; found nested: {nested[:5]}')
print('     archive verified: readable, has a .nuspec, payload is flat')
PYEOF

# ── 4. Push ──────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = 1 ]; then
    echo "==> Not pushing (--dry-run)."
    echo "    Would have pushed: $NUPKG"
    echo "    To push it for real:"
    echo "      lymedeploy push-package \"$NUPKG\""
    exit 0
fi

if ! command -v lymedeploy >/dev/null 2>&1; then
    echo "!! the 'lymedeploy' CLI is not on PATH, so the package cannot be pushed." >&2
    echo "   The package is built and valid at:" >&2
    echo "     $NUPKG" >&2
    echo "   Install the CLI and run:" >&2
    echo "     lymedeploy push-package \"$NUPKG\"" >&2
    exit 1
fi

echo "==> Pushing to LymeDeploy…"
lymedeploy push-package "$NUPKG"

echo ""
echo "==> Pushed $PACKAGE_ID $VERSION"
echo ""
echo "Next, in LymeDeploy: create a release pinning $PACKAGE_ID $VERSION and deploy it to Production."
