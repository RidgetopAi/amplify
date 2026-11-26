import QtQuick

// One desktop orb: the role's own fragment program (orb_<role>.frag.qsb), its
// lease vessel when it holds a claim, and its nameplate. `orb` is one
// Orbs.orbProps() object; every uniform is read from it. Click opens the Amp
// thread (or the session in Mandrel): the viewer is read-only.
Item {
  id: view

  property var orb: null
  property real clock: 0          // the field's spin clock, seconds (OrbField)
  property bool animate: true     // false: no smoothing (deterministic shots)
  property bool trace: false      // AMPLIFY_TRACE=1: log drawn axes (plugin/motion/Trace.qml)
  property bool mono: false       // flat silhouette, for the role-shape proof
  property color hue: "#89b4fa"
  property color foreground: "#cdd6f4"
  property color alarm: "#e0786a"
  property color warm: "#ff9e74"
  readonly property real radius: orb ? orb.r : 30
  readonly property alias hitItem: hit
  signal activated(string url)
  // Its drawn programs, for the ready line (Service.qml): the body, and the vessel when shown.
  function shaders() { return !visible || opacity <= 0 ? [] : vessel.visible ? [fx, vesselFx] : [fx] }

  width: radius * 2 * 1.9
  height: width
  opacity: orb ? orb.endedFade : 1

  // Spin phase stays continuous when the liveness changes the rate.
  property real spinRate: orb ? orb.spin * 6.2832 / 60 : 0
  property real spinBase: 0
  property real spinFrom: 0
  onSpinRateChanged: { spinBase = spinBase + clock * (spinFrom - spinRate); spinFrom = spinRate }
  Component.onCompleted: spinFrom = spinRate

  // State changes ease over a second, so a decay reads as a decay. The eases step on the
  // field's step clock (OrbField `stepMs`, at most 8 steps a second), not on Qt's
  // animation driver: a NumberAnimation drew every frame between spin steps, and starting
  // one made every Amplify window draw a frame (task 118f6917).
  property real stepMs: 0          // the field's step clock, wall ms of its last step
  signal eased(real until)         // an ease started; the step clock runs until `until`
  component Ease: Item {          // a child of the view (`parent`); draws nothing
    visible: false
    required property real to      // what the record asks for
    property int duration: 900
    property bool quad: false      // InOutQuad, else linear
    property real from: 0
    property real goal: 0
    property real t0: 0
    property bool ready: false
    readonly property real value: {
      if (!ready || !parent.animate) return to
      var p = Math.min(1, Math.max(0, (parent.stepMs - t0) / duration))
      if (quad) p = p < 0.5 ? 2 * p * p : 1 - 2 * (1 - p) * (1 - p)
      return from + (goal - from) * p
    }
    // From what is drawn now; the step clock moves it on from the next step.
    onToChanged: if (ready) { from = value; goal = to; t0 = Date.now(); parent.eased(t0 + duration) }
    Component.onCompleted: { from = to; goal = to; ready = true }
  }
  Ease { id: satE; to: view.orb ? view.orb.sat : 0; duration: 1200; quad: true }
  Ease { id: lightE; to: view.orb ? view.orb.light : 0; duration: 1200; quad: true }
  Ease { id: dormE; to: view.orb ? view.orb.dorm : 0; duration: 1600 }
  Ease { id: lostE; to: view.orb ? view.orb.lost : 0; duration: 900 }
  Ease { id: needE; to: view.orb ? view.orb.need : 0; duration: 900 }
  Ease { id: endedE; to: view.orb ? view.orb.ended : 0; duration: 1500 }
  Ease { id: formE; to: view.orb ? view.orb.form : 1; duration: 800 }
  Ease { id: energyE; to: view.orb ? view.orb.energy : 0; duration: 800 }
  Ease { id: levelE; to: view.orb && view.orb.task ? view.orb.task.lease : 0; duration: 900 }

  // Drawn: the orb's centre and opacity, the eased material uniforms, spin angle
  // and lease level; '<axis>:to' is what the session record asks for.
  Loader {
    active: view.trace && !!view.orb
    sourceComponent: Trace {
      comp: "orbs"; part: "orb"; ident: view.orb ? view.orb.id8 : ""
      v: ({ x: view.x + view.width / 2, y: view.y + view.height / 2, opacity: view.opacity, rotation: fx.angle,
            sat: fx.sat, light: fx.light, dorm: fx.dorm, lost: fx.lost, need: fx.need, ended: fx.ended,
            form: fx.form, energy: fx.energy, length: vesselFx.level,
            "sat:to": view.orb.sat, "light:to": view.orb.light, "dorm:to": view.orb.dorm, "lost:to": view.orb.lost,
            "need:to": view.orb.need, "ended:to": view.orb.ended, "form:to": view.orb.form, "energy:to": view.orb.energy,
            "length:to": view.orb.task ? view.orb.task.lease : 0, "x:to": view.orb.x, "y:to": view.orb.y, "opacity:to": view.orb.endedFade,
            "rotation:rate": view.animate && view.visible ? view.orb.spin * 6.2832 / 60 : 0 })
    }
  }

  ShaderEffect {
    id: fx
    anchors.fill: parent
    blending: true
    fragmentShader: Qt.resolvedUrl("../shaders/orb_" + (view.orb ? view.orb.role : "worker") + ".frag.qsb")

    // Surface shimmer (swirl, stutter, alarm and needs-you breathing) is held at the field's
    // first clock value, as still mode draws it: no record drives it (task 8b5eca2f).
    // The surface still turns with the spin angle.
    property real time: 2.3
    property real angle: view.spinBase + view.clock * view.spinFrom
    property real sat: satE.value
    property real light: lightE.value
    property real energy: energyE.value
    property real form: formE.value
    property real dorm: dormE.value
    property real lost: lostE.value
    property real ended: endedE.value
    property real need: needE.value
    property real fuse: view.orb ? view.orb.fuse : -1
    property real pulse: view.orb ? view.orb.pulse : 1
    property real seed: view.orb ? view.orb.seed : 0
    property real mono: view.mono ? 1 : 0
    property real px: view.radius
    property color hue: view.hue
    property color alarm: view.alarm
    property color warm: view.warm

  }

  // Lease vessel, hung from the worker's knot (or below any holder's limb).
  Item {
    id: vessel
    visible: !!(view.orb && view.orb.task)
    readonly property real tetherPx: view.radius * (view.orb && view.orb.role === "worker" ? 0.32 : 0.42)
    width: view.radius * 0.95
    height: tetherPx + view.radius * 1.15
    x: (view.width - width) / 2
    y: view.height / 2 + view.radius * (view.orb && view.orb.role === "worker" ? 1.16 : 1.04)

    ShaderEffect {
      id: vesselFx
      anchors.fill: parent
      blending: true
      fragmentShader: Qt.resolvedUrl("../shaders/orbvessel.frag.qsb")
      property real time: 2.3   // meniscus held, as `time` above
      property real level: levelE.value
      property real held: view.orb && view.orb.task && view.orb.task.held ? 1 : 0
      property real wPx: width
      property real hPx: height
      property real tether: vessel.tetherPx
      // Mono (silhouette proof): neutral liquid and glass, so only shape carries the role.
      property color liquid: view.mono ? "#b4b4b4" : view.orb && view.orb.task ? view.orb.task.color : "#919ef7"
      property color glass: view.mono ? "#d0d0d0" : view.hue
    }

    Text {
      anchors.left: parent.right
      anchors.leftMargin: 4
      anchors.bottom: parent.bottom
      text: view.orb && view.orb.task ? view.orb.task.id8 + "\n" + view.orb.task.left : ""
      color: view.foreground
      opacity: 0.55
      font.family: "monospace"
      font.pixelSize: Math.max(8, view.radius * 0.24)
      lineHeight: 0.95
    }
  }

  // Nameplate.
  Column {
    anchors.horizontalCenter: parent.horizontalCenter
    y: vessel.visible ? vessel.y + vessel.height + 6 : view.height / 2 + view.radius * 1.45
    spacing: 2
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: view.orb ? view.orb.name : ""
      color: view.foreground
      opacity: view.orb && view.orb.untitled ? 0.5 : 0.92
      font.italic: !!(view.orb && view.orb.untitled)
      font.family: "sans-serif"
      font.pixelSize: Math.max(10, view.radius * 0.36)
      font.weight: Font.DemiBold
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: !view.orb ? "" : (view.radius < 26 ? view.orb.role + " · " + view.orb.liveness : view.orb.sub).toUpperCase()
      color: view.orb && view.orb.liveness === "lost" ? view.alarm : view.foreground
      opacity: view.orb && view.orb.liveness === "lost" ? 0.9 : 0.5
      font.family: "monospace"
      font.letterSpacing: 1.2
      font.pixelSize: Math.max(7, view.radius * 0.24)
    }
  }

  MouseArea {
    id: hit
    anchors.centerIn: parent
    width: view.radius * 2.2; height: width
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      var dx = mouse.x - width / 2, dy = mouse.y - height / 2
      if (dx * dx + dy * dy > width * width / 4 || !view.orb) return
      view.activated(view.orb.threadUrl || view.orb.url)
    }
  }
}
