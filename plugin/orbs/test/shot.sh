#!/usr/bin/env bash
# Render the desktop-orb proof sheets headless and write docs/shots/:
#   plugin/orbs/test/shot.sh            # orbs-roles.png, orbs-states.png, then the layer check
#   plugin/orbs/test/shot.sh states     # one sheet
#   plugin/orbs/test/shot.sh layer      # only the layer check
#   plugin/orbs/test/shot.sh motion     # only the motion checks
# The motion check runs the whole plugin with AMPLIFY_TRACE=1 (plugin/motion/Trace.qml),
# animated for 10 s and then with AMPLIFY_STILL=1, and checks the trace of every
# orb, beam, basin pool and row against docs/motion.json with
# tools/motion/follow.mjs (scenarios service and service-still): material tweens
# start at the old value and reach the record's, spins turn at the liveness rate,
# basin rows glide in and the first halo holds steady; in still mode nothing moves
# between data steps.
# The layer check runs the real plugin (Service.qml mounts OrbsLayer) with
# AMPLIFY_STILL=1 and fails when quickshell warns "Unable to assign" from
# plugin/orbs, or when the orbs move: of three 0.5 s windows, one at least must be still,
# as only the 1 Hz data tick may change the picture (critic defect 11cd84cc, D1).
# Same stack as tools/headless-shot.sh: sway (headless, pixman), quickshell,
# grim, and Mesa llvmpipe through HEADLESS_MESA when there is no GPU.
# Exit status is the number of sheets or checks that failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/docs/shots"
W=1600 H=900
mkdir -p "$OUT"
"$ROOT/tools/build-shaders.sh" >/dev/null || { echo "shot: shader build failed" >&2; exit 1; }

