#!/usr/bin/env bash
# Render the Puck proof headless and check his motion, his click and his idle budget:
#   plugin/puck/test/shot.sh           # shot, motion, click, idle, hover
#   plugin/puck/test/shot.sh shot      # docs/shots/puck.png only (any of shot motion click idle hover)
# shot:   docs/shots/puck.png (plugin/puck/test/shell.qml, AMPLIFY_PUCK_SHEET=shot).
# motion: the motion sheet traced (AMPLIFY_TRACE=1), animated and then with AMPLIFY_STILL=1,
#         checked against docs/motion.json with tools/motion/follow.mjs (scenarios puck and
#         puck-still): blinks follow the replay's newest activity, the finger rises when the
#         needs-you rows appear, the glance and smile follow the pointer and settle.
# click:  his click action runs `amp-desktop --puck` (a stub on PATH records its argv).
# idle:   the real PuckLayer alone, replaying the held capture: once settled, its window
#         swaps 0 frames a second (the 5 s windows after the first), and, traced, he never
#         blinks (the first scene is the baseline and a held replay never moves the activity).
# hover:  the same layer, with a real pointer (wayvnc's, driven by vncdo) moved onto him and
#         off again: the smile widens while it is on him and is back at rest after it leaves.
# Same stack as plugin/orbs/test/shot.sh: sway (headless, pixman), quickshell, grim, and
# Mesa llvmpipe through HEADLESS_MESA when there is no GPU; hover also needs wayvnc and vncdo
# (vncdotool), as tools/headless-shot.sh does. Exit status = failed checks.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/docs/shots"
W=1600 H=900
mkdir -p "$OUT"
"$ROOT/tools/build-shaders.sh" >/dev/null || { echo "shot: shader build failed" >&2; exit 1; }

RUN="$(mktemp -d)"
PIDS=()
SHEET="$ROOT/.puck-sheet-$$.qml"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/puck-shot-logs.XXXXXX")"
. "$ROOT/tools/shot-reap.sh"; shot_tag "$RUN"
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

cp "$ROOT/plugin/puck/test/shell.qml" "$SHEET"
errors() { grep -E "TypeError|ReferenceError|is not defined|Unable to assign|binding loop|Cannot|ERROR" "$1"; }
drawnin() { grep -q "amplify: sheet drawn" "$1"; }

shot() {
  AMPLIFY_PUCK_SHEET=shot quickshell -p "$SHEET" > "$RUN/shot.log" 2>&1 & local qs=$! bad=0
  shot_wait 60 "the shot sheet's first frame" drawnin "$RUN/shot.log" || bad=1
  # The figurine is raymarched: on llvmpipe its first frame lands a while after the sheet's.
  sleep 3
  if grim "$OUT/puck.png"; then echo "shot: wrote docs/shots/puck.png"; else bad=1; fi
  if errors "$RUN/shot.log"; then echo "shot: shot sheet logged errors (above)"; bad=1; fi
  shot_stop "$qs"
  return $bad
}

# The replay from 02:29:00Z, 10 virtual s a second: the first needs-you row (an open
# decision) appears at 02:29:2x, and the newest activity moves on at every step.
motion() {
  local bad=0 sc still secs out
  for sc in puck puck-still; do
    [[ $sc == puck ]] && { still=0; secs=9; } || { still=1; secs=6; }
    AMPLIFY_PUCK_SHEET=motion AMPLIFY_TRACE=1 AMPLIFY_STILL=$still AMPLIFY_SCENE_AT=2026-11-22T02:29:00Z AMPLIFY_SCENE_STEP=10 \
      quickshell -p "$SHEET" > "$RUN/motion-$sc.log" 2>&1 & local qs=$!
    # Measurement window: the pointer comes at 4 s and leaves at 6.5 s; every spring settles by 9 s.
    sleep "$secs"; shot_stop "$qs"
    out=$(node "$ROOT/tools/motion/follow.mjs" "$sc" "$RUN/motion-$sc.log"); local rc=$?
    if (( rc )); then echo "$out" | grep "^BAD" | head -20 | sed "s/^/  /"; echo "shot: motion $sc: follow checks failed"; bad=1
    else echo "shot: motion $sc: $(echo "$out" | grep -c "^ok") follow checks pass"; fi
    if errors "$RUN/motion-$sc.log"; then echo "shot: motion $sc logged errors (above)"; bad=1; fi
  done
  return $bad
}

click() {
  mkdir -p "$RUN/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0 $*" > "%s/ran.txt"\n' "$RUN" > "$RUN/bin/amp-desktop"
  chmod +x "$RUN/bin/amp-desktop"
  PATH="$RUN/bin:$PATH" AMPLIFY_PUCK_SHEET=click quickshell -p "$SHEET" > "$RUN/click.log" 2>&1 & local qs=$! bad=0
  ran() { [[ -s $RUN/ran.txt ]]; }
  shot_wait 30 "the stub amp-desktop to run" ran || bad=1
  if [[ $(cat "$RUN/ran.txt" 2>/dev/null) == "$RUN/bin/amp-desktop --puck" ]]; then echo "shot: click ran amp-desktop --puck"
  else echo "shot: click did not run amp-desktop --puck (got: $(cat "$RUN/ran.txt" 2>/dev/null))"; bad=1; fi
  grep -q "amplify: puck run amp-desktop --puck" "$RUN/click.log" || { echo "shot: click logged no run line"; bad=1; }
  shot_stop "$qs"
  return $bad
}

