#!/usr/bin/env bash
# Render the Current river headless from replayed fixtures and check what it drew.
#
#   plugin/river/test/shot.sh      # writes docs/shots/river-default.png, river-busy.png, river-in-service.png
#
# Same stack as tools/headless-shot.sh (sway headless + pixman, Quickshell on
# llvmpipe, grim), at 1920x1080:
#   default: fixtures/amplify-snapshot.json frozen at its capture time (04:00:17Z);
#   busy:    plugin/river/test/busy-frames.json (staged from the same records),
#            frozen 90 s in, the step right after a critic PASS and a REJECT;
#   idle:    animated at 04:30Z (flow 0): two grabs 3 s apart must be identical;
#   flowing: animated at 04:00:17Z (flow 1): the same grabs must differ (control);
#   service: the whole plugin (quickshell -p plugin/), to prove the mount.
# Exit status is the number of failed checks.
#
# Needs: sway, grim, quickshell, qsb. Without a GPU set HEADLESS_MESA (see tools/headless-shot.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/docs/shots"
W=1920 H=1080
mkdir -p "$OUT"
"$ROOT/tools/build-shaders.sh" >/dev/null || echo "shot: shader build failed" >&2

RUN="$(mktemp -d)"
PIDS=()
cleanup() { kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$RUN"; }
trap cleanup EXIT

export XDG_RUNTIME_DIR="$RUN" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY DISPLAY SWAYSOCK
# env-read: HEADLESS_MESA selects a Mesa install for llvmpipe when there is no /dev/dri.
if [[ -n ${HEADLESS_MESA:-} ]]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="$HEADLESS_MESA/share/glvnd/egl_vendor.d/50_mesa.json"
  export LIBGL_DRIVERS_PATH="$HEADLESS_MESA/lib/dri" GBM_BACKENDS_PATH="$HEADLESS_MESA/lib/gbm"
fi

printf 'output HEADLESS-1 resolution %sx%s position 0 0\ndefault_border none\n' "$W" "$H" > "$RUN/sway.cfg"
sway -c "$RUN/sway.cfg" > "$RUN/sway.log" 2>&1 & PIDS+=($!)
for _ in $(seq 50); do ls "$RUN"/wayland-* >/dev/null 2>&1 && break; sleep 0.1; done
export WAYLAND_DISPLAY="$(basename "$(ls "$RUN"/wayland-? | head -1)")"
export QT_QPA_PLATFORM=wayland

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# shot <name> <config dir> <ready pattern> [env...]
shot() {
  local name=$1 dir=$2 pat=$3; shift 3
  env AMPLIFY_STILL=1 "$@" quickshell -p "$dir" > "$RUN/$name.log" 2>&1 & local pid=$!
  for _ in $(seq 150); do grep -q "$pat" "$RUN/$name.log" && break; sleep 0.1; done
  sleep 1.5
  grim "$OUT/river-$name.png"
  cp "$RUN/$name.log" /tmp/river-$name.log; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -h "amplify:\|WARN\|ERROR\|rror" "$RUN/$name.log" | sed "s/^/  [$name] /"
}

shot default "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_RIVER_AT=2026-11-22T04:00:17Z
L="$RUN/default.log"
grep -q "amplify: river lanes draft=9 ready=0 claimed=2 verifying=0 evidence=0 merged=5 trunk=0 vessels=16 tethers=2 expired= " "$L" \
  && pass "default: 16 vessels in their scene lanes, 2 live tethers" || fail "default: lane counts or tethers differ"

node "$ROOT/plugin/river/test/make-busy.mjs" >/dev/null
shot busy "$ROOT/plugin/river" "amplify: river lanes" \
  AMPLIFY_RIVER_AT=2026-11-22T04:01:47Z AMPLIFY_RIVER_FIXTURE="$ROOT/plugin/river/test/busy-frames.json"
L="$RUN/busy.log"
grep "amplify: river events" "$L" | grep "pass 379c80c6 verifying→evidence" | grep -q "reject 6bbaf7d0 verifying→ready" \
  && pass "busy: critic PASS and REJECT from the lane change" || fail "busy: verdict transitions missing"
grep -q "tethers=9 expired=523461dd " "$L" && pass "busy: 9 tethers, the lapsed lease slack" || fail "busy: tethers differ"
grep -q "amplify: river fx pass 379c80c6 → evidence" "$L" && grep -q "amplify: river fx reject 6bbaf7d0 → ready" "$L" \
  && pass "busy: drew the PASS ring on 379c80c6 and the REJECT eddy on 6bbaf7d0" || fail "busy: verdict effects not drawn"

# motion <name> <ISO time>: animated (not AMPLIFY_STILL), clock frozen, two grabs 3 s apart.
# Prints the number of differing pixels.
motion() {
  local name=$1 at=$2
  env AMPLIFY_RIVER_AT="$at" quickshell -p "$ROOT/plugin/river" > "$RUN/$name.log" 2>&1 & local pid=$!
  for _ in $(seq 150); do grep -q "amplify: river lanes" "$RUN/$name.log" && break; sleep 0.1; done
  sleep 2
  grim "$RUN/$name-a.png"; sleep 3; grim "$RUN/$name-b.png"
  cp "$RUN/$name.log" /tmp/river-$name.log; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -h "amplify:" "$RUN/$name.log" | sed "s/^/  [$name] /" >&2
  magick compare -metric AE "$RUN/$name-a.png" "$RUN/$name-b.png" null: 2>&1 | cut -d' ' -f1
}
# Idle: 04:30Z, no task touched in the 15 min before, so flow 0 and nothing may move.
d=$(motion idle 2026-11-22T04:30:00Z)
grep -q "flow=0.00 speed=0.0 " "$RUN/idle.log" && [[ $d == 0 ]] \
  && pass "idle: flow 0, two grabs 3 s apart identical" || fail "idle: water moves without data ($d px differ)"
# Control: at capture the work is flowing, so the same check must see the water move.
d=$(motion flowing 2026-11-22T04:00:17Z)
grep -q "flow=1.00 speed=90.0 " "$RUN/flowing.log" && [[ $d =~ ^[0-9.e+]+$ ]] && [[ $d != 0 ]] \
  && pass "flowing: flow 1, the water moved ($d px)" || fail "flowing: no motion seen ($d)"

shot in-service "$ROOT/plugin" "amplify: river lanes" AMPLIFY_RIVER_AT=2026-11-22T04:00:17Z \
  AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme"
L="$RUN/in-service.log"
grep -q "amplify: ready layer=bottom" "$L" && grep -q "amplify: river lanes draft=9" "$L" \
  && pass "service: plugin mounts the river on the bottom layer" || fail "service: river not mounted"

for f in default busy in-service; do
  if grep -qi "qml.*error\|ReferenceError\|TypeError\|Cannot assign" "$RUN/$f.log"; then fail "$f: QML errors in log"; fi
done
echo "shot: $fails failed check(s); wrote docs/shots/river-{default,busy,in-service}.png"
exit "$fails"
