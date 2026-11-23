#!/usr/bin/env bash
# Test tools/install-plugin.sh against stub omarchy / omarchy-shell / qsb / ln.
# The stub shell models real Omarchy: rescanPlugins returns at once and the
# plugin only appears in `omarchy plugin list` after a delay (rescan is async).
# With WATCHER=on, any change under plugins/ makes the shell wait 150 ms
# (localPluginReloadTimer) and then reload for RELOAD s. The list shows the old
# state until the reload ends, IPC calls meanwhile wait or time out
# (omarchy-shell's default IPC timeout is 2 s), and an enable sent before the
# reload ends is lost to it (result "early").
#
#   tools/test-install-plugin.sh      # exit status = number of failed checks
#
# Needs: bash, jq. Runs on a copy of the tree with a throwaway HOME.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

mkdir -p "$WORK/bin"
# State lives in $STUB: list holds "time listed" lines (the newest line whose
# time has come decides what the list shows), reload "start end" of the latest
# reload, dir.sig the plugins/ mtime the watcher last saw, result one line per
# enable/disable. Knobs: DELAY (rescan lands after DELAY s; never: not at all),
# WATCHER (on|off), RELOAD (s), RESCAN (ok|timeout: rescan never answers),
# ENABLE (ok|timeout-once: the first enable is not answered|error: enable fails).
cat > "$WORK/stub.sh" <<'EOF'
now() { date +%s.%N; }
calc() { awk "BEGIN { printf \"%.3f\", $1 }"; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
reload() { cat "$STUB/reload" 2>/dev/null || echo "0 0"; }
# Seconds until the shell answers: the rest of a reload in progress, if any.
busy() { local n; n=$(now); read -r s e <<<"$(reload)"; calc "($n >= $s && $e > $n) ? $e - $n : 0"; }
visible() { awk -v n="$(now)" '$1 <= n { v = $2 } END { exit !v }' "$STUB/list" 2>/dev/null; }
linked() { [[ -L $LINK ]] && echo 1 || echo 0; }
# ipc: wait like omarchy-shell does, or time out as it does.
ipc() {
  local b t=${OMARCHY_SHELL_IPC_TIMEOUT:-2s}; b=$(busy)
  if ! ge "${t%s}" "$b"; then sleep "${t%s}"; echo "omarchy-shell is not responding" >&2; return 1; fi
  sleep "$b"
}
LINK="$HOME/.config/omarchy/plugins/ridgetopai.amplify"
# The watcher (inotify on plugins/) fires on any link created, replaced or
# removed there, at the time it happened.
if [[ $WATCHER == on ]]; then
  sig=$(stat -c %.9Y "$(dirname "$LINK")" 2>/dev/null)
  if [[ -n $sig && $sig != "$(cat "$STUB/dir.sig" 2>/dev/null)" ]]; then
    echo "$sig" > "$STUB/dir.sig"
    s=$(calc "$sig + 0.15"); e=$(calc "$s + $RELOAD")
    echo "$s $e" > "$STUB/reload"; echo "$e $(linked)" >> "$STUB/list"
  fi
fi
EOF
cat > "$WORK/bin/omarchy-shell" <<'EOF'
#!/usr/bin/env bash
t=${OMARCHY_SHELL_IPC_TIMEOUT:-2s}
echo "omarchy-shell $* timeout=$t" >> "$STUB/calls"
. "$STUBLIB"
[[ "$1 $2" == "shell rescanPlugins" ]] || { ipc; exit; }
b=$(busy)
# The scan runs after any reload in progress, whether or not the reply arrives.
[[ $DELAY != never ]] && echo "$(calc "$(now) + $b + $DELAY") $(linked)" >> "$STUB/list"
reply=$b
if [[ $WATCHER == on ]]; then echo "$(now) $(calc "$(now) + $b + $RELOAD")" > "$STUB/reload"; reply=$(calc "$b + $RELOAD"); fi
if [[ $RESCAN == timeout ]] || ! ge "${t%s}" "$reply"; then
  sleep "${t%s}"; echo "omarchy-shell is not responding" >&2; exit 1
fi
sleep "$reply"
EOF
cat > "$WORK/bin/omarchy" <<'EOF'
#!/usr/bin/env bash
echo "omarchy $* timeout=${OMARCHY_SHELL_IPC_TIMEOUT:-2s}" >> "$STUB/calls"
. "$STUBLIB"
case "$1 $2" in
  "plugin validate") exit 0 ;;
  "plugin list")  # asks the shell (listPlugins)
    ipc || exit 1
    if visible; then json='[{"id":"ridgetopai.amplify","enabled":false}]'; else json='[]'; fi
    if [[ ${3:-} == --json ]]; then echo "$json"; else
      printf '%-32s %-9s\n' ID STATE
      jq -r '.[] | .id' <<<"$json" | while read -r id; do printf '%-32s %-9s\n' "$id" disabled; done
    fi ;;
  "plugin enable"|"plugin disable")  # enablePlugin / setPluginEnabled
    if [[ $2 == enable && $ENABLE == timeout-once ]]; then
      # The first enable is not answered; later ones answer only within 10 s or more.
      t=${OMARCHY_SHELL_IPC_TIMEOUT:-2s}
      if [[ ! -e $STUB/enable.once ]] || ! ge "${t%s}" 10; then
        touch "$STUB/enable.once"; echo "timeout" >> "$STUB/result"
        echo "omarchy-shell is not responding" >&2; exit 1
      fi
    elif [[ $2 == enable && $ENABLE == error ]]; then
      echo "error" >> "$STUB/result"; echo "omarchy-plugin-enable: manifest rejected" >&2; exit 1
    fi
    sent=$(now)
    ipc || { echo "timeout" >> "$STUB/result"; exit 1; }
    if ! visible; then
      echo "unknown" >> "$STUB/result"
      echo "omarchy-plugin-$2: plugin '$3' is not known; run: omarchy-shell shell rescanPlugins" >&2; exit 1
    fi
    read -r _ e <<<"$(reload)"
    if ge "$sent" "$e"; then echo "${2}d" >> "$STUB/result"; else echo "early" >> "$STUB/result"; fi ;;
