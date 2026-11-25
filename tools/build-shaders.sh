#!/usr/bin/env bash
# Compile every shaders/*.frag and *.vert to plugin/shaders/<name>.qsb, and every
# plugin/basin/*.frag to a .qsb beside it, with Qt's qsb.
# The .qsb files are committed because `omarchy plugin add` runs no build step.
# Then the plugin's copies of the compiled shaders (plugin/river/river.frag.qsb) are
# refreshed from plugin/shaders by tools/sync-shared.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/plugin/shaders"
QSB="${QSB:-$(command -v qsb || command -v /usr/lib/qt6/bin/qsb || true)}"
[[ -x $QSB ]] || { echo "build-shaders: qsb not found (Arch: qt6-shadertools; set QSB=)" >&2; exit 1; }

mkdir -p "$OUT"
shopt -s nullglob
count=0
for src in "$ROOT"/shaders/*.frag "$ROOT"/shaders/*.vert; do
  dst="$OUT/$(basename "$src").qsb"
  # GLSL ES 100/300 for GLES, GLSL 120/150 for desktop GL, HLSL/MSL for completeness.
  "$QSB" --glsl "100es,120,150,300es" --hlsl 50 --msl 12 -o "$dst" "$src"
  echo "build-shaders: $(basename "$src") -> plugin/shaders/$(basename "$dst")"
  count=$((count + 1))
done
for src in "$ROOT"/plugin/basin/*.frag; do
  "$QSB" --glsl "100es,120,150,300es" --hlsl 50 --msl 12 -o "$src.qsb" "$src"
  echo "build-shaders: plugin/basin/$(basename "$src") -> plugin/basin/$(basename "$src").qsb"
  count=$((count + 1))
done
(( count > 0 )) || { echo "build-shaders: no shaders found" >&2; exit 1; }
cd "$ROOT" && "$ROOT/tools/sync-shared.sh" plugin/shaders/*.qsb
