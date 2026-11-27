#!/usr/bin/env bash
# Stand-in for cava (plugin/ambient/test/shot.sh; the orb has no audio). Records that it
# started and stopped in $AMBIENT_STUB_DIR, and prints raw ascii frames of 16 bars at
# about 120 a second, four times the field's cap, so the cap has something to drop.
# env-read: AMBIENT_STUB_DIR is where the stub records its starts and stops.
dir=${AMBIENT_STUB_DIR:?}
echo "$*" > "$dir/started.$$"
trap 'touch "$dir/stopped.$$"; exit 0' TERM INT
while :; do
  f=""; for ((i = 0; i < 16; i++)); do f+="$((RANDOM % 1001));"; done
  echo "$f"
  sleep 0.008
done
