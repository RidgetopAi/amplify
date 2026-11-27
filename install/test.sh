#!/usr/bin/env bash
# Proof for task 45de8d89: one-command install, user config file, demo mode.
#
#   install/test.sh        # exit status = number of failed checks
#
# 1. The repo root is an Omarchy plugin: manifest.json there passes the checks
#    omarchy-plugin-validate makes (a stub mirroring them) and matches plugin/manifest.json.
# 2. `omarchy plugin add <url>` as Omarchy runs it (git clone, validate, move into
#    ~/.config/omarchy/plugins/<id>), against a git repo made from this tree, lands a
#    plugin whose entry point exists and whose shared copies match.
# 3. The installed data layer reads MANDREL_URL and MANDREL_VIEWER_TOKEN from the user's
#    ~/.config/amplify/mandrel.env (fixture values, never a real token), the environment
#    wins, and it replays (demo mode) without throwing when the file is missing, empty,
#    unreadable or holds an mdl_ token. A mandrel.env inside the repo or the installed
#    plugin is never read.
# 4. install/configure.sh writes that file (mode 600) outside any git work tree, and
#    mandrel.env is git-ignored and absent from the tree.
# Needs bash, git, jq, node. Uses a throwaway HOME; never touches the real one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
ID=ridgetopai.amplify
FAKE_TOKEN="vt_fixture-not-a-real-token"   # a fixture value; no real token is used here

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

