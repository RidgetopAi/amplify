#!/usr/bin/env bash
# Shared mutation catalogue runner (task e0cabe57). Builder and critic run the same thing.
#
#   tools/mutate.sh                 # control, then every mutation in tools/motion/mutations.json
#   tools/mutate.sh K1-lease-tween-removed C3-reject-rings-dont-turn   # control, then these
#   tools/mutate.sh -j 4 …          # up to 4 runs at once (default: nproc)
#   tools/mutate.sh --list          # ids, sources and gates
#
# Each mutation is applied to a fresh scratch copy of the working tree (tracked and
# untracked files, never the tree itself) by tools/motion/apply.mjs; then the gates it
# lists run there, cheapest first, stopping at the first gate that exits non-zero.
# RED: a gate exited non-zero (the mutation is caught). GREEN: every gate passed (it
# survives). STALE: an edit no longer matches the code (fix the catalogue). The control
# (no edit) runs every gate the selection uses and must be GREEN. Prints one table row
# per run, in selection order, with the exit code of each gate it ran, and keeps every
# gate log in $MUTATE_OUT (default /tmp/mutate-<time>).
# Exit status: survivors + stale + errors + (1 if the control is not GREEN).
#
# Parallel runs (task f8c9133d): the control and the mutations are queued and up to N
# run at once. Each run gets its own scratch copy, and each gate it runs a fresh runtime
# dir, passed as SHOT_RUNTIME_DIR (and TMPDIR): the render gates use it as XDG_RUNTIME_DIR,
# so each gate's sway makes its own Wayland socket and its clients and grim connect only
# to it. A gate holds a lock on its runtime dir; a run that finds it held reports ERROR
# (isolation broken). After each gate, whatever it left running is killed. The headless
# gate drives wayvnc on a fixed port, so headless gates take turns. A render gate keeps
# about one core busy on llvmpipe and its motion checks have time limits (a tether
# settles within 2 s), so at most $MUTATE_RENDER_JOBS (default: nproc) render gates run
# at once, whatever -j is; on a 2-vCPU orb 4 at once made the control's river-shot miss
# that limit (2.08 s).
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

# env-read: MUTATE_RENDER_JOBS caps the render gates (river-shot, orbs-shot, headless) running at once.
JOBS=$(nproc) RENDER=${MUTATE_RENDER_JOBS:-$(nproc)} ids=()
while (( $# )); do
  case $1 in
    -j) JOBS=${2:-}; shift ;;
    -j*) JOBS=${1#-j} ;;
    *) ids+=("$1") ;;
  esac
  shift
done
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo "mutate: -j needs a positive number" >&2; exit 2; }
[[ $RENDER =~ ^[1-9][0-9]*$ ]] || { echo "mutate: MUTATE_RENDER_JOBS needs a positive number" >&2; exit 2; }

