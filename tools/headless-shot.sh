#!/usr/bin/env bash
# Render the Amplify plugin under a headless Wayland compositor and check it.
#
#   tools/headless-shot.sh   # writes docs/spike/headless.png and headless-uncovered.png
#
# Steps: rebuild the .qsb from shaders/, start sway with the headless backend
# and pixman renderer, start the harness (wallpaper on the Background layer and
# an app window over the right half), start `quickshell -p plugin/` with
# AMPLIFY_TRACE=1 so the data-driven orbs (plugin/orbs, replayed snapshot) log
# where they are drawn, screenshot with grim, then assert:
#   1. the plugin reports layer=bottom and shader=compiled with every program this
#      scene draws (orbs=5/5 river=1/1 basin=1/1) on a working GL context, the .qsb
#      having been rebuilt from source; and, run again with each component's programs
#      broken in turn, shader=error with that component at 0 (task 5afeee5f: G3, G4,
#      G6, N2); on a second screen too, and logged before the first frame shader=pending
#      then an "amplify: rendered" line reading compiled, a broken program error even
#      then (task f0e14f4c);
#   2. the uncovered orbs' centres are lit and accent-tinted, and nothing is
#      drawn where the P0 placeholder orb was (0.28W, 0.5H);
#   3. a covered orb's centre shows the app window, so the layer sits below windows;
#   4. a click on an orb opens its record, a click on empty desktop passes
#      through the masks to the wallpaper layer, and with the app window moved
#      away a click on a basin row opens its record;
#   5. neither screenshot is blank (and the blank check itself flags a uniform
#      frame);
#   6. idle on a model of the desktop (task 8b5eca2f): three outputs (one 2560x1440), the
#      whole plugin animated, the replay with nothing changing: Quickshell under 2 % of one
#      core, no river/basin window redraws, each orbs window under one frame a second;
#      with the river replay running at flow 0, no river/basin frame in 30 s; with live orbs
#      spinning, each orbs window within its clock (task 118f6917).
#      Screenshots are taken in a scratch directory
#      and copied to docs/spike only when every check passed, so a failed or
#      unrendered run (e.g. no HEADLESS_MESA without a GPU) never overwrites them.
# Runs are isolated (task 87f71d95): the compositor, its sockets and wayvnc's socket live in
# this run's own dirs, so two runs at once (tools/mutate.sh, tools/headless-pair.sh) never
# touch each other. Every wait is a bounded wait on something observable (shot_wait in
# tools/shot-reap.sh); the only sleeps are check 6's settle and measurement windows.
# Exit status is the number of failed checks (0 = all passed).
#
# Needs: sway, grim, wayvnc, vncdo (vncdotool), quickshell, qsb, ImageMagick (magick). With no GPU, point
# Mesa at a software driver, e.g. HEADLESS_MESA=/nix/store/...-mesa-<ver>.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/spike"
W=1280 H=720
mkdir -p "$OUT"

