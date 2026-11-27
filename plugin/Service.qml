import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import "orbs"
import "river"
import "basin"
import "panes"
import "ambient"
import "focus"
import "basin" as Shared   // SceneClock.qml: one copy per component dir (tools/sync-shared.sh), named here once

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

  // The one scene clock (task 679fbbc5, decision cfce981b): orbs, every screen's river and the
  // basin are built from its scene time and draw its caption, in replay and live.
  // Its id must not be `sceneClock`: inside OrbsLayer, BasinFeed and River that name resolves
  // to their own sceneClock property (null), and each screen's river made its own clock and,
  // live, its own fetch (defect a5d1ffa7).
  Shared.SceneClock { id: sharedClock }
  // The ambient music field (task 523461dd): its own layer, made first so it sits below the others.
  AmbientLayer { sceneClock: sharedClock; accent: root.accent; animate: !root.still; trace: root.trace; logFps: root.logFps }
  OrbsLayer { id: orbsLayer; sceneClock: sharedClock; accent: root.accent; foreground: root.foreground; animate: !root.still; trace: root.trace; logFps: root.logFps
              focusOnClick: true; onFocusRequested: (f, id, x, y, r, scr) => focusLayer.open(f, id, x, y, r, scr) }
  // The focused orb (task 85ff482a): a clicked orb flies to the centre as Meridian; no window until then.
  FocusLayer { id: focusLayer; accent: root.accent; foreground: root.foreground; animate: !root.still; trace: root.trace; logFps: root.logFps }
  BasinFeed { id: basinFeed; sceneClock: sharedClock }

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

      // Only the basin's rows and the panes take input here (the orbs have their own layer);
      // everything else falls through to the wallpaper layer and the desktop's
      // own click handling.
      mask: Region { item: basin.hitItem; Region { item: panes } }

      River { id: river; anchors.fill: parent; sceneClock: sharedClock; screenName: win.modelData.name; animate: !root.still; trace: root.trace }

      Basin {
        id: basin
        feed: basinFeed
        screenName: win.modelData.name
        animate: !root.still
        trace: root.trace
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 28; bottomMargin: 30 }
      }

      // The panes (task bc45ee1d): stats, latest records, project switcher and links, above the basin.
      Panes {
        id: panes
        feed: basinFeed
        screenName: win.modelData.name
        width: Math.min(640, win.width / 2 - 56)
        anchors { right: parent.right; top: parent.top; rightMargin: 28; topMargin: 76 }
      }

      // Counts the frames this window swaps (a FrameAnimation here would itself draw every frame).
      // With the river's water clock steps per second, so a frame drawn between steps shows (task aa5e593d),
      // and the window's measured length in ms, as OrbsLayer logs it (task 85e35a5d).
      property int swapped: 0
      property int stepsAt: 0
      property real windowAt: Date.now()
      Connections {
        target: win.contentItem.Window.window
        enabled: root.logFps
        function onFrameSwapped() { win.swapped++ }
      }
      Timer {
        interval: 5000; repeat: true; running: root.logFps
        onTriggered: {
          var t = Date.now()
          console.log("amplify: fps window=amplify screen=" + win.modelData.name + " " + (win.swapped / 5).toFixed(1)
                      + " steps=" + ((river.steps - win.stepsAt) / 5).toFixed(1) + " ms=" + Math.round(t - win.windowAt))
          win.swapped = 0; win.stepsAt = river.steps; win.windowAt = t
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
      // Traced, after this screen's ready or rendered line that is no longer pending: one
      // "amplify: program" line per program each group draws on this screen, with its status
      // and the centre of every effect drawing it, in screen pixels, so tools/headless-shot.sh
      // can check each orbs program by name and where it draws (task 4131a23d).
      function logPrograms() {
        if (!root.trace) return
        var st = root.programs(), orbs = orbsLayer.windows().filter(function (w) { return w.modelData === win.modelData })
        var groups = { orbs: orbs.length ? orbs[0].shaders() : [], river: river.shaders(), basin: basin.shaders() }
        for (var g in groups) {
          var at = {}, urls = []
          for (var i = 0; i < groups[g].length; i++) {
            var fx = groups[g][i], url = fx.fragmentShader.toString(), c = fx.mapToItem(null, fx.width / 2, fx.height / 2)
            if (!at[url]) { at[url] = []; urls.push(url) }
            at[url].push(Math.round(c.x) + "," + Math.round(c.y))
          }
          for (var j = 0; j < urls.length; j++)
            console.log("amplify: program screen=" + win.modelData.name + " " + g + " " + urls[j].split("/").pop()
                        + " " + st[urls[j]] + " at " + at[urls[j]].join(" "))
        }
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
          win.logPrograms()
        }
      }
      Timer {
        interval: root.readyMs; running: true
        onTriggered: {
          var line = win.report("ready")
          win.waiting = line.indexOf("shader=pending") >= 0
          console.log(line)
          if (!win.waiting) win.logPrograms()
        }
      }
    }
  }
}
