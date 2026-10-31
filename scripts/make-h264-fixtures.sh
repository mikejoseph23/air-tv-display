#!/bin/bash
# SPDX-License-Identifier: MIT
# Generates synthetic H.264 Annex-B fixtures for the video path (M5) without a live capture:
#   Tests/Fixtures/synthetic-1080p.h264       1920x1080 main, 30 fps, 3 s, SPS/PPS on every IDR
#   Tests/Fixtures/synthetic-res-change.h264  1920x1080 for 1.5 s, then 1280x720 for 1.5 s
#                                             (new SPS/PPS mid-stream, as a sender rotation/resize does)
# No B-frames (tune zerolatency), like an AirPlay mirror stream. Validates both with ffprobe.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${FFMPEG_BIN:-$HOME/.cache/m0-mamba/root/envs/ux/bin}"
OUT="$REPO/Tests/Fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

enc() { # size seconds profile out
  "$BIN/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=$1:rate=30:duration=$2" \
    -c:v libx264 -profile:v "$3" -preset veryfast -tune zerolatency -pix_fmt yuv420p \
    -g 30 -b:v 2M -maxrate 2M -bufsize 1M -x264-params repeat-headers=1 -bsf:v h264_mp4toannexb \
    -f h264 "$4"
}

enc 1920x1080 3 main "$OUT/synthetic-1080p.h264"
enc 1920x1080 1.5 main "$TMP/a.h264"
enc 1280x720 1.5 baseline "$TMP/b.h264"
cat "$TMP/a.h264" "$TMP/b.h264" > "$OUT/synthetic-res-change.h264"

for f in "$OUT/synthetic-1080p.h264" "$OUT/synthetic-res-change.h264"; do
  "$REPO/scripts/ffprobe-stream.sh" "$f"
done
