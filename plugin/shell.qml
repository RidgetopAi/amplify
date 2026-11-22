import Quickshell

// Standalone entry for the fallback path: `quickshell -p plugin/`.
// omarchy-shell ignores this file and loads Service.qml from manifest.json.
ShellRoot {
  Service {}
}