idle() {
  # The real PuckLayer alone (the sheet's idle mode), replaying the held capture: the whole
  # plugin would not do, since the river's water clock makes every Amplify window draw
  # while it runs (one render loop), whatever Puck does.
  AMPLIFY_PUCK_SHEET=idle AMPLIFY_TRACE=1 quickshell -p "$SHEET" > "$RUN/idle.log" 2>&1 & local qs=$! bad=0
  # Measurement window: three 5 s fps windows; the first includes his first frames.
  three() { (( $(grep -c "fps window=amplify-puck" "$1") >= 3 )); }
  shot_wait 30 "three amplify-puck fps lines" three "$RUN/idle.log" || bad=1
  local rates; rates=$(grep -o "fps window=amplify-puck [^ ]* [0-9.]*" "$RUN/idle.log" | awk '{ print $NF }' | tr '\n' ' ')
  echo "shot: idle amplify-puck fps per 5 s window: $rates"
  [[ $(echo "$rates" | awk '{ print $2, $3 }') == "0.0 0.0" ]] || { echo "shot: idle Puck draws frames with the data unchanged"; bad=1; }
  grep -q "amplify: trace puck lid desk@" "$RUN/idle.log" || { echo "shot: idle Puck logged no lid trace"; bad=1; }
  if grep -qE "amplify: trace puck lid desk@[^ ]+ lid:on 1\.0" "$RUN/idle.log"; then echo "shot: idle Puck blinked on the held replay"; bad=1
  else echo "shot: idle Puck never blinked on the held replay"; fi
  if errors "$RUN/idle.log"; then echo "shot: idle logged errors (above)"; bad=1; fi
  shot_stop "$qs"
  return $bad
}

hover() {
  AMPLIFY_PUCK_SHEET=idle AMPLIFY_TRACE=1 quickshell -p "$SHEET" > "$RUN/hover.log" 2>&1 & local qs=$! bad=0
  traced() { grep -q "amplify: trace puck mouth desk@" "$1"; }
  shot_wait 30 "the layer's first trace" traced "$RUN/hover.log" || bad=1
  # The headless backend has no input devices: wayvnc holds a virtual pointer on a socket in
  # this run's dir, and vncdo drives it (tools/headless-shot.sh).
  local vnc="$RUN/vnc.sock" size cx cy vpid
  wayvnc -u "$vnc" > "$RUN/wayvnc.log" 2>&1 & vpid=$!; PIDS+=($vpid)
  vncup() { timeout 5 vncdo -s "$vnc" pause 0 >/dev/null 2>&1; }
  shot_wait 20 "wayvnc on $vnc" vncup || bad=1
  # His centre (PuckLayer: lower left, puck.js DESK_LEFT / DESK_BOTTOM, deskSize).
  read -r size cx cy <<< "$(node -e 'const P = require(process.argv[1]); const s = P.deskSize(+process.argv[2], +process.argv[3]);
    console.log(s, P.DESK_LEFT + (s >> 1), +process.argv[3] - P.DESK_BOTTOM - (s >> 1))' "$ROOT/plugin/puck/test/load.cjs" "$W" "$H")"
  # Pacing and settle windows: 1.5 s on him, then 1.5 s off (the 280 ms mouth tween ends well within).
  timeout 20 vncdo -s "$vnc" move "$cx" "$cy" pause 1.5 move "$((W / 2))" "$((H / 3))" pause 1.5 || bad=1
  local to; to=$(grep -oE "amplify: trace puck mouth desk@[^ ]+ bend:to [0-9.-]+" "$RUN/hover.log" | awk '{ print $NF }' | tr '\n' ' ')
  echo "shot: hover mouth bend:to over time: $to"
  if [[ " $to" == *" 1.900000 "* ]]; then echo "shot: hover the pointer on him widens the smile"; else echo "shot: hover the pointer on him did not reach Puck"; bad=1; fi
  if [[ $(echo "$to" | awk '{ print $NF }') == 0.700000 ]]; then echo "shot: hover the smile is back at rest after the pointer leaves"
  else echo "shot: hover the pointer left and Puck still acts hovered"; bad=1; fi
  if errors "$RUN/hover.log"; then echo "shot: hover logged errors (above)"; bad=1; fi
  shot_stop "$vpid"; shot_stop "$qs"
  return $bad
}

fails=0
(( $# )) || set -- shot motion click idle hover
for step in "$@"; do
  "$step" || fails=$((fails + 1))
done
exit "$fails"
