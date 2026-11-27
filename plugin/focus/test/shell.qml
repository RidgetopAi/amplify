import Quickshell
import Quickshell.Wayland
import QtQuick
import "plugin/orbs"
import "plugin/focus"
import "plugin/focus/meridian.js" as G

// Proof sheets for task 85ff482a, rendered by plugin/focus/test/shot.sh, which copies this
// file to the repo root first (Quickshell resolves imports only inside the shell file's folder).
// The desktop orbs replay the shipped capture (fixtures/amplify-snapshot.json, held at its
// capture time); the coord orb amplify-coord (de463c37) is "clicked" and flies to the centre.
//   AMPLIFY_FOCUS_SHEET=focus  landed: the newest record under the loupe        -> meridian.png
//   AMPLIFY_FOCUS_SHEET=loupe  a hand throw west, coast, detent onto a plaque   -> meridian-loupe.png
//   AMPLIFY_FOCUS_SHEET=lease  data-core (4af6ff22), which holds 0edf3b35: the lit arc  -> meridian-lease.png
// Each logs "amplify: focus settled ..." when nothing moves any more; shot.sh captures then.
ShellRoot {
  id: root
  // env-read: AMPLIFY_FOCUS_SHEET selects the sheet (focus | loupe).
  readonly property string sheet: Quickshell.env("AMPLIFY_FOCUS_SHEET") || "focus"
  // env-read: AMPLIFY_TRACE=1 logs the globe's drawn axes (tools/motion/follow.mjs).
  readonly property bool trace: Quickshell.env("AMPLIFY_TRACE") === "1"

  PanelWindow {
    id: win
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "amplify-focus-sheet"
    color: "#05080b"

    OrbField {
      id: desk
      anchors.fill: parent
      animate: false
      snapshotPath: Qt.resolvedUrl("fixtures/amplify-snapshot.json").toString().replace(/^file:\/\//, "")
    }
    Rectangle { anchors.fill: parent; color: "#05080b"; opacity: 0.86 * (view.item ? view.item.fly : 0) }

    // Opens once the field has its frame (the orb's place), as a click would.
    property var orb: desk.frame.orbs ? (Object.keys(desk.frame.orbs).map(function (k) { return desk.frame.orbs[k] })
                                          .filter(function (o) { return o.id8 === (root.sheet === "lease" ? "4af6ff22" : "de463c37") })[0] || null) : null
    Loader {
      id: view
      anchors.fill: parent
      active: !!win.orb
      sourceComponent: Meridian {
        field: desk
        sessionId: win.orb.id
        fromX: win.orb.x; fromY: win.orb.y; fromR: win.orb.r
        trace: root.trace
        property bool thrown: false
        onMovingChanged: {}
        Timer {
          // The hand: once landed, six 30 px moves 16 ms apart to the right, then let go.
          running: root.sheet === "loupe" && parent.fly === 1 && !parent.thrown
          interval: 300
          onTriggered: {
            var v = parent
            v.thrown = true
            for (var i = 0; i < 6; i++) G.drag(v.spin, 30, 0, 0.016, v.rad)
            G.release(v.spin); v.syncSpin(); v.moving = true
            console.log("amplify: focus thrown vy " + v.spin.vy.toFixed(3))
          }
        }
      }
    }
  }
}
