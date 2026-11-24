import QtQuick

// An activity link between two orbs (scene.links[]): a strand from the
// sending orb's limb to the receiving orb's limb with a packet travelling in
// the link's direction. alpha fades with the link's age (Orbs.beams).
Item {
  id: beam

  property var a: null        // from orb {x, y, r}
  property var b: null        // to orb {x, y, r}
  property real alpha: 1
  property real clock: 0
  property bool trace: false
  property color hueFrom: "#89b4fa"
  property color hueTo: "#cdd6f4"

  readonly property real dx: a && b ? b.x - a.x : 0
  readonly property real dy: a && b ? b.y - a.y : 0
  readonly property real dist: Math.sqrt(dx * dx + dy * dy)
  readonly property real gapA: a ? a.r * 1.35 : 0
  readonly property real gapB: b ? b.r * 1.35 : 0
  readonly property real len: Math.max(0, dist - gapA - gapB)

  visible: !!(a && b) && len > 8
  x: a ? a.x + (dist > 0 ? dx / dist * gapA : 0) : 0
  y: a ? a.y + (dist > 0 ? dy / dist * gapA : 0) - height / 2 : 0
  width: len
  height: 24
  transform: Rotation { origin.x: 0; origin.y: beam.height / 2; angle: Math.atan2(beam.dy, beam.dx) * 180 / Math.PI }

  Loader {
    active: beam.trace
    sourceComponent: Trace {
      comp: "orbs"; part: "beam"; ident: beam.a && beam.b ? beam.a.id8 + ">" + beam.b.id8 : ""
      v: ({ x: beam.x, y: beam.y + beam.height / 2, length: beam.len, opacity: beam.visible ? beam.alpha : 0,
            rotation: Math.atan2(beam.dy, beam.dx) * 180 / Math.PI })
    }
  }

  // Its program, for the ready line (Service.qml); none while hidden, since only drawn effects compile.
  function shaders() { return visible ? [fx] : [] }

  ShaderEffect {
    id: fx
    anchors.fill: parent
    blending: true
    fragmentShader: Qt.resolvedUrl("../shaders/orbbeam.frag.qsb")
    property real time: beam.clock
    property real alpha: beam.alpha
    property real lenPx: beam.len
    property real hPx: beam.height
    property color hueFrom: beam.hueFrom
    property color hueTo: beam.hueTo
  }
}
