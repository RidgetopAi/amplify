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
# shot_wait <seconds> <what> <command...>: the gates' readiness wait (task 87f71d95). Runs
# <command> every 50 ms until it succeeds (returns 0), or, once <seconds> have passed,
# prints "shot: timed out after <seconds> s waiting for <what>" to stderr and returns 1.
# Gates wait on what they can observe (a log line, a socket, an output, a pixel) instead
# of sleeping a fixed time; only measurement and settle windows sleep, each commented.
shot_wait() {
  local s=$1 what=$2 end; shift 2
  end=$(( ${EPOCHREALTIME/./} + s * 1000000 ))
  until "$@"; do
    (( ${EPOCHREALTIME/./} < end )) || { echo "shot: timed out after $s s waiting for $what" >&2; return 1; }
    sleep 0.05
  done
}
# shot_stop <pid>: TERM a process the gate started, then reap it, bounded (task 859896c9). A
# TERM sent right after the launch can reach the forked bash child before it execs, while it
# still has the gate's traps (its EXIT trap alone makes bash catch TERM). Mostly the child
# runs them and exits (so a gate's cleanup must run only in the gate's own shell); now and
# then the exec drops the caught signal, the program runs on, and a bare `wait` blocks until
# mutate.sh's gate timeout (W1b did: 1200 s every catalogue run). A process still running 5 s
# after the TERM gets SIGKILL, which no handler can take. Gone: a zombie, or already reaped.
shot_gone() { local s; read -r s 2>/dev/null < "/proc/$1/stat" || return 0; s=${s##*) }; [[ ${s%% *} == Z ]]; }
shot_stop() {
  kill "$1" 2>/dev/null
  shot_wait 5 "process $1 to exit on SIGTERM (sending SIGKILL)" shot_gone "$1" || kill -9 "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}
