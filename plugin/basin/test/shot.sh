#!/usr/bin/env bash
# Layout check for the basin cards and the ambient field's foot (task 205c319c), on one
# 1920x1080 screen with the whole plugin (panes mounted), as on Brian's desktop:
#   1. two needs-you items (the replay), then three (plus an Amp thread awaiting input):
#      every card's text (label, title, meta) lies inside its own card, each card starts
#      below the one above it, and no title is cut (a long one wraps to two lines);
#      from AMPLIFY_TRACE=1 "amplify: basin card" lines (Basin.qml);
#   2. music paused, then playing (stub cava and MPRIS, as plugin/ambient/test/shot.sh):
#      the strip under the field where the orbs' scene caption is drawn stays dark (its
#      blue cast under 10, as the bare wallpaper), while the field above it is lit;
#      and the field stops short of the basin's column (task 32f5427b): no music light
#      behind the lower card (its blue cast below 0; warm card on dark, lit it reads ~+15);
#   3. the panes' stat notes ("TASKS IN FLIGHT" and the others, task 32f5427b) are drawn
#      whole: not elided, wrapped when wider than the tile, inside the tile; from the
#      "amplify: panes@<screen> note" lines (Panes.qml);
#   4. no QML errors.
# Shots go to docs/shots/basin-cards.png and docs/shots/ambient-caption.png only when
# every check passed. Exit status = number of failed checks.
# Needs: sway, grim, quickshell, ImageMagick (magick); HEADLESS_MESA without a GPU.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
W=1920 H=1080
RUN="$(mktemp -d)"
PIDS=()
. "$ROOT/tools/shot-reap.sh"; shot_tag "$RUN"
cleanup() { [[ $BASHPID == "$$" ]] || return; kill "${PIDS[@]}" 2>/dev/null; shot_reap; wait 2>/dev/null; rm -rf "$RUN"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# env-read: SHOT_RUNTIME_DIR overrides the runtime dir (tools/mutate.sh gives each gate its own).
export XDG_RUNTIME_DIR="${SHOT_RUNTIME_DIR:-$RUN}" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE
# env-read: HEADLESS_MESA selects a Mesa install for llvmpipe when there is no /dev/dri.
if [[ -n ${HEADLESS_MESA:-} ]]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="$HEADLESS_MESA/share/glvnd/egl_vendor.d/50_mesa.json"
  export LIBGL_DRIVERS_PATH="$HEADLESS_MESA/lib/dri" GBM_BACKENDS_PATH="$HEADLESS_MESA/lib/gbm"
fi
echo "output HEADLESS-1 resolution ${W}x${H} position 0 0" > "$RUN/sway.cfg"
sway -c "$RUN/sway.cfg" > "$RUN/sway.log" 2>&1 & PIDS+=($!)
swayup() { ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 && ls "$XDG_RUNTIME_DIR"/sway-ipc.* >/dev/null 2>&1; }
shot_wait 10 "sway's sockets" swayup || exit 1
export WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")"
export SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* | head -1)" QT_QPA_PLATFORM=wayland

export AMBIENT_STUB_DIR="$RUN/stub"; mkdir -p "$AMBIENT_STUB_DIR"
MPRIS="$RUN/mpris"
qmlerr() { grep -acE "TypeError|ReferenceError|is not defined|Unable to assign|binding loop" "$1"; }
# cards <log>: the last layout line of each card: "<index> <y> <height> <text top> <text bottom> <title lines> <truncated> <key>".
cards() { grep -a "amplify: basin card " "$1" | sed 's/.*amplify: basin card [^ ]* //' \
  | awk '{ k = $1; $1 = ""; last[k] = substr($0, 2) " " k } END { for (k in last) print last[k] }' | sort -n; }
ncards() { (( $(cards "$1" | awk '$3 > 0' | wc -l) >= $2 )); }
# start <log> <cards> <env...>: the whole plugin, traced, until its ready line and <cards> cards are laid out.
start() {
  local log=$1 n=$2; shift 2
  : > "$log"
  env AMPLIFY_TRACE=1 AMPLIFY_THEME_DIR="$ROOT/tools/harness/theme" AMPLIFY_MPRIS_FIXTURE="$MPRIS" \
    AMPLIFY_CAVA_BIN="$ROOT/plugin/ambient/test/cava-stub.sh" "$@" \
    quickshell -p "$ROOT/plugin" > "$log" 2>&1 & QS=$!; PIDS+=($QS)
  readyl() { grep -aq "amplify: ready " "$1"; }
  shot_wait 30 "the ready line" readyl "$log" || return 1
  shot_wait 15 "$n laid-out basin cards" ncards "$log" "$n" || return 1
  sleep 3   # settle window: rows glide in over 1.4 s when animated, and text lays out
}
# layout <name> <log> <want>: check the cards' layout.
layout() {
  local name=$1 c bad
  c=$(cards "$2")
  echo "$name cards (index y height textTop textBottom titleLines truncated key):"; sed 's/^/  /' <<< "$c"
  (( $(wc -l <<< "$c") == $3 )) && pass "$name: $3 cards laid out" || fail "$name: $(wc -l <<< "$c") cards laid out (want $3)"
  bad=$(awk '$4 < $2 || $5 > $2 + $3 { print $8 }' <<< "$c")
  [[ -z $bad ]] && pass "$name: every card's label, title and meta lie inside the card" || fail "$name: text spills out of its card: $bad"
  bad=$(awk 'NR > 1 && $2 < py + ph { print $8 } { py = $2; ph = $3 }' <<< "$c")
  [[ -z $bad ]] && pass "$name: each card starts below the one above it" || fail "$name: cards overlap: $bad"
  bad=$(awk '$7 != 0 { print $8 }' <<< "$c")
  [[ -z $bad ]] && pass "$name: no title is cut" || fail "$name: titles cut: $bad"
}
# strip <png>: "<blue cast of the caption strip> <blue cast of the field above it>": mean(b - r) x 255.
strip() {
  local a b
  a=$(magick "$1" -crop 900x22+200+$((H - 36)) +repage -format "%[fx:255*(mean.b-mean.r)]" info:)
  b=$(magick "$1" -crop 900x22+200+$((H - 72)) +repage -format "%[fx:255*(mean.b-mean.r)]" info:)
  echo "$a $b"
}
foot() {
  local name=$1 s; s=$(strip "$2")
  echo "$name: caption strip blue cast ${s% *}, field above ${s#* }"
  awk -v a="${s% *}" -v b="${s#* }" 'BEGIN { exit !(a < 10 && b > 15) }' \
    && pass "$name: the caption strip stays dark under a lit field" || fail "$name: the field runs through the caption strip (strip ${s% *}, field ${s#* })"
}

