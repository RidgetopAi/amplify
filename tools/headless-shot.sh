#!/usr/bin/env bash
# Render the Amplify plugin under a headless Wayland compositor and check it.
#
#   tools/headless-shot.sh            # writes docs/spike/headless.png and docs/spike/orb.png
#
# Steps: rebuild the .qsb from shaders/, start sway with the headless backend
# and pixman renderer, start the harness (wallpaper on the Background layer and
# an app window over the right half), start `quickshell -p plugin/`, screenshot
# with grim, then assert:
#   1. the plugin reports layer=bottom and a compiled shader;
#   2. the left (uncovered) orb's centre is lit and accent-tinted;
#   3. the right orb's centre shows the app window, so the layer sits below windows;
#   4. a click on an orb reaches the orb, and a click on empty desktop passes
#      through the mask to the wallpaper layer.
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
AMPLIFY_STILL=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" \
  quickshell -p "$ROOT/plugin" > "$RUN/plugin.log" 2>&1 & PIDS+=($!)
for _ in $(seq 100); do grep -q "amplify: ready" "$RUN/plugin.log" && break; sleep 0.1; done
sleep 1

grim "$OUT/headless.png"
# Focus orb geometry mirrors Service.qml: centre (0.28W, 0.5H), size 0.42*min(W,H).
S=$(( H * 42 / 100 )); FX=$(( W * 28 / 100 )); RX=$(( W * 75 / 100 )); CY=$(( H / 2 ))
grim -g "$(( FX - S / 2 )),$(( CY - S / 2 )) ${S}x${S}" "$OUT/orb.png"

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
pixel() { magick "$OUT/headless.png" -format "%[fx:int(255*p{$1,$2}.r)] %[fx:int(255*p{$1,$2}.g)] %[fx:int(255*p{$1,$2}.b)]" info:; }

ready=$(grep "amplify: ready" "$RUN/plugin.log" | head -1)
echo "log: ${ready#*qml: }"
[[ $ready == *"layer=bottom"* ]] && pass "layer is bottom" || fail "layer is not bottom"
[[ $ready == *"shader=compiled"* ]] && pass "shader compiled from .qsb" || fail "shader not compiled"

read -r r g b <<< "$(pixel "$((FX - S / 8))" "$((CY - S / 8))")"
echo "focus orb pixel: $r $g $b"
(( b > 120 && b > r )) && pass "uncovered orb renders (accent-lit)" || fail "uncovered orb not rendered"

read -r r g b <<< "$(pixel "$RX" "$((CY - 60))")"
echo "covered orb pixel: $r $g $b (app window is 232 227 216)"
(( r > 220 && g > 215 && b > 205 && b < 225 )) && pass "app window covers the orb (layer below windows)" \
  || fail "orb drawn over the app window"

# The headless backend has no input devices. wayvnc holds one virtual pointer
# for the whole session (one-shot tools such as wlrctl add and remove a device
# per call, which races the client binding wl_pointer), and vncdo drives it.
wayvnc 127.0.0.1 5959 > "$RUN/wayvnc.log" 2>&1 & PIDS+=($!)
sleep 1
timeout 20 vncdo -s 127.0.0.1::5959 move "$FX" "$CY" pause 0.3 click 1 pause 0.3 \
  move "$((W / 2 - 40))" "$((H - 60))" pause 0.3 click 1 pause 0.5
grep -q "amplify: orb click meridian" "$RUN/plugin.log" && pass "click on orb reaches the orb" || fail "click on orb lost"
grep -q "harness: wallpaper click" "$RUN/harness.log" && pass "click on empty desktop passes through the mask" \
  || fail "empty-desktop click swallowed by the Amplify layer"

grep -h "amplify:\|harness:\|WARN\|ERROR" "$RUN/plugin.log" "$RUN/harness.log" | sed 's/^/  /'
echo "headless-shot: $fails failed check(s); wrote docs/spike/headless.png docs/spike/orb.png"
exit "$fails"
