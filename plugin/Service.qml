import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import "river/river.js" as RiverJs
import "perf/perf.js" as Perf
import "orbs"
import "river"
import "basin"
import "panes"
import "ambient"
import "puck"
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

  // Where the river's water flows (task 56f55903, decision 17ee105d): only on the focused
  // monitor, and not while a window covers it (perf.js, as AmbientLayer.qml pauses); every other
  // river holds its last step, still, until focus comes to its screen.
  // env-read: HYPRLAND_INSTANCE_SIGNATURE: under Hyprland, its focused monitor; tiled windows on a screen's shown workspace cover it.
  readonly property bool hypr: (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== ""
  // env-read: AMPLIFY_FOCUS_FIXTURE names a file holding the focused screen's name, re-read when it
  // changes; it stands in for Hyprland's focus (tests run under sway).
  readonly property string focusFixture: Quickshell.env("AMPLIFY_FOCUS_FIXTURE") || ""
  property string fixtureFocus: ""
  FileView {
    path: root.focusFixture
    blockLoading: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.fixtureFocus = text().trim()
  }
  // The focused screen's name; "" when nothing says (no Hyprland, no fixture): every river flows.
  readonly property string focusedScreen: focusFixture ? fixtureFocus
    : hypr && Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
  // Every window as a plain object for perf.js screenState.
  readonly property var tops: ToplevelManager.toplevels.values.map(function (t) {
    return { fullscreen: t.fullscreen, maximized: t.maximized, minimized: t.minimized,
             screens: t.screens.map(function (s) { return s.name }) }
  })

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
    var st = {}, wins = orbsLayer.windows().concat(rivers.instances, windows.instances)
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
  // It leaves the basin's column dark (Basin.qml width 500, its right margin 28 below, and a 24 px gap).
  AmbientLayer { sceneClock: sharedClock; accent: root.accent; animate: !root.still; trace: root.trace; logFps: root.logFps
                 clearRight: 28 + 500 + 24 }
  OrbsLayer { id: orbsLayer; sceneClock: sharedClock; accent: root.accent; foreground: root.foreground; animate: !root.still; trace: root.trace; logFps: root.logFps
              focusOnClick: true; onFocusRequested: (f, id, x, y, r, scr) => focusLayer.open(f, id, x, y, r, scr) }
  // The focused orb (task 85ff482a): a clicked orb flies to the centre as Meridian; no window until then.
  FocusLayer { id: focusLayer; accent: root.accent; foreground: root.foreground; animate: !root.still; trace: root.trace; logFps: root.logFps }
  BasinFeed { id: basinFeed; sceneClock: sharedClock }
  // Puck (task 23a62966): his own small window per screen, lower left.
  PuckLayer { sceneClock: sharedClock; animate: !root.still; trace: root.trace; logFps: root.logFps }

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

      // This screen's river window (above), and the river drawn there.
      readonly property var rw: rivers.instances.filter(function (w) { return w.modelData === win.modelData })[0] || null
      readonly property var river: rw ? rw.current : null

      // The still water around the river's strip (task 56f55903): the river's own program with its
      // light and gates, clipped to the rows above and below the strip. Outside the band the water
      // does not depend on phase, so it meets the strip seamlessly and never redraws a water step.
      Repeater {
        id: stillWater
        model: win.rw ? [[0, win.rw.stripTop], [win.rw.stripTop + win.rw.height, win.height]] : []
        Item {
          required property var modelData
          y: modelData[0]; width: win.width; height: Math.max(0, modelData[1] - modelData[0]); clip: true
          ShaderEffect {
            readonly property var rv: win.river
            y: -parent.y; width: win.width; height: win.height
            property real phase: 0
            property real light: rv && rv.lay ? rv.lay.light : 0.55
            property real flow: rv && rv.lay ? rv.lay.flow : 0
            property size size: Qt.size(rv ? rv.dw : 1920, 1080)
            property vector4d g0: rv ? Qt.vector4d(rv.gateX(0), rv.gateX(1), rv.gateX(2), rv.gateX(3)) : Qt.vector4d(0, 0, 0, 0)
            property vector4d g1: rv ? Qt.vector4d(rv.gateX(4), rv.gateX(5), rv.gateX(6), 0) : Qt.vector4d(0, 0, 0, 0)
            fragmentShader: Qt.resolvedUrl("river/river.frag.qsb")
          }
        }
      }
      function stillShaders() {
        var out = []
        for (var i = 0; i < stillWater.count; i++) if (stillWater.itemAt(i)) out.push(stillWater.itemAt(i).children[0])
        return out
      }
      // The river's caption (River.qml, drawCaption false there), above its strip, drawn as it draws it.
      Item {
        width: win.river ? win.river.dw : 0; height: 1080
        scale: win.river ? win.river.k : 1; transformOrigin: Item.TopLeft
        Text {
          visible: text !== ""
          anchors.horizontalCenter: parent.horizontalCenter
          y: 40
          text: win.river && win.river.feed ? win.river.feed.caption : ""
          color: "#7d8799"
          font { family: "JetBrains Mono, DejaVu Sans Mono, monospace"; pixelSize: 11; letterSpacing: 1.6 }
        }
      }

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
      // and the window's measured length in ms, as OrbsLayer logs it (task 85e35a5d). The river draws in
      // its own window now (task 56f55903): its steps here should swap no frame of this one.
      readonly property int riverSteps: win.river ? win.river.steps : 0
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
                      + " steps=" + ((win.riverSteps - win.stepsAt) / 5).toFixed(1) + " ms=" + Math.round(t - win.windowAt))
          win.swapped = 0; win.stepsAt = win.riverSteps; win.windowAt = t
        }
      }

      // The ready line, after readyMs; when it reads pending, an "amplify: rendered" line
      // follows at the first frame after which nothing is pending any more.
      function shaders() { return win.stillShaders().concat(basin.shaders()) }
      // The river's programs on this screen: its strip window's and the still water here.
      function riverShaders() { return (win.rw ? win.rw.shaders() : []).concat(win.stillShaders()) }
      // drawn: this window has shown a frame with RHI shaders (software rendering never does).
      property bool drawn: false
      property bool waiting: false
      function report(what) {
        return "amplify: " + what + " layer=" + root.layerName + " screen=" + win.modelData.name
          + " size=" + win.width + "x" + win.height + " "
          + root.shaderReport({ orbs: orbsLayer.shaders(), river: win.riverShaders(), basin: basin.shaders() },
                              { orbs: orbsLayer.windows().every(function (w) { return w.drawn }),
                                river: win.drawn && !!win.rw && win.rw.drawn, basin: win.drawn })
      }
      // Traced, after this screen's ready or rendered line that is no longer pending: one
      // "amplify: program" line per program each group draws on this screen, with its status
      // and the centre of every effect drawing it, in screen pixels, so tools/headless-shot.sh
      // can check each orbs program by name and where it draws (task 4131a23d).
      function logPrograms() {
        if (!root.trace) return
        var st = root.programs(), orbs = orbsLayer.windows().filter(function (w) { return w.modelData === win.modelData })
        var groups = { orbs: orbs.length ? orbs[0].shaders() : [], river: win.riverShaders(), basin: basin.shaders() }
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
        id: rendered
        target: win.contentItem.Window.window
        enabled: !win.drawn || win.waiting
        function onFrameSwapped() {
          win.drawn = basin.GraphicsInfo.shaderType === GraphicsInfo.RhiShader
          if (!win.waiting) return
          var line = win.report("rendered")
          if (line.indexOf("shader=pending") >= 0) return
          win.waiting = false
          console.log(line)
          win.logPrograms()
        }
      }
      // The river window's frames may come after this window's last one (it swaps none idle).
      Connections {
        target: win.rw ? win.rw.contentItem.Window.window : null
        enabled: win.waiting
        function onFrameSwapped() { rendered.onFrameSwapped() }
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

  // The river (task 56f55903): its own window per screen, only the strip it draws in
  // (river.js STRIP_TOP..STRIP_BOTTOM, scaled as River scales its 1080 rows), no input, under
  // the main window: made after it, since a later window on the same layer sits lower. A water
  // step re-renders this strip alone; the main window, with the basin and panes, draws the
  // still water around it and swaps no frame while the data holds.
  Variants {
    id: rivers
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData

      screen: modelData
      color: "transparent"
      readonly property int stripTop: Math.floor(RiverJs.STRIP_TOP * win.modelData.height / 1080)
      anchors { top: true; left: true; right: true }
      margins.top: stripTop
      implicitHeight: Math.max(1, Math.ceil(RiverJs.STRIP_BOTTOM * win.modelData.height / 1080) - stripTop)
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "amplify-river"
      WlrLayershell.layer: root.desktopLayer
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}

      // The whole screen's river, shifted up so the strip shows its rows where they were.
      Item {
        y: -win.stripTop; width: win.width; height: win.modelData.height
        River { id: river; anchors.fill: parent; sceneClock: sharedClock; screenName: win.modelData.name; animate: !root.still; trace: root.trace }
      }
      Binding { target: river; property: "drawCaption"; value: false }
      Binding { target: river; property: "waterRuns"; value: win.flows }
      // For the main window on this screen: the river it draws around, and its programs.
      readonly property var current: river
      function shaders() { return river.shaders() }

      readonly property int tiled: {
        if (!root.hypr) return 0
        var m = Hyprland.monitorFor(win.modelData)
        return m && m.activeWorkspace ? m.activeWorkspace.toplevels.values.length : 0
      }
      readonly property var st: Perf.screenState(root.tops, win.modelData.name, win.tiled)
      readonly property bool focused: root.focusedScreen === "" || root.focusedScreen === win.modelData.name
      readonly property bool flows: win.focused && Perf.shouldDraw(win.st)
      function logFlow() {
        console.log("amplify: river water screen=" + win.modelData.name + " " + (win.flows ? "runs" : "still")
                    + " focused=" + win.focused + " covered=" + win.st.covered + " fullscreen=" + win.st.fullscreen
                    + " at=" + Date.now())
      }
      onFlowsChanged: logFlow()
      Component.onCompleted: logFlow()

      // AMPLIFY_FPS=1: this window's frames and water steps per second, every 5 s (as the main window).
      property int swapped: 0
      property int stepsAt: 0
      property real windowAt: Date.now()
      // drawn: this window has shown a frame with RHI shaders (Service.programs, the ready line).
      property bool drawn: false
      Connections {
        target: win.contentItem.Window.window
        function onFrameSwapped() {
          if (root.logFps) win.swapped++
          if (!win.drawn) win.drawn = river.GraphicsInfo.shaderType === GraphicsInfo.RhiShader
        }
      }
      Timer {
        interval: 5000; repeat: true; running: root.logFps
        onTriggered: {
          var t = Date.now()
          console.log("amplify: fps window=amplify-river screen=" + win.modelData.name + " " + (win.swapped / 5).toFixed(1)
                      + " steps=" + ((river.steps - win.stepsAt) / 5).toFixed(1) + " ms=" + Math.round(t - win.windowAt))
          win.swapped = 0; win.stepsAt = river.steps; win.windowAt = t
        }
      }
    }
  }
}