esac
EOF
cat > "$WORK/bin/qsb" <<'EOF'
#!/usr/bin/env bash
while (( $# )); do [[ $1 == -o ]] && { touch "$2"; shift; }; shift; done
EOF
cat > "$WORK/bin/ln" <<EOF
#!/usr/bin/env bash
echo "ln \$*" >> "\$STUB/calls"
exec $(command -v ln) "\$@"
EOF
chmod +x "$WORK/bin/"*

# run <name> <delay> [timeout] -> sets out, rc, STUB. Env WATCHER, RELOAD,
# RESCAN pass through, ARG is passed to the installer (--remove); a second run
# with the same name reuses its state.
run() {
  STUB="$WORK/$1"; mkdir -p "$STUB/home" "$STUB/tree"
  [[ -d $STUB/tree/tools ]] || cp -r "$ROOT/plugin" "$ROOT/shaders" "$ROOT/tools" "$STUB/tree/"
  : > "$STUB/calls"; rm -f "$STUB/result"
  out=$(STUB="$STUB" STUBLIB="$WORK/stub.sh" DELAY="$2" WATCHER="${WATCHER:-off}" RELOAD="${RELOAD:-2}" \
    RESCAN="${RESCAN:-ok}" ENABLE="${ENABLE:-ok}" HOME="$STUB/home" PATH="$WORK/bin:$PATH" QSB="$WORK/bin/qsb" \
    AMPLIFY_RESCAN_TIMEOUT="${3:-10}" "$STUB/tree/tools/install-plugin.sh" ${ARG:+"$ARG"} 2>&1); rc=$?
}
count() { grep -c -- "$1" "$STUB/calls"; }
lns() { grep -c '^ln .*ridgetopai.amplify' "$STUB/calls"; }
rescans() { count 'shell rescanPlugins'; }
results() { tr '\n' ' ' 2>/dev/null < "$STUB/result"; }

# 1. Plugin appears 1 s after the rescan: install waits, then enables once.
run delayed 1
[[ $rc == 0 ]] && pass "delayed: install exits 0" || fail "delayed: install exited $rc: $out"
[[ "$(cat "$STUB/result" 2>/dev/null)" == enabled ]] \
  && pass "delayed: enable called once, only after the plugin is listed" \
  || fail "delayed: enable results were [$(tr '\n' ' ' 2>/dev/null < "$STUB/result")] (want: enabled)"
[[ -L $STUB/home/.config/omarchy/plugins/ridgetopai.amplify ]] && pass "delayed: plugin linked" || fail "delayed: plugin not linked"

# 2. Plugin never appears: install fails loudly and never calls enable.
run never never 1
[[ $rc != 0 ]] && pass "never: install exits non-zero ($rc)" || fail "never: install exited 0"
[[ $out == *"did not list ridgetopai.amplify"* ]] && pass "never: timeout message printed" || fail "never: no timeout message: $out"
[[ ! -s $STUB/result ]] && pass "never: enable not called" || fail "never: enable was called"

# 3. Real Omarchy, fresh install: the new link makes the watcher reload for 2 s
#    after 150 ms and any rescan times out. Install leaves the reload to the
#    watcher, waits it out, and enables once.
WATCHER=on RESCAN=timeout run reload never
[[ $rc == 0 ]] && pass "reload: install exits 0" || fail "reload: install exited $rc: $out"
[[ "$(cat "$STUB/result" 2>/dev/null)" == enabled && $(count 'plugin enable') == 1 ]] \
  && pass "reload: enable called once, after the reload" \
  || fail "reload: enable results were [$(tr '\n' ' ' 2>/dev/null < "$STUB/result")] (want: enabled)"
[[ $(rescans) == 0 ]] && pass "reload: no rescan on top of the watcher's reload" || fail "reload: rescanPlugins called $(rescans) time(s)"

# 4. Re-run with the link already in place: no ln, so no reload, no rescan,
#    and no waiting for one.
WATCHER=on RESCAN=timeout run reload never
[[ $rc == 0 ]] && pass "rerun: install exits 0" || fail "rerun: install exited $rc: $out"
[[ $(lns) == 0 ]] && pass "rerun: link left alone" || fail "rerun: ln called $(lns) time(s)"
[[ $(rescans) == 0 ]] && pass "rerun: no rescan" || fail "rerun: rescanPlugins called $(rescans) time(s)"
[[ $(count 'shell ping') == 0 && "$(results)" == "enabled " ]] && pass "rerun: enables at once" \
  || fail "rerun: $(count 'shell ping') ping(s), enable results [$(results)]"

# 4b. Retarget: the link points at another checkout whose plugin is loaded, so
#     the old entry stays listed through the 150 ms debounce and the reload.
#     Install waits the reload out and enables once, after it.
retarget_setup() {
  STUB="$WORK/$1"; P="$STUB/home/.config/omarchy/plugins"; mkdir -p "$P" "$STUB/old/plugin"
  ln -s "$STUB/old/plugin" "$P/ridgetopai.amplify"
  stat -c %.9Y "$P" > "$STUB/dir.sig"; echo "0 1" > "$STUB/list"
}
retarget_check() {
  [[ $rc == 0 ]] && pass "$1: install exits 0" || fail "$1: install exited $rc: $out"
  [[ $(readlink "$P/ridgetopai.amplify") == "$STUB/tree/plugin" ]] && pass "$1: link points at this checkout" \
    || fail "$1: link points at $(readlink "$P/ridgetopai.amplify")"
  [[ "$(results)" == "enabled " && $(count 'plugin enable') == 1 ]] \
    && pass "$1: enable called once, after the reload" \
    || fail "$1: enable results were [$(results)] (want: enabled)"
  [[ $(rescans) == 0 && $out != *"not responding"* ]] && pass "$1: no rescan, nothing timed out" \
    || fail "$1: $(rescans) rescan(s); output: $out"
}
retarget_setup retarget
WATCHER=on RESCAN=timeout run retarget never
retarget_check retarget

# 4c. Comma-decimal locale: bash prints EPOCHREALTIME as "1795325007,733322"
#     there. ms() must still give milliseconds, so a microsecond part such as
#     089322 is no octal error; checked directly, then end to end on a retarget
#     under a comma locale (generated with localedef if none is installed).
ms_src=$(grep '^ms()' "$ROOT/tools/install-plugin.sh")
v=$(bash -c "unset EPOCHREALTIME; EPOCHREALTIME=1795325007,089322; $ms_src; ms" 2>&1)
[[ $v == 1795325007089 ]] && pass "locale: ms() reads a comma-decimal EPOCHREALTIME" \
  || fail "locale: ms() on 1795325007,089322 gave: $v (want 1795325007089)"
comma() { [[ $(LC_ALL=$1 LOCPATH=$2 bash -c 'echo "$EPOCHREALTIME"' 2>/dev/null) == *,* ]]; }
cl=; lp=
for l in de_DE.UTF-8 de_DE.utf8 fr_FR.UTF-8 fr_FR.utf8; do comma "$l" "" && { cl=$l; break; }; done
if [[ -z $cl ]]; then
  mkdir -p "$WORK/locale"; localedef -i de_DE -f UTF-8 "$WORK/locale/de_DE.UTF-8" >/dev/null 2>&1
  comma de_DE.UTF-8 "$WORK/locale" && { cl=de_DE.UTF-8; lp="$WORK/locale"; }
fi
if [[ -n $cl ]]; then
  retarget_setup retarget-comma
  LOCPATH=$lp LC_ALL=$cl WATCHER=on RESCAN=timeout run retarget-comma never
  retarget_check "retarget under $cl"
else
  echo "SKIP retarget under a comma-decimal locale: none installed and localedef -i de_DE -f UTF-8 failed (ms() checked directly above)"
fi

# 5. Link in place but the shell does not list the plugin, and rescanPlugins
#    times out although its scan lands: rescan once (10 s timeout), then the
#    poll decides.
STUB="$WORK/stale"; mkdir -p "$STUB/home/.config/omarchy/plugins" "$STUB/tree"
cp -r "$ROOT/plugin" "$ROOT/shaders" "$ROOT/tools" "$STUB/tree/"
ln -s "$STUB/tree/plugin" "$STUB/home/.config/omarchy/plugins/ridgetopai.amplify"
RESCAN=timeout run stale 1
[[ $rc == 0 ]] && pass "stale: install exits 0 although rescan did not answer" || fail "stale: install exited $rc: $out"
[[ $(rescans) == 1 && $(count 'rescanPlugins timeout=10s') == 1 ]] \
  && pass "stale: rescan called once with a 10 s IPC timeout" || fail "stale: rescan calls: $(grep rescan "$STUB/calls" | tr '\n' ';')"
[[ "$(cat "$STUB/result" 2>/dev/null)" == enabled ]] && pass "stale: enable called once" \
  || fail "stale: enable results were [$(tr '\n' ' ' 2>/dev/null < "$STUB/result")] (want: enabled)"

# 6. --remove on the installed plugin: disables, unlinks, and a rescan that
#    times out (the unlink's reload is running) is not fatal. A second --remove
#    with no link also exits 0.
ARG=--remove WATCHER=on RESCAN=timeout run reload never
L="$STUB/home/.config/omarchy/plugins/ridgetopai.amplify"
[[ $rc == 0 ]] && pass "remove: exits 0 although rescan did not answer" || fail "remove: exited $rc: $out"
[[ ! -e $L && ! -L $L ]] && pass "remove: link removed" || fail "remove: link still there"
[[ "$(results)" == "disabled " ]] && pass "remove: plugin disabled" || fail "remove: disable results [$(results)]"
[[ $(rescans) == 1 && $(count 'rescanPlugins timeout=10s') == 1 && $out != *"plugin list"* ]] \
  && pass "remove: one rescan with a 10 s IPC timeout, no plugin-list message" \
  || fail "remove: rescan calls: $(grep rescan "$STUB/calls" | tr '\n' ';') output: $out"
ARG=--remove WATCHER=on RESCAN=timeout run reload never
[[ $rc == 0 ]] && pass "remove again: exits 0 with no link" || fail "remove again: exited $rc: $out"

# 6b. The first enable is not answered (the shell only answers within a 10 s
#     IPC timeout): install retries once with 10 s and exits 0.
ENABLE=timeout-once run enable-retry 1
[[ $rc == 0 ]] && pass "enable retry: install exits 0" || fail "enable retry: install exited $rc: $out"
[[ $(count 'plugin enable') == 2 && $(count 'plugin enable ridgetopai.amplify timeout=10s') == 2 && "$(results)" == "timeout enabled " ]] \
  && pass "enable retry: enable ran twice with a 10 s IPC timeout, then enabled" \
  || fail "enable retry: calls: $(grep 'plugin enable' "$STUB/calls" | tr '\n' ';') results [$(results)]"

# 6c. Enable fails for another reason: no retry, install fails.
ENABLE=error run enable-error 1
[[ $rc != 0 && $(count 'plugin enable') == 1 ]] && pass "enable error: not retried, install exits non-zero ($rc)" \
  || fail "enable error: exit $rc, $(count 'plugin enable') enable call(s)"

# 7. The stub's plain `plugin list` is a table, as Omarchy's is; only --json is JSON.
plain=$(STUB="$STUB" STUBLIB="$WORK/stub.sh" DELAY=1 WATCHER=off HOME="$STUB/home" "$WORK/bin/omarchy" plugin list)
[[ $plain == ID* ]] && ! jq -e . <<<"$plain" >/dev/null 2>&1 \
  && pass "stub: plain plugin list is a table" || fail "stub: plain plugin list was: $plain"

echo "test-install-plugin: $fails failed check(s)"
exit "$fails"
