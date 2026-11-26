import Quickshell
import Quickshell.Io
import QtQuick
import "mandrel.js" as Mandrel  // copy of data/mandrel.js (tools/sync-shared.sh), like this file

// The scene clock (task 679fbbc5, decision cfce981b): the one moment the orbs, river and
// basin show. Service.qml makes one and hands it to all three, so at any instant they are
// built from the same scene time and draw the same caption (Mandrel.sceneCaption). A
// component alone (quickshell -p plugin/river, the orbs test sheets) or replaying its own
// test fixture makes its own.
//  - replay: the scene holds at the capture (meta.captured_at), the state as of one moment,
//    as a status reference reads; nothing steps it, and no client clock runs it on.
//  - live (MANDREL_URL + MANDREL_VIEWER_TOKEN): one fetch every refetchSec for everyone, and
//    the scene time is the wall clock, stepped once a second, so liveness and leases decay
//    between refetches on the same clock for all three.
// Copied into plugin/basin, plugin/orbs and plugin/river by tools/sync-shared.sh.
Scope {
  id: clock

  // env-read: MANDREL_URL, MANDREL_VIEWER_TOKEN (data layer config; replay when unset or mdl_).
  readonly property var config: Mandrel.resolveConfig({
    MANDREL_URL: Quickshell.env("MANDREL_URL") || "",
    MANDREL_VIEWER_TOKEN: Quickshell.env("MANDREL_VIEWER_TOKEN") || ""
  })
  readonly property bool live: config.mode === "live"
  // The replayed capture: a test fixture when set, else amplify-snapshot.json next to this
  // copy, a copy of fixtures/amplify-snapshot.json (tools/sync-shared.sh).
  property string snapshotPath: ""
  readonly property string path: snapshotPath
    || decodeURIComponent(String(Qt.resolvedUrl("amplify-snapshot.json")).replace(/^file:\/\//, ""))
  // env-read: AMPLIFY_SCENE_AT holds the replayed scene at this ISO time instead of the capture (shots, idle checks).
  property string heldAt: Quickshell.env("AMPLIFY_SCENE_AT") || ""
  // env-read: AMPLIFY_SCENE_STEP=<virtual s> steps the replayed scene time that far each second, up to the capture (tests of scene changes, which live refetches make).
  readonly property real stepSec: Number(Quickshell.env("AMPLIFY_SCENE_STEP") || 0)
  property int refetchSec: 30
  // env-read: AMPLIFY_TRACE=1 logs this clock's id when it is made and at each live fetch (the one-clock check, tools/headless-shot.sh).
  readonly property bool trace: Quickshell.env("AMPLIFY_TRACE") === "1"
  // This clock's id (its address while it lives). Traced, every component names the clock it
  // follows in its "amplify: scene" line, so a check sees one clock, not only one time.
  readonly property string clockId: String(clock).replace(/^.*\(0x0*([0-9a-fA-F]+).*$/, "$1")
  Component.onCompleted: if (trace) console.log("amplify: clock " + clockId + " made " + (live ? "live" : "replay"))

  property var snapshot: null    // replay: the parsed capture
  property var scene: null       // the scene at nowMs: the capture rewound to it (replay) or the latest fetch (live)
  property real fetchMs: 0       // replay: captured_at; live: the latest fetch
  property real nowMs: 0         // the scene time every component draws

  // scene is set last: components rebuild when it changes and read the rest then.
  function load(text) {
    var snap = JSON.parse(text)
    fetchMs = Date.parse(snap.meta.captured_at)
    nowMs = heldAt ? Date.parse(heldAt) : fetchMs
    snapshot = snap
    scene = Mandrel.replayScene(snap, nowMs)
  }

  FileView {
    path: clock.live ? "" : clock.path
    printErrors: true
    onLoaded: {
      try { clock.load(text()) }
      catch (e) { console.log("amplify: scene snapshot unreadable " + e) }
    }
  }
  Timer {
    running: clock.live; repeat: true; triggeredOnStart: true
    interval: clock.refetchSec * 1000
    onTriggered: {
      if (clock.trace) console.log("amplify: clock " + clock.clockId + " fetch")
      var fetch = Mandrel.fetcherFor(clock.config, Mandrel.xhrTransport(), null)
      Mandrel.loadScene(fetch, { baseUrl: clock.config.baseUrl, mode: "live" }).then(function (s) {
        clock.fetchMs = Date.now(); clock.nowMs = clock.fetchMs; clock.scene = s
      }, function (e) { console.log("amplify: scene fetch failed " + e) })
    }
  }
  Timer {
    running: clock.live && clock.scene !== null; repeat: true; interval: 1000
    onTriggered: clock.nowMs = Date.now()
  }
  Timer {
    running: !clock.live && clock.stepSec > 0 && clock.snapshot !== null && clock.nowMs < clock.fetchMs
    repeat: true; interval: 1000
    onTriggered: {
      clock.nowMs = Math.min(clock.fetchMs, clock.nowMs + clock.stepSec * 1000)
      clock.scene = Mandrel.replayScene(clock.snapshot, clock.nowMs)
    }
  }
}
