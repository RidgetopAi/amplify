import Quickshell
import Quickshell.Io
import QtQuick
import "mandrel.js" as Mandrel   // symlink to data/mandrel.js: Quickshell blackholes imports outside the config folder
import "river.js" as R

// A river's replay clock (each River owns one unless its host sets `feed`, so
// every screen runs its own copy of the same fixture). Plays a fixture through the data
// layer (data/mandrel.js buildScene) and reports lane changes between
// successive scenes, which River.qml draws as critic PASS rings and REJECT eddies.
// Live mode (SSE + refetch) will set `scene` the same way; replay is the
// only source until the viewer token exists (viewer contract 22d73eeb).
Scope {
  id: feed

  // env-read: AMPLIFY_RIVER_FIXTURE replays this file instead of fixtures/amplify-snapshot.json.
  // amplify-snapshot.json is a symlink to fixtures/amplify-snapshot.json.
  readonly property string fixturePath: Quickshell.env("AMPLIFY_RIVER_FIXTURE")
    || decodeURIComponent(String(Qt.resolvedUrl("amplify-snapshot.json")).replace(/^file:\/\//, ""))
  // env-read: AMPLIFY_RIVER_AT freezes the replay clock at this ISO time (screenshots).
  readonly property string freezeAt: Quickshell.env("AMPLIFY_RIVER_AT") || ""

  property real speed: 60        // virtual seconds per real second
  property int stepMs: 1000
  property var fixture: null
  property var scene: null
  property var prevScene: null
  property real nowMs: 0
  property real fromMs: 0
  property real toMs: 0
  property var events: []        // lane changes of the latest step
  property int serial: 0
  readonly property string label: scene ? scene.meta.label : ""

  readonly property var mandrel: ({ buildScene: Mandrel.buildScene, replayResponses: Mandrel.replayResponses })

  function advance(ms) {
    var next = R.replaySceneAt(mandrel, fixture, ms)
    var ev = R.transitions(scene, next)
    prevScene = scene
    nowMs = ms
    scene = next
    events = ev
    serial++
    if (ev.length) console.log("amplify: river events " + ev.map(function (e) { return e.kind + " " + e.id8 + " " + e.from + "→" + e.to }).join(", "))
  }

  function load(text) {
    fixture = JSON.parse(text)
    fromMs = Date.parse(fixture.meta.replay_from)
    toMs = Date.parse(fixture.meta.captured_at)
    if (freezeAt) {
      var at = Date.parse(freezeAt)
      advance(at - stepMs * speed)   // the step before, so its lane changes show
      advance(at)
    } else {
      advance(fromMs)
    }
  }

  FileView {
    path: feed.fixturePath
    printErrors: true
    onLoaded: feed.load(text())
  }

  Timer {
    interval: feed.stepMs; repeat: true
    running: feed.fixture !== null && feed.freezeAt === ""
    onTriggered: {
      var n = feed.nowMs + feed.stepMs * feed.speed
      if (n > feed.toMs) { n = feed.fromMs; feed.scene = null }  // loop without a fake retreat
      feed.advance(n)
    }
  }
}