# basincol <name> <png>: the lower basin card (the basin's foot: right margin 28, bottom 30) shows no ambient light.
basincol() {
  local c; c=$(magick "$2" -crop 460x50+$((W - 500))+$((H - 80)) +repage -format "%[fx:255*(mean.b-mean.r)]" info:)
  echo "$1: lower basin card blue cast $c"
  awk -v c="$c" 'BEGIN { exit !(c < 0) }' && pass "$1: no ambient light behind the lower basin card" \
    || fail "$1: the ambient field shows behind the lower basin card (blue cast $c)"
}
# notes <name> <log>: each stat tile's last note line, "<key> <lines> <truncated> <natural width> <width> <bottom> <tile height> <text>".
notes() {
  local n bad
  n=$(grep -a "amplify: panes@[^ ]* note " "$2" | sed 's/.*amplify: panes@[^ ]* note //' \
    | awk '{ last[$1] = $0 } END { for (k in last) print last[k] }' | sort)
  echo "$1 notes (key lines truncated naturalWidth width bottom tileHeight text):"; sed 's/^/  /' <<< "$n"
  (( $(grep -c . <<< "$n") == 4 )) && pass "$1: 4 stat notes laid out" || fail "$1: $(grep -c . <<< "$n") stat notes laid out (want 4)"
  bad=$(awk '$3 != 0 || ($4 > $5 + 1 && $2 < 2) || $6 > $7 { print $1 }' <<< "$n")
  [[ -z $bad ]] && pass "$1: every stat note is whole (wrapped where wider than its tile)" || fail "$1: stat notes cut: $bad"
}

# 1. Two items, paused, still.
echo Paused > "$MPRIS"
start "$RUN/two.log" 2 AMPLIFY_STILL=1 || fail "two items: plugin did not settle"
grim "$RUN/two.png"
layout "two items" "$RUN/two.log" 2
foot "paused" "$RUN/two.png"
basincol "paused" "$RUN/two.png"
notes "two items" "$RUN/two.log"
err=$(qmlerr "$RUN/two.log"); (( err == 0 )) && pass "two items: no QML errors" || fail "two items: $err QML errors"
shot_stop "$QS"

# 2. Three items, music playing (animated: cava runs only then).
echo Playing > "$MPRIS"
start "$RUN/three.log" 3 AMPLIFY_AMP_FIXTURE="$ROOT/plugin/basin/test/top-awaiting.jsonl" || fail "three items: plugin did not settle"
grep -aq "ambient cava start" "$RUN/three.log" && pass "playing: cava started" || fail "playing: cava never started"
grim "$RUN/three.png"
layout "three items" "$RUN/three.log" 3
foot "playing" "$RUN/three.png"
basincol "playing" "$RUN/three.png"
notes "three items" "$RUN/three.log"
err=$(qmlerr "$RUN/three.log"); (( err == 0 )) && pass "three items: no QML errors" || fail "three items: $err QML errors"
shot_stop "$QS"

if (( fails == 0 )); then
  mkdir -p "$ROOT/docs/shots"
  magick "$RUN/two.png" -crop 640x420+$((W - 640))+$((H - 420)) +repage "$RUN/two-basin.png"
  magick "$RUN/three.png" -crop 640x420+$((W - 640))+$((H - 420)) +repage "$RUN/three-basin.png"
  magick "$RUN/two-basin.png" "$RUN/three-basin.png" +append "$ROOT/docs/shots/basin-cards.png"
  magick "$RUN/two.png" -crop 1100x160+0+$((H - 160)) +repage "$RUN/foot-paused.png"
  magick "$RUN/three.png" -crop 1100x160+0+$((H - 160)) +repage "$RUN/foot-playing.png"
  magick "$RUN/foot-paused.png" "$RUN/foot-playing.png" -append "$ROOT/docs/shots/ambient-caption.png"
  echo "basin-shot: 0 failed checks; wrote docs/shots/basin-cards.png and ambient-caption.png"
else
  echo "basin-shot: $fails failed check(s); docs/shots left unchanged"
fi
exit "$fails"
