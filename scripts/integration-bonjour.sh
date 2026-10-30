#!/bin/bash
# Integration: launch the app executable, resolve its _airplay._tcp / _raop._tcp registrations
# with dns-sd -L locally and on the Mac Studio (SSH), and diff the TXT keys against the M0 set.
# Usage: scripts/integration-bonjour.sh [path/to/AirTVDisplay] [--no-studio]
# Env: SERVICE_NAME (default "Air TV Display Dev"), STUDIO_HOST (default Mac-Studio.local)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Build/Products/Debug/AirTVDisplay.app/Contents/MacOS/AirTVDisplay}"
STUDIO=1; [ "${2:-}" = "--no-studio" ] && STUDIO=0
NAME="${SERVICE_NAME:-Air TV Display Dev}"
STUDIO_HOST="${STUDIO_HOST:-Mac-Studio.local}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "michaeljosephwork@$STUDIO_HOST")

AIRPLAY_KEYS="deviceid features flags model pi pk pw srcvers vv"
RAOP_KEYS="am ch cn da et ft md pk pw rhd sf sr ss sv tp txtvers vn vs vv"

TMP="$(mktemp -d)"; APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }

[ -x "$APP" ] || { echo "app executable not found: $APP (build first)"; exit 2; }
EXPECT_MAC="$(ifconfig en0 | awk '/ether /{print $2}')"

"$APP" --autostart >"$TMP/app.log" 2>&1 &
APP_PID=$!
# stdout is block-buffered when redirected, so don't wait on the log; give registration a moment.
sleep 3
kill -0 "$APP_PID" 2>/dev/null || { cat "$TMP/app.log"; fail "app exited early"; exit 1; }

# run dns-sd -L for 4s locally; $1=type $2=instance
resolve_local() { dns-sd -L "$2" "$1" local. >"$TMP/out" 2>&1 & local p=$!; sleep 4; kill $p 2>/dev/null; wait $p 2>/dev/null; cat "$TMP/out"; }
resolve_studio() { "${SSH[@]}" "dns-sd -L '$2' $1 local. & p=\$!; sleep 5; kill \$p" 2>&1; }

# extract sorted TXT keys from dns-sd -L output (the line after "can be reached at")
txt_keys() { awk '/can be reached at/{f=1;next} f&&/=/{for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]!="")print a[1]}; exit}' | sort | tr '\n' ' ' | sed 's/ $//'; }
txt_val() { awk -v k="$1" '/can be reached at/{f=1;next} f&&/=/{for(i=1;i<=NF;i++){if(index($i,k"=")==1){sub(k"=","",$i);print $i}}; exit}'; }

check() { # where type instance expected_keys
  local where="$1" type="$2" inst="$3" want out got
  want="$(echo $4 | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$where" = local ]; then out="$(resolve_local "$type" "$inst")"; else out="$(resolve_studio "$type" "$inst")"; fi
  if ! grep -q "can be reached at" <<<"$out"; then fail "$where $type '$inst' did not resolve"; echo "$out" | head -5; return; fi
  got="$(txt_keys <<<"$out")"
  if [ "$got" = "$want" ]; then echo "PASS: $where $type TXT keys match M0 ($(wc -w <<<"$got" | tr -d ' ') keys)"
  else fail "$where $type TXT keys differ"; diff <(tr ' ' '\n' <<<"$want") <(tr ' ' '\n' <<<"$got"); fi
  if [ "$type" = _airplay._tcp ]; then
    local did; did="$(txt_val deviceid <<<"$out")"
    [ "$did" = "$EXPECT_MAC" ] && echo "PASS: $where deviceid=$did equals en0 MAC" || fail "$where deviceid '$did' != en0 MAC '$EXPECT_MAC'"
  fi
}

RAOP_INST="$(echo "$EXPECT_MAC" | tr -d ':' | tr a-f A-F)@$NAME"
check local _airplay._tcp "$NAME" "$AIRPLAY_KEYS"
check local _raop._tcp "$RAOP_INST" "$RAOP_KEYS"
if [ "$STUDIO" = 1 ]; then
  if "${SSH[@]}" true 2>/dev/null; then
    check studio _airplay._tcp "$NAME" "$AIRPLAY_KEYS"
    check studio _raop._tcp "$RAOP_INST" "$RAOP_KEYS"
  else fail "cannot SSH to $STUDIO_HOST"; fi
fi

kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
[ $FAIL -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $FAIL
