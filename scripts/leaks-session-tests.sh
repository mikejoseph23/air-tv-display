#!/bin/bash
# SPDX-License-Identifier: MIT
# Runs the M4T session tests under `leaks --atExit` and fails on any leak whose allocation
# stack is ours (XCTest's own SwiftTestingExecutionExtension leaks one 32-byte weak ref; ignored).
# Build the tests first: xcodebuild build-for-testing -project AirTVDisplay.xcodeproj \
#   -scheme AirTVDisplayTests -derivedDataPath build
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$REPO/build/Build/Products/Debug/AirTVDisplayTests.xctest"
SUITE="${1:-AirTVDisplayTests.SessionLifecycleTests}"
OUT="$(mktemp -t m4t-leaks)"
[ -d "$BUNDLE" ] || { echo "FAIL: $BUNDLE missing (build-for-testing first)"; exit 1; }

MallocStackLogging=1 leaks --atExit -- "$(xcrun --find xctest)" -XCTest "$SUITE" "$BUNDLE" >"$OUT" 2>&1
grep -E "Executed [0-9]+ tests" "$OUT" | tail -1
grep -E "leaks? for [0-9]+ total" "$OUT"
grep -q "with 0 failures" "$OUT" || { echo "FAIL: tests failed (see $OUT)"; exit 1; }

# One "STACK OF ..." block per leak; count blocks without XCTest's own frames.
ours=$(awk '
  function flush() { if (blk != "" && blk !~ /libXCTestSwiftSupport|XCTestCore/) n++; blk = "" }
  /^STACK OF/ { flush(); blk = $0; next }
  /^====/     { flush(); next }
  blk != ""   { blk = blk "\n" $0 }
  END         { flush(); print n + 0 }' "$OUT")
if [ "$ours" -gt 0 ]; then echo "FAIL: $ours leak(s) outside XCTest, report: $OUT"; exit 1; fi
echo "OK: no leaks outside XCTest (report: $OUT)"