# 1. Shaders are always rebuilt here, orbs, river and basin alike, so a stale .qsb
# cannot pass the check (G3: a broken plugin/basin/pool.frag passed on its committed .qsb).
rm -f "$ROOT"/plugin/shaders/*.qsb "$ROOT"/plugin/basin/*.qsb "$ROOT"/plugin/river/*.qsb
"$ROOT/tools/build-shaders.sh"; built=$?

RUN="$(mktemp -d)"
. "$ROOT/tools/shot-reap.sh"; shot_tag "$RUN"
cleanup() { kill "${PIDS[@]}" 2>/dev/null; shot_reap; wait 2>/dev/null; rm -rf "$RUN"; }
PIDS=()
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# env-read: SHOT_RUNTIME_DIR overrides the runtime dir (tools/mutate.sh gives each gate it runs its own).
export XDG_RUNTIME_DIR="${SHOT_RUNTIME_DIR:-$RUN}" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY DISPLAY SWAYSOCK
# env-read: HEADLESS_MESA selects a Mesa install for llvmpipe when there is no /dev/dri.
if [[ -n ${HEADLESS_MESA:-} ]]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="$HEADLESS_MESA/share/glvnd/egl_vendor.d/50_mesa.json"
  export LIBGL_DRIVERS_PATH="$HEADLESS_MESA/lib/dri" GBM_BACKENDS_PATH="$HEADLESS_MESA/lib/gbm"
fi

cat > "$RUN/sway.cfg" <<EOF
output HEADLESS-1 resolution ${W}x${H} position 0 0
default_border none
default_floating_border none
for_window [title="amplify-cover"] floating enable, resize set $((W / 2)) $H, move absolute position $((W / 2)) 0
EOF
sway -c "$RUN/sway.cfg" > "$RUN/sway.log" 2>&1 & PIDS+=($!)
swayup() { ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 && ls "$XDG_RUNTIME_DIR"/sway-ipc.* >/dev/null 2>&1; }
shot_wait 10 "sway's sockets" swayup
export WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")"
export SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* | head -1)"
export QT_QPA_PLATFORM=wayland

quickshell -p "$ROOT/tools/harness" > "$RUN/harness.log" 2>&1 & PIDS+=($!)
# The harness is up once its wallpaper and its app window have each drawn a frame and sway
# has floated the window over the right half.
harnessup() { grep -q "harness: wallpaper drawn" "$RUN/harness.log" && grep -q "harness: cover drawn" "$RUN/harness.log" \
  && swaymsg -t get_tree | grep -q '"name": "amplify-cover"'; }
shot_wait 20 "the harness's first frames" harnessup
# plugin [dir]: start the plugin (default plugin/), still and traced, and wait until it has
# settled: each of the $SCREENS screens logged its ready line, and each ready line that read
# pending was followed by its rendered line (a broken program reads error, never pending).
# Its orbs replay the test-only fixtures/test/orbs-states.json (every role, a beam, orbs on
# both halves), unless ORBS_FIXTURE= (the shipped capture, the one-capture check below).
ORBS_FIXTURE="$ROOT/fixtures/test/orbs-states.json"
SCREENS=1
settled() {
  local l="$RUN/plugin.log"
  (( $(grep -ac "amplify: ready " "$l") >= SCREENS \
     && $(grep -a "amplify: ready " "$l" | grep -c "shader=pending") <= $(grep -ac "amplify: rendered " "$l") ))
}
plugin() {
  # Emptied here, not by the launch's own redirection: that runs in the forked child, and
  # under load the first check could read the last run's ready line before it.
  : > "$RUN/plugin.log"
  AMPLIFY_STILL=1 AMPLIFY_TRACE=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" AMPLIFY_ORBS_FIXTURE="$ORBS_FIXTURE" \
    quickshell -p "${1:-$ROOT/plugin}" > "$RUN/plugin.log" 2>&1 & QS=$!; PIDS+=($QS)
  shot_wait 30 "the plugin's ready lines (${1:-plugin/})" settled
}
plugin

grim "$RUN/headless.png"

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
pixel() { magick "$RUN/headless.png" -format "%[fx:int(255*p{$1,$2}.r)] %[fx:int(255*p{$1,$2}.g)] %[fx:int(255*p{$1,$2}.b)]" info:; }

# The programs each component draws in this scene (G4), in the ready line's order:
# orbs 5 (coord, critic and worker bodies, beam, vessel), river 1 (water), basin 1 (pool).
# A component that draws none reads n=0/0, so the counts are asserted, not only the status.
COMPS=(orbs river basin); declare -A PROGS=([orbs]=5 [river]=1 [basin]=1)
# counts [group]: "orbs=5/5 river=1/1 basin=1/1", with that group's programs at 0.
counts() { local g s=""; for g in "${COMPS[@]}"; do s+=" $g=$([[ $g == "${1:-}" ]] && echo 0 || echo "${PROGS[$g]}")/${PROGS[$g]}"; done; echo "${s# }"; }
# Without a GL driver Qt fails to make its RHI and the effects never load, yet the ready
# line can still read compiled (N2), so a failed graphics context fails the check too.
nogl() { grep -aE "Failed to create RHI|Failed to initialize graphics backend" "$RUN/plugin.log" | head -1; }

ready=$(grep -a "amplify: ready" "$RUN/plugin.log" | head -1)
echo "log: ${ready#*qml: }"
[[ $ready == *"layer=bottom"* ]] && pass "layer is bottom" || fail "layer is not bottom"
(( built == 0 )) && pass "every .qsb rebuilt from source" || fail "shader build failed (tools/build-shaders.sh exit $built)"
gl=$(nogl)
[[ $ready == *"shader=compiled $(counts)"* && -z $gl ]] && pass "every shader compiled from .qsb ($(counts))" \
  || fail "shaders not all compiled (want shader=compiled $(counts))${gl:+; ${gl#*: }}"

# The orbs from the trace: "<id8> <x> <y> <light>" of every opaque orb, left to
# right, as last drawn (still mode: they hold). Uncovered: the live ones (full
# light) clear of the app window (x >= W/2); covered: any under it.
# (Parsed from the "amplify: trace" text on, since quickshell may colour its log prefix.)
orbs=$(awk 'sub(/.*amplify: trace /, "") && $1 == "orbs" && $2 == "orb" && ($4 == "x" || $4 == "y" || $4 == "opacity" || $4 == "light") { v[$3, $4] = $5; id[$3] = 1 }
  END { for (i in id) if (v[i, "opacity"] == 1) printf "%s %d %d %s\n", i, v[i, "x"], v[i, "y"], v[i, "light"] }' "$RUN/plugin.log" | sort -k2 -n)
uncovered=$(awk -v m=$((W / 2 - 40)) '$2 < m && $4 == 1 { print $1, $2, $3 }' <<< "$orbs")
covered=$(awk -v m=$((W / 2 + 40)) '$2 > m { print $1, $2, $3 }' <<< "$orbs")
echo "orbs (id8 x y): $(tr '\n' ';' <<< "$orbs")"
lit=0
while read -r id x y; do
  [[ -n $id ]] || continue
  read -r r g b <<< "$(pixel "$x" "$y")"
  echo "uncovered orb $id at $x,$y pixel: $r $g $b"
  (( b > 120 && b > r )) && lit=$((lit + 1))
done <<< "$uncovered"
(( lit > 0 && lit == $(grep -c . <<< "$uncovered") )) && pass "uncovered data orbs render (accent-lit, $lit)" \
  || fail "uncovered data orbs not rendered ($lit lit)"

# Where the P0 Meridian placeholder was drawn: only wallpaper and faint river water now.
read -r r g b <<< "$(pixel "$((W * 28 / 100))" "$((H / 2))")"
echo "former placeholder pixel: $r $g $b"
(( r < 90 && g < 90 && b < 110 )) && pass "nothing drawn where the placeholder orb was" || fail "an orb is drawn at the placeholder spot"

read -r id x y <<< "$(head -1 <<< "$covered")"
read -r r g b <<< "$(pixel "${x:-0}" "${y:-0}")"
echo "covered orb ${id:-none} at ${x:-?},${y:-?} pixel: $r $g $b (app window is 232 227 216)"
[[ -n $id ]] && (( r > 220 && g > 215 && b > 205 && b < 225 )) && pass "app window covers the orb (layer below windows)" \
  || fail "orb drawn over the app window (or no covered orb)"

# The click target: the rightmost uncovered live orb.
read -r OID OX OY <<< "$(tail -1 <<< "$uncovered")"

# The headless backend has no input devices. wayvnc holds one virtual pointer
# for the whole session (one-shot tools such as wlrctl add and remove a device
# per call, which races the client binding wl_pointer), and vncdo drives it.
# Its endpoint is a unix socket in this run's own dir (task 87f71d95), so runs at once
# (tools/mutate.sh, tools/headless-pair.sh) never drive each other's compositor; it is up
# once vncdo connects to it, and it must still be running then: a wayvnc that could not
# listen exits, and the connection reached some other run's server.
VNC="$RUN/vnc.sock"
wayvnc -u "$VNC" > "$RUN/wayvnc.log" 2>&1 & VNCPID=$!; PIDS+=($VNCPID)
vncup() { timeout 5 vncdo -s "$VNC" pause 0 >/dev/null 2>&1; }
shot_wait 20 "wayvnc on $VNC" vncup
kill -0 "$VNCPID" 2>/dev/null && pass "wayvnc serves this run's compositor on its own endpoint ($VNC)" \
  || fail "wayvnc is not running on this run's endpoint $VNC ($(head -c 200 "$RUN/wayvnc.log" | tr '\n' ' '))"
# The pauses between a move and its click are input pacing (the client sees the pointer
# enter before the button); after the clicks, wait for what they log.
timeout 20 vncdo -s "$VNC" move "$OX" "$OY" pause 0.3 click 1 pause 0.3 \
  move "$((W / 2 - 40))" "$((H - 60))" pause 0.3 click 1
clicked() { grep -aq "amplify: orb open http" "$RUN/plugin.log" && grep -q "harness: wallpaper click" "$RUN/harness.log"; }
shot_wait 5 "both clicks' log lines" clicked
grep -aq "amplify: orb open http" "$RUN/plugin.log" && pass "click on orb $OID opens its record ($(grep -ao "amplify: orb open .*" "$RUN/plugin.log" | head -1))" \
  || fail "click on orb $OID lost"
grep -q "harness: wallpaper click" "$RUN/harness.log" && pass "click on empty desktop passes through the mask" \
  || fail "empty-desktop click swallowed by the Amplify layer"

# The basin sits under the app window (lower right); move the window away, then
# click the basin's last row (Service.qml: right 28, bottom 30; rows 64 px high).
swaymsg '[title="amplify-cover"] move scratchpad' > /dev/null
# Gone once the window's middle no longer shows its colour (232 227 216) in a capture.
uncovered() {
  local r g b
  grim "$RUN/headless-uncovered.png" || return 1
  read -r r g b <<< "$(magick "$RUN/headless-uncovered.png" -format "%[fx:int(255*p{$((W * 3 / 4)),$((H / 4))}.r)] %[fx:int(255*p{$((W * 3 / 4)),$((H / 4))}.g)] %[fx:int(255*p{$((W * 3 / 4)),$((H / 4))}.b)]" info:)"
  ! (( r > 220 && g > 215 && b > 205 && b < 225 ))
}
shot_wait 10 "the app window to leave the screen" uncovered
timeout 20 vncdo -s "$VNC" move "$((W - 28 - 250))" "$((H - 30 - 32))" pause 0.3 click 1
basinclick() { grep -aq "amplify: basin open http" "$RUN/plugin.log"; }
shot_wait 5 "the basin click's log line" basinclick
grep -aq "amplify: basin open http" "$RUN/plugin.log" && pass "click on a basin row opens its record" || fail "basin click lost"

# A broken program must turn the ready line to shader=error, for every component (G6):
# the same plugin (a copy of plugin/ alone: it holds no links out) with each component's
# programs truncated in turn must read shader=error with that component at 0. The river
# loads its own copy, plugin/river/river.frag.qsb.
kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null; cp "$RUN/plugin.log" "$RUN/plugin-main.log"
declare -A BREAK=([orbs]="plugin/shaders/orb*.qsb" [river]="plugin/river/river.frag.qsb" [basin]="plugin/basin/*.frag.qsb")
for g in "${COMPS[@]}"; do
  B="$RUN/broken-$g"; mkdir "$B"; cp -a "$ROOT/plugin" "$B/"
  for f in $B/${BREAK[$g]}; do head -c 64 "$ROOT/${f#"$B/"}" > "$f"; done
  plugin "$B/plugin"; kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null
  bready=$(grep -a "amplify: ready" "$RUN/plugin.log" | head -1)
  echo "broken $g log: ${bready#*qml: }" | cut -c1-200
  [[ $bready == *"shader=error $(counts "$g")"* ]] && pass "broken $g programs report shader=error ($(counts "$g"))" \
    || fail "ready line hides broken $g programs (want shader=error $(counts "$g"))"
  cat "$RUN/plugin.log" >> "$RUN/plugin-main.log"
done

# Two screens (task f0e14f4c). Qt loads each program once per process, so only the first
# screen's effects report Compiled; the second screen's draw the cached program and stay
# Uncompiled. On a second output, every screen's ready line must still read compiled with
# every program. Then, logged before the first frame (AMPLIFY_READY_MS=0), each screen's
# ready line must read pending, never compiled, and an "amplify: rendered" line must follow
# reading compiled; a broken program must read error even then, never pending.
# outputs <n>: true when sway lists n outputs.
outputs() { (( $(swaymsg -t get_outputs | grep -c '"name": "HEADLESS-') == $1 )); }
swaymsg create_output > /dev/null; shot_wait 10 "a second output" outputs 2; SCREENS=2
# screens <log> <what>: how many screens logged an "amplify: <what>" line, then each line.
screens() { local l; l=$(grep -a "amplify: $2 " "$1" | sed 's/.*qml: //'); grep -c . <<< "$l"; echo "$l" | cut -c1-200; }
# all2 <log> <what> <want>: true when exactly two screens logged <what>, each containing <want>.
all2() { local l; l=$(grep -a "amplify: $2 " "$1"); (( $(grep -c . <<< "$l") == 2 && $(grep -c -- "$3" <<< "$l") == 2 )); }
plugin; kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null; cp "$RUN/plugin.log" "$RUN/two.log"
screens "$RUN/two.log" ready | sed 's/^/two screens: /'
all2 "$RUN/two.log" ready "shader=compiled $(counts)$" && pass "both screens report shader=compiled ($(counts))" \
  || fail "a second screen's ready line is not shader=compiled $(counts)"
AMPLIFY_READY_MS=0 plugin; kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null; cp "$RUN/plugin.log" "$RUN/early.log"
screens "$RUN/early.log" ready | sed 's/^/before the first frame: /'; screens "$RUN/early.log" rendered | sed 's/^/after it: /'
all2 "$RUN/early.log" ready "shader=pending .* pending=[1-9]" && pass "before the first frame both screens report shader=pending" \
  || fail "a ready line logged before the first frame is not shader=pending"
all2 "$RUN/early.log" rendered "shader=compiled $(counts)$" && pass "once drawn both screens report shader=compiled ($(counts))" \
  || fail "no rendered line reading shader=compiled $(counts) on both screens"
AMPLIFY_READY_MS=0 plugin "$RUN/broken-river/plugin"; kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null; cp "$RUN/plugin.log" "$RUN/early-broken.log"
screens "$RUN/early-broken.log" ready | sed 's/^/broken river before the first frame: /'
all2 "$RUN/early-broken.log" ready "shader=error " && pass "a broken river reports shader=error before the first frame" \
  || fail "a broken river reads other than shader=error before the first frame"
# One capture (task 844a60aa): the shipped plugin's orbs, river and basin each log the snapshot
# they replay (data/mandrel.js replaySource) and, traced, each caption they draw. All must name
# one capture, every caption its captured time, and the river's time must read as its last change.
ORBS_FIXTURE= plugin; kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null; cp "$RUN/plugin.log" "$RUN/one.log"
srcs=$(grep -aoE "amplify: replay (orbs|river|basin) .*" "$RUN/one.log" | sort -u)
caps=$(grep -aoE "amplify: caption (orbs|river) .*" "$RUN/one.log")
sed 's/^/  /' <<< "$srcs"; sort -u <<< "$caps" | head -4 | sed 's/^/  /'
want=$(sed -E 's/.* captured ([^ ]+) .*/\1/; s/\.000Z$/Z/' <<< "$srcs" | sort -u)
[[ $(awk '{ print $3 }' <<< "$srcs" | sort -u | tr '\n' ' ') == "basin orbs river " && $(sed -E 's/^amplify: replay [a-z]+ //' <<< "$srcs" | sort -u | grep -c .) == 1 \
   && $(awk '{ print $3 }' <<< "$caps" | sort -u | tr '\n' ' ') == "orbs river " && $(grep -oE "captured [^ ]+" <<< "$caps" | sort -u) == "captured $want" \
   && -n $(grep "  ·  changed " <<< "$caps") && -z $(grep -E "^amplify: caption river .*  ·  [0-9]" <<< "$caps") ]] \
  && pass "one capture: orbs, river and basin replay the same snapshot, every caption reads captured $want, the river's time reads 'changed'" \
  || fail "components or captions disagree on the capture (want one replay source and 'captured ${want:-?}' in every caption, river time as 'changed')"
