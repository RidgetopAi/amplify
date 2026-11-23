import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import "data/mandrel.js" as Mandrel
import "plugin/orbs/orbs.js" as Orbs
import "plugin/orbs"

// Proof sheets for task a40d7440, rendered by plugin/orbs/test/shot.sh, which
// copies this file to the repo root first: Quickshell only resolves imports
// inside the folder of the shell file, and the sheet needs data/ and plugin/.
// Every orb here is a real session from plugin/orbs/fixtures/orbs-snapshot.json
// at a stated client-clock time; nothing is posed by hand.
//   AMPLIFY_ORBS_SHEET=roles   coord / worker / critic silhouettes, untitled, never-heartbeat
//   AMPLIFY_ORBS_SHEET=states  the desktop at fetch time and 20 min later on the client clock
//   AMPLIFY_ORBS_SHEET=motion  animated, traced (AMPLIFY_TRACE=1): the desktop at fetch, then at
//                              3 s the client clock jumps to +20 min, so liveness decays (lost,
//                              dormant, needs-you, ended fade) while the trace runs (shot.sh motion)
ShellRoot {
  id: root
  // env-read: AMPLIFY_ORBS_SHEET selects the sheet (roles | states).
  readonly property string sheet: Quickshell.env("AMPLIFY_ORBS_SHEET") || "roles"
  readonly property color accent: "#89b4fa"
  readonly property color fg: "#cdd6f4"
  property var snap: null
  readonly property real fetchMs: snap ? Date.parse(snap.meta.captured_at) : 0

  function sceneAt(ms, rewind) {
    var r = snap.responses
    var inputs = rewind ? Mandrel.replayResponses(snap, ms)
      : { sessions: r["/api/sessions"], tasks: r["/api/tasks"], contexts: [], decisions: [], projects: r["/api/projects"] }
    var s = Mandrel.buildScene(inputs, { now: rewind ? ms : fetchMs, baseUrl: snap.meta.base_url, mode: "replay" })
    return Mandrel.tickScene(s, ms)
  }
  // One orb: session id8 at client time ms, laid at radius r.
  function orbAt(id8, ms, r, rewind) {
    var s = sceneAt(ms, rewind)
    for (var i = 0; i < s.sessions.length; i++)
      if (s.sessions[i].id8 === id8) {
        var p = Orbs.orbProps(s, s.sessions[i], ms)
        p.r = r
        return p
      }
    return null
  }
  function hueFor(role) {
    if (role === "coord") return Qt.tint(fg, Qt.rgba(1, 1, 1, 0.25))
    if (role === "critic") return Qt.tint(accent, Qt.rgba(0.72, 0.63, 0.96, 0.6))
    return accent
  }
  function clockLabel(ms) { return new Date(ms).toISOString().slice(11, 19) + "Z" }

  FileView {
    path: Qt.resolvedUrl("plugin/orbs/fixtures/orbs-snapshot.json").toString().replace(/^file:\/\//, "")
    onLoaded: root.snap = JSON.parse(text())
  }

  component Cell: Item {
    id: cell
    property var orb: null
    property string caption: ""
    property string note: ""
    property bool mono: false
    width: 250; height: 300
    OrbView {
      anchors.horizontalCenter: parent.horizontalCenter
      y: 6
      orb: cell.orb
      animate: false
      mono: cell.mono
      hue: root.hueFor(cell.orb ? cell.orb.role : "worker")
      foreground: root.fg
    }
    Column {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: cell.caption; color: root.fg; font.family: "sans-serif"; font.pixelSize: 15; font.weight: Font.DemiBold }
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: cell.note; color: root.fg; opacity: 0.5; font.family: "monospace"; font.pixelSize: 11 }
    }
  }

  PanelWindow {
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "amplify-orbs-sheet"
    color: "#05080b"

    Text {
      x: 28; y: 18
      text: root.sheet === "roles" ? "Desktop orbs · roles by silhouette · untitled and never-heartbeat sessions"
                                   : "Desktop orbs · liveness on the client clock · lease vessels · activity beam"
      color: root.fg; font.family: "sans-serif"; font.pixelSize: 20; font.weight: Font.DemiBold
    }
    Text {
      x: 28; y: 46
      text: root.snap ? "REPLAYED SNAPSHOT · " + root.snap.meta.label : ""
      color: root.fg; opacity: 0.45; font.family: "monospace"; font.pixelSize: 11; font.letterSpacing: 1.2
    }

    // ---------------------------------------------------------- roles
    Item {
      visible: root.sheet === "roles" && !!root.snap
      anchors.fill: parent
      anchors.topMargin: 76
      Grid {
        x: 40; columns: 3; columnSpacing: 70; rowSpacing: 4
        Text { text: "SILHOUETTE ONLY (NO COLOUR)"; color: root.fg; opacity: 0.5; font.family: "monospace"; font.pixelSize: 11; font.letterSpacing: 1.5 }
        Item { width: 1; height: 1 } Item { width: 1; height: 1 }
        Cell { mono: true; orb: root.snap ? root.orbAt("de463c37", root.fetchMs, 46) : null; caption: "coord"; note: "lantern + orbit ring, 3 beads" }
        Cell { mono: true; orb: root.snap ? root.orbAt("b8bbe543", root.fetchMs, 46) : null; caption: "worker"; note: "glass sphere + tether knot" }
        Cell { mono: true; orb: root.snap ? root.orbAt("f4fe1f7e", root.fetchMs, 46) : null; caption: "critic"; note: "obsidian lens + calipers" }
      }
      Grid {
        x: 40; y: 330; columns: 4; columnSpacing: 30
        Cell { orb: root.snap ? root.orbAt("de463c37", root.fetchMs, 46) : null; caption: "amplify-coord"; note: "live · coord · " + root.clockLabel(root.fetchMs) }
        Cell { orb: root.snap ? root.orbAt("b8bbe543", root.fetchMs, 46) : null; caption: "orbs"; note: "explicit heartbeat → fuse arc" }
        Cell { orb: root.snap ? root.orbAt("52a1f8c2", root.fetchMs, 46) : null; caption: "river"; note: "never heartbeat → dotted track, socket" }
        Cell { orb: root.snap ? root.orbAt("3e6797ed", Date.parse("2026-11-22T00:28:30Z"), 46, true) : null; caption: "untitled coord"; note: "3e6797ed · title null · 00:28:30Z" }
      }
    }

    // ---------------------------------------------------------- motion
    OrbField {
      id: decay
      visible: root.sheet === "motion"
      anchors.fill: parent
      animate: true
      // env-read: AMPLIFY_TRACE=1 logs the orbs' drawn axes (tools/motion/follow.mjs).
      trace: Quickshell.env("AMPLIFY_TRACE") === "1"
      fixedOffsetMs: 0
      accent: root.accent; foreground: root.fg
      snapshotPath: Qt.resolvedUrl("plugin/orbs/fixtures/orbs-snapshot.json").toString().replace(/^file:\/\//, "")
      Timer {
        interval: 3000; running: root.sheet === "motion"
        onTriggered: { decay.fixedOffsetMs = 20 * 60000; decay.tick(); console.log("amplify: orbs motion clock +20 min") }
      }
    }

    // ---------------------------------------------------------- states
    Item {
      visible: root.sheet === "states" && !!root.snap
      anchors.fill: parent
      anchors.topMargin: 76
      Repeater {
        model: [{ off: 0, t: "AT FETCH · server truth" }, { off: 20 * 60000, t: "CLIENT CLOCK +20 MIN · no refetch" }]
        Rectangle {
          required property var modelData
          required property int index
          x: 20 + index * 790; y: 0; width: 770; height: 460
          radius: 14; color: "#080c12"; border.color: Qt.rgba(0.63, 0.69, 0.8, 0.12)
          clip: true
          OrbField {
            anchors.fill: parent
            animate: false
            fixedOffsetMs: modelData.off
            accent: root.accent; foreground: root.fg
            showLabel: false
            snapshotPath: Qt.resolvedUrl("plugin/orbs/fixtures/orbs-snapshot.json").toString().replace(/^file:\/\//, "")
          }
          Text {
            x: 16; y: 12
            text: modelData.t + " · " + (root.snap ? root.clockLabel(root.fetchMs + modelData.off) : "")
            color: root.fg; opacity: 0.6; font.family: "monospace"; font.pixelSize: 12; font.letterSpacing: 1.4
          }
        }
      }
      Row {
        x: 30; y: 484; spacing: 4
        Cell { width: 255; orb: root.snap ? root.orbAt("de463c37", root.fetchMs, 34) : null; caption: "live"; note: "coord · fetch" }
        Cell { width: 255; orb: root.snap ? root.orbAt("52a1f8c2", root.fetchMs, 34) : null; caption: "forming"; note: "river · connect, no writes" }
        Cell { width: 255; orb: root.snap ? root.orbAt("5be105be", root.fetchMs, 34) : null; caption: "quiet"; note: "needs-you · server quiet" }
        Cell { width: 255; orb: root.snap ? root.orbAt("b8bbe543", root.fetchMs + 20 * 60000, 34) : null; caption: "lost"; note: "orbs · hb 20 min old, claim live" }
        Cell { width: 255; orb: root.snap ? root.orbAt("5be105be", root.fetchMs + 20 * 60000, 34) : null; caption: "dormant"; note: "needs-you · +20 min, no hb" }
        Cell { width: 255; orb: root.snap ? root.orbAt("d045e2e7", root.fetchMs, 34) : null; caption: "ended"; note: "install-fix · ended 6 min" }
      }
    }
  }
}
