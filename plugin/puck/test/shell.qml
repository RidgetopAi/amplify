import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import "data/mandrel.js" as Mandrel
import "plugin/puck/puck.js" as P
import "plugin/puck"
import "plugin/orbs" as Orbs

// Proof sheets for task 23a62966, rendered by plugin/puck/test/shot.sh, which copies this
// file to the repo root first: Quickshell resolves imports only inside the shell file's
// folder. Every Puck here reads the shipped capture (fixtures/amplify-snapshot.json, the
// copy in plugin/orbs) at a stated scene time; only the pointer and the blink frame are posed.
//   AMPLIFY_PUCK_SHEET=shot    docs/shots/puck.png: the cel Puck at desktop size in four
//                              states and the figurine at focus size
//   AMPLIFY_PUCK_SHEET=motion  one desktop Puck on its own scene clock (AMPLIFY_SCENE_AT /
//                              AMPLIFY_SCENE_STEP step the replay, so the activity and the
//                              needs-you rows change), traced; the pointer comes onto him
//                              at 4 s and leaves at 6.5 s (shot.sh motion)
//   AMPLIFY_PUCK_SHEET=click   one desktop Puck; after the first frame his click action runs
//   AMPLIFY_PUCK_SHEET=idle    the real PuckLayer alone on the held replay, logging its frames
//                              per second (AMPLIFY_FPS's line), and nothing else on screen
ShellRoot {
  id: root
  // env-read: AMPLIFY_PUCK_SHEET selects the sheet (shot | motion | click | idle).
  readonly property string sheet: Quickshell.env("AMPLIFY_PUCK_SHEET") || "shot"
  // env-read: AMPLIFY_STILL=1: no smoothing, no blink (motion sheet).
  readonly property bool still: Quickshell.env("AMPLIFY_STILL") === "1"
  // env-read: AMPLIFY_TRACE=1: traced (motion sheet).
  readonly property bool traced: Quickshell.env("AMPLIFY_TRACE") === "1"
  property var snap: null
  readonly property real capMs: snap ? Date.parse(snap.meta.captured_at) : 0
  readonly property real earlyMs: snap ? Date.parse(snap.meta.replay_from) : 0
  function sceneAt(ms) { return Mandrel.replayScene(snap, ms) }
  function hhmm(ms) { return new Date(ms).toISOString().slice(11, 16) + "Z" }

  FileView {
    path: Qt.resolvedUrl("plugin/orbs/amplify-snapshot.json").toString().replace(/^file:\/\//, "")
    onLoaded: root.snap = JSON.parse(text())
  }
  Orbs.SceneClock { id: clock }
  LazyLoader {
    active: root.sheet === "idle"
    PuckLayer { sceneClock: clock; logFps: true }
  }

  PanelWindow {
    id: win
    visible: root.sheet !== "idle"
    color: "#0b0e14"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "amplify-puck-sheet"

    property bool drawn: false
    Connections {
      target: win.contentItem.Window.window
      enabled: !win.drawn && root.snap !== null
      function onFrameSwapped() {
        win.drawn = true
        console.log("amplify: sheet drawn " + root.sheet)
        if (root.sheet === "click") clickPuck.activate()
      }
    }

    // A desktop-ish backdrop: the sticker border has to read on it.
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0; color: "#141a26" }
        GradientStop { position: 1; color: "#07090d" }
      }
    }

    component Cell: Column {
      property alias puck: pk
      property string caption: ""
      spacing: 6
      Puck { id: pk; animate: false }
      Text {
        width: pk.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: parent.caption
        color: "#cdd6f4"; opacity: 0.75
        font.family: "monospace"; font.pixelSize: 12
      }
    }

    Item {
      anchors.fill: parent
      visible: root.sheet === "shot" && root.snap !== null
      readonly property int desk: P.deskSize(win.width, win.height)

      Text {
        x: 40; y: 28
        text: "PUCK · desktop (cel, " + parent.desk + " px on " + win.width + "x" + win.height + ") and focus (figurine)"
        color: "#cdd6f4"; font.family: "sans-serif"; font.pixelSize: 20; font.weight: Font.DemiBold
      }
      Grid {
        x: 40; y: 90
        columns: 2; columnSpacing: 36; rowSpacing: 22
        Cell {
          caption: "curious, at rest · " + root.hhmm(root.capMs) + " · " + P.needs(puck.scene) + " need you: finger up"
          puck.width: parent.parent.desk; puck.scene: root.snap ? root.sceneAt(root.capMs) : null; puck.nowMs: root.capMs
        }
        Cell {
          caption: "curious, at rest · " + root.hhmm(root.earlyMs) + " · " + P.needs(puck.scene) + " need you: finger half up"
          puck.width: parent.parent.desk; puck.scene: root.snap ? root.sceneAt(root.earlyMs) : null; puck.nowMs: root.earlyMs
        }
        Cell {
          caption: "blink (a new write), mid-frame"
          puck.width: parent.parent.desk; puck.scene: root.snap ? root.sceneAt(root.capMs) : null; puck.nowMs: root.capMs
          puck.lid: 0.62
        }
        Cell {
          caption: "pointer on him, up right: glance, smile"
          puck.width: parent.parent.desk; puck.scene: root.snap ? root.sceneAt(root.earlyMs) : null; puck.nowMs: root.earlyMs
          puck.pointing: true; puck.pointerX: puck.width * 0.95; puck.pointerY: puck.height * 0.1
        }
      }
      Cell {
        x: win.width - width - 60; y: 70
        caption: "figurine · in focus · " + root.hhmm(root.capMs) + ", pointer to his left"
        puck.figurine: true
        puck.width: Math.min(win.height - 140, 760)
        puck.scene: root.snap ? root.sceneAt(root.capMs) : null; puck.nowMs: root.capMs
        puck.pointing: true; puck.pointerX: puck.width * 0.15; puck.pointerY: puck.height * 0.42
      }
      Text {
        anchors { left: parent.left; bottom: parent.bottom; margins: 18 }
        text: root.snap ? Mandrel.sceneCaption(root.sceneAt(root.capMs), root.capMs) : ""
        color: "#cdd6f4"; opacity: 0.4; font.family: "monospace"; font.pixelSize: 11; font.letterSpacing: 1.4
      }
    }

    Puck {
      id: motionPuck
      visible: root.sheet === "motion"
      x: P.DESK_LEFT; y: win.height - height - P.DESK_BOTTOM
      width: P.deskSize(win.width, win.height)
      scene: root.sheet === "motion" ? clock.scene : null
      nowMs: clock.nowMs
      animate: !root.still
      trace: root.traced && root.sheet === "motion"
      ident: "sheet"
    }
    Timer {
      running: root.sheet === "motion" && clock.scene !== null; interval: 4000
      onTriggered: { motionPuck.pointerX = motionPuck.width * 0.92; motionPuck.pointerY = motionPuck.height * 0.12; motionPuck.pointing = true; leave.start() }
    }
    Timer { id: leave; interval: 2500; onTriggered: motionPuck.pointing = false }

    Puck {
      id: clickPuck
      visible: root.sheet === "click"
      x: P.DESK_LEFT; y: win.height - height - P.DESK_BOTTOM
      width: P.deskSize(win.width, win.height)
      scene: clock.scene; nowMs: clock.nowMs
      animate: false
    }
  }
}
