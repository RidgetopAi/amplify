#!/usr/bin/env bash
# Render the desktop-orb proof sheets headless and write docs/shots/:
#   plugin/orbs/test/shot.sh            # orbs-roles.png and orbs-states.png
#   plugin/orbs/test/shot.sh states     # one sheet
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
fails=0
for sheet in ${1:-roles states}; do
  AMPLIFY_ORBS_SHEET=$sheet quickshell -p "$SHEET" > "$RUN/$sheet.log" 2>&1 & qs=$!
  sleep "${SHOT_WAIT:-4}"
  if grim "$OUT/orbs-$sheet.png"; then echo "shot: wrote docs/shots/orbs-$sheet.png"; else fails=$((fails + 1)); fi
  if grep -E "ERROR|TypeError|ReferenceError|is not|Cannot" "$RUN/$sheet.log"; then
    echo "shot: $sheet logged errors (above)"; fails=$((fails + 1))
  fi
  kill "$qs" 2>/dev/null; wait "$qs" 2>/dev/null
done
exit "$fails"
