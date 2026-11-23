#!/usr/bin/env bash
# Shared mutation catalogue runner (task e0cabe57). Builder and critic run the same thing.
#
#   tools/mutate.sh                 # control, then every mutation in tools/motion/mutations.json
#   tools/mutate.sh K1-lease-tween-removed C3-reject-rings-dont-turn   # control, then these
#   tools/mutate.sh --list          # ids, sources and gates
#
# Each mutation is applied to a fresh scratch copy of the working tree (tracked and
# untracked files, never the tree itself) by tools/motion/apply.mjs; then the gates it
# lists run there. RED: at least one gate exited non-zero (the mutation is caught).
# GREEN: every gate passed (it survives). STALE: an edit no longer matches the code
# (fix the catalogue). The control (no edit) runs every gate the selection uses and
# must be GREEN. Prints one table row per mutation with each gate's exit code and
# keeps every gate log in $MUTATE_OUT (default /tmp/mutate-<time>).
# Exit status: survivors + stale + (1 if the control is not GREEN).
#
# Gates: data, orbs, river, motion (node --test of data/test, plugin/orbs/test,
# plugin/river/test, tools/motion/test), spec (tools/motion/spec.mjs), river-shot
# (plugin/river/test/shot.sh), orbs-shot (plugin/orbs/test/shot.sh), headless
# (tools/headless-shot.sh). The render gates need the stack in tools/headless-shot.sh
# and HEADLESS_MESA without a GPU. A critic who finds a surviving mutation adds it to
# tools/motion/mutations.json.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAT="$ROOT/tools/motion/mutations.json"
# env-read: MUTATE_OUT is where gate logs go.
OUT="${MUTATE_OUT:-/tmp/mutate-$(date +%Y%m%dT%H%M%S)}"
mkdir -p "$OUT"

if [[ ${1:-} == --list ]]; then
  node -e 'for (const m of require(process.argv[1]).mutations) console.log(`${m.id.padEnd(36)} ${m.gates.join(",").padEnd(18)} ${m.source}`)' "$CAT"
  exit 0
fi

ids=("$@")
(( ${#ids[@]} )) || mapfile -t ids < <(node -e 'for (const m of require(process.argv[1]).mutations) console.log(m.id)' "$CAT")
gates_of() { node -e 'const m = require(process.argv[1]).mutations.find((x) => x.id === process.argv[2]); if (!m) process.exit(2); console.log(m.gates.join(" "))' "$CAT" "$1"; }

declare -A CMD=(
  [data]="node --test data/test/" [orbs]="node --test plugin/orbs/test/" [river]="node --test plugin/river/test/"
  [motion]="node --test tools/motion/test/" [spec]="node tools/motion/spec.mjs"
  [river-shot]="plugin/river/test/shot.sh" [orbs-shot]="plugin/orbs/test/shot.sh" [headless]="tools/headless-shot.sh"
)
ORDER=(data orbs river motion spec headless orbs-shot river-shot)   # cheapest first

# The scratch copy: the working tree as it is now (tracked and untracked, not ignored), without .git.
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE" "${SCR:-}"' EXIT
(cd "$ROOT" && git ls-files -co --exclude-standard -z | grep -zv '^\.amp/' | tar --null -T - -cf -) | tar -xf - -C "$BASE"

# run <id> <gate…>: one table row.
run() {
  local id=$1; shift
  SCR="$(mktemp -d)"; cp -a "$BASE/." "$SCR/"
  if [[ $id != control ]]; then
    node "$ROOT/tools/motion/apply.mjs" "$SCR" "$id" > "$OUT/$id-apply.log" 2>&1
    if [[ $? != 0 ]]; then printf '%-36s STALE  %s\n' "$id" "$(head -1 "$OUT/$id-apply.log")"; rm -rf "$SCR"; return 2; fi
  fi
  local g codes="" red=0
  for g in "${ORDER[@]}"; do
    [[ " $* " == *" $g "* ]] || continue
    (cd "$SCR" && ${CMD[$g]}) > "$OUT/$id-$g.log" 2>&1
    local rc=$?
    codes+=" $g=$rc"; (( rc )) && red=1
  done
  rm -rf "$SCR"
  printf '%-36s %-6s%s\n' "$id" "$( ((red)) && echo RED || echo GREEN)" "$codes"
  return $((red ? 0 : 1))
}

all=()
for id in "${ids[@]}"; do
  g=$(gates_of "$id") || { echo "mutate: no mutation $id" >&2; exit 2; }
  for x in $g; do [[ " ${all[*]} " == *" $x "* ]] || all+=("$x"); done
done

echo "mutate: ${#ids[@]} mutations, logs in $OUT"
printf '%-36s %-6s %s\n' MUTATION RESULT "GATE=EXIT"
bad=0
run control "${all[@]}"; [[ $? == 1 ]] || { echo "mutate: control is not GREEN (see $OUT/control-*.log)"; bad=1; }
red=0 green=0 stale=0
for id in "${ids[@]}"; do
  run "$id" $(gates_of "$id")
  case $? in 0) red=$((red + 1)) ;; 1) green=$((green + 1)) ;; *) stale=$((stale + 1)) ;; esac
done
echo "mutate: $red RED, $green GREEN (survived), $stale STALE of ${#ids[@]}; control $( ((bad)) && echo 'NOT GREEN' || echo GREEN)"
exit $((green + stale + bad))
