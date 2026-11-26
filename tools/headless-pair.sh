#!/usr/bin/env bash
# Two tools/headless-shot.sh runs at once (task 87f71d95), each in its own copy of this
# tree, runtime dir and temp dir, as tools/mutate.sh runs them side by side. Anything the
# two share beyond those (a fixed VNC port, a socket path) makes one drive the other's
# compositor, and its click checks fail.
#
#   tools/headless-pair.sh     # exit status: the number of runs that failed (0 = both passed)
#
# Needs what tools/headless-shot.sh needs. Its gate in tools/mutate.sh is headless-pair.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; wait; rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Separate trees: each run rebuilds its .qsb files in place and writes docs/spike.
for k in a b; do
  mkdir -p "$T/$k/tree" "$T/$k/rt"
  tar -C "$ROOT" --exclude=./.git --exclude=./.amp -cf - . | tar -xf - -C "$T/$k/tree"
done
for k in a b; do
  SHOT_RUNTIME_DIR="$T/$k/rt" TMPDIR="$T/$k/rt" "$T/$k/tree/tools/headless-shot.sh" > "$T/$k.log" 2>&1 &
done
fails=0
for k in a b; do wait -n || fails=$((fails + 1)); done
for k in a b; do
  grep -E "^(PASS|FAIL)|^headless-shot:|timed out" "$T/$k.log" | sed "s/^/[$k] /"
done
echo "headless-pair: $fails of 2 runs failed"
exit "$fails"
