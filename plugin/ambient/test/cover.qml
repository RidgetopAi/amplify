import Quickshell
import QtQuick

// An application window for plugin/ambient/test/shot.sh, which has sway make it fullscreen
// on one screen, so the ambient field must pause there and keep drawing on the other.
ShellRoot {
  FloatingWindow {
    id: cover
    title: "amplify-ambient-cover"
    color: "#e8e3d8"
    implicitWidth: 640
    implicitHeight: 480
    Text { anchors.centerIn: parent; text: "fullscreen application"; color: "#3b3a36"; font.pixelSize: 28 }
    property bool drawn: false
    Connections {
      target: cover.contentItem.Window.window
      enabled: !cover.drawn
      function onFrameSwapped() { cover.drawn = true; console.log("cover: drawn") }
    }
  }
}
