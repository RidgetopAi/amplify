import Quickshell
import QtQuick
import "mandrel.js" as Mandrel  // copy of data/mandrel.js (tools/sync-shared.sh): Quickshell blocks imports outside plugin/
import "puck.js" as P

// Puck (task 23a62966): the cel die-cut sticker at desktop size (PuckLayer), the raymarched
// figurine in focus (figurine: true). Curious by default; he blinks when the scene's
// newest activity moves on, his eyes follow the pointer while it is on him, and his finger
// goes up while something needs you. A click runs Amp's `amp-desktop --puck`.
// Every motion is a Behavior or a one-shot animation on a value the records (or the pointer)
// set, so with the data unchanged and no pointer on him nothing animates and his window
// draws no frames (no FrameAnimation, no time uniform, no per-frame timer).
Item {
  id: puck

  property var scene: null        // the scene clock's scene (SceneClock.qml)
  property real nowMs: 0          // the moment it shows
  property bool figurine: false   // true: the figurine (focus); false: the cel sticker (desktop)
  property bool animate: true     // false: no smoothing, no blink (AMPLIFY_STILL=1, shots)
  property bool trace: false      // AMPLIFY_TRACE=1: log drawn axes (plugin/motion/Trace.qml)
  property string ident: "puck"
  // Glaze (the lab's "nebula"): Puck keeps his own colours on every theme.
  property color colA: Qt.rgba(0.30, 0.12, 0.62, 1)
  property color colB: Qt.rgba(0.06, 0.05, 0.22, 1)
  property color colC: Qt.rgba(0.45, 0.75, 1.00, 1)
  readonly property alias hitItem: hit
  readonly property alias shaderItem: fx
  signal ran(var argv)

  width: 210
  height: width

  // Records: the scene's newest activity (Mandrel.lastActivityMs, the moment the caption
  // reads) and its needs-you rows.
  readonly property var activityMs: scene ? Mandrel.lastActivityMs(scene, nowMs) : null
  readonly property int needs: P.needs(scene)

  // Pointer, written by the hit area (tests set these directly).
  property bool pointing: false
  property real pointerX: width / 2
  property real pointerY: height / 2

  // Glance: toward the pointer while it is on Puck, else at the viewer.
  readonly property var lookTo: pointing ? P.look(pointerX - width / 2, pointerY - height / 2, width * 0.45) : P.REST_LOOK
  property real lookX: lookTo.x
  property real lookY: lookTo.y
  Behavior on lookX { enabled: puck.animate; SpringAnimation { spring: 3.2; damping: 0.55; epsilon: 0.003 } }
  Behavior on lookY { enabled: puck.animate; SpringAnimation { spring: 3.2; damping: 0.55; epsilon: 0.003 } }
  // The raised finger.
  property real raise: P.raise(scene, pointing)
  Behavior on raise { enabled: puck.animate; SpringAnimation { spring: 2.6; damping: 0.5; epsilon: 0.003 } }
  // Curious mouth; a wider smile on hover.
  property real mouth: P.mouth(pointing)
  Behavior on mouth { enabled: puck.animate; NumberAnimation { duration: 280; easing.type: Easing.OutQuad } }
  property real mouthHalf: P.mouthHalf(pointing)
  Behavior on mouthHalf { enabled: puck.animate; NumberAnimation { duration: 280; easing.type: Easing.OutQuad } }

  // Blink: one, each time the newest activity moves later than the one seen (puck.js blinks).
  property real lid: 0
  property var seenMs: null
  onActivityMsChanged: {
    if (P.blinks(seenMs, activityMs) && animate) blinkAnim.restart()
    if (activityMs !== null) seenMs = activityMs
  }
  SequentialAnimation {
    id: blinkAnim
    NumberAnimation { target: puck; property: "lid"; to: 1; duration: 90; easing.type: Easing.InQuad }
    NumberAnimation { target: puck; property: "lid"; to: 0; duration: 170; easing.type: Easing.OutQuad }
  }

  // The one action: Amp's desktop Puck. Never a URL: Puck has no Mandrel record to open.
  function activate() {
    var argv = P.command()
    console.log("amplify: puck run " + argv.join(" "))
    Quickshell.execDetached(argv)
    ran(argv)
  }

  // Drawn: lid, glance, finger and mouth as the shader gets them; '<axis>:to' is what the
  // record (or the pointer) asks for; 'lid:on' is 1 while a blink runs.
  Loader {
    active: puck.trace
    sourceComponent: Trace { comp: "puck"; part: "lid"; ident: puck.ident; v: ({ lid: fx.blink, "lid:on": blinkAnim.running ? 1 : 0 }) }
  }
  Loader {
    active: puck.trace
    sourceComponent: Trace { comp: "puck"; part: "glance"; ident: puck.ident; v: ({ x: fx.lookX, y: fx.lookY, "x:to": puck.lookTo.x, "y:to": puck.lookTo.y }) }
  }
  Loader {
    active: puck.trace
    sourceComponent: Trace { comp: "puck"; part: "finger"; ident: puck.ident; v: ({ raise: fx.raise, "raise:to": P.raise(puck.scene, puck.pointing) }) }
  }
  Loader {
    active: puck.trace
    sourceComponent: Trace {
      comp: "puck"; part: "mouth"; ident: puck.ident
      v: ({ bend: fx.mouth, half: fx.mouthHalf, "bend:to": P.mouth(puck.pointing), "half:to": P.mouthHalf(puck.pointing) })
    }
  }

  ShaderEffect {
    id: fx
    anchors.fill: parent
    blending: true
    fragmentShader: Qt.resolvedUrl("../shaders/puck_" + (puck.figurine ? "figurine" : "cel") + ".frag.qsb")
    property real lookX: puck.lookX
    property real lookY: puck.lookY
    property real blink: puck.lid
    property real raise: puck.raise
    property real mouth: puck.mouth
    property real mouthHalf: puck.mouthHalf
    property real brow: P.BROW
    property real sizePx: width
    property color colA: puck.colA
    property color colB: puck.colB
    property color colC: puck.colC
  }

  // The figure, not the transparent corners, takes the pointer.
  MouseArea {
    id: hit
    anchors.centerIn: parent
    width: puck.width * 0.72
    height: puck.height * 0.78
    acceptedButtons: Qt.LeftButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: puck.pointing = containsMouse
    onPositionChanged: mouse => { puck.pointerX = hit.x + mouse.x; puck.pointerY = hit.y + mouse.y }
    onClicked: puck.activate()
  }
}
