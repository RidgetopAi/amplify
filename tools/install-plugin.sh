#!/usr/bin/env bash
# Install this checkout's plugin/ into omarchy-shell as the third-party
# service plugin "ridgetopai.amplify" (primary path; see docs/spike/REPORT.md).
#
#   tools/install-plugin.sh            # link, rescan, enable
#   tools/install-plugin.sh --remove   # disable and unlink
#
# `omarchy plugin add <url>` expects manifest.json at the repo root, which this
# repo does not have yet (plugin/ is a subdirectory), so the spike links the
# directory by hand as the Omarchy manual describes for local plugins.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID=ridgetopai.amplify
DEST="$HOME/.config/omarchy/plugins/$ID"

if [[ ${1:-} == --remove ]]; then
  omarchy plugin disable "$ID" || true
  [[ -L $DEST ]] && rm "$DEST"
  omarchy-shell shell rescanPlugins
  exit 0
fi

"$ROOT/tools/build-shaders.sh"
omarchy plugin validate "$ROOT/plugin"
mkdir -p "$(dirname "$DEST")"
[[ -e $DEST && ! -L $DEST ]] && { echo "install-plugin: $DEST exists and is not a link" >&2; exit 1; }
ln -sfn "$ROOT/plugin" "$DEST"
omarchy-shell shell rescanPlugins
omarchy plugin enable "$ID"
echo "install-plugin: enabled $ID; logs: journalctl --user -t omarchy-shell or ~/.local/state/quickshell"
