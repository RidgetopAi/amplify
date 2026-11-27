import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import "data/mandrel.js" as Mandrel
import "plugin/basin/basin.js" as Basin
import "plugin/panes"

// Proof sheet for task bc45ee1d (docs/shots/panes-switch.png), rendered by
// plugin/panes/test/shot.sh, which copies this file to the repo root first: Quickshell only
// resolves imports inside the folder of the shell file, and the sheet needs data/ and plugin/.
// The scene is fixtures/amplify-snapshot.json at its capture, as the plugin replays it, with
// /api/projects replaced by the real project list in plugin/panes/test/projects.json. Three
// panes: no records at all (every field null), the panes closed, and the switcher open.
ShellRoot {
  id: root
  property var snap: null
  property var projects: null
  readonly property real atMs: snap ? Date.parse(snap.meta.captured_at) : 0

  function sceneOf(empty) {
    if (!snap || !projects) return null
    var inputs = empty ? {} : Mandrel.replayResponses(snap, atMs)
    if (!empty) inputs.projects = projects
    return Mandrel.buildScene(inputs, { now: atMs, baseUrl: empty ? "" : snap.meta.base_url, mode: "replay",
                                        projectId: empty ? null : snap.meta.project_id,
                                        label: "REPLAYED SNAPSHOT · " + snap.meta.label })
  }
  readonly property var scene: sceneOf(false)
  readonly property var emptyScene: sceneOf(true)

  FileView {
    path: Qt.resolvedUrl("fixtures/amplify-snapshot.json").toString().replace(/^file:\/\//, "")
    onLoaded: root.snap = JSON.parse(text())
  }
  FileView {
    path: Qt.resolvedUrl("plugin/panes/test/projects.json").toString().replace(/^file:\/\//, "")
    onLoaded: root.projects = JSON.parse(text())
  }

  // Stand-ins for the BasinFeed the plugin hands the panes: the scene, its clock and the basin rows.
  component Feed: QtObject {
    property var activeScene: null
    property real now: root.atMs
    property var rows: activeScene ? Basin.buildBasin(activeScene, null, { now: now }) : []
  }
  Feed { id: full; activeScene: root.scene }
  Feed { id: none; activeScene: root.emptyScene }

  // The idle budget: from the first draw on, every second the feeds hand the panes new but
  // equal rows and the same clock, as the basin's 15 s rebuild does, and every frame the sheet
  // swaps is logged with its time. shot.sh counts the frames 3 to 9 s after the draw, and wants
  // none. (Measured from the log, not with a timer that starts and stops: a QML Timer starting
  // or stopping makes the window swap a frame of its own, with or without the panes.)
  Timer {
    interval: 1000; repeat: true; running: sheetWin.framesWithData >= 2
    onTriggered: {
      full.rows = Basin.buildBasin(full.activeScene, null, { now: full.now }); full.now = root.atMs
      none.rows = []
    }
  }

  PanelWindow {
    id: sheetWin
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "amplify-panes-sheet"
    color: "#05080b"

    // "amplify: sheet drawn" once a frame synced after both files loaded has been swapped.
    property int framesWithData: 0
    Connections {
      target: sheetWin.contentItem.Window.window
      enabled: !!root.scene && sheetWin.framesWithData < 2
      function onFrameSwapped() {
        if (++sheetWin.framesWithData === 1) sheetWin.contentItem.Window.window.update()
        else console.log("amplify: sheet drawn panes " + Date.now())
      }
    }
    Connections {
      target: sheetWin.contentItem.Window.window
      function onFrameSwapped() { console.log("amplify: sheet frame " + Date.now()) }
    }

    Text {
      x: 28; y: 18
      text: "Panes · stats, latest records, project switcher, quick links"
      color: "#cdd6f4"; font.family: "sans-serif"; font.pixelSize: 20; font.weight: Font.DemiBold
    }
    Text {
      x: 28; y: 46
      text: root.snap ? "REPLAYED SNAPSHOT · " + root.snap.meta.label + " · projects: " + (root.projects ? root.projects.meta.label : "") : ""
      color: "#cdd6f4"; opacity: 0.45; font.family: "monospace"; font.pixelSize: 11; font.letterSpacing: 1.0
    }

    Repeater {
      model: [{ t: "NO RECORDS · EVERY FIELD NULL", feed: none, open: false },
              { t: "AT CAPTURE · SWITCHER CLOSED", feed: full, open: false },
              { t: "AT CAPTURE · SWITCHER OPEN", feed: full, open: true }]
      Item {
        required property var modelData
        required property int index
        x: 28 + index * 664; y: 84
        Text {
          text: parent.modelData.t
          color: "#cdd6f4"; opacity: 0.6; font.family: "monospace"; font.pixelSize: 12; font.letterSpacing: 1.4
        }
        Panes { y: 26; feed: parent.modelData.feed; switcherOpen: parent.modelData.open; screenName: "sheet" + parent.index }
      }
    }
  }
}
