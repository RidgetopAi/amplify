#!/usr/bin/env bash
# Write the user's Amplify config, ${XDG_CONFIG_HOME:-~/.config}/amplify/mandrel.env (task
# 45de8d89), which the plugin reads at start (data/mandrel.js configFilePath). The file is
# the user's own, mode 600, and never inside the repo or the installed plugin folder, so a
# token is never committed. Without it the plugin replays its snapshot (demo mode).
#
#   install/configure.sh [MANDREL_URL]   # asks for the URL (unless given) and the viewer token
#   install/configure.sh --demo          # delete the file: demo/replay mode
#
# The token is read from the terminal without echo, or from stdin when stdin is not a
# terminal; it never goes on the command line. Then pick it up with:
#   omarchy plugin disable ridgetopai.amplify && omarchy plugin enable ridgetopai.amplify
set -euo pipefail

# env-read: XDG_CONFIG_HOME, HOME locate the config file, as data/mandrel.js configFilePath does.
if [[ ${XDG_CONFIG_HOME:-} == /* ]]; then DIR="${XDG_CONFIG_HOME%/}/amplify"
elif [[ ${HOME:-} == /* ]]; then DIR="${HOME%/}/.config/amplify"
else echo "configure: neither XDG_CONFIG_HOME nor HOME is an absolute path" >&2; exit 2
fi
FILE="$DIR/mandrel.env"

if [[ ${1:-} == --demo ]]; then
  rm -f "$FILE"
  echo "configure: removed $FILE; Amplify replays its snapshot (demo mode)"
  exit 0
fi

# Refuse to write into a git work tree (a checkout or the installed plugin clone).
mkdir -p "$DIR"
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "configure: $DIR is inside a git work tree; refusing to write a token there" >&2; exit 1
fi

url=${1:-}
if [[ -z $url ]]; then read -rp "MANDREL_URL (e.g. https://you.mandrel.example): " url; fi
while [[ $url == */ ]]; do url=${url%/}; done
[[ $url =~ ^https?://[^[:space:]]+$ ]] || { echo "configure: MANDREL_URL must be an http(s) URL" >&2; exit 2; }
if [[ -t 0 ]]; then read -rsp "MANDREL_VIEWER_TOKEN (not shown): " token; echo
else IFS= read -r token || true
fi
token=${token//[[:space:]]/}
[[ -n $token ]] || { echo "configure: no token given" >&2; exit 2; }
[[ $token != mdl_* ]] || { echo "configure: mdl_ tokens are MCP read-write tokens; use a Mandrel viewer token" >&2; exit 2; }

umask 077
tmp=$(mktemp "$DIR/.mandrel.env.XXXXXX")
printf '# Amplify config (install/configure.sh). Never commit this file.\nMANDREL_URL=%s\nMANDREL_VIEWER_TOKEN=%s\n' "$url" "$token" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$FILE"
echo "configure: wrote $FILE (mode 600); restart the plugin: omarchy plugin disable ridgetopai.amplify && omarchy plugin enable ridgetopai.amplify"
