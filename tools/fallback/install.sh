#!/usr/bin/env bash
# Install the fallback host: a systemd user unit running `quickshell -p plugin/`
# plus an Omarchy theme-set hook. Use only if the plugin path
# (tools/install-plugin.sh) does not work; do not run both at once.
#
#   tools/fallback/install.sh            # install and start
#   tools/fallback/install.sh --remove   # stop and remove
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UNIT="$HOME/.config/systemd/user/amplify.service"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/amplify"

if [[ ${1:-} == --remove ]]; then
  systemctl --user disable --now amplify.service || true
  rm -f "$UNIT" "$HOOK"
  systemctl --user daemon-reload
  exit 0
fi

"$ROOT/tools/build-shaders.sh"
mkdir -p "$(dirname "$UNIT")" "$(dirname "$HOOK")"
sed "s|@AMPLIFY_PLUGIN_DIR@|$ROOT/plugin|; s|/usr/bin/quickshell|$(command -v quickshell)|" \
  "$ROOT/tools/fallback/amplify.service" > "$UNIT"
sed "s|\${AMPLIFY_PLUGIN_DIR:-\$HOME/.local/share/amplify/plugin}|$ROOT/plugin|" \
  "$ROOT/tools/fallback/theme-set-hook.sh" > "$HOOK"
chmod +x "$HOOK"
systemctl --user daemon-reload
systemctl --user enable --now amplify.service
echo "fallback: amplify.service running; hook at $HOOK"
