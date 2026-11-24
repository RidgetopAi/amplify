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

  // The orbs' drawn shader programs on every screen, for the ready line (Service.qml).
  function shaders() {
    var out = []
    for (var i = 0; i < screens.instances.length; i++) out = out.concat(screens.instances[i].shaders())
    return out
  }

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

      OrbField {
        id: field
        anchors.fill: parent
        accent: orbsLayer.accent
        foreground: orbsLayer.foreground
        animate: orbsLayer.animate
        trace: orbsLayer.trace
      }
    }
  }
}
