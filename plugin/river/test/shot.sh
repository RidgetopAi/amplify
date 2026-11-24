#!/usr/bin/env bash
# Render the Current river headless from replayed fixtures and check what it
# drew and how it moves.
#
#   plugin/river/test/shot.sh      # writes docs/shots/river-default.png, river-busy.png, river-in-service.png
#
# Same stack as tools/headless-shot.sh (sway headless + pixman, Quickshell on
# llvmpipe, grim), at 1920x1080. Fixtures: fixtures/amplify-snapshot.json
# (captured 04:00:17Z) and plugin/river/test/busy-frames.json (staged from the
# same records: 9 claims, one expired; 85ff482a blocked; at 04:01:17Z a critic
# PASS of 379c80c6 and a REJECT of 6bbaf7d0). Motion checks compare frame
# sequences (tools/motion/frames.mjs), not single stills:
#   still:   AMPLIFY_STILL=1, busy at 04:01:47Z (flow 1, effects, eddy): 4 frames over 3 s identical, CPU idle;
#   idle:    animated, snapshot at 04:30Z (flow 0, no effects): 4 frames over 3 s identical, CPU idle;
#   settle:  animated, snapshot at 02:33Z (flow 0, three vessels sail ready → claimed): they move,
#            then 3 frames over 2 s identical and CPU idle (springs settle);
#   flowing: animated, snapshot at 04:00:17Z (flow 1): the water moves (control), downstream;
#   eddy:    animated, busy at 04:23:17Z (flow 0, one blocked task): the swirl turns on its own hull in 6/6 pairs;
#   fx:      animated, busy at 04:01:47Z: the PASS ring and REJECT eddy move, then are static by 5 s and log done;
#            everything off the water but the blocked swirl is static from 5 s to 6 s (tethers and gates settle);
#   replay:  AMPLIFY_STILL=1, busy with the replay clock running: a verdict effect shows for one step only.
# Trajectory checks (tools/motion/follow.mjs, spec docs/motion.json): settle, fx,
# eddy and still run with AMPLIFY_TRACE=1, which logs every drawn axis of every
# moving item (plugin/motion/Trace.qml) with the value its record asks for. The
# follow check finds the movers from that data (no hand-named keys) and checks
# each against its spec row: springs and tweens start at the old target, end at
# the new, pass strictly between, never jump or overshoot past the bound, settle
# in time; riders (tether ends, knots) stay on their hull; sweeps (PASS ring,
# REJECT rings) go once from start to end; spins and clocks turn at the record's
# rate; in still mode nothing changes between data steps. Still
# runs check the drawn result: each tether's lit stroke ends where its lease
# splits the tether (row 4), the REJECT rings stand turned -70 degrees at
# p = 0.5, and the PASS ring is drawn in gold around its landing point (row 7).
# Still runs also log what they draw: which hulls show a swirl (only blocked
# tasks) and each tether's lit fraction, tone and holder, checked against the
# fixture's leases and the holders' liveness (decision 23973614, contract 22d73eeb).
# CPU idle: Quickshell's utime+stime over the window is under 2 % of one core (decision 25eced40).
# Every run's log must be free of QML errors and binding loops.
# Exit status is the number of failed checks.
#
# Needs: sway, grim, quickshell, qsb, node, ImageMagick (magick). Without a GPU set HEADLESS_MESA (see tools/headless-shot.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/docs/shots"
MOTION="node $ROOT/tools/motion/frames.mjs"
FOLLOW="node $ROOT/tools/motion/follow.mjs"
# follow <scenario> <log> <label>: run the spec-driven follow check on a traced run.
follow() {
  local out ok
  out=$($FOLLOW "$1" "$2"); ok=$?
  echo "$out" | grep "^BAD" | head -20 | sed "s/^/  [$1] /"
  [[ $ok == 0 ]] && pass "$3 ($(echo "$out" | grep -c "^ok") follow checks, spec docs/motion.json)" \
    || fail "$3: $(echo "$out" | grep -c "^BAD") follow checks failed"
}
BUSY="$ROOT/plugin/river/test/busy-frames.json"
W=1920 H=1080
mkdir -p "$OUT"
"$ROOT/tools/build-shaders.sh" >/dev/null || echo "shot: shader build failed" >&2
node "$ROOT/plugin/river/test/make-busy.mjs" >/dev/null

