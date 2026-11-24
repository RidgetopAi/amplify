import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import "orbs"
import "river"
import "basin"

// Amplify service. Loaded two ways from the same file:
//  - inside omarchy-shell as a third-party `service` plugin (manifest.json),
//    where the host injects `shell` / `manifest` facades we do not need;
//  - standalone via `quickshell -p plugin/` (shell.qml), the fallback path.
// Only Quickshell/QtQuick imports are used (no qs.Commons), so both work.
Item {
  id: root

  // Injected by omarchy-shell when present; unused by the spike.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // The desktop layer. Bottom = above the wallpaper, below every window.
  readonly property int desktopLayer: WlrLayer.Bottom
  readonly property string layerName: desktopLayer === WlrLayer.Bottom ? "bottom"
    : desktopLayer === WlrLayer.Top ? "top"
    : desktopLayer === WlrLayer.Background ? "background" : "overlay"

  // env-read: AMPLIFY_THEME_DIR overrides the Omarchy current-theme dir (tests).
  readonly property string themeDir: Quickshell.env("AMPLIFY_THEME_DIR")
    || (Quickshell.env("HOME") + "/.local/state/omarchy/current/theme")
  // env-read: AMPLIFY_PROBE_URL, when set, is fetched once with XMLHttpRequest.
  readonly property string probeUrl: Quickshell.env("AMPLIFY_PROBE_URL") || ""
  // env-read: AMPLIFY_STILL=1 freezes shader time (deterministic screenshots).
  readonly property bool still: Quickshell.env("AMPLIFY_STILL") === "1"
  // env-read: AMPLIFY_FPS=1 logs frames per second per screen every 5 s.
  readonly property bool logFps: Quickshell.env("AMPLIFY_FPS") === "1"
  // env-read: AMPLIFY_TRACE=1 logs each moving item's drawn axes (tools/motion/follow.mjs).
  readonly property bool trace: Quickshell.env("AMPLIFY_TRACE") === "1"

  property color accent: "#89b4fa"
  property color foreground: "#cdd6f4"

  // omarchy-shell shell call ridgetopai.amplify refreshTheme ""
  function refreshTheme(arg) {
    if (!themeProc.running) themeProc.running = true
    return "ok"
  }

  function parseColors(text) {
    var out = {}
    var re = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/gm, m
    while ((m = re.exec(text)) !== null) out[m[1]] = m[2]
    if (out.accent) accent = out.accent
    if (out.foreground) foreground = out.foreground
    console.log("amplify: palette accent=" + accent + " foreground=" + foreground)
  }

  // Process: read the theme palette out of process (proves Process works
  // for a third-party plugin; data reads later go through the same path).
  Process {
    id: themeProc
    command: ["cat", root.themeDir + "/colors.toml"]
    stdout: StdioCollector { onStreamFinished: root.parseColors(this.text) }
  }

  // Re-read when Omarchy swaps the theme (omarchy-theme-set rewrites the dir).
  FileView {
    path: root.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshTheme("")
  }

  // Standalone: `quickshell ipc -p plugin/ call amplify refreshTheme ""`.
  // Inside omarchy-shell: `omarchy-shell amplify refreshTheme ""`.
  IpcHandler {
    target: "amplify"
    function refreshTheme(arg: string): string { return root.refreshTheme(arg) }
  }

  // "shader=<all> orbs=<compiled>/<programs> river=… basin=…" over every drawn
  // ShaderEffect (per .qsb program), then the logs of failed ones. A program
  // that fails to load reports Error on every effect that uses it. Qt 6 reports
  // Compiled only for a program one effect uses: effects sharing a program stay
  // Uncompiled while they draw, so a shared program counts as compiled unless
  // one of its effects reports Error. shader=compiled only when all compiled.
  function shaderReport(groups) {
    var all = "compiled", parts = [], logs = []
    for (var g in groups) {
      var progs = {}, n = 0, ok = 0
      for (var i = 0; i < groups[g].length; i++) {
        var fx = groups[g][i], url = fx.fragmentShader.toString()
        if (!progs[url]) { progs[url] = { uses: 0, error: false, compiled: false }; n++ }
        progs[url].uses++
        if (fx.status === ShaderEffect.Error) { progs[url].error = true; if (fx.log) logs.push(g + ": " + fx.log) }
        if (fx.status === ShaderEffect.Compiled) progs[url].compiled = true
      }
      for (var u in progs) {
        var p = progs[u]
        if (p.error) all = "error"
        else if (p.compiled || p.uses > 1) ok++
        else if (all !== "error") all = "uncompiled"
      }
      parts.push(g + "=" + ok + "/" + n)
    }
    return "shader=" + all + " " + parts.join(" ") + (logs.length ? " " + logs.join(" ") : "")
  }

  function probe() {
    if (!probeUrl) return
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState === XMLHttpRequest.DONE)
        console.log("amplify: xhr " + probeUrl + " status=" + xhr.status + " bytes=" + xhr.responseText.length)
    }
    xhr.open("GET", probeUrl)
    xhr.send()
  }

  Component.onCompleted: {
    refreshTheme("")
    probe()
  }

  OrbsLayer { id: orbsLayer; accent: root.accent; foreground: root.foreground; animate: !root.still; trace: root.trace }
  BasinFeed { id: basinFeed }

  Variants {
    id: windows
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData

      screen: modelData
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "amplify"
      WlrLayershell.layer: root.desktopLayer
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Only the basin's rows take input here (the orbs have their own layer);
      // everything else falls through to the wallpaper layer and the desktop's
      // own click handling.
      mask: Region { item: basin.hitItem }

      River { id: river; anchors.fill: parent; animate: !root.still; trace: root.trace }

      Basin {
        id: basin
        feed: basinFeed
        animate: !root.still
        trace: root.trace
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 28; bottomMargin: 30 }
      }

      FrameAnimation {
        id: frames
        running: root.logFps
        property int count: 0
        onTriggered: count++
      }
      Timer {
        interval: 5000; repeat: true; running: root.logFps
        onTriggered: {
          console.log("amplify: fps screen=" + win.modelData.name + " " + (frames.count / 5).toFixed(1))
          frames.count = 0
        }
      }

      Timer {
        interval: 1500; running: true
        onTriggered: console.log("amplify: ready layer=" + root.layerName
          + " screen=" + win.modelData.name + " size=" + win.width + "x" + win.height + " "
          + root.shaderReport({ orbs: orbsLayer.shaders(), river: river.shaders(), basin: basin.shaders() }))
      }
    }
  }
}