cat "$RUN/two.log" "$RUN/early.log" "$RUN/early-broken.log" "$RUN/one.log" >> "$RUN/plugin-main.log"
mv "$RUN/plugin-main.log" "$RUN/plugin.log"

# Idle CPU on a model of Brian's desktop (task 8b5eca2f): three outputs (1920x1080,
# 1920x1080, 2560x1440), the whole plugin animated (orbs, river and basin on every screen,
# six windows), replaying the shipped capture with nothing changing: the river frozen at flow 0
# (04:30Z), the orbs' client clock from 04:38:18Z, capture + 38 min (one lost orb turning, its
# lease draining in 42 s steps, the last at 04:38:16Z, so none falls in the window; the rest
# dormant), basin rows from the amp capture. After 6 s to settle, over 10 s: Quickshell
# under 2 % of one core (decision 25eced40); no amplify window swaps a frame; each
# amplify-orbs window swaps under one frame a second, the lost orb's turn (AMPLIFY_FPS=1
# logs each window's swapped frames every 5 s). On llvmpipe one frame of these windows
# costs about 20 ms of CPU, so this budget leaves no room for a clock that runs on its own.
# Then two more runs on the same outputs (task 118f6917):
#  - the river replay running (not frozen) at flow 0 with nothing changing, from 22:00Z
#    (no river change until 00:28Z, 148 s of replay), orbs idle as above: over 30 s no
#    amplify window swaps a single frame (a once-a-second caption or clock would);
#  - live orbs spinning (the orbs' replay from its capture, river frozen at flow 0): over
#    20 s (client time about 7-27 s, with a live coord and two forming workers whose leases
#    step, so eases run in it) each amplify-orbs
#    window draws no more than its clock: at most 8.6 steps/s
#    (125 ms), at most 9 frames/s in any 5 s, and at most one frame a second more than
#    the steps it logged, so nothing (a tween on Qt's animation driver) draws between steps.
swaymsg output HEADLESS-1 resolution 1920x1080 position 0 0 > /dev/null
swaymsg output HEADLESS-2 resolution 1920x1080 position 1920 0 > /dev/null
swaymsg create_output > /dev/null; shot_wait 10 "a third output" outputs 3
swaymsg output HEADLESS-3 resolution 2560x1440 position 3840 0 > /dev/null
# fpsrun <log> <seconds> <env...>: the plugin animated with AMPLIFY_FPS=1 on these outputs; after
# 6 s to settle, samples Quickshell's CPU over <seconds>, then prints its percent of one core
# and, one per line, "<window> <screen> <fps> <steps/s or ->" logged inside that span.
fpsrun() {
  local log=$1 secs=$2; shift 2
  env AMPLIFY_FPS=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" AMPLIFY_AMP_FIXTURE="$ROOT/data/amp/fixtures/top-capture.jsonl" "$@" \
    quickshell -p "$ROOT/plugin" > "$log" 2>&1 & QS=$!; PIDS+=($QS)
  readyin() { grep -aq "amplify: ready" "$1"; }
  shot_wait 30 "the plugin's ready line" readyin "$log"
  # Settle window (6 s from the ready line), then the measurement window (<seconds>): both
  # are part of the check (the live-orbs span is placed on the replay's eases), not waits.
  sleep 6
  local clk c0 c1 l0; clk=$(getconf CLK_TCK) c0=$(awk '{ print $14 + $15 }' "/proc/$QS/stat") l0=$(wc -l < "$log")
  sleep "$secs"
  c1=$(awk '{ print $14 + $15 }' "/proc/$QS/stat"); kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null
  awk -v t=$((c1 - c0)) -v k="$clk" -v s="$secs" 'BEGIN { printf "%.1f\n", t / k / s * 100 }'
  tail -n +"$((l0 + 1))" "$log" | grep -aoE "amplify: fps window=[a-z-]* screen=[A-Z0-9-]* [0-9.]*( steps=[0-9.]*)?" \
    | sed 's/amplify: fps window=//; s/ screen=/ /; s/ steps=/ /' | awk '{ print $1, $2, $3, ($4 == "" ? "-" : $4) }'
}
# showfps <name> <fps lines>: each window's 5 s rates (frames/s, or frames/s/steps/s).
showfps() { awk -v n="$1" '{ v[$1 " " $2] = v[$1 " " $2] " " $3 ($4 == "-" ? "" : "/" $4) } END { for (k in v) print "  " n " fps " k ":" v[k] }' <<< "$2" | sort; }
# screens3 <window> <fps lines>: true when all three screens logged that window.
screens3() { (( $(awk -v w="$1" '$1 == w { s[$2] = 1 } END { print length(s) }' <<< "$2") == 3 )); }
qmlerr() { grep -acE "TypeError|ReferenceError|is not defined|Unable to assign|binding loop" "$1"; }

