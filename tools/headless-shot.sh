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
#      then (task f0e14f4c); and by name, each orbs program (coord, critic and worker
#      bodies, beam, vessel) compiled and changing the pixels where it draws (task 4131a23d);
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
# Only this shell cleans up: a launch TERMed before its exec runs these traps in the forked
# child (task 859896c9), which tore down this run's compositor and run dir mid-run.
cleanup() { [[ $BASHPID == "$$" ]] || return; kill "${PIDS[@]}" 2>/dev/null; shot_reap; wait 2>/dev/null; rm -rf "$RUN"; }
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
# This run's orbs programs by name, for the every-program check below (task 4131a23d).
progs=$(grep -aoE "amplify: program screen=[^ ]+ orbs .*" "$RUN/plugin.log")
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
shot_stop "$QS"; cp "$RUN/plugin.log" "$RUN/plugin-main.log"
declare -A BREAK=([orbs]="plugin/shaders/orb*.qsb" [river]="plugin/river/river.frag.qsb" [basin]="plugin/basin/*.frag.qsb")
for g in "${COMPS[@]}"; do
  B="$RUN/broken-$g"; mkdir "$B"; cp -a "$ROOT/plugin" "$B/"
  for f in $B/${BREAK[$g]}; do head -c 64 "$ROOT/${f#"$B/"}" > "$f"; done
  plugin "$B/plugin"; shot_stop "$QS"
  bready=$(grep -a "amplify: ready" "$RUN/plugin.log" | head -1)
  echo "broken $g log: ${bready#*qml: }" | cut -c1-200
  [[ $bready == *"shader=error $(counts "$g")"* ]] && pass "broken $g programs report shader=error ($(counts "$g"))" \
    || fail "ready line hides broken $g programs (want shader=error $(counts "$g"))"
  cat "$RUN/plugin.log" >> "$RUN/plugin-main.log"
done

# Every orbs program draws (task 4131a23d): the shipped capture has no critic and no beam,
# so the shipped plugin on the test fixture is the one run that draws them all. Each of its
# programs (the coord, critic and worker bodies, the beam and the vessel) must be named in
# the first run's "amplify: program" lines, compiled, with no other orbs program, and every
# effect drawing it must change the pixels at its centre: headless-uncovered.png (that run,
# the app window away) against the same scene with every orbs program broken (drawing
# nothing). A count alone (orbs=5/5) passes a program that compiles but draws nothing.
ORBS_PROGS="orb_coord orb_critic orb_worker orbbeam orbvessel"
plugin "$RUN/broken-orbs/plugin"; grim "$RUN/no-orbs.png"; shot_stop "$QS"
cat "$RUN/plugin.log" >> "$RUN/plugin-main.log"
# moved <x> <y> [n]: true when the n x n box (default 9) centred on x,y changes between the
# two captures: some pixel's summed RGB difference (0-765) is over 24; prints the largest.
moved() {
  local d n=${3:-9}; local box="${n}x$n+$(($1 - n / 2))+$(($2 - n / 2))"
  d=$(magick "$RUN/headless-uncovered.png[$box]" "$RUN/no-orbs.png[$box]" -compose difference -composite \
    -separate -evaluate-sequence add -format "%[fx:int(255*maxima)]" info:)
  echo "${d:-0}"; (( ${d:-0} > 24 ))
}
# The control: away from the orbs (where the placeholder was) the two captures agree, so a
# change at an orb is that orb's programs drawing, not a scene that moved.
d=$(moved "$((W * 28 / 100))" "$((H / 2))") && fail "the scene without orbs programs differs away from the orbs ($d at the placeholder spot)" \
  || pass "the scene without orbs programs differs only where orbs draw (placeholder spot changes by $d)"
names=$(awk '{ sub(/\.frag\.qsb$/, "", $5); print $5 }' <<< "$progs" | sort -u | tr '\n' ' ')
[[ $names == "$ORBS_PROGS " ]] && pass "the orbs draw exactly their programs: $ORBS_PROGS" \
  || fail "the orbs' programs are not exactly $ORBS_PROGS (drawn: ${names:-none})"
