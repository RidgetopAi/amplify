#!/usr/bin/env bash
# Test tools/install-plugin.sh against stub omarchy / omarchy-shell / qsb / ln.
# The stub shell models real Omarchy: rescanPlugins returns at once and the
# plugin only appears in `omarchy plugin list` after a delay (rescan is async);
# with WATCHER=on, a new or replaced plugin link starts a RELOAD-second plugin
# reload that blocks the shell, so IPC calls meanwhile wait or time out
# (omarchy-shell's default IPC timeout is 2 s).
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
# State lives in $STUB: loaded.at holds the time the plugin is listed from,
# reload.end the time the current reload ends, link.sig the link the watcher
# last saw. Knobs: DELAY (rescan lands after DELAY s; never: not at all),
# WATCHER (on|off), RELOAD (s), RESCAN (ok|timeout: rescan never answers).
cat > "$WORK/stub.sh" <<'EOF'
now() { date +%s.%N; }
calc() { awk "BEGIN { printf \"%.3f\", $1 }"; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
busy() { local e; e=$(cat "$STUB/reload.end" 2>/dev/null || echo 0); calc "($e > $(now)) ? $e - $(now) : 0"; }
visible() { [[ -f $STUB/loaded.at ]] && ge "$(now)" "$(cat "$STUB/loaded.at")"; }
LINK="$HOME/.config/omarchy/plugins/ridgetopai.amplify"
# The watcher (inotify on plugins/) fires on any new or replaced link.
if [[ $WATCHER == on ]]; then
  sig=$(stat -c '%i %z' "$LINK" 2>/dev/null)
  if [[ $sig != "$(cat "$STUB/link.sig" 2>/dev/null)" ]]; then
    echo "$sig" > "$STUB/link.sig"
    end=$(calc "$(now) + $RELOAD"); echo "$end" > "$STUB/reload.end"
    if [[ -L $LINK ]]; then echo "$end" > "$STUB/loaded.at"; else rm -f "$STUB/loaded.at"; fi
  fi
fi
EOF
cat > "$WORK/bin/omarchy-shell" <<'EOF'
#!/usr/bin/env bash
t=${OMARCHY_SHELL_IPC_TIMEOUT:-2s}
echo "omarchy-shell $* timeout=$t" >> "$STUB/calls"
. "$STUBLIB"
[[ "$1 $2" == "shell rescanPlugins" ]] || exit 0
b=$(busy)
# The scan runs after any reload in progress, whether or not the reply arrives.
[[ $DELAY != never ]] && calc "$(now) + $b + $DELAY" > "$STUB/loaded.at"
reply=$b
if [[ $WATCHER == on ]]; then calc "$(now) + $b + $RELOAD" > "$STUB/reload.end"; reply=$(calc "$b + $RELOAD"); fi
if [[ $RESCAN == timeout ]] || ! ge "${t%s}" "$reply"; then
  sleep "${t%s}"; echo "omarchy-shell is not responding" >&2; exit 1
fi
sleep "$reply"
EOF
cat > "$WORK/bin/omarchy" <<'EOF'
#!/usr/bin/env bash
echo "omarchy $*" >> "$STUB/calls"
. "$STUBLIB"
case "$1 $2" in
  "plugin validate") exit 0 ;;
  "plugin list")  # asks the shell (listPlugins) with the default 2 s timeout
    b=$(busy)
    if ! ge 2 "$b"; then sleep 2; echo "omarchy-shell is not responding" >&2; exit 1; fi
    sleep "$b"
    if visible; then json='[{"id":"ridgetopai.amplify","enabled":false}]'; else json='[]'; fi
    if [[ ${3:-} == --json ]]; then echo "$json"; else
      printf '%-32s %-9s\n' ID STATE
      jq -r '.[] | .id' <<<"$json" | while read -r id; do printf '%-32s %-9s\n' "$id" disabled; done
    fi ;;
  "plugin enable")
    if visible; then echo "enabled" >> "$STUB/result"; else
      echo "unknown" >> "$STUB/result"
      echo "omarchy-plugin-enable: plugin '$3' is not known; run: omarchy-shell shell rescanPlugins" >&2; exit 1
    fi ;;
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
# RESCAN pass through; a second run with the same name reuses its state.
run() {
  STUB="$WORK/$1"; mkdir -p "$STUB/home" "$STUB/tree"
  [[ -d $STUB/tree/tools ]] || cp -r "$ROOT/plugin" "$ROOT/shaders" "$ROOT/tools" "$STUB/tree/"
  : > "$STUB/calls"; rm -f "$STUB/result"
  out=$(STUB="$STUB" STUBLIB="$WORK/stub.sh" DELAY="$2" WATCHER="${WATCHER:-off}" RELOAD="${RELOAD:-2}" \
    RESCAN="${RESCAN:-ok}" HOME="$STUB/home" PATH="$WORK/bin:$PATH" QSB="$WORK/bin/qsb" \
    AMPLIFY_RESCAN_TIMEOUT="${3:-10}" "$STUB/tree/tools/install-plugin.sh" 2>&1); rc=$?
}
count() { grep -c -- "$1" "$STUB/calls"; }
lns() { grep -c '^ln .*ridgetopai.amplify' "$STUB/calls"; }
rescans() { count 'shell rescanPlugins'; }

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

# 3. Real Omarchy: the new link makes the watcher reload for 2 s and any
#    rescan times out. Install leaves the reload to the watcher and enables.
WATCHER=on RESCAN=timeout run reload never
[[ $rc == 0 ]] && pass "reload: install exits 0" || fail "reload: install exited $rc: $out"
[[ "$(cat "$STUB/result" 2>/dev/null)" == enabled && $(count 'plugin enable') == 1 ]] \
  && pass "reload: enable called once, after the reload" \
  || fail "reload: enable results were [$(tr '\n' ' ' 2>/dev/null < "$STUB/result")] (want: enabled)"
[[ $(rescans) == 0 ]] && pass "reload: no rescan on top of the watcher's reload" || fail "reload: rescanPlugins called $(rescans) time(s)"

# 4. Re-run with the link already in place: no ln, so no reload, and no rescan.
WATCHER=on RESCAN=timeout run reload never
[[ $rc == 0 ]] && pass "rerun: install exits 0" || fail "rerun: install exited $rc: $out"
[[ $(lns) == 0 ]] && pass "rerun: link left alone" || fail "rerun: ln called $(lns) time(s)"
[[ $(rescans) == 0 ]] && pass "rerun: no rescan" || fail "rerun: rescanPlugins called $(rescans) time(s)"

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

# 6. The stub's plain `plugin list` is a table, as Omarchy's is; only --json is JSON.
plain=$(STUB="$STUB" STUBLIB="$WORK/stub.sh" DELAY=1 WATCHER=off HOME="$STUB/home" "$WORK/bin/omarchy" plugin list)
[[ $plain == ID* ]] && ! jq -e . <<<"$plain" >/dev/null 2>&1 \
  && pass "stub: plain plugin list is a table" || fail "stub: plain plugin list was: $plain"

echo "test-install-plugin: $fails failed check(s)"
exit "$fails"
