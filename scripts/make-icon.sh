#!/bin/bash
# SPDX-License-Identifier: MIT
# Regenerates AirTVDisplay/Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O -o "$work/make-icon" "$repo/scripts/make-icon.swift"
"$work/make-icon" "$work/icon-1024.png"
set="$work/AppIcon.iconset"
mkdir -p "$set"
for s in 16 32 128 256 512; do
  sips -z $s $s "$work/icon-1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$work/icon-1024.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p "$repo/AirTVDisplay/Resources"
iconutil -c icns "$set" -o "$repo/AirTVDisplay/Resources/AppIcon.icns"
echo "wrote $repo/AirTVDisplay/Resources/AppIcon.icns"