out=$(fpsrun "$RUN/idle.log" 10 AMPLIFY_RIVER_AT=2026-11-22T04:30:00Z AMPLIFY_ORBS_FROM=2026-11-22T04:38:18Z)
pct=$(head -1 <<< "$out") fps=$(tail -n +2 <<< "$out")
sizes=$(grep -ao "amplify: ready .* size=[0-9x]*" "$RUN/idle.log" | sed 's/.*screen=//' | sort | tr '\n' ' ')
echo "idle: screens $sizes"
idlerr=$(qmlerr "$RUN/idle.log")
[[ $sizes == "HEADLESS-1 size=1920x1080 HEADLESS-2 size=1920x1080 HEADLESS-3 size=2560x1440 " ]] && awk -v p="$pct" 'BEGIN { exit !(p <= 2) }' && (( idlerr == 0 )) \
  && pass "idle: three outputs, orbs + river + basin animated, Quickshell at $pct % of one core (budget 2 %)" \
  || fail "idle: Quickshell at $pct % of one core over 10 s on three outputs (budget 2 %; screens: $sizes; $idlerr QML errors)"
showfps idle "$fps"
worst=$(awk '$1 == "amplify" && $3 > m { m = $3 } END { print m + 0 }' <<< "$fps")
screens3 amplify "$fps" && awk -v m="$worst" 'BEGIN { exit !(m <= 0.2) }' \
  && pass "idle: no river/basin window redraws at flow 0 with nothing changing (worst $worst fps on 3 screens)" \
  || fail "idle: a river/basin window keeps drawing with nothing changing (worst $worst fps; all 3 screens logged: $(screens3 amplify "$fps" && echo yes || echo no))"
