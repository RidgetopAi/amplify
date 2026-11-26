#!/usr/bin/env bash
# Compile every shaders/*.frag and *.vert to plugin/shaders/<name>.qsb, and every
# plugin/basin/*.frag to a .qsb beside it, with Qt's qsb.
# The .qsb files are committed because `omarchy plugin add` runs no build step.
# Then the plugin's copies of the compiled shaders (plugin/river/river.frag.qsb) are
# refreshed from plugin/shaders by tools/sync-shared.sh.
#
#   tools/build-shaders.sh           # rebuild the committed .qsb in place
#   tools/build-shaders.sh --check   # rebuild into a temp dir and compare, writing nothing
#
# --check (task 179bbd77) is the gate on what ships: every render gate rebuilds the .qsb
# first, so it never loads the committed ones. It fails when a committed .qsb (or the
# river's copy) differs from what its source compiles to (stale, truncated or missing), or
# has no source. qsb output is deterministic for one qsb version (6.12.0 built these).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# env-read: QSB is the qsb binary (default: qsb on PATH, else Arch's /usr/lib/qt6/bin/qsb).
QSB="${QSB:-$(command -v qsb || command -v /usr/lib/qt6/bin/qsb || true)}"
[[ -x $QSB ]] || { echo "build-shaders: qsb not found (Arch: qt6-shadertools; set QSB=)" >&2; exit 1; }
CHECK=0; [[ ${1:-} == --check ]] && CHECK=1
# Where the .qsb go: the tree itself, or for --check a temp copy of its layout.
DEST="$ROOT"
if (( CHECK )); then DEST="$(mktemp -d)"; trap 'rm -rf "$DEST"' EXIT; mkdir -p "$DEST/plugin/basin"; fi

mkdir -p "$DEST/plugin/shaders"
shopt -s nullglob
built=()   # repo-relative paths of the .qsb this run compiled
compile() { "$QSB" --glsl "100es,120,150,300es" --hlsl 50 --msl 12 -o "$DEST/$2" "$1"; built+=("$2"); }
# GLSL ES 100/300 for GLES, GLSL 120/150 for desktop GL, HLSL/MSL for completeness.
for src in "$ROOT"/shaders/*.frag "$ROOT"/shaders/*.vert; do
  compile "$src" "plugin/shaders/$(basename "$src").qsb"
  (( CHECK )) || echo "build-shaders: $(basename "$src") -> plugin/shaders/$(basename "$src").qsb"
done
for src in "$ROOT"/plugin/basin/*.frag; do
  compile "$src" "plugin/basin/$(basename "$src").qsb"
  (( CHECK )) || echo "build-shaders: plugin/basin/$(basename "$src") -> plugin/basin/$(basename "$src").qsb"
done
(( ${#built[@]} > 0 )) || { echo "build-shaders: no shaders found" >&2; exit 1; }
(( CHECK )) || { cd "$ROOT" && "$ROOT/tools/sync-shared.sh" plugin/shaders/*.qsb; exit; }

bad=0
for q in "${built[@]}" plugin/river/river.frag.qsb; do
  fresh="$DEST/$q"; [[ $q == plugin/river/river.frag.qsb ]] && fresh="$DEST/plugin/shaders/river.frag.qsb"
  if [[ ! -f $ROOT/$q ]]; then echo "build-shaders: $q is not committed; run tools/build-shaders.sh" >&2; bad=1
  elif ! cmp -s "$fresh" "$ROOT/$q"; then
    echo "build-shaders: $q ($(stat -c %s "$ROOT/$q") bytes) differs from its source's build ($(stat -c %s "$fresh") bytes, $("$QSB" --version 2>&1 | head -1)); run tools/build-shaders.sh" >&2; bad=1
  fi
done
for q in "$ROOT"/plugin/shaders/*.qsb "$ROOT"/plugin/basin/*.qsb; do
  [[ " ${built[*]} " == *" ${q#"$ROOT/"} "* ]] || { echo "build-shaders: ${q#"$ROOT/"} has no source" >&2; bad=1; }
done
(( bad )) || echo "build-shaders: ${#built[@]} committed .qsb and the river's copy match their sources"
exit "$bad"
