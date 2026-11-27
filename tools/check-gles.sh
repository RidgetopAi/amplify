#!/usr/bin/env bash
# Strict check of the old-GL variants of every shipped .qsb (task 3432bf5a).
#
#   tools/check-gles.sh            # every committed plugin/**/*.qsb
#   tools/check-gles.sh <qsb>...   # only these
#   tools/check-gles.sh --build    # first rebuild the .qsb from source (tools/build-shaders.sh),
#                                  # as the render gates do: checks what the sources compile to
#
# Qt picks the GLSL "100 es" variant of a .qsb on some drivers (NVIDIA on Brian's desktop)
# and GLSL 120 on old desktop GL. Headless Mesa accepts more than those drivers do: it drew
# meridian.frag's array constructors (vec4[8](...)) while NVIDIA refused the whole program
# (C7553 "OpenGL array assignments require #version 120"), so no globe was drawn. For each
# .qsb this extracts the GLSL 100 es and 120 variants with qsb and fails when either
#   1. contains an array constructor (type[n](...) or type[](...)), which GLSL ES 1.00 and
#      GLSL 1.10 forbid and drivers reject unevenly, or
#   2. does not compile under glslangValidator (Khronos' reference front end) for its version.
# Exit status: the number of failed variants (0 = all passed).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# env-read: QSB is the qsb binary (default: qsb on PATH, else Arch's /usr/lib/qt6/bin/qsb).
QSB="${QSB:-$(command -v qsb || command -v /usr/lib/qt6/bin/qsb || true)}"
[[ -x $QSB ]] || { echo "check-gles: qsb not found (Arch: qt6-shadertools; set QSB=)" >&2; exit 1; }
# env-read: GLSLANG is glslangValidator (default: on PATH; Arch: glslang).
GLSLANG="${GLSLANG:-$(command -v glslangValidator || true)}"
[[ -x $GLSLANG ]] || { echo "check-gles: glslangValidator not found (Arch: glslang; set GLSLANG=)" >&2; exit 1; }

if [[ ${1:-} == --build ]]; then
  shift
  "$ROOT/tools/build-shaders.sh" >/dev/null || { echo "check-gles: shader build failed" >&2; exit 1; }
fi
shopt -s nullglob globstar
qsbs=("$@")
(( ${#qsbs[@]} )) || { cd "$ROOT" && qsbs=(plugin/**/*.qsb); }
(( ${#qsbs[@]} )) || { echo "check-gles: no .qsb found" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# An array constructor: a scalar, vector or matrix type, a bracket pair, then a call.
CTOR='\b(float|int|uint|bool|[biu]?vec[234]|mat[234](x[234])?)[[:space:]]*\[[[:space:]]*[0-9]*[[:space:]]*\][[:space:]]*\('
bad=0 n=0
for q in "${qsbs[@]}"; do
  [[ $q == /* ]] || q="$ROOT/$q"
  rel="${q#"$ROOT/"}" stage=frag
  [[ $q == *.vert.qsb ]] && stage=vert
  for v in 100es 120; do
    out="$TMP/$(basename "$q" .qsb).$v.$stage"
    if ! "$QSB" -x "glsl,$v" -o "$out" "$q" >/dev/null 2>&1 || [[ ! -s $out ]]; then
      echo "check-gles: $rel has no GLSL $v variant" >&2; bad=$((bad + 1)); continue
    fi
    n=$((n + 1))
    if hits=$(grep -nE "$CTOR" "$out"); then
      echo "check-gles: $rel GLSL $v has array constructors (GLSL ES 1.00 and NVIDIA's 100 es path reject them):" >&2
      sed 's/^/    /' <<< "$hits" >&2; bad=$((bad + 1)); continue
    fi
    if ! log=$("$GLSLANG" -S "$stage" "$out" 2>&1); then
      echo "check-gles: $rel GLSL $v does not compile:" >&2
      grep -E 'ERROR' <<< "$log" | sed 's/^/    /' >&2; bad=$((bad + 1))
    fi
  done
done
(( bad )) || echo "check-gles: $n GLSL 100 es / 120 variants of ${#qsbs[@]} .qsb: no array constructors, all compile"
exit "$bad"