worst=$(awk '$1 == "amplify-orbs" && $3 > m { m = $3 } END { print m + 0 }' <<< "$fps")
screens3 amplify-orbs "$fps" && awk -v m="$worst" 'BEGIN { exit !(m < 1) }' \
  && pass "idle: each orbs window draws only as its lost orb turns (worst $worst fps on 3 screens, under 1)" \
  || fail "idle: an orbs window draws faster than its records move (worst $worst fps; all 3 screens logged: $(screens3 amplify-orbs "$fps" && echo yes || echo no))"

out=$(fpsrun "$RUN/idle-river.log" 30 AMPLIFY_RIVER_FROM=2026-11-21T22:00:00Z AMPLIFY_ORBS_FROM=2026-11-22T04:38:18Z)
fps=$(tail -n +2 <<< "$out"); showfps "river running" "$fps"
frames=$(awk '$1 == "amplify" { f += $3 * 5 } END { printf "%d", f + 0.5 }' <<< "$fps")
rerr=$(qmlerr "$RUN/idle-river.log")
screens3 amplify "$fps" && (( frames == 0 && rerr == 0 )) \
  && pass "idle, river replay running at flow 0: no river/basin window swaps a frame in 30 s (3 screens)" \
  || fail "idle, river replay running at flow 0: river/basin windows swapped $frames frames in 30 s with nothing changing (all 3 screens logged: $(screens3 amplify "$fps" && echo yes || echo no); $rerr QML errors)"

