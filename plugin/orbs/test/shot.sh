#!/usr/bin/env bash
# Render the desktop-orb proof sheets headless and write docs/shots/:
#   plugin/orbs/test/shot.sh            # orbs-roles.png, orbs-states.png, then the layer check
#   plugin/orbs/test/shot.sh states     # one sheet
#   plugin/orbs/test/shot.sh layer      # only the layer check
# The layer check runs the real plugin (Service.qml mounts OrbsLayer) with
# AMPLIFY_STILL=1 and fails when quickshell warns "Unable to assign" from
# plugin/orbs, or when the orbs move: two captures 0.5 s apart may differ only
# by the 1 Hz data tick (critic defect 11cd84cc, D1).
# Same stack as tools/headless-shot.sh: sway (headless, pixman), quickshell,
# grim, and Mesa llvmpipe through HEADLESS_MESA when there is no GPU.
# Exit status is the number of sheets that failed to render.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/docs/shots"
W=1600 H=900
mkdir -p "$OUT"
"$ROOT/tools/build-shaders.sh" >/dev/null || { echo "shot: shader build failed" >&2; exit 1; }

RUN="$(mktemp -d)"
PIDS=()
SHEET="$ROOT/.orbs-sheet.qml"
cleanup() { kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; cp "$RUN"/*.log /tmp/ 2>/dev/null; rm -rf "$RUN" "$SHEET"; }
trap cleanup EXIT

export XDG_RUNTIME_DIR="$RUN" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY DISPLAY SWAYSOCK
# env-read: HEADLESS_MESA selects a Mesa install for llvmpipe when there is no /dev/dri.
if [[ -n ${HEADLESS_MESA:-} ]]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="$HEADLESS_MESA/share/glvnd/egl_vendor.d/50_mesa.json"
  export LIBGL_DRIVERS_PATH="$HEADLESS_MESA/lib/dri" GBM_BACKENDS_PATH="$HEADLESS_MESA/lib/gbm"
fi
printf 'output HEADLESS-1 resolution %sx%s position 0 0\ndefault_border none\n' "$W" "$H" > "$RUN/sway.cfg"
sway -c "$RUN/sway.cfg" > "$RUN/sway.log" 2>&1 & PIDS+=($!)
for _ in $(seq 50); do ls "$RUN"/wayland-* >/dev/null 2>&1 && break; sleep 0.1; done
export WAYLAND_DISPLAY="$(basename "$(ls "$RUN"/wayland-? | head -1)")" QT_QPA_PLATFORM=wayland

# Quickshell resolves imports only inside the shell file's folder, so the sheet runs from the repo root.
cp "$ROOT/plugin/orbs/test/shell.qml" "$SHEET"
orbs_warnings() { grep -E "Unable to assign" "$1" | grep -E "plugin/orbs|(Orb[A-Za-z]*|Beam)\.qml"; }

layer_check() {
  AMPLIFY_STILL=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" \
    quickshell -p "$ROOT/plugin" > "$RUN/layer.log" 2>&1 & local qs=$! bad=0
  for _ in $(seq 100); do grep -q "amplify: ready" "$RUN/layer.log" && break; sleep 0.1; done
  sleep "${SHOT_WAIT:-4}"
  grim "$RUN/still-a.png"; sleep 0.5; grim "$RUN/still-b.png"
  local moved
  moved=$(magick compare -metric AE -fuzz 2% "$RUN/still-a.png" "$RUN/still-b.png" null: 2>&1 | cut -d' ' -f1)
  echo "shot: layer AMPLIFY_STILL=1, $moved px changed in 0.5 s (limit ${STILL_LIMIT:-200})"
  [[ $moved =~ ^[0-9.e+]+$ ]] && awk -v m="$moved" -v l="${STILL_LIMIT:-200}" 'BEGIN { exit !(m <= l) }' \
    || { echo "shot: layer orbs move under AMPLIFY_STILL=1"; bad=1; }
  if orbs_warnings "$RUN/layer.log"; then echo "shot: layer logged binding warnings from plugin/orbs (above)"; bad=1; fi
  grep -q "amplify: ready" "$RUN/layer.log" || { echo "shot: layer plugin never reported ready"; bad=1; }
  kill "$qs" 2>/dev/null; wait "$qs" 2>/dev/null
  return $bad
}

fails=0
for sheet in ${1:-roles states layer}; do
  if [[ $sheet == layer ]]; then layer_check || fails=$((fails + 1)); continue; fi
  AMPLIFY_ORBS_SHEET=$sheet quickshell -p "$SHEET" > "$RUN/$sheet.log" 2>&1 & qs=$!
  sleep "${SHOT_WAIT:-4}"
  if grim "$OUT/orbs-$sheet.png"; then echo "shot: wrote docs/shots/orbs-$sheet.png"; else fails=$((fails + 1)); fi
  if grep -E "ERROR|TypeError|ReferenceError|is not|Cannot" "$RUN/$sheet.log" || orbs_warnings "$RUN/$sheet.log"; then
    echo "shot: $sheet logged errors (above)"; fails=$((fails + 1))
  fi
  kill "$qs" 2>/dev/null; wait "$qs" 2>/dev/null
done
exit "$fails"
