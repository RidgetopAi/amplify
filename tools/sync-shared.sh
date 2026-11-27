#!/usr/bin/env bash
# Shared files: each has one source and real copies inside plugin/ (task af4b39ff).
# Quickshell resolves imports and URLs outside its config folder (plugin/ for the
# whole plugin, plugin/river for `quickshell -p plugin/river`) to qrc:/qs-blackhole,
# and `omarchy plugin validate` rejects symlinks inside a plugin folder, so the
# components carry copies. Edit the source, then run this; never edit a copy.
#
#   tools/sync-shared.sh             # copy every source over its copies
#   tools/sync-shared.sh <src>...    # only these sources' copies (tools/motion/apply.mjs)
#   tools/sync-shared.sh --check     # exit 1 if a copy differs from its source or plugin/ has a symlink
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# <source> <copy>...
SHARED=(
  "data/mandrel.js plugin/basin/mandrel.js plugin/orbs/mandrel.js plugin/river/mandrel.js"
  "data/amp/amp.js plugin/basin/amp.js"
  "fixtures/amplify-snapshot.json plugin/basin/amplify-snapshot.json plugin/orbs/amplify-snapshot.json plugin/river/amplify-snapshot.json"
  "plugin/motion/Trace.qml plugin/basin/Trace.qml plugin/orbs/Trace.qml plugin/river/Trace.qml plugin/focus/Trace.qml"
  "data/SceneClock.qml plugin/basin/SceneClock.qml plugin/orbs/SceneClock.qml plugin/river/SceneClock.qml"
  "plugin/shaders/river.frag.qsb plugin/river/river.frag.qsb"
)

if [[ ${1:-} == --check ]]; then
  bad=0
  for row in "${SHARED[@]}"; do
    read -ra f <<< "$row"
    for c in "${f[@]:1}"; do
      if [[ -L $ROOT/$c ]]; then echo "sync-shared: $c is a symlink (omarchy plugin validate rejects it); run tools/sync-shared.sh" >&2; bad=1
      elif ! cmp -s "$ROOT/${f[0]}" "$ROOT/$c"; then echo "sync-shared: $c differs from ${f[0]}; edit the source, then run tools/sync-shared.sh" >&2; bad=1
      fi
    done
  done
  links=$(find "$ROOT/plugin" -type l)
  [[ -z $links ]] || { echo "sync-shared: symlinks inside plugin/: ${links//$ROOT\//}" >&2; bad=1; }
  exit "$bad"
fi

for row in "${SHARED[@]}"; do
  read -ra f <<< "$row"
  if (( $# )); then [[ " $* " == *" ${f[0]} "* ]] || continue; fi
  for c in "${f[@]:1}"; do
    rm -f "$ROOT/$c"   # a symlink is replaced, not written through
    cp "$ROOT/${f[0]}" "$ROOT/$c" || exit 1
  done
done
