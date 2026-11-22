#!/usr/bin/env bash
# Install this checkout's plugin/ into omarchy-shell as the third-party
# service plugin "ridgetopai.amplify" (primary path; see docs/spike/REPORT.md).
#
#   tools/install-plugin.sh            # link, wait until listed, enable
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
    echo "install-plugin: rescanPlugins did not answer; waiting for the plugin list anyway" >&2
}

if [[ ${1:-} == --remove ]]; then
  omarchy plugin disable "$ID" || true
  [[ -L $DEST ]] && rm "$DEST"
  rescan
  exit 0
fi

"$ROOT/tools/build-shaders.sh"
omarchy plugin validate "$ROOT/plugin"
mkdir -p "$(dirname "$DEST")"
[[ -e $DEST && ! -L $DEST ]] && { echo "install-plugin: $DEST exists and is not a link" >&2; exit 1; }
rescanned=
if [[ $(readlink "$DEST") != "$ROOT/plugin" ]]; then
  ln -sfn "$ROOT/plugin" "$DEST"  # the watcher reloads; rescan only if it does not
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
omarchy plugin enable "$ID"
echo "install-plugin: enabled $ID; logs: journalctl --user -t omarchy-shell or ~/.local/state/quickshell"