# The checks omarchy-plugin-validate (basecamp/omarchy, quattro) makes, for a folder.
validate() {
  local d=$1 m=$1/manifest.json ep
  [[ -f $m ]] && jq -e . "$m" >/dev/null 2>&1 || { echo "validate: no valid manifest.json in $d"; return 1; }
  jq -e '.schemaVersion == 1 and has("id") and has("name") and has("version") and has("kinds") and has("entryPoints")
    and (.kinds | type == "array" and length > 0) and (.entryPoints | type == "object")
    and ((.kinds | index("service")) == null or (.entryPoints | has("service")))' "$m" >/dev/null \
    || { echo "validate: manifest fields"; return 1; }
  [[ $(jq -r .id "$m") =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $(jq -r .id "$m") != omarchy.* ]] || { echo "validate: id"; return 1; }
  while IFS= read -r ep; do
    [[ -n $ep && $ep != /* && $ep != *..* && -f $d/$ep ]] || { echo "validate: entry point '$ep'"; return 1; }
  done < <(jq -r '.entryPoints[]' "$m")
  local l; l=$(find "$d" -name .git -prune -o -type l -print -quit)
  [[ -z $l ]] || { echo "validate: symlinks are not allowed inside a plugin folder: $l"; return 1; }
}

# ---- 1. the repo root is the plugin
v=$(validate "$ROOT" 2>&1); check "root: manifest.json passes omarchy-plugin-validate's checks ($v)" test -z "$v"
check "root: manifest is plugin/manifest.json with entry points under plugin/" \
  test "$(jq -S '.entryPoints |= map_values("plugin/" + .)' "$ROOT/plugin/manifest.json")" == "$(jq -S . "$ROOT/manifest.json")"
check "root: service entry point is plugin/Service.qml" test "$(jq -r .entryPoints.service "$ROOT/manifest.json")" == plugin/Service.qml

# ---- 2. omarchy plugin add <url>, as bin/omarchy-plugin-add does it
SRC="$WORK/src"; mkdir -p "$SRC"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | grep -zv '^\.amp/' | tar --null -T - -cf -) | tar -xf - -C "$SRC"
else  # a scratch copy without .git (tools/mutate.sh)
  (cd "$ROOT" && tar --exclude=./.git --exclude=./.amp -cf - .) | tar -xf - -C "$SRC"
fi
git -C "$SRC" init -q && git -C "$SRC" add -A && git -C "$SRC" -c user.name=t -c user.email=t@t commit -qm src
check "never committed: no mandrel.env in the tree" test -z "$(cd "$SRC" && git ls-files | grep -E '(^|/)mandrel\.env$')"
for p in mandrel.env plugin/mandrel.env install/mandrel.env; do
  check "never committed: $p is git-ignored" git -C "$SRC" check-ignore -q "$p"
done
check "never committed: no token-shaped strings in install/, README.md, data/ or fixtures/" \
  test -z "$(grep -rlE 'mdl_[A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$SRC/install" "$SRC/README.md" "$SRC/data" "$SRC/fixtures" 2>/dev/null)"

export HOME="$WORK/home"; unset XDG_CONFIG_HOME MANDREL_URL MANDREL_VIEWER_TOKEN
PLUGINS="$HOME/.config/omarchy/plugins"; mkdir -p "$PLUGINS"
stage="$PLUGINS/.add.tmp.$$"
git clone -q -- "file://$SRC" "$stage" 2>/dev/null; check "add: git clone of the repo URL" test -d "$stage/.git"
v=$(validate "$stage" 2>&1); check "add: the clone validates ($v)" test -z "$v"
id=$(jq -r .id "$stage/manifest.json"); check "add: id is $ID" test "$id" == "$ID"
mv "$stage" "$PLUGINS/$id"; P="$PLUGINS/$id"
check "add: entry point exists in the installed plugin" test -f "$P/$(jq -r .entryPoints.service "$P/manifest.json")"
check "add: installed shared copies match their sources (no build step runs)" bash "$P/tools/sync-shared.sh" --check
check "add: committed shaders are present (no build step runs)" test -s "$P/plugin/river/river.frag.qsb"

# ---- 3. config file, environment, demo mode: the installed data layer, run from inside the plugin
cfg() { (cd "$P" && node -e 'const c = require("./data/node.cjs").config(); console.log([c.mode, String(c.baseUrl), c.token ? "token" : "-"].join(" "))' 2>&1); }
CF="$HOME/.config/amplify/mandrel.env"
out=$(cfg); check "demo: no config file, no env: replay ($out)" test "$out" == "replay null -"
mkdir -p "$(dirname "$CF")"
printf '# fixture\nexport MANDREL_URL="https://m.example/"\nMANDREL_VIEWER_TOKEN=%s  # comment\n' "$FAKE_TOKEN" > "$CF"
out=$(cfg); check "config: ~/.config/amplify/mandrel.env makes it live ($out)" test "$out" == "live https://m.example token"
out=$(cd "$P" && node -e 'console.log(require("./data/node.cjs").config().token)'); check "config: token read from the file" test "$out" == "$FAKE_TOKEN"
out=$(MANDREL_URL=https://env.example cfg); check "config: environment wins per variable ($out)" test "$out" == "live https://env.example token"
mv "$CF" "$WORK/cf"
mkdir -p "$WORK/xdg/amplify"; cp "$WORK/cf" "$WORK/xdg/amplify/mandrel.env"
out=$(XDG_CONFIG_HOME="$WORK/xdg" cfg); check "config: XDG_CONFIG_HOME/amplify/mandrel.env ($out)" test "$out" == "live https://m.example token"
rm -rf "$WORK/xdg"
# A config inside the repo or the installed plugin is never read.
for d in "$P" "$P/plugin" "$P/data" "$P/install"; do cp "$WORK/cf" "$d/mandrel.env"; done
out=$(cfg); check "repo: a mandrel.env inside the plugin clone is not read: replay ($out)" test "$out" == "replay null -"
out=$(cd "$P" && HOME="$P" node -e 'console.log(require("./data/node.cjs").M.configFilePath({HOME: process.env.HOME}))')
check "repo: config path is under the user's home, not a repo-relative path ($out)" test "$out" == "$P/.config/amplify/mandrel.env"
rm -f "$P/mandrel.env" "$P/plugin/mandrel.env" "$P/data/mandrel.env" "$P/install/mandrel.env"
printf 'MANDREL_URL=https://m.example\n' > "$CF"
out=$(cfg); check "demo: URL without token: replay ($out)" test "$out" == "replay https://m.example -"
printf 'MANDREL_URL=https://m.example\nMANDREL_VIEWER_TOKEN=mdl_fixture\n' > "$CF"
out=$(cfg); check "demo: mdl_ token in the file: replay ($out)" test "$out" == "replay https://m.example -"
: > "$CF"; out=$(cfg); check "demo: empty config file: replay ($out)" test "$out" == "replay null -"
rm "$CF"; mkdir "$CF"; out=$(cfg); check "demo: unreadable config (a directory): replay, no throw ($out)" test "$out" == "replay null -"
rmdir "$CF"
out=$(env -u HOME bash -c 'cd "$1" && node -e "const c = require(\"./data/node.cjs\").config(); console.log(c.mode)"' _ "$P" 2>&1)
check "demo: no HOME at all: replay ($out)" test "$out" == replay
# The QML scene clock (every copy) reads the same file through the same functions.
for c in "$P"/plugin/{basin,orbs,river}/SceneClock.qml; do
  check "qml: ${c#$P/} reads Mandrel.configFilePath and Mandrel.configFrom" \
    grep -q 'Mandrel.configFrom(env, configFile.path ? configFile.text() : "")' "$c"
done
if command -v quickshell >/dev/null; then
  Q="$WORK/qml"; mkdir -p "$Q"; cp "$P"/plugin/river/{SceneClock.qml,mandrel.js,amplify-snapshot.json} "$Q/"
  printf 'import Quickshell\nimport QtQuick\nShellRoot { SceneClock { id: c; refetchSec: 3600 }\n  Component.onCompleted: { console.log("probe: " + c.config.mode + " " + c.config.baseUrl); Qt.exit(0) } }\n' > "$Q/shell.qml"
  probe() { QT_QPA_PLATFORM=offscreen timeout 20 quickshell -p "$Q" 2>&1 | grep -ao 'probe: .*' | head -1; }
  out=$(probe); check "qml: no config file: replay ($out)" test "$out" == "probe: replay null"
  cp "$WORK/cf" "$CF"; out=$(probe); check "qml: config file: live ($out)" test "$out" == "probe: live https://m.example"; rm "$CF"
else
  echo "SKIP qml probe: quickshell not on PATH (the static check above still ran)"
fi

# ---- 4. install/configure.sh
C="$P/install/configure.sh"
out=$(printf '%s\n' "$FAKE_TOKEN" | bash "$C" https://m.example/ 2>&1); rc=$?
check "configure: writes the file from a piped token ($rc)" test "$rc" == 0 -a -f "$CF"
check "configure: file is mode 600" test "$(stat -c %a "$CF")" == 600
check "configure: the token never appears in its output" test "${out/$FAKE_TOKEN/}" == "$out"
out=$(cfg); check "configure: the data layer reads what it wrote ($out)" test "$out" == "live https://m.example token"
printf 'mdl_fixture\n' | bash "$C" https://m.example >/dev/null 2>&1; rc=$?
check "configure: refuses an mdl_ token ($rc)" test "$rc" != 0
check "configure: a refused token leaves the file as it was" grep -q "$FAKE_TOKEN" "$CF"
out=$(bash "$C" --demo 2>&1); check "configure: --demo removes the file" test ! -e "$CF"
out=$(cfg); check "configure: --demo is replay ($out)" test "$out" == "replay null -"
printf '%s\n' "$FAKE_TOKEN" | HOME="$P" bash "$C" https://m.example >/dev/null 2>&1; rc=$?
check "configure: refuses to write inside a git work tree ($rc)" test "$rc" != 0 -a ! -e "$P/.config/amplify/mandrel.env"

echo "install/test.sh: $fails failed check(s)"
exit "$fails"
