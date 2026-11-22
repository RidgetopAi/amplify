import Quickshell
import Quickshell.Wayland
import QtQuick

// The desktop orbs as their own layer (task a40d7440): one PanelWindow per
// screen on WlrLayer.Bottom whose input mask is only the orbs' hit circles, so
// clicks anywhere else fall through to the windows below (other Amplify
// layers, the wallpaper). Service.qml mounts this with one line.
Item {
  id: layer
  property color accent: "#89b4fa"
  property color foreground: "#cdd6f4"
  property bool animate: true

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
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
        accent: layer.accent
        foreground: layer.foreground
        animate: layer.animate
      }
    }
  }
}
