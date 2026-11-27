import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import QtQuick
import "../motion"
import "ambient.js" as A
import "../perf/perf.js" as Perf

// The ambient music field (task 523461dd): a soft band of light along the bottom of each
// screen, on its own WlrLayer.Bottom window ("amplify-ambient", no input) so its frames
// never redraw the river, basin or orbs. Its height is the scene's active sessions
// (ambient.js fieldBase: scene.counts.liveness, from the scene clock everyone reads).
// While an MPRIS player reports Playing and a screen is uncovered, one cava process runs
// and its bands only scale that height, at most 30 frames a second (perf.js FPS_CAP); a
// screen under a fullscreen, maximized or tiled window ignores them. Nothing playing,
// cava is not running and the field holds still: no Animation, Behavior or frame timer.
// Service.qml mounts this with one line, before the other layers, so it sits below them.
Item {
  id: ambient

  property var sceneClock: null
  property color accent: "#89b4fa"
  property bool animate: true
  property bool trace: false
  property bool logFps: false

  readonly property var base: A.fieldBase(sceneClock ? sceneClock.scene : null)

  // env-read: AMPLIFY_MPRIS_FIXTURE names a file holding one playback state (Playing, Paused,
  // Stopped) that stands in for MPRIS, re-read when it changes (tests: the orb has no audio).
  readonly property string mprisFixture: Quickshell.env("AMPLIFY_MPRIS_FIXTURE") || ""
  property string fixtureState: ""
  FileView {
    path: ambient.mprisFixture
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: ambient.fixtureState = text().trim()
  }
  readonly property bool playing: mprisFixture ? A.isPlaying([fixtureState])
    : A.isPlaying(Mpris.players.values.map(function (p) { return p.isPlaying ? "Playing" : "Paused" }))

  // env-read: AMPLIFY_CAVA_BIN overrides the cava binary (default: cava on PATH; tests use a stub).
  readonly property string cavaBin: Quickshell.env("AMPLIFY_CAVA_BIN") || "cava"
  readonly property string cavaConf: decodeURIComponent(String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, ""))
  // env-read: HYPRLAND_INSTANCE_SIGNATURE: under Hyprland, tiled windows on a screen's shown workspace cover it.
  readonly property bool hypr: (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== ""

  // Every window as a plain object for perf.js screenState.
  readonly property var tops: ToplevelManager.toplevels.values.map(function (t) {
    return { fullscreen: t.fullscreen, maximized: t.maximized, minimized: t.minimized,
             screens: t.screens.map(function (s) { return s.name }) }
  })

  readonly property int drawing: screens.instances.filter(function (w) { return w.live }).length
  readonly property bool cavaWanted: animate && A.cavaShouldRun({ playing: playing, drawing: drawing })
  // The latest accepted cava frame (BARS values in 0..1), null while cava is not running.
  property var bands: null
  property var gate: Perf.createFrameGate(Perf.FPS_CAP)
  function frame(line) {
    if (!gate.accept(Date.now())) return
    var b = A.parseFrame(line)
    if (b) bands = b
  }

  // Started and stopped explicitly: a cava that exits on its own (none installed, no audio
  // server) is not restarted until playback or covering changes the wish.
  onCavaWantedChanged: cava.running = cavaWanted
  Component.onCompleted: cava.running = cavaWanted
  Process {
    id: cava
    command: [ambient.cavaBin, "-p", ambient.cavaConf]
    stdout: SplitParser { onRead: data => ambient.frame(data) }
    onRunningChanged: {
      console.log("amplify: ambient cava " + (running ? "start" : "stop") + " playing=" + ambient.playing
                  + " drawing=" + ambient.drawing)
      if (!running) { ambient.bands = null; ambient.gate.reset() }
    }
  }

  Variants {
    id: screens
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      color: "transparent"
      // Only the screen's foot, where the field is: a smaller surface to draw and blend per frame.
      anchors { bottom: true; left: true; right: true }
      implicitHeight: Math.max(1, Math.round(win.modelData.height * 0.26))
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "amplify-ambient"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}

      readonly property int tiled: {
        if (!ambient.hypr) return 0
        var m = Hyprland.monitorFor(win.modelData)
        return m && m.activeWorkspace ? m.activeWorkspace.toplevels.values.length : 0
      }
      readonly property var st: Perf.screenState(ambient.tops, win.modelData.name, win.tiled)
      // live: this screen draws the music; covered, it holds the resting field.
      readonly property bool live: Perf.shouldDraw(st)
      onLiveChanged: console.log("amplify: ambient screen=" + win.modelData.name + " " + (live ? "live" : "paused")
                                 + " fullscreen=" + st.fullscreen + " covered=" + st.covered)
      readonly property var levels: A.fieldLevels(ambient.base.level, win.live ? ambient.bands : null)

      Loader {
        active: ambient.trace
        sourceComponent: Trace {
          comp: "ambient"; part: "field"; ident: win.modelData.name
          v: ({ base: ambient.base.level, "base:to": A.fieldBase(ambient.sceneClock ? ambient.sceneClock.scene : null).level,
                music: win.live && ambient.bands ? 1 : 0 })
        }
      }

      Item {
        id: field
        anchors.fill: parent
        Repeater {
          model: A.BARS
          Rectangle {
            required property int index
            readonly property real bw: field.width / A.BARS
            x: index * bw; width: bw + 1
            height: field.height * win.levels[index]
            anchors.bottom: parent.bottom
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(ambient.accent.r, ambient.accent.g, ambient.accent.b, 0) }
              GradientStop { position: 1.0; color: Qt.rgba(ambient.accent.r, ambient.accent.g, ambient.accent.b, 0.34) }
            }
          }
        }
      }

      // AMPLIFY_FPS=1: the frames this window swapped per second, every 5 s (as Service.qml), and
      // how often its field changed: what it asks to draw, which a compositor that stops
      // sending frames to a hidden surface (sway under a fullscreen window) does not show.
      property int swapped: 0
      property int changed: 0
      onLevelsChanged: if (ambient.logFps) win.changed++
      Connections {
        target: win.contentItem.Window.window
        enabled: ambient.logFps
        function onFrameSwapped() { win.swapped++ }
      }
      Timer {
        interval: 5000; repeat: true; running: ambient.logFps
        onTriggered: {
          console.log("amplify: fps window=amplify-ambient screen=" + win.modelData.name + " " + (win.swapped / 5).toFixed(1)
                      + " changes=" + (win.changed / 5).toFixed(1))
          win.swapped = 0; win.changed = 0
        }
      }
    }
  }
}
