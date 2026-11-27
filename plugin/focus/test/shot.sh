#!/usr/bin/env bash
# Render the focused-orb proof shots headless (task 85ff482a) and check the idle budget:
#   plugin/focus/test/shot.sh            # docs/shots/meridian.png, meridian-loupe.png, then idle
#   plugin/focus/test/shot.sh focus|loupe|idle
# focus: the coord orb of the shipped capture flown to the centre, newest record under the loupe.
# loupe: then a hand throw, coast and detent onto an older plaque.
# lease: data-core, which holds a claim: the lit arc east of now (meridian-lease.png, not committed).
# idle:  the whole plugin (Service.qml) with AMPLIFY_FPS=1, held at 04:38:18Z (river at flow 0):
#        an orb click (vncdo) focuses it, and once settled the focus window swaps no frame in a
#        whole 5 s window (0 fps).
# Same stack as plugin/orbs/test/shot.sh: sway (headless, pixman), quickshell, grim, wayvnc,
# vncdo, and Mesa llvmpipe through HEADLESS_MESA when there is no GPU.
# Exit status is the number of sheets or checks that failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/docs/shots"
W=1600 H=900
mkdir -p "$OUT"
"$ROOT/tools/build-shaders.sh" >/dev/null || { echo "shot: shader build failed" >&2; exit 1; }

RUN="$(mktemp -d)"
PIDS=()
SHEET="$ROOT/.focus-sheet-$$.qml"
. "$ROOT/tools/shot-reap.sh"; shot_tag "$RUN"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/focus-shot-logs.XXXXXX")"
cleanup() { [[ $BASHPID == "$$" ]] || return; kill "${PIDS[@]}" 2>/dev/null; shot_reap; wait 2>/dev/null; cp "$RUN"/*.log "$LOGS/" 2>/dev/null && echo "shot: logs in $LOGS"; rm -rf "$RUN" "$SHEET"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# env-read: SHOT_RUNTIME_DIR overrides the runtime dir (tools/mutate.sh gives each gate it runs its own).
export XDG_RUNTIME_DIR="${SHOT_RUNTIME_DIR:-$RUN}" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
export QSG_USE_SIMPLE_ANIMATION_DRIVER=1
unset WAYLAND_DISPLAY DISPLAY SWAYSOCK
# env-read: HEADLESS_MESA selects a Mesa install for llvmpipe when there is no /dev/dri.
if [[ -n ${HEADLESS_MESA:-} ]]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="$HEADLESS_MESA/share/glvnd/egl_vendor.d/50_mesa.json"
  export LIBGL_DRIVERS_PATH="$HEADLESS_MESA/lib/dri" GBM_BACKENDS_PATH="$HEADLESS_MESA/lib/gbm"
fi
printf 'output HEADLESS-1 resolution %sx%s position 0 0\ndefault_border none\n' "$W" "$H" > "$RUN/sway.cfg"
sway -c "$RUN/sway.cfg" > "$RUN/sway.log" 2>&1 & PIDS+=($!)
swayup() { ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1; }
shot_wait 10 "sway's socket" swayup || exit 1
export WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")" QT_QPA_PLATFORM=wayland
cp "$ROOT/plugin/focus/test/shell.qml" "$SHEET"
errors() { grep -E "TypeError|ReferenceError|is not defined|Unable to assign|binding loop|Error" "$1" | grep -v "^.*amplify:"; }

sheet() {
  local s=$1 log="$RUN/$1.log" n
  AMPLIFY_FOCUS_SHEET=$s quickshell -p "$SHEET" > "$log" 2>&1 & local qs=$!
  # Settled once (landed); loupe: settled again after the throw.
  [[ $s == loupe ]] && n=2 || n=1
  done_() { (( $(grep -ac "amplify: focus settled" "$log") >= n )); }
  local bad=0
  shot_wait 40 "the $s sheet to settle" done_ || bad=1
  # One frame after the settled line has been asked for and drawn: grim reads the last swapped buffer.
  sleep 0.5
  if grim "$OUT/meridian${s/focus/}.png" 2>/dev/null; then :; fi
  [[ $s != focus ]] && mv "$OUT/meridian$s.png" "$OUT/meridian-$s.png"
  echo "shot: $s: $(grep -a "amplify: focus" "$log" | sed 's/.*amplify: /  /' | tr '\n' ';')"
  if errors "$log"; then echo "shot: $s logged errors (above)"; bad=1; fi
  shot_stop "$qs"
  return $bad
}

idle() {
  local log="$RUN/idle.log" bad=0
  # Held at the idle model's moment (tools/headless-shot.sh check 6): the river at flow 0, so
  # no other window animates. At the capture itself (04:00:17Z) the river flows on its 4/s water
  # clock (task aa5e593d) and the settled focus window still draws 0 fps (measured).
  AMPLIFY_SCENE_AT=2026-11-22T04:38:18Z AMPLIFY_FPS=1 AMPLIFY_TRACE=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" \
    quickshell -p "$ROOT/plugin" > "$log" 2>&1 & local qs=$!
  readyin() { grep -aq "amplify: ready" "$log"; }
  shot_wait 30 "the plugin's ready line" readyin || { shot_stop "$qs"; return 1; }
  wayvnc -u "$RUN/vnc.sock" > "$RUN/wayvnc.log" 2>&1 & PIDS+=($!)
  vncup() { timeout 5 vncdo -s "$RUN/vnc.sock" pause 0 >/dev/null 2>&1; }
  shot_wait 20 "wayvnc" vncup || { shot_stop "$qs"; return 1; }
  # The coord orb's centre, from its trace line (orbs comp, part orb, x/y).
  local ox oy
  ox=$(grep -a "amplify: trace orbs orb de463c37 x " "$log" | tail -1 | awk '{print int($9)}')
  oy=$(grep -a "amplify: trace orbs orb de463c37 y " "$log" | tail -1 | awk '{print int($9)}')
  [[ -n $ox && -n $oy ]] || { echo "shot: idle: no traced coord orb"; shot_stop "$qs"; return 1; }
  timeout 20 vncdo -s "$RUN/vnc.sock" move "$ox" "$oy" pause 0.3 click 1
  settled() { grep -aq "amplify: focus settled" "$log"; }
  shot_wait 15 "the focused orb to settle" settled || bad=1
  # Measurement window: the next whole 5 s fps window after settling (the logger's own period).
  fpsline() { grep -a "amplify: fps window=amplify-focus" "$log" | grep -q settled; }
  local before; before=$(grep -ac "amplify: fps window=amplify-focus" "$log")
  morelines() { (( $(grep -ac "amplify: fps window=amplify-focus" "$log") >= before + 2 )); }
  shot_wait 12 "two fps windows after settling" morelines || bad=1
  local last; last=$(grep -a "amplify: fps window=amplify-focus" "$log" | tail -1)
  echo "shot: idle: ${last#*amplify: }"
  [[ $last == *" 0.0 settled"* ]] && echo "shot: idle: focused and settled, the focus window draws 0 fps" \
    || { echo "shot: idle: the settled focus window still draws"; bad=1; }
  grep -a "amplify: trace focus globe" "$log" | tail -3 | sed 's/^.*amplify: /  /'
  if errors "$log"; then echo "shot: idle logged errors (above)"; bad=1; fi
  shot_stop "$qs"
  return $bad
}

fails=0
for s in ${1:-focus loupe lease idle}; do
  if [[ $s == idle ]]; then idle || fails=$((fails + 1)); else sheet "$s" || fails=$((fails + 1)); fi
done
echo "shot: $fails failed"
exit "$fails"