out=$(fpsrun "$RUN/live-orbs.log" 20 AMPLIFY_RIVER_AT=2026-11-22T04:30:00Z)
pct=$(head -1 <<< "$out") fps=$(tail -n +2 <<< "$out"); showfps "live orbs" "$fps"
echo "  live orbs: Quickshell at $pct % of one core"
# Per 5 s line: frames/s over 9, steps/s over 8.6, or frames/s over steps/s + 1 (when logged).
over=$(awk '$1 == "amplify-orbs" && ($3 > 9 || ($4 != "-" && ($4 > 8.6 || $3 > $4 + 1))) { print $2 " " $3 ($4 == "-" ? "" : " fps, " $4 " steps/s") }' <<< "$fps" | head -3 | tr '\n' ';')
spun=$(awk '$1 == "amplify-orbs" && ($4 == "-" || $4 >= 1) { n++ } END { print n + 0 }' <<< "$fps")
lerr=$(qmlerr "$RUN/live-orbs.log")
screens3 amplify-orbs "$fps" && [[ -z $over ]] && (( spun > 0 && lerr == 0 )) \
  && pass "live orbs spinning: each orbs window draws within its clock (<= 9 fps, <= 8.6 steps/s, <= steps + 1; 3 screens)" \
  || fail "live orbs spinning: an orbs window draws above its clock (${over:-none over}; spinning lines $spun; all 3 screens logged: $(screens3 amplify-orbs "$fps" && echo yes || echo no); $lerr QML errors)"
