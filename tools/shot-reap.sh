# Sourced by the render gates (tools/headless-shot.sh, plugin/orbs/test/shot.sh,
# plugin/river/test/shot.sh). shot_tag <dir> marks every process the gate starts from
# then on with SHOT_TAG=<dir> (its own temp dir); shot_reap kills them all and waits
# (up to 3 s) for them to exit. Killing the pids a gate holds is not enough: Nix's sway
# wrapper runs sway under dbus-run-session when there is no session bus, so sway,
# swaybg and dbus-daemon outlive it (task 5afeee5f, N3). Reap before a bare `wait`: on
# SIGTERM a gate may still run a client it holds no pid for, and the wait would hang on it.
shot_tag() { export SHOT_TAG="$1"; }
shot_reap() {
  local p e pids=() i
  [[ -n ${SHOT_TAG:-} ]] || return 0
  for p in /proc/[0-9]*; do
    { while IFS= read -r -d '' e; do [[ $e == "SHOT_TAG=$SHOT_TAG" ]] && { pids+=("${p#/proc/}"); break; }; done < "$p/environ"; } 2>/dev/null
  done
  (( ${#pids[@]} )) || return 0
  kill "${pids[@]}" 2>/dev/null
  for ((i = 0; i < 30; i++)); do kill -0 "${pids[@]}" 2>/dev/null || return 0; sleep 0.1; done
  kill -9 "${pids[@]}" 2>/dev/null
}
