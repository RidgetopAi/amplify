#!/usr/bin/env bash
# Render the whole plugin headless on two screens with a stub cava and a stub MPRIS
# (task 523461dd; the orb has no audio) and check the ambient field's budget:
#   1. paused: cava is never started, every ambient window draws 0 fps;
#   2. playing: cava starts once, each screen's field draws music at 10..30 fps from a
#      stub that prints 120 frames a second (the 30 fps cap), and the field shows
#      (docs/shots/ambient.png, kept only when every check passes);
#   3. one screen under a fullscreen window: that screen draws 0 fps, the other keeps the music;
#   4. paused again: cava is stopped and every ambient window is back to 0 fps;
#   5. idle (the scene held at 04:38:18Z, nothing playing, as tools/headless-shot.sh's idle
#      check): Quickshell under 2 % of one core over 10 s with the ambient layer mounted.
# The CPU and fps numbers are printed for docs/perf/REPORT.md.
#   plugin/ambient/test/shot.sh      # exit status = number of failed checks
# Needs: sway, grim, quickshell, ImageMagick (magick); HEADLESS_MESA without a GPU.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
W=1280 H=720
RUN="$(mktemp -d)"
PIDS=()
. "$ROOT/tools/shot-reap.sh"; shot_tag "$RUN"
cleanup() { [[ $BASHPID == "$$" ]] || return; kill "${PIDS[@]}" 2>/dev/null; shot_reap; wait 2>/dev/null; rm -rf "$RUN"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# env-read: SHOT_RUNTIME_DIR overrides the runtime dir (tools/mutate.sh gives each gate its own).
export XDG_RUNTIME_DIR="${SHOT_RUNTIME_DIR:-$RUN}" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE
# env-read: HEADLESS_MESA selects a Mesa install for llvmpipe when there is no /dev/dri.
if [[ -n ${HEADLESS_MESA:-} ]]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="$HEADLESS_MESA/share/glvnd/egl_vendor.d/50_mesa.json"
  export LIBGL_DRIVERS_PATH="$HEADLESS_MESA/lib/dri" GBM_BACKENDS_PATH="$HEADLESS_MESA/lib/gbm"
fi
cat > "$RUN/sway.cfg" <<EOF
output HEADLESS-1 resolution ${W}x${H} position 0 0
default_border none
for_window [title="amplify-ambient-cover"] fullscreen enable
EOF
sway -c "$RUN/sway.cfg" > "$RUN/sway.log" 2>&1 & PIDS+=($!)
swayup() { ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 && ls "$XDG_RUNTIME_DIR"/sway-ipc.* >/dev/null 2>&1; }
shot_wait 10 "sway's sockets" swayup || exit 1
export WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")"
export SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* | head -1)" QT_QPA_PLATFORM=wayland QT_WAYLAND_FRAME_CALLBACK_TIMEOUT=60000
outputs() { (( $(swaymsg -t get_outputs | grep -c '"name": "HEADLESS-') >= $1 )); }
swaymsg create_output > /dev/null; shot_wait 10 "a second output" outputs 2 || exit 1
swaymsg output HEADLESS-2 resolution ${W}x${H} position $W 0 > /dev/null