for p in $ORBS_PROGS; do
  row=$(grep -E " orbs $p\.frag\.qsb " <<< "$progs" | head -1) st=$(awk '{ print $6 }' <<< "$row")
  n=0 bad="" ds=""
  for c in $(sed 's/.* at //' <<< "$row"); do
    x=${c%,*} y=${c#*,}
    (( x >= 0 && x < W && y >= 0 && y < H )) || continue
    n=$((n + 1)); d=$(moved "$x" "$y") || bad+=" $c($d)"; ds+=" $d"
  done
  echo "orbs program $p: ${st:-missing}, $n on screen${row:+ at ${row#* at }}${ds:+ (centre box changes by$ds)}"
  [[ $st == compiled ]] && (( n > 0 )) && [[ -z $bad ]] && pass "orbs program $p compiles and draws ($n effects)" \
    || fail "orbs program $p does not compile and draw (${st:-not drawn}; $n on screen; drawing nothing at:${bad:- -})"
done
# Colour and shape (task 179bbd77, critic gap G1 of verdict dbb2ea97): a change at the centre
# also passes a program that draws the wrong colour or fills its whole quad. Each critic body
# must draw its calipers (orbbody.glsl ROLE 2: arcs at 1.2 radii, left and right of its centre)
# in the critic's lavender and leave the corners of its quad unchanged (0.8 of the way out on
# each diagonal, past its halo). Each beam must light its axis at its centre in its blue, and
# leave the pixels 10 px either side of the axis unchanged (its quad is 24 px high; its glow
# there is under the change threshold). Lavender and blue: lit (blue over 80), blue at least
# 1.3 times red, and not magenta (green within 30 of red).
# peak <x> <y> <w> <h>: "r g b" (0-255) of the brightest pixel of the w x h box centred on x,y
# in headless-uncovered.png (the calipers and the beam's core are a pixel or two wide).
peak() {
  magick "$RUN/headless-uncovered.png" -crop "$3x$4+$(($1 - $3 / 2))+$(($2 - $4 / 2))" +repage -depth 8 txt:- \
    | awk -F'[(),]' 'NR > 1 && $3 + $4 + $5 >= m { m = $3 + $4 + $5; p = $3 " " $4 " " $5 } END { print p }'
}
# tinted <r g b>: true when the pixel is lit blue (or lavender), not white, grey or magenta.
tinted() { local r g b; read -r r g b <<< "$1"; (( b > 80 && 10 * b >= 13 * r && g + 30 > r )); }
# The critic's radius in pixels (plugin/orbs/orbs.js layout: 39 units, a unit 1/1920 of the width or 1/1080 of the height).
CR=$(awk -v w=$W -v h=$H 'BEGIN { u = w / 1920 < h / 1080 ? w / 1920 : h / 1080; printf "%d", 39 * u + 0.5 }')
arm=$(( CR * 12 / 10 )) corner=$(( CR * 19 * 8 / 100 ))
n=0
for c in $(grep -E " orbs orb_critic\.frag\.qsb " <<< "$progs" | head -1 | sed 's/.* at //'); do
  x=${c%,*} y=${c#*,}
  (( x >= 0 && x < W && y >= 0 && y < H )) || continue
  n=$((n + 1)) bad="" info=""
  for dx in -$arm $arm; do
    t=$(peak $((x + dx)) "$y" 5 3); tinted "$t" || bad+=" caliper $((x + dx)),$y ($t)"; info+=" caliper $t;"
  done
  for dx in -$corner $corner; do for dy in -$corner $corner; do
    d=$(moved $((x + dx)) $((y + dy)) 3) && bad+=" corner $((x + dx)),$((y + dy)) changed by $d"; info+=" corner $d;"
  done; done
  echo "critic body at $c (radius $CR):$info"
  [[ -z $bad ]] && pass "critic body at $c draws lavender calipers and leaves its quad's corners alone" \
    || fail "critic body at $c draws the wrong colour or shape:$bad"
done
(( n > 0 )) || fail "no critic body on screen to check its colour"
# The beams from the trace, as drawn: "<centre x> <centre y> <cos> <sin>" of each shown beam
# (Beam.qml: x, y the start of its axis, turned by rotation about it, length long).
beams=$(awk 'sub(/.*amplify: trace /, "") && $1 == "orbs" && $2 == "beam" { v[$3, $4] = $5; id[$3] = 1 }
  END { for (i in id) if (v[i, "opacity"] > 0) { t = v[i, "rotation"] * atan2(0, -1) / 180
    printf "%.0f %.0f %.4f %.4f\n", v[i, "x"] + v[i, "length"] / 2 * cos(t), v[i, "y"] + v[i, "length"] / 2 * sin(t), cos(t), sin(t) } }' "$RUN/plugin-main.log")
n=0
while read -r x y co si; do
  [[ -n $x ]] && (( x >= 0 && x < W && y >= 0 && y < H )) || continue
  n=$((n + 1)) bad=""
  t=$(peak "$x" "$y" 3 3); tinted "$t" || bad+=" axis $x,$y ($t)"
  info="axis $t;"
  for s in -1 1; do
    read -r px py <<< "$(awk -v x="$x" -v y="$y" -v s="$s" -v c="$co" -v k="$si" 'BEGIN { printf "%.0f %.0f", x - s * 10 * k, y + s * 10 * c }')"
    d=$(moved "$px" "$py" 1) && bad+=" off-axis $px,$py changed by $d"; info+=" off-axis $px,$py $d;"
  done
  echo "beam at $x,$y: $info"
  [[ -z $bad ]] && pass "beam at $x,$y draws a blue line along its axis, not its whole quad" \
    || fail "beam at $x,$y draws the wrong colour or shape:$bad"
done <<< "$beams"
(( n > 0 )) || fail "no beam on screen to check its colour"

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
plugin; shot_stop "$QS"; cp "$RUN/plugin.log" "$RUN/two.log"
screens "$RUN/two.log" ready | sed 's/^/two screens: /'
all2 "$RUN/two.log" ready "shader=compiled $(counts)$" && pass "both screens report shader=compiled ($(counts))" \
  || fail "a second screen's ready line is not shader=compiled $(counts)"
AMPLIFY_READY_MS=0 plugin; shot_stop "$QS"; cp "$RUN/plugin.log" "$RUN/early.log"
screens "$RUN/early.log" ready | sed 's/^/before the first frame: /'; screens "$RUN/early.log" rendered | sed 's/^/after it: /'
all2 "$RUN/early.log" ready "shader=pending .* pending=[1-9]" && pass "before the first frame both screens report shader=pending" \
  || fail "a ready line logged before the first frame is not shader=pending"
all2 "$RUN/early.log" rendered "shader=compiled $(counts)$" && pass "once drawn both screens report shader=compiled ($(counts))" \
  || fail "no rendered line reading shader=compiled $(counts) on both screens"
AMPLIFY_READY_MS=0 plugin "$RUN/broken-river/plugin"; shot_stop "$QS"; cp "$RUN/plugin.log" "$RUN/early-broken.log"
screens "$RUN/early-broken.log" ready | sed 's/^/broken river before the first frame: /'
all2 "$RUN/early-broken.log" ready "shader=error " && pass "a broken river reports shader=error before the first frame" \
  || fail "a broken river reads other than shader=error before the first frame"
# One capture on one clock (tasks 844a60aa, 679fbbc5): the shipped plugin's orbs, river and basin
# each log the snapshot they replay (data/mandrel.js replaySource) and, traced, on each of the two
# screens, the scene time they are drawn at and the clock they follow ("amplify: scene
# <comp>@<screen> at <ISO> clock <id>") and the caption they draw ("amplify: caption
# <comp>@<screen> <text>"); each scene clock logs "amplify: clock <id> made" (SceneClock.qml).
# Read per component per screen, the last line of each: all must replay one capture, the
# service must make one clock and every component on every screen must follow it (a river
# left on its own clock holds at the same capture, so equal times alone pass it: defect
# a5d1ffa7), be drawn at one moment, the capture (replay holds there), and draw one caption
# (Mandrel.sceneCaption) naming that moment: "REPLAYED SNAPSHOT · <label> · as of <moment> ·
# last activity <time>", to the minute.
ORBS_FIXTURE= plugin; shot_stop "$QS"; cp "$RUN/plugin.log" "$RUN/one.log"
srcs=$(grep -aoE "amplify: replay (orbs|river|basin) .*" "$RUN/one.log" | sort -u)
clocks=$(grep -aoE "amplify: clock [^ ]+ made .*" "$RUN/one.log" | awk '{ print $3 }' | sort -u)
# latest <what>: "<comp>@<screen><TAB><value>" of each key's last "amplify: <what> <comp>@<screen> <value>" line.
latest() { grep -aoE "amplify: $1 (orbs|river|basin)(@[^ ]+)? .*" "$RUN/one.log" | sed -E "s/^amplify: $1 //" \
  | awk '{ i = index($0, " "); v[substr($0, 1, i - 1)] = substr($0, i + 1) } END { for (c in v) print c "\t" v[c] }' | sort; }
moments=$(latest scene) caps=$(latest caption)
sed 's/^/  /' <<< "$srcs"; sed 's/^/  clock made /' <<< "$clocks"; sed 's/^/  scene /' <<< "$moments"; sed 's/^/  caption /' <<< "$caps"
want=$(sed -E 's/.* captured ([^ ]+) .*/\1/' <<< "$srcs" | sort -u)
wantmin="$(date -u -d "$want" +'%Y-%m-%d %H:%M' 2>/dev/null)Z"
# Every component on every screen sway lists: "basin@HEADLESS-1 basin@HEADLESS-2 orbs@… river@… ".
keys=$(for c in basin orbs river; do swaymsg -t get_outputs | grep -oE '"name": "HEADLESS-[0-9]+"' | cut -d'"' -f4 | sed "s/^/$c@/"; done | sort | tr '\n' ' ')
comps() { cut -f1 <<< "$1" | tr '\n' ' '; }
[[ $(awk '{ print $3 }' <<< "$srcs" | sort -u | tr '\n' ' ') == "basin orbs river " && $(sed -E 's/^amplify: replay [a-z]+ //' <<< "$srcs" | sort -u | grep -c .) == 1 ]] \
  && pass "one capture: orbs, river and basin replay one snapshot ($want)" \
  || fail "orbs, river and basin do not replay one snapshot (sources: $(cut -d' ' -f3- <<< "$srcs" | tr '\n' ';'))"
[[ $(grep -c . <<< "$clocks") == 1 && $(comps "$moments") == "$keys" \
   && $(sed -E 's/.* clock //' <<< "$moments" | sort -u) == "$clocks" ]] \
  && pass "one clock: the service makes one scene clock ($clocks) and $keys each follow it" \
  || fail "not one clock: $(grep -c . <<< "$clocks") made (${clocks//$'\n'/ }), followed by: $(awk -F'\t' '{ sub(/.* clock /, "", $2); printf "%s=%s ", $1, $2 }' <<< "$moments")(want every one of $keys on one)"
[[ $(comps "$moments") == "$keys" && $(cut -f2 <<< "$moments" | sed -E 's/ clock .*//' | sort -u) == "at $want" \
   && $(comps "$caps") == "$keys" && $(cut -f2 <<< "$caps" | sort -u | grep -c .) == 1 \
   && $(cut -f2 <<< "$caps" | head -1) =~ ^REPLAYED\ SNAPSHOT\ ·\ .+\ ·\ as\ of\ $wantmin\ ·\ last\ activity\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}Z$ ]] \
  && pass "one moment: $keys are drawn at the capture $want and draw one caption (as of $wantmin)" \
  || fail "components or screens disagree on the moment or caption (want $keys each at ${want:-?}, one caption 'REPLAYED SNAPSHOT · … · as of $wantmin · last activity …')"
cat "$RUN/two.log" "$RUN/early.log" "$RUN/early-broken.log" "$RUN/one.log" >> "$RUN/plugin-main.log"
mv "$RUN/plugin-main.log" "$RUN/plugin.log"

# Idle CPU on a model of Brian's desktop (task 8b5eca2f): three outputs (1920x1080,
# 1920x1080, 2560x1440), the whole plugin animated (orbs, river and basin on every screen,
# six windows), replaying the shipped capture with nothing changing: the one scene clock held at
# 04:38:18Z, capture + 38 min (AMPLIFY_SCENE_AT: the river at flow 0, one lost orb turning, its
# lease held, the rest dormant), basin rows from the amp capture. After 6 s to settle, over 10 s: Quickshell
# under 2 % of one core (decision 25eced40); no amplify window swaps a frame; each
# amplify-orbs window swaps under one frame a second, the lost orb's turn (AMPLIFY_FPS=1
# logs each window's swapped frames every 5 s). On llvmpipe one frame of these windows
# costs about 20 ms of CPU, so this budget leaves no room for a clock that runs on its own.
# Then two more runs on the same outputs (task 118f6917):
#  - the same held scene over 30 s: no amplify window swaps a single frame (a once-a-second
#    caption or clock would; task 679fbbc5: the replayed scene clock never steps);
#  - the shipped default (task aa5e593d): no AMPLIFY_SCENE_AT, the scene held at the capture
#    04:00:17Z, whose last activity (03:52Z) keeps the river flowing (flow > 0) for as long as
#    it is held. Over 10 s each amplify window steps its water clock (River.qml waterClock) at
#    most 4.2 times a second, at least once (the water flows), and over the span swaps at most
#    1.5 frames a step + 0.5 a second + 2 (one frame a step; under a loaded catalogue run some
#    windows swap about 1.35 a step, as the orbs windows do; a layer over the water swaps 2 a
#    step), so no frame clock draws every vsync (on Brian's desktop that was 11 % of a core;
#    on llvmpipe a frame costs about 140 ms of CPU, so Quickshell's CPU is logged here and the
#    2 % budget is asserted on the flow-0 run above);
#  - live orbs spinning (the scene clock held at the capture: a live coord and two forming
#    workers) over 20 s, each amplify-orbs
#    window draws no more than its clock: at most 8.6 steps/s
#    (125 ms), at most 9 frames/s in any 5 s, and over the whole span no more frames than
#    the steps it logged, plus one a second for the scene's once-a-second data tick
#    (unloaded, every line reads frames = steps + 1/s) and 2 at the span's edges, so nothing
#    (a tween on Qt's animation driver) draws between steps. Judged over the span, not per
#    5 s line (task 85e35a5d): a step's frame swaps a little after it, so under load one
#    lands in the next line (5.0 fps over 3.8 steps/s), which the span's sum cancels; only
#    its start can take one from before (a pending step and tick swap as one frame), and the
#    span (measured, the lines' ms) can hold one more tick than whole seconds. A tween
#    between steps draws tens of frames over the bound.
swaymsg output HEADLESS-1 resolution 1920x1080 position 0 0 > /dev/null
swaymsg output HEADLESS-2 resolution 1920x1080 position 1920 0 > /dev/null
swaymsg create_output > /dev/null; shot_wait 10 "a third output" outputs 3
swaymsg output HEADLESS-3 resolution 2560x1440 position 3840 0 > /dev/null
# fpsrun <log> <seconds> <env...>: the plugin animated with AMPLIFY_FPS=1 on these outputs; after
# 6 s to settle, samples Quickshell's CPU over <seconds>, then prints its percent of one core
# and, one per line, "<window> <screen> <fps> <steps/s or -> <window ms or ->" logged inside that span.
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
  c1=$(awk '{ print $14 + $15 }' "/proc/$QS/stat"); shot_stop "$QS"
  awk -v t=$((c1 - c0)) -v k="$clk" -v s="$secs" 'BEGIN { printf "%.1f\n", t / k / s * 100 }'
  tail -n +"$((l0 + 1))" "$log" | grep -aoE "amplify: fps window=[a-z-]* screen=[A-Z0-9-]* [0-9.]*( steps=[0-9.]* ms=[0-9]*)?" \
    | sed 's/amplify: fps window=//; s/ screen=/ /; s/ steps=/ /; s/ ms=/ /' \
    | awk '{ print $1, $2, $3, ($4 == "" ? "-" : $4), ($5 == "" ? "-" : $5) }'
}
# showfps <name> <fps lines>: each window's 5 s rates (frames/s, or frames/s/steps/s).
showfps() { awk -v n="$1" '{ v[$1 " " $2] = v[$1 " " $2] " " $3 ($4 == "-" ? "" : "/" $4) } END { for (k in v) print "  " n " fps " k ":" v[k] }' <<< "$2" | sort; }
# screens3 <window> <fps lines>: true when all three screens logged that window.
screens3() { (( $(awk -v w="$1" '$1 == w { s[$2] = 1 } END { print length(s) }' <<< "$2") == 3 )); }
qmlerr() { grep -acE "TypeError|ReferenceError|is not defined|Unable to assign|binding loop" "$1"; }

out=$(fpsrun "$RUN/idle.log" 10 AMPLIFY_SCENE_AT=2026-11-22T04:38:18Z)
pct=$(head -1 <<< "$out") fps=$(tail -n +2 <<< "$out")
sizes=$(grep -ao "amplify: ready .* size=[0-9x]*" "$RUN/idle.log" | sed 's/.*screen=//' | sort | tr '\n' ' ')
echo "idle: screens $sizes"
idlerr=$(qmlerr "$RUN/idle.log")
[[ $sizes == "HEADLESS-1 size=1920x1080 HEADLESS-2 size=1920x1080 HEADLESS-3 size=2560x1440 " ]] && awk -v p="$pct" 'BEGIN { exit !(p <= 2) }' && (( idlerr == 0 )) \
  && pass "idle: three outputs, orbs + river + basin animated, Quickshell at $pct % of one core (budget 2 %)" \
  || fail "idle: Quickshell at $pct % of one core over 10 s on three outputs (budget 2 %; screens: $sizes; $idlerr QML errors)"
showfps idle "$fps"
worst=$(awk '$1 == "amplify" && $3 > m { m = $3 } END { print m + 0 }' <<< "$fps")
# At flow 0 the water clock (River.qml waterClock) must not step at all (task aa5e593d).
wsteps=$(awk '$1 == "amplify" && ($4 == "-" || $4 > m) { m = ($4 == "-" ? 99 : $4) } END { print m + 0 }' <<< "$fps")
screens3 amplify "$fps" && awk -v m="$worst" -v w="$wsteps" 'BEGIN { exit !(m <= 0.2 && w == 0) }' \
  && pass "idle: no river/basin window redraws or steps its water at flow 0 with nothing changing (worst $worst fps, $wsteps steps/s on 3 screens)" \
  || fail "idle: a river/basin window keeps drawing or stepping its water with nothing changing (worst $worst fps, $wsteps steps/s (99: none logged); all 3 screens logged: $(screens3 amplify "$fps" && echo yes || echo no))"
worst=$(awk '$1 == "amplify-orbs" && $3 > m { m = $3 } END { print m + 0 }' <<< "$fps")
screens3 amplify-orbs "$fps" && awk -v m="$worst" 'BEGIN { exit !(m < 1) }' \
  && pass "idle: each orbs window draws only as its lost orb turns (worst $worst fps on 3 screens, under 1)" \
  || fail "idle: an orbs window draws faster than its records move (worst $worst fps; all 3 screens logged: $(screens3 amplify-orbs "$fps" && echo yes || echo no))"

out=$(fpsrun "$RUN/idle-river.log" 30 AMPLIFY_SCENE_AT=2026-11-22T04:38:18Z)
fps=$(tail -n +2 <<< "$out"); showfps "held" "$fps"
frames=$(awk '$1 == "amplify" { f += $3 * 5 } END { printf "%d", f + 0.5 }' <<< "$fps")
rerr=$(qmlerr "$RUN/idle-river.log")
screens3 amplify "$fps" && (( frames == 0 && rerr == 0 )) \
  && pass "idle, scene held at flow 0: no river/basin window swaps a frame in 30 s (3 screens)" \
  || fail "idle, scene held at flow 0: river/basin windows swapped $frames frames in 30 s with nothing changing (all 3 screens logged: $(screens3 amplify "$fps" && echo yes || echo no); $rerr QML errors)"

out=$(fpsrun "$RUN/shipped.log" 10)
pct=$(head -1 <<< "$out") fps=$(tail -n +2 <<< "$out"); showfps "shipped" "$fps"
echo "  shipped default: Quickshell at $pct % of one core"
flow=$(grep -aoE "amplify: river lanes .* flow=[0-9.]+" "$RUN/shipped.log" | tail -1 | sed -E 's/.*flow=//')
# Per 5 s amplify line: no steps or ms logged, or steps/s over 4.2 or under 0.2 (still water). Per screen
# over the span, summed as the live-orbs check does (task 85e35a5d): frames over 1.5 x steps + 0.5 a
# second (its lines' summed ms) + 2 at the span's edges.
over=$(awk '$1 == "amplify" && ($5 == "-" || $4 > 4.2 || $4 < 0.2) { print $2 " " $3 " fps" ($5 == "-" ? ", no steps or ms logged" : ", " $4 " steps/s") }' <<< "$fps"
  awk '$1 == "amplify" && $5 != "-" { f[$2] += int($3 * 5 + 0.5); s[$2] += int($4 * 5 + 0.5); ms[$2] += $5 }
       END { for (k in f) if (f[k] > 1.5 * s[k] + 0.5 * ms[k] / 1000 + 2) printf "%s %d frames over %.1f s, %d steps\n", k, f[k], ms[k] / 1000, s[k] }' <<< "$fps")
over=$(grep . <<< "$over" | head -3 | tr '\n' ';')
serr=$(qmlerr "$RUN/shipped.log")
screens3 amplify "$fps" && [[ -z $over ]] && awk -v f="${flow:-0}" 'BEGIN { exit !(f > 0) }' && (( serr == 0 )) \
  && pass "shipped default: the held capture flows (flow $flow) and each river/basin window draws on its water clock (<= 4.2 steps/s; over the span <= 1.5 x steps + 0.5/s + 2 frames; 3 screens; Quickshell $pct %)" \
  || fail "shipped default: a river/basin window draws off its water clock or the water is still (flow ${flow:-?}; ${over:-none over}; all 3 screens logged: $(screens3 amplify "$fps" && echo yes || echo no); $serr QML errors; Quickshell $pct %)"

out=$(fpsrun "$RUN/live-orbs.log" 20)
pct=$(head -1 <<< "$out") fps=$(tail -n +2 <<< "$out"); showfps "live orbs" "$fps"
echo "  live orbs: Quickshell at $pct % of one core"
# Per 5 s line: frames/s over 9 or steps/s over 8.6. Per screen over the span: frames over
# steps + 1 a second (its lines' summed ms) + 2; a line without steps or ms fails it.
over=$(awk '$1 == "amplify-orbs" && ($3 > 9 || $5 == "-" || $4 > 8.6) { print $2 " " $3 " fps" ($5 == "-" ? ", no steps or ms logged" : ", " $4 " steps/s") }' <<< "$fps"
  awk '$1 == "amplify-orbs" && $5 != "-" { f[$2] += int($3 * 5 + 0.5); s[$2] += int($4 * 5 + 0.5); ms[$2] += $5 }
       END { for (k in f) if (f[k] > s[k] + ms[k] / 1000 + 2) printf "%s %d frames over %.1f s, %d steps (bound %d)\n", k, f[k], ms[k] / 1000, s[k], s[k] + ms[k] / 1000 + 2 }' <<< "$fps")
over=$(grep . <<< "$over" | head -3 | tr '\n' ';')
span=$(awk '$1 == "amplify-orbs" { f[$2] += int($3 * 5 + 0.5); s[$2] += int($4 * 5 + 0.5); ms[$2] += $5 }
            END { for (k in f) printf "%s %d frames/%d steps/%.1f s; ", k, f[k], s[k], ms[k] / 1000 }' <<< "$fps")
echo "  live orbs span: $span"
spun=$(awk '$1 == "amplify-orbs" && ($4 == "-" || $4 >= 1) { n++ } END { print n + 0 }' <<< "$fps")
lerr=$(qmlerr "$RUN/live-orbs.log")
screens3 amplify-orbs "$fps" && [[ -z $over ]] && (( spun > 0 && lerr == 0 )) \
  && pass "live orbs spinning: each orbs window draws within its clock (<= 9 fps, <= 8.6 steps/s; over the span <= steps + 1/s + 2; 3 screens)" \
  || fail "live orbs spinning: an orbs window draws above its clock (${over:-none over}; spinning lines $spun; all 3 screens logged: $(screens3 amplify-orbs "$fps" && echo yes || echo no); $lerr QML errors)"
for f in idle idle-river shipped live-orbs; do
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
