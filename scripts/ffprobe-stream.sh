#!/bin/bash
# SPDX-License-Identifier: MIT
# Sanity-checks a raw H.264 Annex-B file (default: logs/stream.h264, the app's debug dump):
# codec/profile, frame count, every distinct resolution in order, and a full decode for errors.
# Exit 1 if it isn't H.264, has no frames, or the decoder reports errors.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${FFMPEG_BIN:-$HOME/.cache/m0-mamba/root/envs/ux/bin}"
F="${1:-$REPO/logs/stream.h264}"
[ -s "$F" ] || { echo "FAIL: $F missing or empty"; exit 1; }

codec=$("$BIN/ffprobe" -v error -f h264 -select_streams v:0 -show_entries stream=codec_name,profile \
  -of default=nw=1:nk=1 "$F" | paste -sd' ' -)
sizes=$("$BIN/ffprobe" -v error -f h264 -select_streams v:0 -show_entries frame=width,height \
  -of csv=p=0 "$F")
frames=$(printf '%s\n' "$sizes" | grep -c . || true)
res=$(printf '%s\n' "$sizes" | awk -F, 'NF==2 && $0!=last {printf "%s%sx%s", sep, $1, $2; sep=" -> "; last=$0}')
errs=$("$BIN/ffmpeg" -hide_banner -v error -f h264 -i "$F" -f null - 2>&1 | head -5 || true)

echo "$(basename "$F"): $(stat -f %z "$F") bytes, codec=[$codec], frames=$frames, resolution: $res"
[[ "$codec" == h264* ]] || { echo "FAIL: not h264"; exit 1; }
[ "$frames" -gt 0 ] || { echo "FAIL: no decodable frames"; exit 1; }
[ -z "$errs" ] || { echo "FAIL: decode errors:"; echo "$errs"; exit 1; }
echo "OK"
