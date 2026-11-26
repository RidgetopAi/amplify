import Quickshell
import Quickshell.Io
import QtQuick
import "mandrel.js" as Mandrel  // copy of data/mandrel.js (tools/sync-shared.sh): Quickshell blocks imports outside plugin/
import "orbs.js" as Orbs

// Desktop orbs (task a40d7440): one orb per Mandrel session on the desktop
// layer, lease vessels under claim holders, and beams for activity links.
//
// Data and time come from the scene clock (SceneClock.qml, task 679fbbc5), the one the river
// and basin read: live, its latest fetch at the wall clock; replay, the capture as the last
// fetch, held at its capture time. Each time the clock moves, the scene is ticked to it
// (Mandrel.tickScene), so liveness, lease and heartbeat fuse show that moment.
Item {
  id: field

  property color accent: "#89b4fa"
  property color foreground: "#cdd6f4"
  property color alarm: "#e0786a"     // lost: muted red, never the warm hue
  property color warm: "#ff9e74"      // reserved for needs-you
  property bool animate: true
  // AMPLIFY_TRACE=1: each orb and beam logs its drawn axes (plugin/motion/Trace.qml).
  property bool trace: false
  property bool mono: false
  // Test sheets only (plugin/orbs/test/shell.qml): the moment as ms after the capture,
  // instead of the clock's.
  property real fixedOffsetMs: -1
  // The scene clock every component reads (Service.qml through OrbsLayer). Unset, or with a
  // fixture of its own, the field makes its own clock on that file.
  property var sceneClock: null
  // env-read: AMPLIFY_ORBS_FIXTURE replays this file instead of the shared capture (tests: fixtures/test/orbs-states.json, never shipped).
  property string snapshotPath: Quickshell.env("AMPLIFY_ORBS_FIXTURE") || ""
  LazyLoader {
    id: own
    active: !field.sceneClock || field.snapshotPath !== ""
    SceneClock { snapshotPath: field.snapshotPath }
  }
  readonly property var src: field.sceneClock && field.snapshotPath === "" ? field.sceneClock : own.item
  property bool showLabel: true
  // The screen this field is drawn on (OrbsLayer), which keys its traced lines: "orbs@<screen>".
  property string screenName: ""

  property var scene: null
  property real fetchMs: 0
  property real nowMs: 0
  property var frame: ({ ids: [], orbs: {}, beams: [] })
  property var ids: []
  // Orbs keyed by session id, so a session joining or leaving does not rebuild
  // the others (a rebuilt orb restarts its spin phase and replays its material
  // tweens from zero).
  ListModel { id: orbModel }
  onIdsChanged: {
    for (var i = 0; i < ids.length; i++) {
      var j = -1
      for (var m = i; m < orbModel.count; m++) if (orbModel.get(m).oid === ids[i]) { j = m; break }
      if (j < 0) orbModel.insert(i, { oid: ids[i] })
      else if (j !== i) orbModel.move(j, i, 1)
    }
    if (orbModel.count > ids.length) orbModel.remove(ids.length, orbModel.count - ids.length)
  }
  property var beamKeys: []
  property real clock: 2.3
  readonly property list<QtObject> regions: hitRegions.instances
  // The one caption (Mandrel.sceneCaption) for the moment the orbs show.
  readonly property string label: scene && nowMs && src && src.scene ? Mandrel.sceneCaption(src.scene, nowMs) : ""
  // AMPLIFY_TRACE=1: the moment and caption as drawn, for the one-clock check (tools/headless-shot.sh).
  // Each line names the screen, and the scene line the clock followed (SceneClock.clockId).
  readonly property string traceKey: "orbs" + (screenName ? "@" + screenName : "")
  onLabelChanged: if (trace && label !== "") console.log("amplify: caption " + traceKey + " " + label)
  onNowMsChanged: if (trace && scene) console.log("amplify: scene " + traceKey + " at " + new Date(nowMs).toISOString() + " clock " + (src ? src.clockId : "none"))

  function hueFor(role) {
    if (role === "coord") return Qt.tint(foreground, Qt.rgba(1, 1, 1, 0.25))
    if (role === "critic") return Qt.tint(accent, Qt.rgba(0.72, 0.63, 0.96, 0.6))
    return accent
  }

  // The orbs' eases start with this field's window's first frame (OrbView framed): the shared
  // clock's scene is ready before it, and an enter ease started then ran half way while the
  // window was still starting up, unseen. The step clock runs for the longest ease from it.
  property bool framed: false
  property real framedMs: 0
  Connections {
    target: field.Window.window
    enabled: !field.framed
    function onFrameSwapped() {
      field.framedMs = Date.now(); field.framed = true
      field.easeUntil = Math.max(field.easeUntil, field.framedMs + 1600)
    }
  }

  function tick() {
    if (!scene) return
    nowMs = fixedOffsetMs >= 0 ? fetchMs + fixedOffsetMs : src.nowMs
    var f = Orbs.frame(scene, nowMs, width, height, Mandrel.tickScene)
    if (f.ids.join() !== ids.join()) ids = f.ids
    var bk = f.beams.map(function (b) { return b.key })
    if (bk.join() !== beamKeys.join()) beamKeys = bk
    frame = f
  }

  // Replay: the capture as the last fetch (server liveness as read), ticked to the clock's
  // moment, or before the capture the clock's scene (the capture rewound to it); live: the
  // clock's fetch.
  function rebuild() {
    var c = src
    if (!c || !c.scene) return
    fetchMs = c.fetchMs
    if (!scene && !c.live) console.log("amplify: replay orbs " + Mandrel.replaySource(c.snapshot))
    if (c.live || c.nowMs < c.fetchMs) { scene = c.scene; tick(); return }
    var snap = c.snapshot, r = snap.responses
    scene = Mandrel.buildScene({
      sessions: r["/api/sessions"], tasks: r["/api/tasks"], contexts: r["/api/contexts"],
      decisions: r["/api/decisions"], projects: r["/api/projects"], sessionDetails: r["/api/sessions/:id"]
    }, { now: fetchMs, mode: "replay", label: "REPLAYED SNAPSHOT · " + (snap.meta.label || ""), baseUrl: snap.meta.base_url,
         projectId: snap.meta.project_id, fetchedAt: snap.meta.captured_at })
    tick()
  }
  onSrcChanged: rebuild()
  Connections {
    target: field.src
    function onSceneChanged() { field.rebuild() }
    function onNowMsChanged() { field.tick() }
  }
  onWidthChanged: tick()
  onHeightChanged: tick()

  // Spin clock (task 8b5eca2f): seconds that advance only while a drawn orb spins at its
  // liveness rate (orbs.js MATERIAL), in one step each time the fastest rim has turned
  // Orbs.SPIN_STEP_PX, at most 8 steps a second. So the window draws as often as its
  // records move pixels: about twice a second for a live orb, every 4-6 s for a lost
  // one, and never when every orb is dormant or ended. Each step adds the real time
  // since the last, so spins keep their rate.
  readonly property real rimSpeed: {
    var v = 0
    for (var i = 0; i < ids.length; i++) {
      var o = frame.orbs[ids[i]]
      if (o && o.spin > 0) v = Math.max(v, o.spin / 60 * 2 * Math.PI * o.r)
    }
    return v
  }
  readonly property bool spinning: animate && visible && rimSpeed > 0
  property real clockAt: 0
  onSpinningChanged: clockAt = Date.now()
  // The same clock paces the orbs' eases (OrbView Ease, task 118f6917): while one runs it
  // steps every 125 ms, so a window draws at most 8 frames a second for its spins and
  // eases together, and none between steps. stepMs is the wall time of the last step;
  // steps counts them (AMPLIFY_FPS logs both).
  property real stepMs: Date.now()
  property real easeUntil: 0
  property int steps: 0
  readonly property bool easing: animate && visible && stepMs < easeUntil
  Timer { id: spinClock
    running: field.spinning || field.easing; repeat: true
    interval: field.easing ? 125 : Math.max(125, 1000 * Orbs.SPIN_STEP_PX / Math.max(field.rimSpeed, 1e-3))
    onTriggered: {
      var t = Date.now()
      if (field.spinning) field.clock += (t - field.clockAt) / 1000
      field.clockAt = t; field.stepMs = t; field.steps++
    }
  }
  Loader {
    active: field.trace
    sourceComponent: Trace { comp: "orbs"; part: "clock"; ident: "field"; v: ({ x: field.clock, "x:rate": field.spinning ? 1 : 0 }) }
  }

  // Every drawn orb and beam program, for the ready line (Service.qml).
  function shaders() {
    var out = []
    for (var i = 0; i < beamRep.count; i++) if (beamRep.itemAt(i)) out = out.concat(beamRep.itemAt(i).shaders())
    for (var j = 0; j < rep.count; j++) if (rep.itemAt(j)) out = out.concat(rep.itemAt(j).shaders())
    return out
  }

  Repeater {
    id: beamRep
    model: field.beamKeys
    Beam {
      required property var modelData
      readonly property var row: field.frame.beams.filter(function (x) { return x.key === modelData })[0] || null
      a: row ? field.frame.orbs[row.from] || null : null
      b: row ? field.frame.orbs[row.to] || null : null
      alpha: row ? row.alpha : 0
      trace: field.trace
      hueFrom: a ? field.hueFor(a.role) : field.accent
      hueTo: b ? field.hueFor(b.role) : field.accent
    }
  }

  Repeater {
    id: rep
    model: orbModel
    OrbView {
      required property string oid
      orb: field.frame.orbs[oid] || null
      x: orb ? orb.x - width / 2 : 0
      y: orb ? orb.y - height / 2 : 0
      clock: field.clock
      stepMs: field.stepMs
      framed: field.framed
      framedMs: field.framedMs
      onEased: until => field.easeUntil = Math.max(field.easeUntil, until)
      animate: field.animate
      trace: field.trace
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
