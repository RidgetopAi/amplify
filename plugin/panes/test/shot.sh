#!/usr/bin/env bash
# Render the panes (task bc45ee1d) headless and write docs/shots/:
#   plugin/panes/test/shot.sh           # panes-switch.png (sheet + idle budget), then panes.png (service)
#   plugin/panes/test/shot.sh sheet     # only the sheet
#   plugin/panes/test/shot.sh service   # only the whole plugin
# sheet: plugin/panes/test/shell.qml, the replayed capture with the real project list: no records
#   (every field null), closed, and the switcher open. Then the idle budget: the feeds hand the
#   panes new but equal rows every second, and the sheet must swap no frame 3 to 9 s after the draw.
# service: the whole plugin (quickshell -p plugin/) at 1920x1080, as installed: the panes'
#   model line in the log, no QML errors, and the capture.
# Same stack as plugin/orbs/test/shot.sh: sway (headless, pixman), quickshell, grim, and
# Mesa llvmpipe through HEADLESS_MESA when there is no GPU.
# Exit status is the number of failed checks.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/docs/shots"
mkdir -p "$OUT"
"$ROOT/tools/build-shaders.sh" >/dev/null || { echo "shot: shader build failed" >&2; exit 1; }

RUN="$(mktemp -d)"
PIDS=()
SHEET="$ROOT/.panes-sheet-$$.qml"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/panes-shot-logs.XXXXXX")"
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

fails=0
ERRS="TypeError|ReferenceError|is not defined|Unable to assign|binding loop|Cannot|ERROR"
compositor() {   # compositor <w> <h>: (re)start sway at that size
  shot_reap; PIDS=()
  printf 'output HEADLESS-1 resolution %sx%s position 0 0\ndefault_border none\n' "$1" "$2" > "$RUN/sway.cfg"
  sway -c "$RUN/sway.cfg" > "$RUN/sway-$1.log" 2>&1 & PIDS+=($!)
  swayup() { ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1; }
  shot_wait 10 "sway's socket" swayup || return 1
  export WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")" QT_QPA_PLATFORM=wayland
}

sheet() {
  compositor 2000 760 || return 1
  cp "$ROOT/plugin/panes/test/shell.qml" "$SHEET"
  quickshell -p "$SHEET" > "$RUN/sheet.log" 2>&1 & local qs=$! bad=0
  drawn() { grep -q "amplify: sheet drawn" "$RUN/sheet.log"; }
  shot_wait 30 "the panes sheet's first frame with its data" drawn || bad=1
  if grim "$OUT/panes-switch.png"; then echo "shot: wrote docs/shots/panes-switch.png"; else bad=1; fi
  # Measurement window: the idle budget counts the frames 3 to 9 s after the first draw.
  sleep 9.5
  local t0 n; t0=$(grep -ao "amplify: sheet drawn panes [0-9]*" "$RUN/sheet.log" | grep -o "[0-9]*$")
  n=$(grep -ao "amplify: sheet frame [0-9]*" "$RUN/sheet.log" | grep -o "[0-9]*$" \
      | awk -v t="${t0:-0}" '$1 >= t + 3000 && $1 <= t + 9000' | wc -l)
  if [[ -n $t0 && $n == 0 ]]; then echo "shot: idle budget: 0 frames 3-9 s after the draw while the feeds re-sent equal data each second"
  else echo "shot: idle budget: $n frames 3-9 s after the draw (want 0)"; bad=1; fi
  if grep -E "$ERRS" "$RUN/sheet.log"; then echo "shot: sheet logged errors (above)"; bad=1; fi
  shot_stop "$qs"
  # Full titles: the newest context, decision and task at the capture, read from the raw
  # snapshot here, are drawn whole (not cut, not elided) in the closed panes.
  local kind want got
  for kind in context decision task; do
    want=$(node -e '
      const s = require(process.argv[1]), at = Date.parse(s.meta.captured_at), k = process.argv[2];
      const r = s.responses["/api/" + k + "s"][k + "s"].filter((x) => Date.parse(x.created_at) <= at)
        .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))[0];
      console.log(String(k === "context" ? r.content : r.title).split("\n")[0])' "$ROOT/fixtures/amplify-snapshot.json" "$kind")
    got=$(grep -a "amplify: panes@sheet1 title $kind " "$RUN/sheet.log" | tail -1 | sed "s/^.*amplify: panes@sheet1 title $kind //")
    if [[ $got == "truncated=false $want" ]]; then echo "shot: $kind title drawn whole: $want"
    else echo "shot: $kind title drawn as \"$got\", want \"truncated=false $want\""; bad=1; fi
  done
  return $bad
}

service() {
  compositor 1920 1080 || return 1
  AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" AMPLIFY_AMP_FIXTURE="$ROOT/data/amp/fixtures/top-capture.jsonl" \
    quickshell -p "$ROOT/plugin" > "$RUN/service.log" 2>&1 & local qs=$! bad=0
  readyin() { grep -q "amplify: ready" "$RUN/service.log" && grep -q "amplify: panes@" "$RUN/service.log"; }
  shot_wait 30 "the plugin's ready line and the panes' model line" readyin || bad=1
  # Settle window: the basin rows' 1.4 s glide-in and the pool's 1.6 s fill.
  sleep 3
  if grim "$OUT/panes.png"; then echo "shot: wrote docs/shots/panes.png"; else bad=1; fi
  grep -a "amplify: panes@" "$RUN/service.log" | tail -1 | sed "s/^.*amplify: /shot: /"
  if grep -E "$ERRS" "$RUN/service.log" | grep -v "^qt.qpa"; then echo "shot: service logged errors (above)"; bad=1; fi
  shot_stop "$qs"
  return $bad
}

for part in ${1:-sheet service}; do "$part" || fails=$((fails + 1)); done
exit "$fails"
