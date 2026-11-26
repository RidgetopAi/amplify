import Quickshell
import QtQuick
import "mandrel.js" as Mandrel   // copy of data/mandrel.js (tools/sync-shared.sh): Quickshell blackholes imports outside the config folder
import "river.js" as R

// The river's scenes on the scene clock (SceneClock.qml, task 679fbbc5): builds the river
// at the clock's moment through the data layer (Mandrel.replayScene, or the clock's live
// fetch) and reports lane changes between successive scenes, which River.qml draws as
// critic PASS rings and REJECT eddies. The river never runs a clock of its own:
//  - replay: the clock holds, so the river builds the minute before the moment and then the
//    moment, once, and the lane changes of that minute show;
//  - live: each refetch is the next scene, and nowMs follows the clock between them.
Scope {
  id: feed

  // The shared scene clock (Service.qml). Unset, or with a fixture of its own, the river
  // makes its own clock (quickshell -p plugin/river, plugin/river/test/shot.sh).
  property var sceneClock: null
  // env-read: AMPLIFY_RIVER_FIXTURE replays this file (on the river's own clock) instead of the shared capture.
  readonly property string fixturePath: Quickshell.env("AMPLIFY_RIVER_FIXTURE") || ""
  LazyLoader {
    id: own
    active: !feed.sceneClock || feed.fixturePath !== ""
    SceneClock { snapshotPath: feed.fixturePath }
  }
  readonly property var src: feed.sceneClock && feed.fixturePath === "" ? feed.sceneClock : own.item

  readonly property real beforeMs: 60000  // replay: the scene time before the moment whose lane changes show
  readonly property int stepMs: 1000      // real ms a scene change eases over (River.qml tethers)
  property var scene: null
  property var prevScene: null
  property real nowMs: 0
  property var events: []        // lane changes of the latest step
  property int serial: 0
  // The one caption (Mandrel.sceneCaption) for the moment the river shows.
  readonly property string caption: nowMs && src && src.scene ? Mandrel.sceneCaption(src.scene, nowMs) : ""

  function advance(next, ms) {
    var ev = R.transitions(scene, next)
    prevScene = scene
    nowMs = ms
    scene = next
    events = ev
    serial++
    if (ev.length) console.log("amplify: river events " + ev.map(function (e) { return e.kind + " " + e.id8 + " " + e.from + "→" + e.to }).join(", "))
  }

  function follow() {
    var c = src
    if (!c || !c.scene) return
    if (c.live) {
      if (c.scene !== scene) advance(c.scene, c.nowMs)
      else nowMs = c.nowMs
      return
    }
    if (c.nowMs === nowMs && scene) return
    if (!scene) {
      console.log("amplify: replay river " + Mandrel.replaySource(c.snapshot))
      advance(R.replaySceneAt(Mandrel, c.snapshot, c.nowMs - beforeMs), c.nowMs - beforeMs)
    }
    advance(R.replaySceneAt(Mandrel, c.snapshot, c.nowMs), c.nowMs)
  }
  onSrcChanged: follow()
  Connections {
    target: feed.src
    function onSceneChanged() { feed.follow() }
    function onNowMsChanged() { feed.follow() }
  }
}
