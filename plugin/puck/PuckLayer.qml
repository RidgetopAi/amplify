import Quickshell
import Quickshell.Wayland
import QtQuick
import "puck.js" as P

// Puck on the desktop (task 23a62966): one small PanelWindow per screen on WlrLayer.Bottom,
// in the lower left corner, just Puck's size, so his blinks and glances redraw only his own
// pixels. Its input mask is his figure; everything else falls through. Service.qml mounts
// this with one line and hands it the shared scene clock.
Item {
  id: puckLayer
  property var sceneClock: null
  property bool animate: true
  property bool trace: false
  // AMPLIFY_FPS=1 (Service.qml): log the frames each window swapped per second, every 5 s.
  property bool logFps: false

  // Its windows, one per screen, each with shaders() and drawn.
  function windows() { return screens.instances }

  Variants {
    id: screens
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      color: "transparent"
      anchors { left: true; bottom: true }
      margins { left: P.DESK_LEFT; bottom: P.DESK_BOTTOM }
      implicitWidth: puck.width
      implicitHeight: puck.height
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "amplify-puck"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region { item: puck.hitItem }

      function shaders() { return [puck.shaderItem] }
      // drawn: this window has shown a frame with RHI shaders (software rendering never does).
      property bool drawn: false
      Connections {
        target: win.contentItem.Window.window
        enabled: !win.drawn
        function onFrameSwapped() { win.drawn = puck.GraphicsInfo.shaderType === GraphicsInfo.RhiShader }
      }
      property int swapped: 0
      Connections {
        target: win.contentItem.Window.window
        enabled: puckLayer.logFps
        function onFrameSwapped() { win.swapped++ }
      }
      Timer {
        interval: 5000; repeat: true; running: puckLayer.logFps
        onTriggered: {
          console.log("amplify: fps window=amplify-puck screen=" + win.modelData.name + " " + (win.swapped / 5).toFixed(1))
          win.swapped = 0
        }
      }

      Puck {
        id: puck
        width: P.deskSize(win.modelData.width, win.modelData.height)
        scene: puckLayer.sceneClock ? puckLayer.sceneClock.scene : null
        nowMs: puckLayer.sceneClock ? puckLayer.sceneClock.nowMs : 0
        animate: puckLayer.animate
        trace: puckLayer.trace
        ident: "desk@" + win.modelData.name
      }
    }
  }
}
