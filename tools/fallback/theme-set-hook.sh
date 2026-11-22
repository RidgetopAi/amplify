#!/usr/bin/env bash
# ~/.config/omarchy/hooks/theme-set.d/amplify — run by `omarchy-hook theme-set`
# after a theme switch. The service already watches colors.toml with FileView;
# this hook is the belt-and-braces path for the standalone fallback, where a
# theme swap that replaces the directory can drop the file watch.
quickshell ipc -p "${AMPLIFY_PLUGIN_DIR:-$HOME/.local/share/amplify/plugin}" call amplify refreshTheme "" 2>/dev/null \
  || systemctl --user try-restart amplify.service
