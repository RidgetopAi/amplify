#!/usr/bin/env bash
# Install this checkout's plugin/ into omarchy-shell as the third-party
# service plugin "ridgetopai.amplify" (primary path; see docs/spike/REPORT.md).
#
#   tools/install-plugin.sh            # link, wait out the reload, wait until listed, enable
#   tools/install-plugin.sh --remove   # disable and unlink
#
# `omarchy plugin add <url>` expects manifest.json at the repo root, which this
# repo does not have yet (plugin/ is a subdirectory), so the spike links the
# directory by hand as the Omarchy manual describes for local plugins.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID=ridgetopai.amplify
DEST="$HOME/.config/omarchy/plugins/$ID"

listed() { omarchy plugin list --json 2>/dev/null | jq -e --arg id "$ID" 'any(.[]; .id == $id)' >/dev/null; }

# Omarchy's plugin watcher reloads every plugin when a link under plugins/
# changes, blocking the shell for about 2 s. A rescanPlugins sent meanwhile
# starts a second reload and misses omarchy-shell's default 2 s IPC timeout
# ("not responding", although the scan still runs), so rescan only when the
# watcher did not, give it longer, and let the plugin list poll decide.
rescan() {
  OMARCHY_SHELL_IPC_TIMEOUT=10s omarchy-shell shell rescanPlugins ||
    echo "install-plugin: rescanPlugins did not answer; the scan may still run" >&2
}

# After a link change the watcher waits 150 ms, then reloads every plugin,
# freezing IPC for about 2 s; until the reload ends the list still shows the
# old entry and an enable can be lost or time out. Ping until a slow reply (the
# freeze) is followed by a quick one, or until 2 s of quick replies show no
# reload is coming; give up after 15 s.
# EPOCHREALTIME uses the locale's decimal point ("1795325007,733322" in
# de_DE), so keep only the digits and read them as base 10.
ms() { local t=${EPOCHREALTIME//[!0-9]/}; echo $(( 10#$t / 1000 )); }
settle() {
  local start t slow=
  start=$(ms)
  sleep 0.2
  while (( $(ms) - start < 15000 )); do
    t=$(ms)
    OMARCHY_SHELL_IPC_TIMEOUT=10s omarchy-shell shell ping >/dev/null 2>&1 || true
    if (( $(ms) - t >= 500 )); then slow=1
    elif [[ -n $slow ]] || (( $(ms) - start >= 2000 )); then return 0
    fi
    sleep 0.1
  done
  echo "install-plugin: omarchy-shell still busy 15 s after the link changed; enabling anyway" >&2
}

# A 10 s IPC timeout outlasts a reload still finishing. "not responding" means
# the call may not have run, so retry it once.
enable() {
  local out
  if out=$(OMARCHY_SHELL_IPC_TIMEOUT=10s omarchy plugin enable "$ID" 2>&1); then echo "$out"; return 0; fi
  [[ $out == *"not responding"* ]] || { echo "$out" >&2; return 1; }
  echo "install-plugin: enable did not answer; retrying once" >&2
  OMARCHY_SHELL_IPC_TIMEOUT=10s omarchy plugin enable "$ID"
}

if [[ ${1:-} == --remove ]]; then
  omarchy plugin disable "$ID" || true
  [[ -L $DEST ]] && rm "$DEST"
  rescan
  exit 0
fi

# omarchy plugin validate rejects symlinks inside a plugin folder, so plugin/ holds
# real copies of the files it shares with data/, fixtures/ and plugin/shaders
# (tools/sync-shared.sh); refuse to install a copy that drifted or became a link.
# Check before the shader build, which rewrites plugin/river/river.frag.qsb.
"$ROOT/tools/sync-shared.sh" --check
"$ROOT/tools/build-shaders.sh"
omarchy plugin validate "$ROOT/plugin"
mkdir -p "$(dirname "$DEST")"
[[ -e $DEST && ! -L $DEST ]] && { echo "install-plugin: $DEST exists and is not a link" >&2; exit 1; }
rescanned=
if [[ $(readlink "$DEST") != "$ROOT/plugin" ]]; then
  ln -sfn "$ROOT/plugin" "$DEST"  # the watcher reloads; rescan only if it does not
  settle
elif ! listed; then
  rescan; rescanned=1
fi

# A scan returns before it lands, and an enable before then answers "unknown".
# Wait until the shell lists the plugin; halfway, rescan if nothing has yet.
# env-read: AMPLIFY_RESCAN_TIMEOUT overrides the 10 s wait (in 0.2 s steps).
tries=$(( ${AMPLIFY_RESCAN_TIMEOUT:-10} * 5 ))
half=$(( tries / 2 ))
until listed; do
  (( --tries > 0 )) || { echo "install-plugin: omarchy-shell did not list $ID within ${AMPLIFY_RESCAN_TIMEOUT:-10} s; check: journalctl --user -b | grep -i plugin" >&2; exit 1; }
  if [[ -z $rescanned ]] && (( tries <= half )); then rescan; rescanned=1; fi
  sleep 0.2
done
enable
echo "install-plugin: enabled $ID; logs: journalctl --user -t omarchy-shell or ~/.local/state/quickshell"
