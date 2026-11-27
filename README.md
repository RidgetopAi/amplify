# Amplify

A live, Mandrel-driven desktop layer for Omarchy: session orbs, the Current river, the Meridian focus globe, panes, ambient light and the puck. It runs as the omarchy-shell service plugin `ridgetopai.amplify`.

## Install (one command)

```bash
omarchy plugin add https://github.com/RidgetopAi/amplify --enable
```

The repo root is the plugin. `manifest.json` points at `plugin/Service.qml`, and the compiled shaders and shared copies are committed, so `plugin add` needs no build step. Remove it with `omarchy plugin remove ridgetopai.amplify`, and update it with `omarchy plugin update ridgetopai.amplify`.

To work from a checkout instead, run `tools/install-plugin.sh`. It links `plugin/`, rebuilds the shaders (this needs `qt6-shadertools`) and enables the plugin. `tools/install-plugin.sh --remove` undoes it.

## Connect to Mandrel (optional)

Without a config file, Amplify runs in **demo mode**: it replays the bundled snapshot (`fixtures/amplify-snapshot.json`), and every view is captioned `REPLAYED SNAPSHOT`. To show your live Mandrel, write your user config:

```bash
~/.config/omarchy/plugins/ridgetopai.amplify/install/configure.sh https://you.mandrel.example
# paste your Mandrel viewer token at the hidden prompt
omarchy plugin disable ridgetopai.amplify && omarchy plugin enable ridgetopai.amplify
```

This writes `${XDG_CONFIG_HOME:-~/.config}/amplify/mandrel.env` with mode 600:

```sh
MANDREL_URL=https://you.mandrel.example
MANDREL_VIEWER_TOKEN=<viewer token>
```

- The file lives in your home directory. It is never in the repo or the installed plugin folder (a git clone), and `configure.sh` refuses to write it inside a git work tree. `mandrel.env` is also git-ignored. **Never commit a token.**
- `MANDREL_URL` or `MANDREL_VIEWER_TOKEN` set in omarchy-shell's environment overrides the matching file entry.
- If either value is missing, the file is missing or unreadable, or the token starts with `mdl_` (an MCP read-write token, not a viewer token), Amplify falls back to demo mode instead of failing.
- To go back to demo mode, run `install/configure.sh --demo`, which deletes the file.

The config is read once when the plugin starts, so restart the plugin after you change it.

## Check it

```bash
omarchy plugin list | grep amplify
journalctl --user -t omarchy-shell | grep amplify | tail
```

## Development

- `install/test.sh` checks the install contract: a root manifest that validates, `omarchy plugin add` run against a clone, config file reading, demo fallback and `configure.sh`. It uses fixture values and a throwaway HOME.
- `tools/test-install-plugin.sh` tests the checkout installer against stub Omarchy commands.
- `tools/sync-shared.sh` copies shared sources (for example `data/mandrel.js` and `data/SceneClock.qml`) into `plugin/`. Edit the source, never a copy.
- `tools/mutate.sh` runs the mutation catalogue in `tools/motion/mutations.json`.
- For the data layer, see `data/README.md`. For the plugin skeleton and the headless render proof, see `docs/spike/REPORT.md`.
