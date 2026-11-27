import QtQuick
import "meridian.js" as G

// Meridian, the focused orb (task 85ff482a, decision 49f5d444). One session's globe, flown
// from its desktop orb to the centre of the screen. Every drawn value comes from the scene
// the orbs read (OrbField.scene at OrbField.nowMs, viewer contract 22d73eeb) through
// meridian.js globe(): time is longitude, record type latitude, trust plaque brightness,
// the claim lease the lit arc east of now. The hand turns it (drag, inertia, loupe detent).
// One FrameAnimation drives the fly and the spin and runs only while one of them moves:
// settled, with the record unchanged, nothing here asks for a frame.
Item {
  id: m

  property var field: null          // the OrbField whose orb was clicked
  property string sessionId: ""
  property real fromX: 0            // the desktop orb, where the fly starts and ends
  property real fromY: 0
  property real fromR: 30
  property bool animate: true
  property bool trace: false
  property color accent: "#89b4fa"
  property color foreground: "#cdd6f4"
  signal closed()

  // Landed geometry: centre and globe radius (px).
  readonly property real toX: width / 2
  readonly property real toY: height * 0.52
  readonly property real toR: Math.max(60, Math.min(height * 0.42, (width - 760) / 2.4))
  // goal: 1 while focused, 0 when flying home; fly follows it (0 = at the desktop orb).
  property real goal: 0
  property real fly: 0
  property real flyT: 0
  readonly property real flySec: 0.7
  readonly property bool flying: fly !== goal
  readonly property real cx: fromX + (toX - fromX) * fly
  readonly property real cy: fromY + (toY - fromY) * fly
  readonly property real rad: fromR + (toR - fromR) * fly
  readonly property real land: Math.max(0, Math.min(1, (fly - 0.75) / 0.25))

  // The globe as drawn (meridian.js globe), replaced only when it changes visibly.
  property var g: null
  property var spin: G.spin(0, 0)
  property real yaw: 0
  property real pitch: 0
  property bool moving: false
  property int under: -1             // plaque index under the loupe
  readonly property var plaques: g ? g.plaques : []
  readonly property alias hitItem: globeHit
  readonly property alias panelItem: panel
  readonly property alias captionItem: caption

  function close() { if (goal !== 0) { goal = 0; flyT = fly; if (!animate) { fly = 0; m.closed() } } }

  function syncSpin() { yaw = spin.yaw; pitch = spin.pitch; under = spin.target }
  function refresh() {
    if (!field || !field.scene) return
    var n = G.globe(field.scene, sessionId, field.nowMs)
    if (!n) { close(); return }
    if (!G.changed(g, n, 1 / Math.max(toR, 1))) return
    var keep = under >= 0 && g && g.plaques[under] ? g.plaques[under].id : null
    var first = !g
    g = n
    if (first) {
      // The newest record arrives under the loupe.
      if (n.newest >= 0) { var d = G.detentFor(n.plaques[n.newest], 0); spin = G.spin(d.yaw, d.pitch); spin.target = n.newest }
      syncSpin()
    } else if (keep !== null) { G.follow(spin, n.plaques, keep); syncSpin() }
    atlasTex.scheduleUpdate()
  }
  Connections {
    target: m.field
    function onFrameChanged() { m.refresh() }
  }
  Component.onCompleted: {
    refresh()
    console.log("amplify: focus " + sessionId.slice(0, 8) + " plaques " + plaques.length + (g && g.lease.held ? " lease " + g.lease.text : ""))
    goal = 1
    if (!animate) fly = 1
  }

  // The one clock: fly and spin, each frame while either moves; stopped when both are settled.
  FrameAnimation {
    running: (m.flying || m.moving) && m.visible
    onTriggered: m.advance(frameTime)
  }
  function advance(dt) {
    if (flying) {
      flyT = Math.max(0, Math.min(1, flyT + (goal > fly ? 1 : -1) * dt / flySec))
      var t = flyT, e = goal > fly ? 1 - Math.pow(1 - t, 3) : t * t * t
      fly = (goal > fly && t >= 1) || (goal < fly && t <= 0) ? goal : e
      if (fly === 0 && goal === 0) { m.closed(); return }
    }
    if (moving) {
      moving = G.step(spin, dt, plaques)
      syncSpin()
    }
    if (!flying && !moving) console.log("amplify: focus settled " + sessionId.slice(0, 8) + " loupe "
                                        + (under >= 0 && plaques[under] ? plaques[under].kind + " " + plaques[under].id8 : "none")
                                        + " yaw " + yaw.toFixed(5) + " pitch " + pitch.toFixed(5))
  }

  // Drawn: the globe's centre and radius against what the focus asks for (fly in from the
  // orb, home again), and the hand-driven spin angle.
  Loader {
    active: m.trace
    sourceComponent: Trace {
      comp: "focus"; part: "globe"; ident: m.sessionId.slice(0, 8)
      v: ({ x: m.cx, y: m.cy, length: m.rad, rotation: m.yaw * 180 / Math.PI,
            "x:to": m.width > 0 ? m.fromX + (m.toX - m.fromX) * m.goal : m.cx,
            "y:to": m.height > 0 ? m.fromY + (m.toY - m.fromY) * m.goal : m.cy,
            "length:to": m.height > 0 ? m.fromR + (m.toR - m.fromR) * m.goal : m.rad })
    }
  }

  // Plaque text atlas: 4 x 2 slots of 512 x 256 (meridian.frag), captured when the data changes.
  Item {
    id: atlasSrc
    width: 2048; height: 512
    visible: false
    Repeater {
      model: 8
      Item {
        required property int index
        readonly property var p: index < m.plaques.length ? m.plaques[index] : null
        x: (index % 4) * 512; y: Math.floor(index / 4) * 256
        width: 512; height: 256
        Rectangle {
          visible: !!parent.p
          anchors.fill: parent; anchors.margins: 8
          radius: 10; color: Qt.rgba(0, 0, 0, 0.3)
          border.width: 2.5; border.color: parent.p ? Qt.alpha(parent.p.color, 0.7) : "transparent"
        }
        Text {
          visible: !!parent.p
          x: 30; y: 28; width: 452
          text: parent.p ? parent.p.head : ""
          color: parent.p ? parent.p.color : "white"
          font.family: "monospace"; font.pixelSize: 25; font.weight: Font.DemiBold
          elide: Text.ElideRight
        }
        Text {
          visible: !!parent.p
          x: 30; y: 70; width: 452; height: 130
          text: parent.p ? parent.p.title : ""
          color: "#f1ece0"
          font.family: "sans-serif"; font.pixelSize: 36; font.weight: Font.DemiBold
          wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; lineHeight: 0.95
        }
        Text {
          visible: !!parent.p
          x: 30; y: 206; width: 452
          text: parent.p ? parent.p.meta : ""
          color: Qt.rgba(0.91, 0.89, 0.83, 0.62)
          font.family: "monospace"; font.pixelSize: 22
          elide: Text.ElideRight
        }
      }
    }
  }
  ShaderEffectSource {
    id: atlasTex
    sourceItem: atlasSrc
    live: false
    hideSource: true
    mipmap: true
    textureSize: Qt.size(2048, 512)
    width: 1; height: 1; visible: false
  }

  ShaderEffect {
    id: fx
    readonly property real ext: 1.3
    x: m.cx - width / 2; y: m.cy - height / 2
    width: 2 * ext * m.rad; height: width
    blending: true
    fragmentShader: Qt.resolvedUrl("../shaders/meridian.frag.qsb")
    property var atlas: atlasTex
    property real yaw: m.yaw
    property real pitch: m.pitch
    property real px: m.rad
    property real land: m.land
    property real leaseLon: m.g ? m.g.lease.lon : 0
    property real hbFuse: m.g ? m.g.hbFuse : -1
    property real light: m.g ? m.g.light : 0.4
    property real lost: m.g ? m.g.lost : 0
    property real dorm: m.g ? m.g.dorm : 0
    property real ended: m.g ? m.g.ended : 0
    property real nPlq: m.plaques.length
    property real dimOut: G.LOUPE.dim
    property vector4d loupe: Qt.vector4d(G.LOUPE.x, G.LOUPE.y, G.LOUPE.r, G.LOUPE.mag)
    property vector4d sun: m.g ? Qt.vector4d(m.g.sun[0], m.g.sun[1], m.g.sun[2], 0) : Qt.vector4d(0, 0, 1, 0)
    property vector4d marksA: Qt.vector4d(G.lonOf(60), G.lonOf(300), G.lonOf(900), G.lonOf(3600))
    property vector4d marksB: Qt.vector4d(G.lonOf(21600), G.lonOf(86400), 0, 0)
    function q(i) { var p = m.plaques[i]; return p ? Qt.vector4d(p.lon, p.lat, p.hw, p.hh) : Qt.vector4d(9, 9, 0, 0) }
    // Every plaque is drawn at its trust brightness; the loupe's rim may cut one (meridian.js LOUPE).
    function b(i) { var p = m.plaques[i]; return p ? p.bright : 0 }
    property vector4d plq0: q(0)
    property vector4d plq1: q(1)
    property vector4d plq2: q(2)
    property vector4d plq3: q(3)
    property vector4d plq4: q(4)
    property vector4d plq5: q(5)
    property vector4d plq6: q(6)
    property vector4d plq7: q(7)
    property vector4d brightA: Qt.vector4d(b(0), b(1), b(2), b(3))
    property vector4d brightB: Qt.vector4d(b(4), b(5), b(6), b(7))
    property color atm: m.accent
    property color leaseCol: "#e0a85a"
  }
  function shaders() { return [fx] }

  // The hand: drag turns the globe under it; let go and it coasts, then the detent settles
  // the nearest plaque under the loupe. A click on a plaque opens its record; right click
  // flies the orb home.
  MouseArea {
    id: globeHit
    x: m.cx - width / 2; y: m.cy - height / 2
    width: 2 * m.rad * 1.06; height: width
    enabled: m.fly === 1 && m.goal === 1
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
    property real lx: 0
    property real ly: 0
    property real lt: 0
    property real dist: 0
    onPressed: function (e) {
      if (e.button === Qt.RightButton) { m.close(); return }
      lx = e.x; ly = e.y; lt = Date.now(); dist = 0
    }
    onPositionChanged: function (e) {
      if (!pressed || e.buttons !== Qt.LeftButton) return
      var t = Date.now(), dx = e.x - lx, dy = e.y - ly
      dist += Math.abs(dx) + Math.abs(dy)
      if (dist < 6) return
      G.drag(m.spin, dx, dy, (t - lt) / 1000, m.rad)
      lx = e.x; ly = e.y; lt = t
      m.moving = false; m.syncSpin()
    }
    onReleased: function (e) {
      if (e.button !== Qt.LeftButton) return
      if (dist < 6) {
        var i = G.pick(m.spin, (e.x - width / 2) / m.rad, -(e.y - height / 2) / m.rad, m.plaques)
        if (i >= 0) { console.log("amplify: focus open " + m.plaques[i].url); Qt.openUrlExternally(m.plaques[i].url) }
        return
      }
      // A hand held still before letting go throws nothing.
      if (Date.now() - lt > 120) m.spin.vy = 0
      G.release(m.spin)
      if (!m.animate) { while (G.step(m.spin, 0.1, m.plaques)) {} m.syncSpin(); return }
      m.moving = true
    }
  }

  // ---------------------------------------------------------------- HUD (QML text, read-only links)
  readonly property var sess: g ? g.session : null
  readonly property color livCol: !sess ? foreground : sess.liveness === "lost" ? "#e0786a" : sess.liveness === "live" ? "#6ee7b7"
                                  : sess.liveness === "quiet" ? "#8fd3ff" : "#9aa3b5"
  Column {
    id: panel
    opacity: m.land
    visible: opacity > 0
    width: 330
    x: m.cx - m.rad * 1.12 - width
    y: m.cy - m.rad * 0.9
    spacing: 6
    Text { text: m.sess ? "SESSION · " + m.sess.id8 + " · " + m.sess.role.toUpperCase() : ""; color: m.foreground; opacity: 0.45
           font.family: "monospace"; font.pixelSize: 11; font.letterSpacing: 1.6 }
    Text { width: parent.width; text: m.sess ? (m.sess.untitled ? "untitled · " + m.sess.name : m.sess.title) : ""
           color: m.foreground; font.family: "sans-serif"; font.pixelSize: 28; font.weight: Font.DemiBold
           font.italic: !!(m.sess && m.sess.untitled); wrapMode: Text.Wrap }
    Text { text: m.sess ? "● " + m.sess.liveness + "   " + (m.sess.heartbeatAgo ? "♥ " + m.sess.heartbeatAgo + " ago" : "no heartbeat yet") : ""
           color: m.livCol; font.family: "monospace"; font.pixelSize: 13 }
    Text { text: !m.sess ? "" : m.sess.wroteAgo ? "last write " + m.sess.wroteAgo + " ago" : (m.sess.creationReason === "connect" ? "just connected · no writes yet" : "no writes")
           color: m.foreground; opacity: 0.6; font.family: "monospace"; font.pixelSize: 12 }
    Item { width: 1; height: 8 }
    Text { visible: !!(m.g && m.g.lease.task); width: parent.width
           text: m.g && m.g.lease.task ? "TASK · " + m.g.lease.task.id8 + " · " + (m.g.lease.task.lane || "").toUpperCase() + "\n" + m.g.lease.task.title : ""
           color: m.foreground; opacity: 0.8; font.family: "sans-serif"; font.pixelSize: 13; wrapMode: Text.Wrap }
    Text { visible: !!(m.g && m.g.lease.task)
           text: m.g && m.g.lease.held ? "claim lease " + m.g.lease.text + " left  — the lit arc east of now" : "claim expired"
           color: "#e0a85a"; font.family: "monospace"; font.pixelSize: 13 }
    Item { width: 1; height: 8 }
    Row {
      spacing: 14
      Text { text: "open thread ↗"; visible: !!(m.sess && m.sess.threadUrl); color: "#8fd3ff"; font.family: "monospace"; font.pixelSize: 12
             MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                         onClicked: { console.log("amplify: focus open " + m.sess.threadUrl); Qt.openUrlExternally(m.sess.threadUrl) } } }
      Text { text: "session in Mandrel ↗"; color: "#8fd3ff"; font.family: "monospace"; font.pixelSize: 12
             MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                         onClicked: { console.log("amplify: focus open " + m.sess.url); Qt.openUrlExternally(m.sess.url) } } }
      Text { text: "✕ desktop"; color: m.foreground; opacity: 0.6; font.family: "monospace"; font.pixelSize: 12
             MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: m.close() } }
    }
  }
  // Legend above, caption below the globe: what is under the loupe.
  Text {
    opacity: m.land * 0.55; visible: opacity > 0
    anchors.horizontalCenter: fx.horizontalCenter
    y: m.cy - m.rad * 1.1 - height
    text: "← PAST  ·  TIME IS LONGITUDE  ·  NOW  ·  LEASE IS THE LIT FUTURE →"
    color: m.foreground; font.family: "monospace"; font.pixelSize: 11; font.letterSpacing: 1.6
  }
  Text {
    id: caption
    opacity: m.land; visible: opacity > 0
    anchors.horizontalCenter: fx.horizontalCenter
    y: m.cy + m.rad * 1.1
    readonly property var p: m.under >= 0 && m.under < m.plaques.length ? m.plaques[m.under] : null
    text: p ? "UNDER THE LOUPE · " + p.kind.toUpperCase() + " " + p.id8 + " · trust " + p.trust + " · click to open"
            : m.plaques.length ? "drag to turn · let go and the nearest record settles under the loupe" : "no records written yet"
    color: m.foreground; font.family: "monospace"; font.pixelSize: 13
  }
}