for f in idle idle-river live-orbs; do
  grep -aE "TypeError|ReferenceError|is not defined|Unable to assign|binding loop" "$RUN/$f.log" | head -3 | sed "s/^/  $f: /"
  grep -av "amplify: fps" "$RUN/$f.log" >> "$RUN/plugin.log"
done

grep -ah "amplify:\|harness:\|WARN\|ERROR" "$RUN/plugin.log" "$RUN/harness.log" | grep -v "amplify: trace" | sed 's/^/  /'
# A blank capture (nothing rendered) has no spread; a real one has wallpaper, water and orbs.
# lit <png>: prints the capture's spread and is true when it is not blank. The guard is the
# only check that keeps a black capture out of docs/spike, so it is first run on a uniform
# frame, which it must flag (N1).
lit() { local sd; sd=$(magick "$1" -format "%[fx:int(1000*standard_deviation)]" info: 2>/dev/null || echo 0); echo "$sd"; (( sd > 10 )); }
magick -size 64x64 xc:'#101418' "$RUN/uniform.png"
sd=$(lit "$RUN/uniform.png") && fail "blank-capture guard passes a uniform frame (stddev $sd/1000)" \
  || pass "blank-capture guard flags a uniform frame (stddev $sd/1000)"
for f in headless headless-uncovered; do
  sd=$(lit "$RUN/$f.png") && pass "$f.png is not blank (stddev $sd/1000)" || fail "$f.png is blank or missing (stddev $sd/1000)"
done

if (( fails == 0 )); then
  cp "$RUN/headless.png" "$RUN/headless-uncovered.png" "$OUT/"
  echo "headless-shot: 0 failed checks; wrote docs/spike/headless.png docs/spike/headless-uncovered.png"
else
  echo "headless-shot: $fails failed check(s); docs/spike screenshots left unchanged"
fi
exit "$fails"
