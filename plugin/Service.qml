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
  // env-read: AMPLIFY_FPS=1 logs the frames each window swapped per second, every 5 s.
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

  // env-read: AMPLIFY_READY_MS sets when each screen's ready line is logged (default 1500 ms;
  // tools/headless-shot.sh uses 0 to log it before the first frame, so it must read pending).
  readonly property int readyMs: Number(Quickshell.env("AMPLIFY_READY_MS") || 1500)

  // Each program's (.qsb URL's) status over every effect that uses it, on any screen
  // (task f0e14f4c). Qt loads a program synchronously when an effect first uses it and
  // caches it per URL for the whole process: only that first effect reports Compiled (or
  // Error), and every later one, on this screen or another, stays Uncompiled while it
  // draws. A program that fails is not cached, so every effect using it reports Error. So:
  // error if any effect reports Error; compiled if one reports Compiled or sits in a
  // window that has drawn a frame with RHI shaders (it was drawn from the cache: the
  // effect that first loaded it may since be gone); otherwise pending.
  function programs() {
    var st = {}, wins = orbsLayer.windows().concat(windows.instances)
    for (var w = 0; w < wins.length; w++) {
      var fx = wins[w].shaders()
      for (var i = 0; i < fx.length; i++) {
        var url = fx[i].fragmentShader.toString(), s = fx[i].status
        if (s === ShaderEffect.Error) st[url] = "error"
        else if (st[url] === "error") continue
        else if (s === ShaderEffect.Compiled || wins[w].drawn) st[url] = "compiled"
        else if (!st[url]) st[url] = "pending"
      }
    }
    return st
  }

  // "shader=<all> orbs=<compiled>/<programs> river=… basin=… [pending=<n>]" over the drawn
  // effects of each group, then the logs of failed ones. rendered[g] is false while a
  // window group g draws in has not drawn a frame: its programs are pending then, never
  // compiled, whatever Qt reports. shader=error if any program failed, else pending if any
  // is pending, else compiled.
  function shaderReport(groups, rendered) {
    var st = programs(), all = "compiled", parts = [], logs = [], pending = 0
    for (var g in groups) {
      var seen = {}, n = 0, ok = 0
      for (var i = 0; i < groups[g].length; i++) {
        var fx = groups[g][i], url = fx.fragmentShader.toString()
        if (fx.status === ShaderEffect.Error && fx.log) logs.push(g + ": " + fx.log)
        if (seen[url]) continue
        seen[url] = true; n++
        var s = st[url] === "compiled" && !rendered[g] ? "pending" : st[url]
        if (s === "error") all = "error"
        else if (s === "compiled") ok++
        else { pending++; if (all !== "error") all = "pending" }
      }
      parts.push(g + "=" + ok + "/" + n)
    }
    return "shader=" + all + " " + parts.join(" ") + (pending ? " pending=" + pending : "")
      + (logs.length ? " " + logs.join(" ") : "")
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

  OrbsLayer { id: orbsLayer; accent: root.accent; foreground: root.foreground; animate: !root.still; trace: root.trace; logFps: root.logFps }
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

      // Counts the frames this window swaps (a FrameAnimation here would itself draw every frame).
      property int swapped: 0
      Connections {
        target: win.contentItem.Window.window
        enabled: root.logFps
        function onFrameSwapped() { win.swapped++ }
      }
      Timer {
        interval: 5000; repeat: true; running: root.logFps
        onTriggered: {
          console.log("amplify: fps window=amplify screen=" + win.modelData.name + " " + (win.swapped / 5).toFixed(1))
          win.swapped = 0
        }
      }

      // The ready line, after readyMs; when it reads pending, an "amplify: rendered" line
      // follows at the first frame after which nothing is pending any more.
      function shaders() { return river.shaders().concat(basin.shaders()) }
      // drawn: this window has shown a frame with RHI shaders (software rendering never does).
      property bool drawn: false
      property bool waiting: false
      function report(what) {
        return "amplify: " + what + " layer=" + root.layerName + " screen=" + win.modelData.name
          + " size=" + win.width + "x" + win.height + " "
          + root.shaderReport({ orbs: orbsLayer.shaders(), river: river.shaders(), basin: basin.shaders() },
                              { orbs: orbsLayer.windows().every(function (w) { return w.drawn }), river: win.drawn, basin: win.drawn })
      }
      Connections {
        target: win.contentItem.Window.window
        enabled: !win.drawn || win.waiting
        function onFrameSwapped() {
          win.drawn = river.GraphicsInfo.shaderType === GraphicsInfo.RhiShader
          if (!win.waiting) return
          var line = win.report("rendered")
          if (line.indexOf("shader=pending") >= 0) return
          win.waiting = false
          console.log(line)
        }
      }
      Timer {
        interval: root.readyMs; running: true
        onTriggered: {
          var line = win.report("ready")
          win.waiting = line.indexOf("shader=pending") >= 0
          console.log(line)
        }
      }
    }
  }
}