(( ${#ids[@]} )) || mapfile -t ids < <(node -e 'for (const m of require(process.argv[1]).mutations) console.log(m.id)' "$CAT")
gates_of() { node -e 'const m = require(process.argv[1]).mutations.find((x) => x.id === process.argv[2]); if (!m) process.exit(2); console.log(m.gates.join(" "))' "$CAT" "$1"; }

declare -A CMD=(
  [data]="node --test data/test/" [orbs]="node --test plugin/orbs/test/" [river]="node --test plugin/river/test/"
  [motion]="node --test tools/motion/test/" [spec]="node tools/motion/spec.mjs"
  [river-shot]="plugin/river/test/shot.sh" [orbs-shot]="plugin/orbs/test/shot.sh" [headless]="tools/headless-shot.sh"
)
ORDER=(data orbs river motion spec headless orbs-shot river-shot)   # cheapest first

# WORK holds the base copy, each run's scratch copy, runtime dir and result.
WORK="$(mktemp -d)"

# reap <glob>: kill every process whose MUTATE_RUN (which each gate passes to everything it
# starts) matches <glob>: after a gate, what it left running; on exit, everything any gate
# started. (Nix's sway wrapper runs sway under dbus-run-session when there is no session
# bus, so the shot scripts' kill of the sway pid leaves sway and dbus-daemon running.)
reap() {
  local p e
  for p in /proc/[0-9]*; do
    { while IFS= read -r -d '' e; do [[ $e == MUTATE_RUN=$1 ]] && { kill "${p#/proc/}"; break; }; done < "$p/environ"; } 2>/dev/null
  done
}
# On exit, interrupted or not: stop the runs, then whatever their gates still run.
cleanup() { kill $(jobs -p) 2>/dev/null; wait; reap "$WORK/*"; sleep 0.5; reap "$WORK/*"; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# The base copy: the working tree as it is now (tracked and untracked, not ignored), without .git.
BASE="$WORK/base"; mkdir "$BASE"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | grep -zv '^\.amp/' | tar --null -T - -cf -) | tar -xf - -C "$BASE"

# render_slot: hold (on fd 8) one of the RENDER render-gate slots, waiting for a free one.
render_slot() {
  local k
  while :; do
    for ((k = 1; k <= RENDER; k++)); do exec 8> "$WORK/render-$k.lock"; flock -n 8 && return; done
    exec 8>&-; sleep 0.5
  done
}

# gate <n> <id> <gate>: run one gate in run n's scratch copy, in its own runtime dir
# (fresh per gate, locked while in use) and temp dir; prints its exit code, or "busy"
# when the runtime dir is already locked (isolation broken).
gate() {
  local n=$1 id=$2 g=$3 rt="$WORK/rt-$1-$3" rc
  mkdir -p "$rt"
  exec 9< "$rt"
  flock -n 9 || { echo "mutate: runtime dir $rt is in use by another run" > "$OUT/$id-$g.log"; exec 9<&-; echo busy; return; }
  [[ $g == *-shot || $g == headless ]] && render_slot
  local env=(MUTATE_RUN="$rt" SHOT_RUNTIME_DIR="$rt" TMPDIR="$rt")
  [[ $g == headless ]] && env+=(flock "$WORK/headless.lock")
  (cd "$WORK/scr-$n" && exec env "${env[@]}" ${CMD[$g]}) > "$OUT/$id-$g.log" 2>&1
  rc=$?
  reap "$rt"; exec 8>&- 9<&-; rm -rf "$rt"
  echo "$rc"
}

# run <n> <id> <gate…>: one table row on stdout. Returns 0 RED, 1 GREEN, 2 STALE, 3 ERROR.
run() {
  local n=$1 id=$2; shift 2
  local scr="$WORK/scr-$n"
  mkdir -p "$scr"; cp -a "$BASE/." "$scr/"
  if [[ $id != control ]]; then
    node "$ROOT/tools/motion/apply.mjs" "$scr" "$id" > "$OUT/$id-apply.log" 2>&1
    if [[ $? != 0 ]]; then printf '%-36s STALE  %s\n' "$id" "$(head -1 "$OUT/$id-apply.log")"; rm -rf "$scr"; return 2; fi
  fi
  local g rc codes="" red=0
  for g in "${ORDER[@]}"; do
    [[ " $* " == *" $g "* ]] || continue
    rc=$(gate "$n" "$id" "$g")
    if [[ $rc == busy ]]; then
      printf '%-36s ERROR  %s\n' "$id" "$(< "$OUT/$id-$g.log")"; rm -rf "$scr"; return 3
    fi
    codes+=" $g=$rc"
    (( rc )) && { red=1; break; }
  done
  rm -rf "$scr"
  printf '%-36s %-6s%s\n' "$id" "$( ((red)) && echo RED || echo GREEN)" "$codes"
  return $((red ? 0 : 1))
}

all=()
for id in "${ids[@]}"; do
  g=$(gates_of "$id") || { echo "mutate: no mutation $id" >&2; exit 2; }
  for x in $g; do [[ " ${all[*]} " == *" $x "* ]] || all+=("$x"); done
done

# The queue: the control first, then the selection. Runs finish in any order; rows
# print in queue order as soon as every earlier run has finished.
queue=(control "${ids[@]}")
echo "mutate: ${#ids[@]} mutations, -j $JOBS (render gates $RENDER), logs in $OUT"
printf '%-36s %-6s %s\n' MUTATION RESULT "GATE=EXIT"
bad=0 red=0 green=0 stale=0 err=0 next=0
flush() {
  while [[ -f $WORK/rc-$next ]]; do
    cat "$WORK/row-$next"
    local rc; rc=$(< "$WORK/rc-$next")
    if (( next == 0 )); then
      [[ $rc == 1 ]] || { echo "mutate: control is not GREEN (see $OUT/control-*.log)"; bad=1; }
    else
      case $rc in 0) red=$((red + 1)) ;; 1) green=$((green + 1)) ;; 2) stale=$((stale + 1)) ;; *) err=$((err + 1)) ;; esac
    fi
    next=$((next + 1))
  done
}
for n in "${!queue[@]}"; do
  while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n; flush; done
  id=${queue[n]}
  if (( n == 0 )); then gates=("${all[@]}"); else read -ra gates <<< "$(gates_of "$id")"; fi
  ( run "$n" "$id" "${gates[@]}" > "$WORK/row-$n"; echo $? > "$WORK/rc-$n.tmp"; mv "$WORK/rc-$n.tmp" "$WORK/rc-$n" ) &
  flush
done
while (( next < ${#queue[@]} )) && [[ -n $(jobs -rp) ]]; do wait -n; flush; done
wait; flush
echo "mutate: $red RED, $green GREEN (survived), $stale STALE$( ((err)) && echo ", $err ERROR") of ${#ids[@]}; control $( ((bad)) && echo 'NOT GREEN' || echo GREEN)"
exit $((green + stale + err + bad))
