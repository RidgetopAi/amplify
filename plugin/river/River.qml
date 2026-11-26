import QtQuick
import QtQuick.Shapes
import "river.js" as R

// The Current river (direction c755578f): the punch lifecycle as a river.
// Lanes draft → ready → claimed → verifying → evidence → merged → trunk flow
// left to right; each task is a vessel in the lane the scene model gives it
// (lane mapping c1f75776); a claim is a tether from its holder whose lit length
// is the lease left; a critic PASS throws a gold ring, a REJECT spins an eddy and
// sends the vessel back upstream. Every motion here comes from the scene:
//  - water flow speed and light: recent task updates and live sessions;
//  - vessel travel: a lane change between two scenes;
//  - tether light: claimExpiresAt against the scene clock;
//  - rings and eddies: verifying → downstream / verifying|evidence → upstream;
//  - a slow swirl: a blocked task (an eddy in place).
// Read-only: nothing here writes to Mandrel.
Item {
  id: river

  // The scene clock every component reads (Service.qml); unset, the river makes its own.
  property var sceneClock: null
  property var feed: ownFeed
  RiverFeed { id: ownFeed; sceneClock: river.sceneClock }
  // The screen this river is drawn on (Service.qml), which keys its traced lines: "river@<screen>".
  property string screenName: ""
  readonly property string traceKey: "river" + (screenName ? "@" + screenName : "")
  // AMPLIFY_TRACE=1: the scene time the river is drawn at and the clock it follows
  // (SceneClock.clockId), for the one-clock check (tools/headless-shot.sh).
  readonly property real shownMs: feed ? feed.nowMs : 0
  onShownMsChanged: if (trace && shownMs) console.log("amplify: scene " + traceKey + " at " + new Date(shownMs).toISOString()
                                                       + " clock " + (feed && feed.src ? feed.src.clockId : "none"))
  property bool animate: true
  // Trace mode (AMPLIFY_TRACE=1, shot.sh): each moving item makes a Trace
  // (plugin/motion/Trace.qml) that logs what it draws as it changes, with the
  // value its record asks for, so tools/motion/follow.mjs checks the path
  // against docs/motion.json. Off, the Loaders below create nothing.
  property bool trace: false

  readonly property real k: height > 0 ? height / 1080 : 1
  readonly property real dw: height > 0 ? 1080 * width / height : 1920
  readonly property var lay: feed && feed.scene ? R.layout(feed.scene, feed.nowMs, dw) : null
  property real phase: 0
  property int loggedSerial: -1

  readonly property string mono: "JetBrains Mono, DejaVu Sans Mono, monospace"
  readonly property string sans: "Inter, Noto Sans, DejaVu Sans, sans-serif"

  // Its shader program, for the ready line (Service.qml).
  function shaders() { return [water] }

  function cy(x) { return R.centerY(x, dw) }
  function hw(x) { return R.halfWidth(x, dw) }
  function gateX(i) { return lay ? lay.gates[i].x : dw * (0.025 + i * 0.139) }
  function alpha(c, a) { return Qt.rgba(Qt.color(c).r, Qt.color(c).g, Qt.color(c).b, a) }

  // Keep delegates alive across scenes (keyed by task id) so a lane change
  // animates the vessel instead of recreating it at its new place.
  function sync(model, arr) {
    for (var i = 0; i < arr.length; i++) {
      var j = -1
      for (var m = i; m < model.count; m++) if (model.get(m).key === arr[i].key) { j = m; break }
      if (j < 0) model.insert(i, arr[i])
      else { if (j !== i) model.move(j, i, 1); model.set(i, arr[i]) }
    }
    if (model.count > arr.length) model.remove(arr.length, model.count - arr.length)
  }

  onLayChanged: refresh()
  function refresh() {
    if (!lay) return
    // Gates keyed by lane, so a lane that widens slides its gate (row 2).
    sync(gates, lay.gates.map(function (g) {
      return { key: g.lane, lane: g.lane, label: g.label, color: g.color, gx: g.x, count: g.count,
               more: lay.overflow[g.lane] || 0 }
    }))
    var vx = {}
    sync(vessels, lay.vessels.map(function (v) {
      vx[v.id] = v
      return { key: v.id, id8: v.id8, lane: v.lane, tone: v.color, px: v.x, off: v.off,
               eddy: v.eddy, needsYou: v.needsYou }
    }))
    sync(tethers, lay.tethers.map(function (t) {
      return { key: t.id, id8: t.id8, holder: t.holder, mx: t.mx, my: t.my, expired: t.expired,
               fraction: t.fraction, text: t.text, tone: t.tone, liveness: t.holderLiveness || "",
               vx: vx[t.id].x, voff: vx[t.id].off }
    }))
  }
  // Once per scene, after spawn, so fx= counts the effects this scene draws.
  function logScene() {
    if (!lay || feed.serial === loggedSerial) return
    loggedSerial = feed.serial
    console.log("amplify: river lanes " + lay.gates.map(function (g) { return g.label + "=" + g.count }).join(" ")
        + " vessels=" + lay.vessels.length + " tethers=" + lay.tethers.length
        + " expired=" + lay.tethers.filter(function (t) { return t.expired }).map(function (t) { return t.id8 }).join(",")
        + " flow=" + lay.flow.toFixed(2) + " speed=" + speed.toFixed(1) + " fx=" + effects.count
        + " at=" + new Date(feed.nowMs).toISOString())
    // Where each blocked swirl is centred, in screen px (shot.sh checks it turns on this hull).
    lay.vessels.forEach(function (v) {
      if (v.eddy) console.log("amplify: river eddy " + v.id8 + " at " + Math.round(v.x * k) + "," + Math.round((cy(v.x) + v.off) * k))
    })
  }

  // A verdict effect lives for one event. Animated, it ends when its animation
  // does (dropFx); still, it shows at p = 0.5 until the next scene step.
  function spawn(events) {
    if (!animate) while (effects.count) dropFx(effects.get(0).uid)
    if (!lay || !events || !events.length) return
    var prev = feed.prevScene ? R.layout(feed.prevScene, feed.nowMs, dw) : null
    events.forEach(function (e) {
      if (e.kind !== "pass" && e.kind !== "reject") return
      var to = lay.vessels.filter(function (v) { return v.id === e.taskId })[0]
      var from = prev ? prev.vessels.filter(function (v) { return v.id === e.taskId })[0] : null
      if (!to) return
      var fx = from ? from.x : to.x, fy = cy(to.x) + to.off, box
      if (e.kind === "pass") box = [to.x - 110, fy - 110, to.x + 250, fy + 110]
      else {
        var ay = cy(fx) + (from ? from.off : to.off) - 16
        var qy = Math.min(ay, fy - 18) - 70 - Math.abs(fx - to.x - 30) * 0.12
        box = [Math.min(fx - 90, to.x - 140), qy - 15, Math.max(fx + 90, to.x + 140), fy + 72]
      }
      // box: the screen px the effect may draw in (shot.sh checks it goes still).
      console.log("amplify: river fx " + e.kind + " " + e.id8 + " → " + e.to
                  + " box=" + box.map(function (b) { return Math.round(b * k) }).join(",")
                  + " at " + Math.round(to.x * k) + "," + Math.round(fy * k))
      effects.append({ uid: e.taskId + "@" + feed.serial, kind: e.kind, id8: e.id8, to: e.to,
                       px: to.x, off: to.off, fromX: from ? from.x : to.x, fromOff: from ? from.off : to.off })
    })
  }
  function dropFx(uid) {
    for (var i = 0; i < effects.count; i++) if (effects.get(i).uid === uid) {
      console.log("amplify: river fx done " + effects.get(i).kind + " " + effects.get(i).id8)
      effects.remove(i)
      return
    }
  }

  ListModel { id: gates }
  ListModel { id: vessels }
  ListModel { id: tethers }
  ListModel { id: effects }

  Connections {
    target: river.feed
    function onSerialChanged() { river.spawn(river.feed.events); river.logScene() }
  }
  Component.onCompleted: { refresh(); if (feed) spawn(feed.events); logScene() }

  // The current advances only as fast as the work does; with no recent task
  // updates the speed is 0 and the frame clock stops, so idle water is still.
  readonly property real speed: R.flowSpeed(lay ? lay.flow : 0)
  FrameAnimation {
    id: waterClock
    running: river.animate && river.visible && river.speed > 0
    onTriggered: river.phase += river.speed * frameTime
  }
  Loader {
    active: river.trace
    sourceComponent: Trace { comp: "river"; part: "water"; ident: "phase"; v: ({ x: river.phase, "x:rate": river.animate && river.visible ? river.speed : 0 }) }
  }

  Item {
    id: canvas
    width: river.dw; height: 1080
    scale: river.k; transformOrigin: Item.TopLeft

    // ---------------------------------------------------------------- water
    Item {
      anchors.fill: parent
      layer.enabled: true
      layer.smooth: true
      layer.textureSize: Qt.size(Math.max(1, Math.round(river.width / 2)), Math.max(1, Math.round(river.height / 2)))
      ShaderEffect {
        id: water
        anchors.fill: parent
        property real phase: river.phase
        property real light: river.lay ? river.lay.light : 0.55
        property real flow: river.lay ? river.lay.flow : 0
        property size size: Qt.size(river.dw, 1080)
        property vector4d g0: Qt.vector4d(river.gateX(0), river.gateX(1), river.gateX(2), river.gateX(3))
        property vector4d g1: Qt.vector4d(river.gateX(4), river.gateX(5), river.gateX(6), 0)
        fragmentShader: Qt.resolvedUrl("river.frag.qsb")   // copy of plugin/shaders/river.frag.qsb
      }
    }

    // ---------------------------------------------------------------- gates
    Repeater {
      model: gates
      Item {
        id: gate
        property real gx: model.gx
        Behavior on gx { enabled: river.animate; SpringAnimation { spring: 1.2; damping: 0.4; epsilon: 0.2 } }
        readonly property real gy: river.cy(gx)
        readonly property real gw: river.hw(gx)
        x: gx; y: 0
        Loader {
          active: river.trace
          sourceComponent: Trace { comp: "river"; part: "gate"; ident: model.lane; v: ({ x: gate.x + gateLine.x, "x:to": model.gx }) }
        }

        Rectangle {
          id: gateLine
          x: 0; y: gy - gw - 12; width: 1.2; height: gw * 2 + 44
          gradient: Gradient {
            GradientStop { position: 0; color: river.alpha(model.color, 0) }
            GradientStop { position: 0.5; color: river.alpha(model.color, 0.55) }
            GradientStop { position: 1; color: river.alpha(model.color, 0) }
          }
        }
        Text {
          x: 7; y: gy + gw + 14
          text: (model.lane === "deployed" ? "→ " : "") + model.label.toUpperCase()
          color: river.alpha(model.color, 0.88)
          font { family: river.mono; pixelSize: 11; weight: Font.DemiBold; letterSpacing: 1.6 }
        }
        Text {
          x: 7; y: gy + gw + 31
          text: model.count + (model.more ? "  +" + model.more + " more" : "")
          color: river.alpha(model.color, model.count ? 0.95 : 0.32)
          font { family: river.sans; pixelSize: 16; weight: Font.Medium }
        }
      }
    }

    // ---------------------------------------------------------------- tethers
    Repeater {
      model: tethers
      Item {
        id: teth
        anchors.fill: parent
        property real vx: model.vx
        Behavior on vx { enabled: river.animate; SpringAnimation { spring: 1.4; damping: 0.32; epsilon: 0.2 } }
        // The hull's row offset, eased like the vessel's so the end stays on the hull.
        property real voff: model.voff
        Behavior on voff { enabled: river.animate; SpringAnimation { spring: 1.4; damping: 0.32; epsilon: 0.2 } }
        property real f: model.fraction
        Behavior on f { enabled: river.animate; NumberAnimation { duration: river.feed ? river.feed.stepMs : 1000 } }
        // Still mode: what this tether draws (lit fraction, colour, holder, and
        // the drawn lit and spent paths: start, control, end), for shot.sh.
        readonly property string drawn: "lit=" + f.toFixed(4) + " tone=" + model.tone + " holder=" + (model.liveness || "none")
            + " path=" + [litPath.startX, litPath.startY, litQ.controlX, litQ.controlY, litQ.x, litQ.y,
                          spentPath.startX, spentPath.startY, spentQ.controlX, spentQ.controlY, spentQ.x, spentQ.y]
                         .map(function (v) { return v.toFixed(2) }).join(",")
        function logDrawn() { if (!river.animate) console.log("amplify: river tether " + model.id8 + " " + drawn) }
        onDrawnChanged: logDrawn()
        Component.onCompleted: logDrawn()
        // Drawn: the spent stroke's hull end and the knot (hull centre y = end + 12), the lit fraction.
        Loader {
          active: river.trace
          sourceComponent: Trace {
            comp: "river"; part: "tether"; ident: model.id8
            v: ({ x: spentQ.x, y: spentQ.y + 12, off: spentQ.y + 12 - river.cy(spentQ.x), kx: knot.x + 2, ky: knot.y + 14,
                  length: teth.f, "x:to": model.vx, "off:to": model.voff, "length:to": model.fraction })
          }
        }

        readonly property real x0: model.mx
        readonly property real y0: model.my
        readonly property real x2: vx
        readonly property real y2: river.cy(vx) + voff - 12
        // Taut while leased (arrives straight down, between the hulls above);
        // slack and sagging below the chord once the lease is gone.
        readonly property real x1: model.expired ? (x0 + x2) / 2 : x2
        readonly property real y1: model.expired ? Math.max(y0, y2) + 26 : y0 + (y2 - y0) * 0.42
        // de Casteljau split at f: [0, f] is lit (lease left), [f, 1] is spent.
        readonly property real bx: (1 - f) * (1 - f) * x0 + 2 * (1 - f) * f * x1 + f * f * x2
        readonly property real by: (1 - f) * (1 - f) * y0 + 2 * (1 - f) * f * y1 + f * f * y2

        Shape {
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            id: spentPath
            strokeColor: river.alpha(model.tone, model.expired ? 0.45 : 0.3)
            strokeWidth: 1.1
            strokeStyle: ShapePath.DashLine
            dashPattern: [2, 4]
            fillColor: "transparent"
            startX: teth.bx; startY: teth.by
            PathQuad { id: spentQ; x: teth.x2; y: teth.y2; controlX: teth.x1 + teth.f * (teth.x2 - teth.x1); controlY: teth.y1 + teth.f * (teth.y2 - teth.y1) }
          }
          ShapePath {
            id: litPath
            strokeColor: river.alpha(model.tone, 0.85)
            strokeWidth: model.expired ? 0 : 1.8
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            startX: teth.x0; startY: teth.y0
            PathQuad { id: litQ; x: teth.bx; y: teth.by; controlX: teth.x0 + teth.f * (teth.x1 - teth.x0); controlY: teth.y0 + teth.f * (teth.y1 - teth.y0) }
          }
        }
        // glow under the lit length's tip, and the knot on the hull
        Rectangle {
          visible: !model.expired
          x: teth.bx - 7; y: teth.by - 7; width: 14; height: 14; radius: 7
          color: river.alpha(model.tone, 0.18)
        }
        Rectangle {
          visible: !model.expired
          x: teth.bx - 2.6; y: teth.by - 2.6; width: 5.2; height: 5.2; radius: 2.6
          color: model.tone
        }
        Rectangle {
          id: knot
          x: teth.x2 - 2; y: teth.y2 - 2; width: 4; height: 4; radius: 2
          color: river.alpha(model.tone, model.expired ? 0.5 : 0.9)
        }
        // mooring: the holder
        Rectangle {
          x: teth.x0 - 4.5; y: teth.y0 - 4.5; width: 9; height: 9; radius: 4.5
          color: "#0b0f16"; border.width: 1.4; border.color: model.tone
        }
        Text {
          x: teth.x0 - width / 2; y: teth.y0 - 38
          text: model.holder
          color: river.alpha(model.tone, model.expired ? 0.7 : 1)
          font { family: river.mono; pixelSize: 12; weight: Font.Medium }
        }
        Text {
          x: teth.x0 - width / 2; y: teth.y0 - 22
          text: model.text
          color: river.alpha(model.tone, model.expired ? 0.6 : 0.7)
          font { family: river.mono; pixelSize: 10; italic: model.expired }
        }
      }
    }

    // ---------------------------------------------------------------- vessels
    Repeater {
      model: vessels
      Item {
        id: hull
        property real vx: model.px
        Behavior on vx { enabled: river.animate; SpringAnimation { spring: 1.4; damping: 0.32; epsilon: 0.2 } }
        // Row offset: a vessel that changes row eases there instead of hopping.
        property real voff: model.off
        Behavior on voff { enabled: river.animate; SpringAnimation { spring: 1.4; damping: 0.32; epsilon: 0.2 } }
        readonly property real len: 14 + 22 * (river.lay ? river.lay.flow : 0)
        x: vx - R.HULL / 2; y: river.cy(vx) + voff - 11
        width: R.HULL; height: 22
        // Drawn hull centre; off is its row offset from the river's centre line there.
        Loader {
          active: river.trace
          sourceComponent: Trace {
            comp: "river"; part: "vessel"; ident: model.id8
            v: ({ x: hull.x + R.HULL / 2, y: hull.y + 11, off: hull.y + 11 - river.cy(hull.x + R.HULL / 2),
                  "x:to": model.px, "off:to": model.off })
          }
        }
        Loader {
          active: river.trace
          sourceComponent: Trace { comp: "river"; part: "swirl"; ident: model.id8; v: ({ rotation: swirl.rotation, on: swirl.visible ? 1 : 0, "rotation:rate": river.animate && river.visible && model.eddy ? -40 : 0 }) }
        }

        // wake: water passing the hull, as long as the current is strong
        Repeater {
          model: 3
          Rectangle {
            required property int index
            x: -5 - index * 3 - hull.len; y: 5 + index * 6; height: 1
            width: hull.len - index * 3
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: river.alpha(model.tone, 0) }
              GradientStop { position: 1; color: river.alpha(model.tone, 0.22 - index * 0.05) }
            }
          }
        }
        // blocked: an eddy turning in place. The arcs are centred on the
        // Shape's (0, 0), which sits on the hull centre; the default
        // transformOrigin (centre of the arcs' bounding box) would make the
        // swirl orbit off its hull, onto neighbouring vessels.
        Shape {
          id: swirl
          visible: model.eddy
          // Each hull that shows a swirl (shot.sh: only blocked tasks do).
          function logShown() { if (visible) console.log("amplify: river swirl " + model.id8) }
          onVisibleChanged: logShown()
          Component.onCompleted: logShown()
          x: hull.width / 2; y: hull.height / 2
          transformOrigin: Item.TopLeft
          preferredRendererType: Shape.CurveRenderer
          RotationAnimation on rotation { running: river.animate && river.visible && model.eddy; from: 0; to: -360; duration: 9000; loops: Animation.Infinite }
          transform: Scale { yScale: 0.5 }
          ShapePath {
            strokeColor: river.alpha(model.tone, 0.55); strokeWidth: 1.4; fillColor: "transparent"
            PathAngleArc { radiusX: 54; radiusY: 54; startAngle: 0; sweepAngle: 250 }
          }
          ShapePath {
            strokeColor: river.alpha(model.tone, 0.32); strokeWidth: 1.2; fillColor: "transparent"
            PathAngleArc { radiusX: 66; radiusY: 66; startAngle: 140; sweepAngle: 220 }
          }
        }
        Rectangle {
          anchors.fill: parent; anchors.margins: -5; radius: height / 2
          color: river.alpha(model.tone, 0.10)
        }
        Rectangle {
          anchors.fill: parent; radius: height / 2
          color: "#e60a0e16"
          border.width: 1.3; border.color: river.alpha(model.tone, 0.85)
        }
        Rectangle {
          x: 8; y: 7.8; width: 6.4; height: 6.4; radius: 3.2
          color: model.tone
        }
        Text {
          x: 20; anchors.verticalCenter: parent.verticalCenter
          text: model.id8
          color: "#e8ecf4"
          font { family: river.mono; pixelSize: 11; weight: Font.Medium }
        }
      }
    }

    // ---------------------------------------------------------------- verdicts
    Repeater {
      model: effects
      Item {
        id: fxi
        anchors.fill: parent
        property real p: river.animate ? 0 : 0.5
        NumberAnimation on p {
          running: river.animate; from: 0; to: 1; duration: 3200
          // One closure per effect: Qt.callLater merges calls to the same
          // function, so two effects ending together would drop only one.
          onFinished: { var uid = model.uid; Qt.callLater(function () { river.dropFx(uid) }) }
        }
        readonly property real cx: model.px
        readonly property real cyv: river.cy(model.px) + model.off
        readonly property real fade: 1 - p * p

        // critic PASS: a gold ring thrown from the hull
        Item {
          id: passFx
          visible: model.kind === "pass"
          anchors.fill: parent
          // Drawn: the arc's opacity (0 when hidden), radius and sweep.
          Loader {
            active: river.trace && model.kind === "pass"
            sourceComponent: Trace {
              comp: "river"; part: "pass"; ident: model.id8
              v: ({ opacity: passFx.visible && fxi.visible ? passArcPath.strokeColor.a : 0, length: passArc.radiusX, sweep: passArc.sweepAngle })
            }
          }
          Rectangle {
            x: fxi.cx - r; y: fxi.cyv - r; width: r * 2; height: r * 2; radius: r
            readonly property real r: 12 + fxi.p * 40
            color: river.alpha(R.PASS_GOLD, 0.22 * fxi.fade)
          }
          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              id: passArcPath
              strokeColor: river.alpha(R.PASS_GOLD, 0.95 * fxi.fade); strokeWidth: 2.2; fillColor: "transparent"
              capStyle: ShapePath.RoundCap
              PathAngleArc {
                id: passArc
                centerX: fxi.cx; centerY: fxi.cyv
                radiusX: 14 + fxi.p * 84; radiusY: radiusX
                startAngle: -90; sweepAngle: 360 * Math.min(1, fxi.p * 1.7)
              }
            }
          }
          Text {
            x: fxi.cx + 34 + fxi.p * 30; y: fxi.cyv - 56 - fxi.p * 10
            text: "PASS"
            color: river.alpha("#f5dca0", fxi.fade)
            font { family: river.mono; pixelSize: 13; weight: Font.Bold; letterSpacing: 1.5 }
          }
          Text {
            x: fxi.cx + 34 + fxi.p * 30; y: fxi.cyv - 40 - fxi.p * 10
            text: "critic · " + model.id8 + " → " + model.to
            color: river.alpha("#e9c47c", 0.8 * fxi.fade)
            font { family: river.mono; pixelSize: 10 }
          }
        }

        // REJECT: an eddy where the vessel lands, and its path back upstream
        Item {
          id: rej
          visible: model.kind === "reject"
          anchors.fill: parent
          readonly property real ax: model.fromX
          readonly property real ay: river.cy(model.fromX) + model.fromOff - 16
          readonly property real ex: fxi.cx + 30
          readonly property real ey: fxi.cyv - 18
          readonly property real qx: (ax + ex) / 2
          readonly property real qy: Math.min(ay, ey) - 70 - Math.abs(ax - ex) * 0.12
          readonly property real ang: Math.atan2(ey - qy, ex - qx)

          Item {
            id: rings
            x: fxi.cx; y: fxi.cyv
            rotation: -fxi.p * 140
            Loader {
              active: river.trace && model.kind === "reject"
              sourceComponent: Trace { comp: "river"; part: "rings"; ident: model.id8; v: ({ rotation: rings.rotation }) }
            }
            // Still mode: where the turned rings are centred, in screen px, and
            // how far they have turned (shot.sh checks they turn about the
            // landing point, by 70 degrees at p = 0.5).
            Component.onCompleted: if (model.kind === "reject") {
              if (!river.animate) Qt.callLater(function () {
                var c = rings.mapToItem(river, 0, 0)
                console.log("amplify: river fx rings " + model.id8 + " at " + Math.round(c.x) + "," + Math.round(c.y) + " rot=" + rings.rotation.toFixed(1))
              })
            }
            transform: Scale { yScale: 0.62 }
            Shape {
              preferredRendererType: Shape.CurveRenderer
              ShapePath {
                strokeColor: river.alpha("#c8b4ff", 0.85 * fxi.fade); strokeWidth: 2; fillColor: "transparent"
                PathAngleArc { radiusX: 18 + fxi.p * 12; radiusY: radiusX; startAngle: 0; sweepAngle: 240 }
              }
              ShapePath {
                strokeColor: river.alpha("#c8b4ff", 0.62 * fxi.fade); strokeWidth: 1.7; fillColor: "transparent"
                PathAngleArc { radiusX: 32 + fxi.p * 14; radiusY: radiusX; startAngle: 52; sweepAngle: 240 }
              }
              ShapePath {
                strokeColor: river.alpha("#c8b4ff", 0.42 * fxi.fade); strokeWidth: 1.4; fillColor: "transparent"
                PathAngleArc { radiusX: 46 + fxi.p * 16; radiusY: radiusX; startAngle: 104; sweepAngle: 240 }
              }
              ShapePath {
                strokeColor: river.alpha("#c8b4ff", 0.25 * fxi.fade); strokeWidth: 1.2; fillColor: "transparent"
                PathAngleArc { radiusX: 60 + fxi.p * 18; radiusY: radiusX; startAngle: 156; sweepAngle: 240 }
              }
            }
          }
          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              strokeColor: river.alpha("#c8b4ff", 0.7 * fxi.fade); strokeWidth: 1.4; fillColor: "transparent"
              strokeStyle: ShapePath.DashLine; dashPattern: [4, 3]
              startX: rej.ax; startY: rej.ay
              PathQuad { x: rej.ex; y: rej.ey; controlX: rej.qx; controlY: rej.qy }
            }
            ShapePath {
              strokeColor: "transparent"; fillColor: river.alpha("#c8b4ff", 0.85 * fxi.fade)
              startX: rej.ex; startY: rej.ey
              PathLine { x: rej.ex - 9 * Math.cos(rej.ang - 0.45); y: rej.ey - 9 * Math.sin(rej.ang - 0.45) }
              PathLine { x: rej.ex - 9 * Math.cos(rej.ang + 0.45); y: rej.ey - 9 * Math.sin(rej.ang + 0.45) }
              PathLine { x: rej.ex; y: rej.ey }
            }
          }
          Text {
            x: fxi.cx - width / 2; y: fxi.cyv + 48
            text: "REJECT ↺ back to " + model.to + " · " + model.id8
            color: river.alpha("#d6beff", fxi.fade)
            font { family: river.mono; pixelSize: 12; weight: Font.DemiBold }
          }
        }
      }
    }

    // ---------------------------------------------------------------- caption
    Text {
      visible: text !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      y: 40
      // The one caption (Mandrel.sceneCaption, task 679fbbc5): the moment shown and its last
      // activity, to the minute, the same text the orbs and basin draw.
      text: river.feed ? river.feed.caption : ""
      // AMPLIFY_TRACE=1: the moment and caption as drawn, for the one-clock check (tools/headless-shot.sh).
      onTextChanged: if (river.trace && text !== "") console.log("amplify: caption " + river.traceKey + " " + text)
      color: "#7d8799"
      font { family: river.mono; pixelSize: 11; letterSpacing: 1.6 }
    }
  }
}