export AMBIENT_STUB_DIR="$RUN/stub"; mkdir -p "$AMBIENT_STUB_DIR"
MPRIS="$RUN/mpris"; echo Paused > "$MPRIS"
LOG="$RUN/plugin.log"
qmlerr() { grep -acE "TypeError|ReferenceError|is not defined|Unable to assign|binding loop" "$1"; }
started() { ls "$AMBIENT_STUB_DIR"/started.* 2>/dev/null | wc -l; }
logged() { grep -aq "$2" "$1"; }
# start <log> <env...>: the whole plugin, animated, fps logged, stub cava and MPRIS; waits for both ready lines.
start() {
  local log=$1; shift
  : > "$log"
  env AMPLIFY_FPS=1 AMPLIFY_TRACE=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" \
    AMPLIFY_AMP_FIXTURE="$ROOT/data/amp/fixtures/top-capture.jsonl" \
    AMPLIFY_MPRIS_FIXTURE="$MPRIS" AMPLIFY_CAVA_BIN="$ROOT/plugin/ambient/test/cava-stub.sh" "$@" \
    quickshell -p "$ROOT/plugin" > "$log" 2>&1 & QS=$!; PIDS+=($QS)
  ready2() { (( $(grep -ac "amplify: ready " "$1") >= 2 )); }
  shot_wait 30 "both screens' ready lines" ready2 "$log"
}
# measure <log> <seconds>: Quickshell's CPU (% of one core) over <seconds>, then the ambient
# windows' fps lines logged in that span as "<screen> <fps> <changes/s>" (changes: how often
# the field changed, which counts even where the compositor sends a hidden surface no frames).
measure() {
  local log=$1 secs=$2 clk c0 c1 l0
  clk=$(getconf CLK_TCK) c0=$(awk '{ print $14 + $15 }' "/proc/$QS/stat") l0=$(wc -l < "$log")
  sleep "$secs"   # measurement window
  c1=$(awk '{ print $14 + $15 }' "/proc/$QS/stat")
  awk -v t=$((c1 - c0)) -v k="$clk" -v s="$secs" 'BEGIN { printf "%.1f\n", t / k / s * 100 }'
  tail -n +"$((l0 + 1))" "$log" | grep -aoE "amplify: fps window=amplify-ambient screen=[A-Z0-9-]* [0-9.]* changes=[0-9.]*" \
    | sed 's/.*screen=//; s/ changes=/ /'
}
# fpsof <screen> <lines>: that screen's fps lines, space-separated.
fpsof() { awk -v s="$1" '$1 == s { printf "%s ", $2 }' <<< "$2"; }
# changesof <screen> <lines>: that screen's field changes per second, space-separated.
changesof() { awk -v s="$1" '$1 == s { printf "%s ", $3 }' <<< "$2"; }
# within <lo> <hi> <values...>: at least one value, every one in [lo, hi].
within() { local lo=$1 hi=$2; shift 2; (( $# )) && awk -v lo="$lo" -v hi="$hi" 'BEGIN { for (i = 1; i < ARGC; i++) if (ARGV[i] < lo || ARGV[i] > hi) exit 1 }' "$@"; }

start "$LOG"
# 1. Paused. Settle window: the first frames and the ready line's timer, before the span.
sleep 6
out=$(measure "$LOG" 10); paused_cpu=$(head -1 <<< "$out"); f=$(tail -n +2 <<< "$out")
a=$(fpsof HEADLESS-1 "$f") b=$(fpsof HEADLESS-2 "$f")
echo "paused: Quickshell $paused_cpu % of one core; ambient fps HEADLESS-1: $a HEADLESS-2: $b"
(( $(started) == 0 )) && ! logged "$LOG" "ambient cava start" \
  && pass "paused: cava never started" || fail "paused: cava started while MPRIS reports Paused ($(started) stub starts)"
c=$(changesof HEADLESS-1 "$f")$(changesof HEADLESS-2 "$f")
within 0 0 $a && within 0 0 $b && within 0 0 $c && pass "paused: every ambient window draws 0 fps, its field unchanged" \
  || fail "paused: an ambient window draws with nothing playing (HEADLESS-1: $a HEADLESS-2: $b; changes/s $c)"

# 2. Playing.
echo Playing > "$MPRIS"
shot_wait 10 "cava to start" logged "$LOG" "ambient cava start" || true
sleep 6   # settle window: the fps lines straddling the start are left out
out=$(measure "$LOG" 10); playing_cpu=$(head -1 <<< "$out"); f=$(tail -n +2 <<< "$out")
a=$(fpsof HEADLESS-1 "$f") b=$(fpsof HEADLESS-2 "$f")
echo "playing: Quickshell $playing_cpu % of one core; ambient fps HEADLESS-1: $a HEADLESS-2: $b"
(( $(started) == 1 )) && pass "playing: one cava started ($(cat "$AMBIENT_STUB_DIR"/started.* 2>/dev/null))" \
  || fail "playing: $(started) cava starts (want 1)"
within 10 30.4 $a && within 10 30.4 $b && pass "playing: each screen draws the music at 10..30 fps from a 120 fps cava" \
  || fail "playing: ambient fps outside 10..30 (HEADLESS-1: $a HEADLESS-2: $b)"
grim -o HEADLESS-2 "$RUN/ambient.png"
# The field's band along the foot is lit and moves between frames.
grim -g "$W,$((H * 3 / 4)) ${W}x$((H / 4))" "$RUN/foot-0.png"
sleep 0.2   # a few music frames apart
grim -g "$W,$((H * 3 / 4)) ${W}x$((H / 4))" "$RUN/foot-1.png"
moved=$(magick compare -metric AE -fuzz 1% "$RUN/foot-0.png" "$RUN/foot-1.png" null: 2>&1 | cut -d' ' -f1)
[[ $moved =~ ^[0-9.e+]+$ ]] || moved=0
awk -v m="$moved" 'BEGIN { exit !(m > 500) }' && pass "playing: the field's foot changes between frames ($moved px)" \
  || fail "playing: the field's foot does not move with the music ($moved px)"

# 3. HEADLESS-1 under a fullscreen window.
swaymsg focus output HEADLESS-1 > /dev/null
quickshell -p "$ROOT/plugin/ambient/test/cover.qml" > "$RUN/cover.log" 2>&1 & PIDS+=($!)
shot_wait 15 "HEADLESS-1 to pause under the fullscreen window" logged "$LOG" "ambient screen=HEADLESS-1 paused fullscreen=true" || true
sleep 6   # settle window
out=$(measure "$LOG" 10); covered_cpu=$(head -1 <<< "$out"); f=$(tail -n +2 <<< "$out")
a=$(fpsof HEADLESS-1 "$f") b=$(fpsof HEADLESS-2 "$f")
c=$(changesof HEADLESS-1 "$f")
echo "covered: Quickshell $covered_cpu % of one core; ambient fps HEADLESS-1 (fullscreen): $a (changes/s $c) HEADLESS-2: $b"
# Both: sway sends a surface under a fullscreen window no frames, so a field that kept
# following the music there would still swap 0; its changes show it (mutation A2).
within 0 0 $a && within 0 0 $c && pass "covered: the screen under a fullscreen window draws 0 fps and holds its field" \
  || fail "covered: the ambient window under a fullscreen window keeps drawing (HEADLESS-1: $a fps, field changes/s $c)"
within 10 30.4 $b && pass "covered: the uncovered screen keeps the music (HEADLESS-2: $b)" \
  || fail "covered: the uncovered screen lost the music (HEADLESS-2: $b)"

# 4. Paused again.
echo Paused > "$MPRIS"
shot_wait 10 "cava to stop" logged "$LOG" "ambient cava stop" || true
gone() { ls "$AMBIENT_STUB_DIR"/stopped.* >/dev/null 2>&1; }
shot_wait 5 "the stub to exit" gone || true
sleep 6   # settle window
out=$(measure "$LOG" 10); f=$(tail -n +2 <<< "$out")
a=$(fpsof HEADLESS-1 "$f") b=$(fpsof HEADLESS-2 "$f")
gone && logged "$LOG" "ambient cava stop" && pass "paused again: cava stopped" || fail "paused again: cava still running"
c=$(changesof HEADLESS-1 "$f")$(changesof HEADLESS-2 "$f")
within 0 0 $a && within 0 0 $b && within 0 0 $c && pass "paused again: every ambient window back to 0 fps, its field unchanged" \
  || fail "paused again: an ambient window still draws (HEADLESS-1: $a HEADLESS-2: $b)"
err=$(qmlerr "$LOG")
(( err == 0 )) && pass "no QML errors" || { fail "$err QML errors"; grep -aE "TypeError|ReferenceError|is not defined|Unable to assign|binding loop" "$LOG" | head -5; }
grep -a "amplify: ambient" "$LOG" | sed 's/^/  /'
shot_stop "$QS"

# 5. Idle, as tools/headless-shot.sh's idle check: the held scene, nothing playing.
start "$RUN/idle.log" AMPLIFY_SCENE_AT=2026-11-22T04:38:18Z
sleep 6   # settle window
out=$(measure "$RUN/idle.log" 10); idle_cpu=$(head -1 <<< "$out")
echo "idle: Quickshell $idle_cpu % of one core (two ${W}x$H screens, held scene, nothing playing)"
awk -v p="$idle_cpu" 'BEGIN { exit !(p <= 2) }' && pass "idle: Quickshell at $idle_cpu % of one core (budget 2 %)" \
  || fail "idle: Quickshell at $idle_cpu % of one core (budget 2 %)"
shot_stop "$QS"

echo "ambient-shot: cpu paused=$paused_cpu playing=$playing_cpu covered=$covered_cpu idle=$idle_cpu"
if (( fails == 0 )); then
  mkdir -p "$ROOT/docs/shots"; cp "$RUN/ambient.png" "$ROOT/docs/shots/ambient.png"
  echo "ambient-shot: 0 failed checks; wrote docs/shots/ambient.png"
else
  echo "ambient-shot: $fails failed check(s); docs/shots/ambient.png left unchanged"
fi
exit "$fails"
