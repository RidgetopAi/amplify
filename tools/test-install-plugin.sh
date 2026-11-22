#!/usr/bin/env bash
# Test tools/install-plugin.sh against stub omarchy / omarchy-shell / qsb.
# The stub shell's rescanPlugins returns at once and the plugin only appears in
# `omarchy plugin list` after a delay, as on real Omarchy (rescan is async).
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
# State lives in $STUB: rescan.at holds the time of rescanPlugins; the plugin is
# listed once DELAY seconds have passed (DELAY=never: not at all).
cat > "$WORK/bin/omarchy-shell" <<'EOF'
#!/usr/bin/env bash
echo "omarchy-shell $*" >> "$STUB/calls"
[[ "$1 $2" == "shell rescanPlugins" ]] && date +%s.%N > "$STUB/rescan.at"
exit 0
EOF
cat > "$WORK/bin/omarchy" <<'EOF'
#!/usr/bin/env bash
echo "omarchy $*" >> "$STUB/calls"
visible() {
  [[ $DELAY != never && -f $STUB/rescan.at ]] || return 1
  awk -v a="$(cat "$STUB/rescan.at")" -v n="$(date +%s.%N)" -v d="$DELAY" 'BEGIN { exit !(n - a >= d) }'
}
case "$1 $2" in
  "plugin validate") exit 0 ;;
  "plugin list")
    if visible; then echo '[{"id":"ridgetopai.amplify","enabled":false}]'; else echo '[]'; fi ;;
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
chmod +x "$WORK/bin/"*

run() {  # run <name> <delay> [timeout] -> sets out, rc, STUB
  STUB="$WORK/$1"; mkdir -p "$STUB/home" "$STUB/tree"
  cp -r "$ROOT/plugin" "$ROOT/shaders" "$ROOT/tools" "$STUB/tree/"
  out=$(STUB="$STUB" DELAY="$2" HOME="$STUB/home" PATH="$WORK/bin:$PATH" QSB="$WORK/bin/qsb" \
    AMPLIFY_RESCAN_TIMEOUT="${3:-10}" "$STUB/tree/tools/install-plugin.sh" 2>&1); rc=$?
}

# 1. Plugin appears 1 s after the rescan: install waits, then enables once.
run delayed 1
[[ $rc == 0 ]] && pass "delayed: install exits 0" || fail "delayed: install exited $rc: $out"
[[ "$(cat "$STUB/result" 2>/dev/null)" == enabled ]] \
  && pass "delayed: enable called once, only after the plugin is listed" \
  || fail "delayed: enable results were [$(tr '\n' ' ' < "$STUB/result" 2>/dev/null)] (want: enabled)"
[[ -L $STUB/home/.config/omarchy/plugins/ridgetopai.amplify ]] && pass "delayed: plugin linked" || fail "delayed: plugin not linked"

# 2. Plugin never appears: install fails loudly and never calls enable.
run never never 1
[[ $rc != 0 ]] && pass "never: install exits non-zero ($rc)" || fail "never: install exited 0"
[[ $out == *"did not list ridgetopai.amplify"* ]] && pass "never: timeout message printed" || fail "never: no timeout message: $out"
[[ ! -s $STUB/result ]] && pass "never: enable not called" || fail "never: enable was called"

echo "test-install-plugin: $fails failed check(s)"
exit "$fails"