RUN="$(mktemp -d)"
PIDS=()
# Per run, so parallel runs neither share a sheet nor overwrite each other's kept logs.
SHEET="$ROOT/.orbs-sheet-$$.qml"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/orbs-shot-logs.XXXXXX")"
. "$ROOT/tools/shot-reap.sh"; shot_tag "$RUN"
# Only this shell cleans up: a launch TERMed before its exec runs these traps in the forked
# child (task 859896c9), which would tear down this run's compositor and run dir mid-run.
cleanup() {
  [[ $BASHPID == "$$" ]] || return
  kill "${PIDS[@]}" 2>/dev/null; shot_reap; wait 2>/dev/null
  cp "$RUN"/*.log "$LOGS/" 2>/dev/null && echo "shot: logs in $LOGS"; rm -rf "$RUN" "$SHEET"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# env-read: SHOT_RUNTIME_DIR overrides the runtime dir (tools/mutate.sh gives each gate it runs its own).
export XDG_RUNTIME_DIR="${SHOT_RUNTIME_DIR:-$RUN}" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
# Animations on wall-clock time. Qt's default (vsync) driver advances one frame interval
# per frame however late it is drawn, so on llvmpipe with 2 vCPUs a 1.2 s tween ran up to
# 2.2 s and failed its 2 s settle limit (orbs.orb.sat, basin.pool.opacity); with this they
# settle in 1.25-1.33 s and 1.42-1.44 s. The limits are unchanged (task 5afeee5f).
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

# Quickshell resolves imports only inside the shell file's folder, so the sheet runs from the repo root.
cp "$ROOT/plugin/orbs/test/shell.qml" "$SHEET"
orbs_warnings() { grep -E "Unable to assign" "$1" | grep -E "plugin/orbs|(Orb[A-Za-z]*|Beam)\.qml"; }

motion_check() {
  local bad=0 sc secs still
  for sc in service service-still; do
    [[ $sc == service ]] && { secs=10; still=0; } || { secs=8; still=1; }
    AMPLIFY_STILL=$still AMPLIFY_TRACE=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" \
      AMPLIFY_AMP_FIXTURE="$ROOT/data/amp/fixtures/top-capture.jsonl" \
      quickshell -p "$ROOT/plugin" > "$RUN/motion-$sc.log" 2>&1 & local qs=$!
    # Measurement window: the trace the follow check reads (from launch; its want floors count on it).
    sleep "$secs"; shot_stop "$qs"
    local out; out=$(node "$ROOT/tools/motion/follow.mjs" "$sc" "$RUN/motion-$sc.log")
    report_motion "$sc" "$out" $? || bad=1
    if grep -E "TypeError|ReferenceError|is not defined|Unable to assign|binding loop" "$RUN/motion-$sc.log"; then
      echo "shot: motion $sc logged errors (above)"; bad=1; fi
  done
  # orbs-decay: the orbs sheet animated, its client clock jumping +20 min at 3 s.
  AMPLIFY_ORBS_SHEET=motion AMPLIFY_TRACE=1 quickshell -p "$SHEET" > "$RUN/motion-decay.log" 2>&1 & local qs=$!
  # Measurement window: the clock jumps at 3 s, and the longest ease (1.6 s) settles well within 8 s.
  sleep 8; shot_stop "$qs"
  out=$(node "$ROOT/tools/motion/follow.mjs" orbs-decay "$RUN/motion-decay.log")
  report_motion orbs-decay "$out" $? || bad=1
  if grep -E "TypeError|ReferenceError|is not defined|Unable to assign|binding loop" "$RUN/motion-decay.log"; then
    echo "shot: motion orbs-decay logged errors (above)"; bad=1; fi
  return $bad
}
report_motion() {
  if [[ $3 == 0 ]]; then echo "shot: motion $1: $(echo "$2" | grep -c "^ok") follow checks pass"; return 0; fi
  echo "$2" | grep "^BAD" | head -20 | sed "s/^/  /"; echo "shot: motion $1: follow checks failed"; return 1
}
layer_check() {
  # The river shares the layer since P1; the scene clock holds the replay at the capture
  # (task 679fbbc5), so nothing steps the data under still mode.
  AMPLIFY_STILL=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" \
    quickshell -p "$ROOT/plugin" > "$RUN/layer.log" 2>&1 & local qs=$! bad=0
  # The ready line follows every window's first frame (it reads compiled only then). The
  # captures are taken only once it is in the log, checked again after the wait (task
  # 859896c9): captures of a plugin still loading show no orbs and pass trivially.
  readyin() { grep -q "amplify: ready" "$1"; }
  shot_wait 30 "the plugin's ready line" readyin "$RUN/layer.log"
  if ! readyin "$RUN/layer.log"; then
    echo "shot: layer plugin not ready, no captures taken"; shot_stop "$qs"; return 1
  fi
  # Measurement window: four captures 0.5 s apart. Still mode may change the picture at a
  # data step (1 Hz: the shipped capture's forming orb steps its form, about 900 px), so the
  # check takes the quietest of the three 0.5 s windows: a step once a second dirties at most
  # two of them, motion between steps (the defect, 11cd84cc D1) all three. A single pair was
  # phase-locked to the data tick (the ready line comes 1.5 s after load) and failed about
  # one run in two once the orbs replayed the shipped capture (task 87f71d95).
  local k moved=() m
  for k in 0 1 2 3; do (( k )) && sleep 0.5; grim "$RUN/still-$k.png"; done
  for k in 1 2 3; do
    m=$(magick compare -metric AE -fuzz 2% "$RUN/still-$((k - 1)).png" "$RUN/still-$k.png" null: 2>&1 | cut -d' ' -f1)
    [[ $m =~ ^[0-9.e+]+$ ]] || m=999999
    moved+=("$m")
  done
  m=$(printf '%s\n' "${moved[@]}" | sort -g | head -1)
  echo "shot: layer AMPLIFY_STILL=1, ${moved[*]} px changed in three 0.5 s windows, quietest $m (limit ${STILL_LIMIT:-200})"
  awk -v m="$m" -v l="${STILL_LIMIT:-200}" 'BEGIN { exit !(m <= l) }' \
    || { echo "shot: layer orbs move under AMPLIFY_STILL=1"; bad=1; }
  if orbs_warnings "$RUN/layer.log"; then echo "shot: layer logged binding warnings from plugin/orbs (above)"; bad=1; fi
  shot_stop "$qs"
  return $bad
}

fails=0
for sheet in ${1:-roles states layer motion}; do
  if [[ $sheet == layer ]]; then layer_check || fails=$((fails + 1)); continue; fi
  if [[ $sheet == motion ]]; then motion_check || fails=$((fails + 1)); continue; fi
  AMPLIFY_ORBS_SHEET=$sheet quickshell -p "$SHEET" > "$RUN/$sheet.log" 2>&1 & qs=$!
  drawnin() { grep -q "amplify: sheet drawn" "$1"; }
  shot_wait 30 "the $sheet sheet's first frame with its snapshot" drawnin "$RUN/$sheet.log" || fails=$((fails + 1))
  if grim "$OUT/orbs-$sheet.png"; then echo "shot: wrote docs/shots/orbs-$sheet.png"; else fails=$((fails + 1)); fi
  if grep -E "ERROR|TypeError|ReferenceError|is not|Cannot" "$RUN/$sheet.log" || orbs_warnings "$RUN/$sheet.log"; then
    echo "shot: $sheet logged errors (above)"; fails=$((fails + 1))
  fi
  shot_stop "$qs"
done
exit "$fails"
