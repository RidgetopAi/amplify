import Quickshell
import Quickshell.Wayland
import QtQuick

// The desktop orbs as their own layer (task a40d7440): one PanelWindow per
// screen on WlrLayer.Bottom whose input mask is only the orbs' hit circles, so
// clicks anywhere else fall through to the windows below (other Amplify
// layers, the wallpaper). Service.qml mounts this with one line.
// The id must not be `layer`: inside OrbField that name resolves to Item's
// built-in `layer` grouped property, and the bindings below go undefined.
Item {
  id: orbsLayer
  property color accent: "#89b4fa"
  property color foreground: "#cdd6f4"
  property bool animate: true
  property bool trace: false
  // AMPLIFY_FPS=1 (Service.qml): log the frames each window swapped per second, every 5 s.
  property bool logFps: false

  // The orbs' drawn shader programs on every screen, for the ready line (Service.qml).
  function shaders() {
    var out = []
    for (var i = 0; i < screens.instances.length; i++) out = out.concat(screens.instances[i].shaders())
    return out
  }
  // Its windows, one per screen, each with shaders() and drawn (Service.qml's ready line).
  function windows() { return screens.instances }

  Variants {
    id: screens
    model: Quickshell.screens

    PanelWindow {
      id: win
      function shaders() { return field.shaders() }
      required property var modelData
      screen: modelData
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "amplify-orbs"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region { regions: field.regions }

      // drawn: this window has shown a frame with RHI shaders (software rendering never does).
      property bool drawn: false
      Connections {
        target: win.contentItem.Window.window
        enabled: !win.drawn
        function onFrameSwapped() { win.drawn = field.GraphicsInfo.shaderType === GraphicsInfo.RhiShader }
      }
      // With the field's clock steps per second, so a frame drawn between steps shows (task 118f6917).
      property int swapped: 0
      property int stepsAt: 0
      Connections {
        target: win.contentItem.Window.window
        enabled: orbsLayer.logFps
        function onFrameSwapped() { win.swapped++ }
      }
      Timer {
        interval: 5000; repeat: true; running: orbsLayer.logFps
        onTriggered: {
          console.log("amplify: fps window=amplify-orbs screen=" + win.modelData.name + " " + (win.swapped / 5).toFixed(1)
                      + " steps=" + ((field.steps - win.stepsAt) / 5).toFixed(1))
          win.swapped = 0; win.stepsAt = field.steps
        }
      }

      OrbField {
        id: field
        anchors.fill: parent
        accent: orbsLayer.accent
        foreground: orbsLayer.foreground
        animate: orbsLayer.animate
        trace: orbsLayer.trace
        // env-read: AMPLIFY_ORBS_FROM starts the replayed orbs' client clock at this ISO time (tools/headless-shot.sh idle check).
        startAt: Quickshell.env("AMPLIFY_ORBS_FROM") || ""
      }
    }
  }
}
