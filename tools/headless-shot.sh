#!/usr/bin/env bash
# Render the Amplify plugin under a headless Wayland compositor and check it.
#
#   tools/headless-shot.sh   # writes docs/spike/headless.png, headless-uncovered.png and orb.png
#
# Steps: rebuild the .qsb from shaders/, start sway with the headless backend
# and pixman renderer, start the harness (wallpaper on the Background layer and
# an app window over the right half), start `quickshell -p plugin/` with
# AMPLIFY_TRACE=1 so the data-driven orbs (plugin/orbs, replayed snapshot) log
# where they are drawn, screenshot with grim, then assert:
#   1. the plugin reports layer=bottom and shader=compiled (every orb, river and
#      basin program), and reports shader=error when a program is broken;
#   2. the uncovered orbs' centres are lit and accent-tinted, and nothing is
#      drawn where the P0 placeholder orb was (0.28W, 0.5H);
#   3. a covered orb's centre shows the app window, so the layer sits below windows;
#   4. a click on an orb opens its record, a click on empty desktop passes
#      through the masks to the wallpaper layer, and with the app window moved
#      away a click on a basin row opens its record.
# Exit status is the number of failed checks (0 = all passed).
#
# Needs: sway, grim, wayvnc, vncdo (vncdotool), quickshell, qsb, ImageMagick (magick). With no GPU, point
# Mesa at a software driver, e.g. HEADLESS_MESA=/nix/store/...-mesa-<ver>.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/spike"
W=1280 H=720
mkdir -p "$OUT"

# 1. Shaders are always rebuilt here so a stale .qsb cannot pass the check.
rm -f "$ROOT"/plugin/shaders/*.qsb
"$ROOT/tools/build-shaders.sh" || echo "headless-shot: shader build failed" >&2

RUN="$(mktemp -d)"
cleanup() { kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$RUN"; }
PIDS=()
trap cleanup EXIT

export XDG_RUNTIME_DIR="$RUN" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
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
for _ in $(seq 50); do ls "$RUN"/wayland-* >/dev/null 2>&1 && ls "$RUN"/sway-ipc.* >/dev/null 2>&1 && break; sleep 0.1; done
export WAYLAND_DISPLAY="$(basename "$(ls "$RUN"/wayland-? | head -1)")"
export SWAYSOCK="$(ls "$RUN"/sway-ipc.* | head -1)"
export QT_QPA_PLATFORM=wayland

quickshell -p "$ROOT/tools/harness" > "$RUN/harness.log" 2>&1 & PIDS+=($!)
sleep 2
# plugin [dir]: start the plugin (default plugin/), still and traced, and wait for its ready line.
plugin() {
  AMPLIFY_STILL=1 AMPLIFY_TRACE=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" \
    quickshell -p "${1:-$ROOT/plugin}" > "$RUN/plugin.log" 2>&1 & QS=$!; PIDS+=($QS)
  for _ in $(seq 100); do grep -aq "amplify: ready" "$RUN/plugin.log" && break; sleep 0.1; done
  sleep 1
}
plugin

grim "$OUT/headless.png"

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
pixel() { magick "$OUT/headless.png" -format "%[fx:int(255*p{$1,$2}.r)] %[fx:int(255*p{$1,$2}.g)] %[fx:int(255*p{$1,$2}.b)]" info:; }

ready=$(grep -a "amplify: ready" "$RUN/plugin.log" | head -1)
echo "log: ${ready#*qml: }"
[[ $ready == *"layer=bottom"* ]] && pass "layer is bottom" || fail "layer is not bottom"
[[ $ready == *"shader=compiled"* ]] && pass "every shader compiled from .qsb" || fail "shader not compiled"

# The orbs from the trace: "<id8> <x> <y> <light>" of every opaque orb, left to
# right, as last drawn (still mode: they hold). Uncovered: the live ones (full
# light) clear of the app window (x >= W/2); covered: any under it.
orbs=$(awk '$4 == "trace" && $5 == "orbs" && $6 == "orb" && ($8 == "x" || $8 == "y" || $8 == "opacity" || $8 == "light") { v[$7, $8] = $9; id[$7] = 1 }
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

# Close-up of the rightmost uncovered live orb (the click target).
read -r OID OX OY <<< "$(tail -1 <<< "$uncovered")"
grim -g "$(( OX - 90 )),$(( OY - 90 )) 180x180" "$OUT/orb.png"

# The headless backend has no input devices. wayvnc holds one virtual pointer
# for the whole session (one-shot tools such as wlrctl add and remove a device
# per call, which races the client binding wl_pointer), and vncdo drives it.
wayvnc 127.0.0.1 5959 > "$RUN/wayvnc.log" 2>&1 & PIDS+=($!)
sleep 1
timeout 20 vncdo -s 127.0.0.1::5959 move "$OX" "$OY" pause 0.3 click 1 pause 0.3 \
  move "$((W / 2 - 40))" "$((H - 60))" pause 0.3 click 1 pause 0.5
grep -aq "amplify: orb open http" "$RUN/plugin.log" && pass "click on orb $OID opens its record ($(grep -ao "amplify: orb open .*" "$RUN/plugin.log" | head -1))" \
  || fail "click on orb $OID lost"
grep -q "harness: wallpaper click" "$RUN/harness.log" && pass "click on empty desktop passes through the mask" \
  || fail "empty-desktop click swallowed by the Amplify layer"

# The basin sits under the app window (lower right); move the window away, then
# click the basin's last row (Service.qml: right 28, bottom 30; rows 64 px high).
swaymsg '[title="amplify-cover"] move scratchpad' > /dev/null
sleep 0.5
grim "$OUT/headless-uncovered.png"
timeout 20 vncdo -s 127.0.0.1::5959 move "$((W - 28 - 250))" "$((H - 30 - 32))" pause 0.3 click 1 pause 0.5
grep -aq "amplify: basin open http" "$RUN/plugin.log" && pass "click on a basin row opens its record" || fail "basin click lost"

# A broken program must turn the ready line to shader=error: the same plugin with one
# orb program truncated (a copy; plugin/ links into data/).
kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null; cp "$RUN/plugin.log" "$RUN/plugin-main.log"
mkdir "$RUN/broken"; cp -a "$ROOT/plugin" "$ROOT/data" "$RUN/broken/"
head -c 64 "$ROOT/plugin/shaders/orb_worker.frag.qsb" > "$RUN/broken/plugin/shaders/orb_worker.frag.qsb"
plugin "$RUN/broken/plugin"
bready=$(grep -a "amplify: ready" "$RUN/plugin.log" | head -1)
echo "broken log: ${bready#*qml: }" | cut -c1-200
[[ $bready == *"shader=error"* ]] && pass "a broken orb program reports shader=error" || fail "ready line hides a broken shader"
cat "$RUN/plugin.log" >> "$RUN/plugin-main.log"; mv "$RUN/plugin-main.log" "$RUN/plugin.log"

grep -ah "amplify:\|harness:\|WARN\|ERROR" "$RUN/plugin.log" "$RUN/harness.log" | grep -v "amplify: trace" | sed 's/^/  /'
echo "headless-shot: $fails failed check(s); wrote docs/spike/headless.png docs/spike/headless-uncovered.png docs/spike/orb.png"
exit "$fails"