RUN="$(mktemp -d)"
PIDS=()
cleanup() { kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$RUN"; }
trap cleanup EXIT

# env-read: SHOT_RUNTIME_DIR overrides the runtime dir (tools/mutate.sh gives each gate it runs its own).
export XDG_RUNTIME_DIR="${SHOT_RUNTIME_DIR:-$RUN}" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY DISPLAY SWAYSOCK
# env-read: HEADLESS_MESA selects a Mesa install for llvmpipe when there is no /dev/dri.
if [[ -n ${HEADLESS_MESA:-} ]]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="$HEADLESS_MESA/share/glvnd/egl_vendor.d/50_mesa.json"
  export LIBGL_DRIVERS_PATH="$HEADLESS_MESA/lib/dri" GBM_BACKENDS_PATH="$HEADLESS_MESA/lib/gbm"
fi

printf 'output HEADLESS-1 resolution %sx%s position 0 0\ndefault_border none\n' "$W" "$H" > "$RUN/sway.cfg"
sway -c "$RUN/sway.cfg" > "$RUN/sway.log" 2>&1 & PIDS+=($!)
for _ in $(seq 50); do ls "$XDG_RUNTIME_DIR"/wayland-* >/dev/null 2>&1 && break; sleep 0.1; done
export WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")"
export QT_QPA_PLATFORM=wayland

checks=0 fails=0 RUNS=()
pass() { checks=$((checks + 1)); echo "PASS $*"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL $*"; }

# start <name> <config dir> <ready pattern> [env...]: run Quickshell until stop.
start() {
  local pat=$3
  NAME=$1; RUNS+=("$1")
  env "${@:4}" quickshell -p "$2" > "$RUN/$NAME.log" 2>&1 & QS=$!
  for _ in $(seq 200); do grep -q "$pat" "$RUN/$NAME.log" && break; sleep 0.1; done
  T0=$(date +%s.%N)
}
# at <seconds>: sleep until that long after start saw its ready pattern.
at() { sleep "$(awk -v t0="$T0" -v s="$1" -v now="$(date +%s.%N)" 'BEGIN { d = t0 + s - now; print (d > 0 ? d : 0) }')"; }
grab() { grim "$RUN/$NAME-$1.png"; }
stop() {
  kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null
  cp "$RUN/$NAME.log" "/tmp/river-$NAME.log"
  grep -h "amplify:\|WARN\|ERROR\|rror" "$RUN/$NAME.log" | grep -v "river lanes\|amplify: trace\|river tether" | sed "s/^/  [$NAME] /"
  grep -h "river lanes" "$RUN/$NAME.log" | tail -1 | sed "s/^/  [$NAME] /"
}
frames() { local n; for n in "$@"; do printf '%s ' "$RUN/$NAME-$n.png"; done; }
# CPU ticks Quickshell has used so far; idle <t0> <t1> <seconds>: under 2 % of one core.
ticks() { awk '{ print $14 + $15 }' "/proc/$QS/stat"; }
CLK=$(getconf CLK_TCK)
idle() { (( ($2 - $1) * 100 <= 2 * $3 * CLK )); }
swirls() { grep -o "amplify: river swirl [0-9a-f]*" "$1" | awk '{ print $NF }' | sort -u | tr '\n' ' '; }

# ---------------------------------------------------------------- default: the snapshot at capture
start default "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_STILL=1 AMPLIFY_RIVER_AT=2026-11-22T04:00:17Z
at 1.5; grim "$OUT/river-default.png"; stop
grep -q "amplify: river lanes draft=9 ready=0 claimed=2 verifying=0 evidence=0 merged=5 trunk=0 vessels=16 tethers=2 expired= " "$RUN/default.log" \
  && pass "default: 16 vessels in their scene lanes, 2 live tethers" || fail "default: lane counts or tethers differ"

# ---------------------------------------------------------------- busy: verdicts, tethers; still mode is static
start busy "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_STILL=1 AMPLIFY_RIVER_AT=2026-11-22T04:01:47Z AMPLIFY_RIVER_FIXTURE="$BUSY"
at 1.5; grim "$OUT/river-busy.png"
cp "$OUT/river-busy.png" "$RUN/busy-0.png"; c0=$(ticks); at 2.5; grab 1; at 3.5; grab 2; at 4.5; grab 3; c1=$(ticks); stop
L="$RUN/busy.log"
grep "amplify: river events" "$L" | grep "pass 379c80c6 verifying→evidence" | grep -q "reject 6bbaf7d0 verifying→ready" \
  && pass "busy: critic PASS and REJECT from the lane change" || fail "busy: verdict transitions missing"
grep -q "tethers=9 expired=523461dd " "$L" && pass "busy: 9 tethers, the lapsed lease slack" || fail "busy: tethers differ"
grep -q "amplify: river fx pass 379c80c6 → evidence" "$L" && grep -q "amplify: river fx reject 6bbaf7d0 → ready" "$L" \
  && pass "busy: drew the PASS ring on 379c80c6 and the REJECT eddy on 6bbaf7d0" || fail "busy: verdict effects not drawn"
d=$($MOTION still $(frames 0 1 2 3))
[[ $? == 0 ]] && grep -q "flow=1.00" "$L" && grep -q "amplify: river eddy 85ff482a" "$L" && idle "$c0" "$c1" 3 \
  && pass "still: AMPLIFY_STILL=1 busy scene (flow 1, eddy, PASS, REJECT) static over 3 s ($d px, $((c1 - c0)) CPU ticks)" \
  || fail "still: AMPLIFY_STILL=1 scene moved over 3 s ($d px, $((c1 - c0)) CPU ticks)"
want=$(grep -o "amplify: river fx reject 6bbaf7d0 → .* at [0-9]*,[0-9]*" "$L" | head -1 | awk '{ print $NF }')
got=$(grep -o "amplify: river fx rings 6bbaf7d0 at [0-9]*,[0-9]*" "$L" | tail -1 | awk '{ print $NF }')
rot=$(grep -o "amplify: river fx rings 6bbaf7d0 at .* rot=[-0-9.]*" "$L" | tail -1 | sed 's/.*rot=//')
[[ -n $want ]] && awk -v a="$want" -v b="$got" -v r="${rot:-x}" 'BEGIN { split(a, p, ","); split(b, q, ","); exit !(b != "" && (p[1]-q[1])^2 + (p[2]-q[2])^2 <= 4 && r != "x" && (r + 70)^2 <= 1) }' \
  && pass "busy: the REJECT rings turn about 6bbaf7d0's landing point ($got), turned $rot° at p = 0.5" \
  || fail "busy: REJECT rings centred at ${got:-?} turned ${rot:-?}°, want landing point ${want:-?} turned -70°"
at=$(grep -o "amplify: river fx pass 379c80c6 → .* at [0-9]*,[0-9]*" "$L" | head -1 | awk '{ print $NF }')
out=$([[ -n $at ]] && $MOTION gold "$at" "$OUT/river-busy.png")
[[ $? == 0 && -n $at ]] && pass "busy: the PASS ring is drawn in gold around 379c80c6's landing point ($at: $out)" \
  || fail "busy: no PASS ring drawn around ${at:-?} (${out:-not logged})"
s=$(swirls "$L")
[[ $s == "85ff482a " ]] && pass "busy: a swirl on the blocked hull only (85ff482a)" || fail "busy: swirls on [$s], want only 85ff482a"
# Each tether's drawn lit fraction is its lease left at 04:01:47Z, from the fixture's
# claim_expires_at (0 when lapsed); its tone follows its holder (lost muted red,
# quiet dim, slack grey, live periwinkle).
out=$(node "$ROOT/plugin/river/test/tethers.mjs" "$BUSY" 2026-11-22T04:01:47Z "$L")
[[ $? == 0 ]] && pass "busy: each tether lit to its lease, toned by its holder (lost e3f2e1a4, quiet a40d7440)" \
  || fail "busy: drawn tethers differ: $out"

# ---------------------------------------------------------------- still-trace: tracing on draws the same, and still mode holds
# The same still busy scene with AMPLIFY_TRACE=1: the same pixels as the untraced shot, and in
# the trace nothing changes between data steps (follow river-still). Untraced runs log no trace.
start still-trace "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_STILL=1 AMPLIFY_TRACE=1 AMPLIFY_RIVER_AT=2026-11-22T04:01:47Z AMPLIFY_RIVER_FIXTURE="$BUSY"
at 2.5; grab 0; at 3.5; grab 1; stop
# Settled frames of both runs (busy at 4.5 s, this run at 3.5 s), below the replay label: the
# centred label lands on one of two subpixel positions in about one run in three, traced or
# not. Otherwise separate runs differ only by sub-1 % antialiasing noise, so compare at 1 % fuzz.
cmp_below_label() { magick "$1" -crop "${W}x$((H - 70))+0+70" +repage png:- | magick compare -metric AE -fuzz 1% - <(magick "$2" -crop "${W}x$((H - 70))+0+70" +repage png:-) null: 2>&1 | cut -d' ' -f1; }
d=$(cmp_below_label "$RUN/busy-3.png" "$RUN/still-trace-1.png")
[[ $d == 0 ]] && ! grep -q "amplify: trace" "$RUN/busy.log" "$RUN/default.log" && grep -q "amplify: trace" "$RUN/still-trace.log" \
  && pass "trace: on and off draw the same still busy frame below the replay label ($d px over 1 % apart), and untraced runs log no trace" \
  || fail "trace: tracing changes the picture ($d px) or untraced runs log trace lines"
follow river-still "$RUN/still-trace.log" "still: in the trace, nothing moves between data steps"

# ---------------------------------------------------------------- idle: flow 0, nothing may move
start idle "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_RIVER_AT=2026-11-22T04:30:00Z
at 2; grab 0; c0=$(ticks); at 3; grab 1; at 4; grab 2; at 5; grab 3; c1=$(ticks); stop
d=$($MOTION still $(frames 0 1 2 3))
[[ $? == 0 ]] && grep -q "flow=0.00 speed=0.0 " "$RUN/idle.log" && ! grep -q "river eddy\|river fx \|river swirl" "$RUN/idle.log" \
  && idle "$c0" "$c1" 3 \
  && pass "idle: flow 0, no eddy, swirl or effect, 4 frames over 3 s identical, $((c1 - c0)) CPU ticks" \
  || fail "idle: river moves or re-renders without data ($d px, $((c1 - c0)) CPU ticks)"

# ---------------------------------------------------------------- settle: vessels sail to a new lane, then stop
start settle "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_TRACE=1 AMPLIFY_RIVER_AT=2026-11-22T02:33:00Z
at 0.3; grab 0; at 1; grab 1; at 5; grab 2; c0=$(ticks); at 6; grab 3; at 7; grab 4; c1=$(ticks); stop
early=$($MOTION still $(frames 0 1)); late=$($MOTION still $(frames 2 3 4)); ok=$?
grep -q "flow=0.00 speed=0.0 " "$RUN/settle.log" && [[ $early =~ ^[0-9]+$ && $early != 0 && $ok == 0 ]] && idle "$c0" "$c1" 2 \
  && pass "settle: three vessels sail ready → claimed ($early px), then static from 5 s to 7 s, $((c1 - c0)) CPU ticks" \
  || fail "settle: lane change did not animate and settle (early $early px, late $late px, $((c1 - c0)) CPU ticks)"
# Rows 5 and 2: every vessel and gate whose target moved slides there.
follow river-settle "$RUN/settle.log" "settle: every moved vessel and gate follows its spec row"

# ---------------------------------------------------------------- flowing: the same check sees motion (control)
start flowing "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_RIVER_AT=2026-11-22T04:00:17Z
at 2; grab 0; at 5; grab 1; at 5.2; grab 2; at 5.4; grab 3; stop
d=$($MOTION still $(frames 0 1))
grep -q "flow=1.00 speed=90.0 " "$RUN/flowing.log" && [[ $d =~ ^[0-9]+$ ]] && [[ $d != 0 ]] \
  && pass "flowing: flow 1, the water moved ($d px)" || fail "flowing: no motion seen ($d)"
# Row 1: the streaks move downstream (left to right) between close frames.
out=$($MOTION flow $(frames 1 2 3)) && pass "flowing: the water runs downstream, left to right ($out)" \
  || fail "flowing: the water does not run downstream (${out:-?})"

# ---------------------------------------------------------------- eddy: the blocked swirl turns on its own hull
start eddy "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_TRACE=1 AMPLIFY_RIVER_AT=2026-11-22T04:23:17Z AMPLIFY_RIVER_FIXTURE="$BUSY"
for i in 0 1 2 3 4 5 6; do at "$(awk -v i=$i 'BEGIN { print 2.5 + i / 2 }')"; grab $i; done; stop
E=$(grep -o "amplify: river eddy 85ff482a at [0-9]*,[0-9]*" "$RUN/eddy.log" | tail -1 | awk '{print $NF}')
out=$([[ -n $E ]] && $MOTION eddy "$E" $(frames 0 1 2 3 4 5 6)); ok=$?
echo "$out" | sed "s/^/  [eddy] /"
[[ -n $E && $ok == 0 ]] && grep -q "flow=0.00 speed=0.0 " "$RUN/eddy.log" \
  && [[ $(grep -o "river eddy [0-9a-f]*" "$RUN/eddy.log" | sort -u | wc -l) == 1 ]] \
  && pass "eddy: blocked 85ff482a's swirl turns on its own hull ($E) in 6/6 frame pairs over 3 s" \
  || fail "eddy: swirl not on the blocked hull (${E:-no eddy logged})"
follow river-eddy "$RUN/eddy.log" "eddy: the swirl turns at its record's rate, the water clock stopped"

# ---------------------------------------------------------------- fx: verdict effects end within 5 s
start fx "$ROOT/plugin/river" "amplify: river fx reject" AMPLIFY_TRACE=1 AMPLIFY_RIVER_AT=2026-11-22T04:01:47Z AMPLIFY_RIVER_FIXTURE="$BUSY"
at 0.6; grab 0; at 1.4; grab 1; at 5; grab 2; at 6; grab 3; stop
L="$RUN/fx.log"
eddy=$(grep -o "amplify: river eddy 85ff482a at [0-9]*,[0-9]*" "$L" | tail -1 | awk '{print $NF}')
fxok=1 fxmsg=""
for e in "pass 379c80c6" "reject 6bbaf7d0"; do
  box=$(grep -o "amplify: river fx $e → [a-z]* box=[-0-9,]*" "$L" | head -1 | sed 's/.*box=//')
  [[ -n $box ]] || { fxok=0; fxmsg+=" ${e% *}: no box;"; continue; }
  read -r early gap late <<< "$($MOTION region "$box" "${eddy:--}" $(frames 0 1 2 3))"
  fxmsg+=" ${e% *} ${early}→${late} px;"
  (( early > 0 && late == 0 )) || fxok=0
done
(( fxok )) && pass "fx: PASS ring and REJECT eddy move, then their regions are static by 5 s ($fxmsg)" \
  || fail "fx: a verdict effect did not move or is still moving after 5 s ($fxmsg)"
grep -q "amplify: river fx done pass 379c80c6" "$L" && grep -q "amplify: river fx done reject 6bbaf7d0" "$L" \
  && pass "fx: both effects ended (fx done logged within 6 s)" || fail "fx: an effect never ended"
# Every axis of every moving item: hulls and gates (x, row offset), tether ends and
# knots (x, y) riding their hulls, tether lease length (K1), PASS ring live (K14),
# REJECT rings, water clock and swirl rate.
follow river-fx "$L" "fx: every moving item follows its spec row (vessels, gates, tethers x/y/length, PASS ring, REJECT rings)"
late=$($MOTION region 0,0,$W,$H "${eddy:--}" $(frames 2 3))
[[ $late == 0 ]] && pass "fx: off the water, only the blocked swirl moves from 5 s to 6 s (tethers, gates, effects settled)" \
  || fail "fx: $late px still moving off the water at 5-6 s"

# ---------------------------------------------------------------- replay: still mode shows a verdict for one step
start replay "$ROOT/plugin/river" "amplify: river lanes" AMPLIFY_STILL=1 AMPLIFY_RIVER_FIXTURE="$BUSY"
at 5.5; stop
L="$RUN/replay.log"
seq=$(grep -o "amplify: river lanes .* fx=[0-9]*" "$L" | awk -F'fx=' '{ printf "%s ", $NF }')
grep -q "amplify: river fx done pass 379c80c6" "$L" && grep -q "amplify: river fx done reject 6bbaf7d0" "$L" \
  && [[ " $seq" == *" 2 0 "* ]] && ! [[ " $seq" =~ \ ([3-9]|[1-9][0-9]) ]] \
  && pass "replay: AMPLIFY_STILL=1, the PASS and REJECT show for one step, then clear (fx per step: $seq)" \
  || fail "replay: still-mode verdict effects not cleared at the next step (fx per step: $seq)"

# ---------------------------------------------------------------- service: the whole plugin mounts the river
start in-service "$ROOT/plugin" "amplify: ready layer" AMPLIFY_STILL=1 AMPLIFY_RIVER_AT=2026-11-22T04:00:17Z \
  AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme"
at 1; grim "$OUT/river-in-service.png"; stop
grep -q "amplify: ready layer=bottom" "$RUN/in-service.log" && grep -q "amplify: river lanes draft=9" "$RUN/in-service.log" \
  && pass "service: plugin mounts the river on the bottom layer" || fail "service: river not mounted"

# ---------------------------------------------------------------- runtime log
bad=""
for f in "${RUNS[@]}"; do
  n=$(grep -ci "Unable to assign\|Cannot assign\|TypeError\|ReferenceError\|binding loop\|qml.*error\|is not defined\|is not a function" "$RUN/$f.log")
  (( n )) && { bad+=" $f($n)"; grep -i "Unable to assign\|Cannot assign\|TypeError\|ReferenceError\|binding loop\|qml.*error\|is not defined\|is not a function" "$RUN/$f.log" | head -3 | sed "s/^/  [$f] /"; }
done
[[ -z $bad ]] && pass "log: no QML errors or binding loops in ${#RUNS[@]} runs" || fail "log: QML errors or binding loops in$bad"

echo "shot: $checks checks, $fails failed; wrote docs/shots/river-{default,busy,in-service}.png"
exit "$fails"
