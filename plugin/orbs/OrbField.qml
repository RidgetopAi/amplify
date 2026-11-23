import Quickshell
import Quickshell.Io
import QtQuick
import "mandrel.js" as Mandrel  // symlink to ../../data/mandrel.js: Quickshell blocks imports outside plugin/
import "orbs.js" as Orbs

// Desktop orbs (task a40d7440): one orb per Mandrel session on the desktop
// layer, lease vessels under claim holders, and beams for activity links.
//
// Data: live when MANDREL_URL + MANDREL_VIEWER_TOKEN are set (refetch every
// refetchSec); otherwise the snapshot below is treated as the last fetch and
// the client clock runs forward from its capture time (replay). Either way the
// scene is re-ticked once a second (Mandrel.tickScene), so liveness, lease and
// heartbeat fuse decay on the client clock between refetches.
Item {
  id: field

  property color accent: "#89b4fa"
  property color foreground: "#cdd6f4"
  property color alarm: "#e0786a"     // lost: muted red, never the warm hue
  property color warm: "#ff9e74"      // reserved for needs-you
  property bool animate: true
  property bool mono: false
  // For shots: a fixed client clock, as ms since the snapshot's capture.
  property real fixedOffsetMs: -1
  property string snapshotPath: Qt.resolvedUrl("fixtures/orbs-snapshot.json").toString().replace(/^file:\/\//, "")
  property int refetchSec: 30
  property bool showLabel: true

  // env-read: MANDREL_URL, MANDREL_VIEWER_TOKEN (data layer config; replay when unset or mdl_).
  readonly property var config: Mandrel.resolveConfig({
    MANDREL_URL: Quickshell.env("MANDREL_URL") || "",
    MANDREL_VIEWER_TOKEN: Quickshell.env("MANDREL_VIEWER_TOKEN") || ""
  })

  property var scene: null
  property real fetchMs: 0
  property real startReal: Date.now()
  property real nowMs: 0
  property var frame: ({ ids: [], orbs: {}, beams: [] })
  property var ids: []
  property var beamKeys: []
  property real clock: 2.3
  readonly property list<QtObject> regions: hitRegions.instances
  readonly property string label: !scene ? "" : (scene.meta.mode === "replay"
      ? "REPLAYED SNAPSHOT · " + (scene.meta.label || "") + " · client clock +" + Math.round((nowMs - fetchMs) / 60000) + " min"
      : "live · " + (scene.meta.baseUrl || ""))

  function hueFor(role) {
    if (role === "coord") return Qt.tint(foreground, Qt.rgba(1, 1, 1, 0.25))
    if (role === "critic") return Qt.tint(accent, Qt.rgba(0.72, 0.63, 0.96, 0.6))
    return accent
  }

  function tick() {
    if (!scene) return
    nowMs = fixedOffsetMs >= 0 ? fetchMs + fixedOffsetMs
          : config.mode === "live" ? Date.now()
          : fetchMs + (Date.now() - startReal)
    var f = Orbs.frame(scene, nowMs, width, height, Mandrel.tickScene)
    if (f.ids.join() !== ids.join()) ids = f.ids
    var bk = f.beams.map(function (b) { return b.key })
    if (bk.join() !== beamKeys.join()) beamKeys = bk
    frame = f
  }

  function sceneFromSnapshot(snap) {
    var r = snap.responses
    fetchMs = Date.parse(snap.meta.captured_at)
    startReal = Date.now()
    scene = Mandrel.buildScene({
      sessions: r["/api/sessions"], tasks: r["/api/tasks"], contexts: r["/api/contexts"],
      decisions: r["/api/decisions"], projects: r["/api/projects"], sessionDetails: r["/api/sessions/:id"]
    }, { now: fetchMs, mode: "replay", label: snap.meta.label, baseUrl: snap.meta.base_url,
         projectId: snap.meta.project_id, fetchedAt: snap.meta.captured_at })
    tick()
  }

  function refetch() {
    var fetch = Mandrel.fetcherFor(config, Mandrel.xhrTransport(), null)
    Mandrel.loadScene(fetch, { baseUrl: config.baseUrl, mode: "live" }).then(function (s) {
      fetchMs = Date.now(); scene = s; tick()
    }, function (e) { console.log("amplify: orbs refetch failed " + e) })
  }

  FileView {
    path: field.config.mode === "live" ? "" : field.snapshotPath
    printErrors: true
    onLoaded: {
      try { field.sceneFromSnapshot(JSON.parse(text())) }
      catch (e) { console.log("amplify: orbs snapshot unreadable " + e) }
    }
  }
  Timer {
    running: field.config.mode === "live"; repeat: true; triggeredOnStart: true
    interval: field.refetchSec * 1000
    onTriggered: field.refetch()
  }
  Timer {
    running: field.fixedOffsetMs < 0; repeat: true; interval: 1000
    onTriggered: {
      // Replay loops after 45 min of client time, back to the capture.
      if (field.config.mode !== "live" && Date.now() - field.startReal > 45 * 60000) field.startReal = Date.now()
      field.tick()
    }
  }
  onWidthChanged: tick()
  onHeightChanged: tick()

  // Shared surface clock for every shader (motion only; state comes from frame).
  NumberAnimation on clock {
    running: field.animate && field.visible
    from: 0; to: 3600; duration: 3600 * 1000; loops: Animation.Infinite
  }

  Repeater {
    model: field.beamKeys
    Beam {
      required property var modelData
      readonly property var row: field.frame.beams.filter(function (x) { return x.key === modelData })[0] || null
      a: row ? field.frame.orbs[row.from] || null : null
      b: row ? field.frame.orbs[row.to] || null : null
      alpha: row ? row.alpha : 0
      clock: field.clock
      hueFrom: a ? field.hueFor(a.role) : field.accent
      hueTo: b ? field.hueFor(b.role) : field.accent
    }
  }

  Repeater {
    id: rep
    model: field.ids
    OrbView {
      required property var modelData
      orb: field.frame.orbs[modelData] || null
      x: orb ? orb.x - width / 2 : 0
      y: orb ? orb.y - height / 2 : 0
      clock: field.clock
      animate: field.animate
      mono: field.mono
      hue: field.hueFor(orb ? orb.role : "worker")
      foreground: field.foreground
      alarm: field.alarm
      warm: field.warm
      onActivated: url => { console.log("amplify: orb open " + url); if (url) Qt.openUrlExternally(url) }
    }
  }

  // Input mask pieces for the layer window: only the orbs' hit circles.
  Variants {
    id: hitRegions
    model: field.ids
    Region {
      required property var modelData
      item: { rep.count; var it = rep.itemAt(field.ids.indexOf(modelData)); return it ? it.hitItem : null }
    }
  }

  Text {
    visible: field.showLabel && field.label !== ""
    anchors { left: parent.left; bottom: parent.bottom; margins: 18 }
    text: field.label
    color: field.foreground
    opacity: 0.4
    font.family: "monospace"
    font.pixelSize: 11
    font.letterSpacing: 1.4
  }
}
