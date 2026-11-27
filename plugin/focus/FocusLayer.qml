import Quickshell
import Quickshell.Wayland
import QtQuick

// The focused orb's layer (task 85ff482a). Nothing exists until an orb is clicked
// (OrbsLayer focusRequested): then one PanelWindow on that orb's screen, on the Top layer,
// dims the desktop and flies a Meridian globe from the orb to the centre. Escape, a right
// click on the globe, or the panel's "desktop" link flies it home and the window goes away. With nothing focused there is no window, so nothing draws.
// Service.qml mounts this with one line.
Item {
  id: focusRoot
  property color accent: "#89b4fa"
  property color foreground: "#cdd6f4"
  property bool animate: true
  property bool trace: false
  // AMPLIFY_FPS=1 (Service.qml): log the frames the focus window swapped per second, every 5 s,
  // so a check can see it draws nothing once settled (task 85ff482a).
  property bool logFps: false

  // The focus request: the field and orb it came from, and the screen it is on.
  property var req: null
  function open(field, id, x, y, r, screen) {
    if (req && req.id === id) return
    req = null
    req = { field: field, id: id, x: x, y: y, r: r, screen: screen }
  }
  function close() { if (win.item) win.item.view.close() }
  // Its drawn programs and window, for the ready line (Service.qml): none while unfocused.
  function shaders() { return win.item ? win.item.view.shaders() : [] }
  function windows() { return win.item ? [win.item] : [] }

  LazyLoader {
    id: win
    active: focusRoot.req !== null
    PanelWindow {
      id: pw
      readonly property alias view: view
      property bool drawn: false
      function shaders() { return view.shaders() }
      screen: focusRoot.req ? focusRoot.req.screen : null
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "amplify-focus"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
      // Input is only the globe and its panel: a click anywhere else reaches the desktop below
      // (another orb there refocuses on it). Escape, right click or "✕ desktop" fly it home.
      mask: Region { Region { item: view.hitItem } Region { item: view.panelItem } }
      Connections {
        target: pw.contentItem.Window.window
        enabled: !pw.drawn
        function onFrameSwapped() { pw.drawn = view.GraphicsInfo.shaderType === GraphicsInfo.RhiShader }
      }

      property int swapped: 0
      Connections {
        target: pw.contentItem.Window.window
        enabled: focusRoot.logFps
        function onFrameSwapped() { pw.swapped++ }
      }
      Timer {
        interval: 5000; repeat: true; running: focusRoot.logFps
        onTriggered: { console.log("amplify: fps window=amplify-focus " + (pw.swapped / 5).toFixed(1) + (view.flying || view.moving ? " moving" : " settled")); pw.swapped = 0 }
      }
      Rectangle {
        anchors.fill: parent
        color: "#05080b"
        opacity: 0.86 * view.fly
      }
      Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: view.close()
      }
      Meridian {
        id: view
        anchors.fill: parent
        field: focusRoot.req ? focusRoot.req.field : null
        sessionId: focusRoot.req ? focusRoot.req.id : ""
        fromX: focusRoot.req ? focusRoot.req.x : 0
        fromY: focusRoot.req ? focusRoot.req.y : 0
        fromR: focusRoot.req ? focusRoot.req.r : 30
        animate: focusRoot.animate
        trace: focusRoot.trace
        accent: focusRoot.accent
        foreground: focusRoot.foreground
        onClosed: { console.log("amplify: focus closed " + focusRoot.req.id.slice(0, 8)); focusRoot.req = null }
      }
    }
  }
}
