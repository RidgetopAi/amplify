import Quickshell
import Quickshell.Wayland
import QtQuick

// Test harness for tools/headless-shot.sh. Stands in for the Omarchy desktop:
//  - a wallpaper on WlrLayer.Background that logs clicks reaching it, so a
//    click outside an orb proves Amplify's input mask lets it through;
//  - an ordinary application window over the right half of the screen, so the
//    screenshot shows whether Amplify sits below windows (Bottom) or above (Top).
ShellRoot {
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "harness-wallpaper"
      WlrLayershell.layer: WlrLayer.Background

      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0; color: "#1a1b26" }
          GradientStop { position: 1; color: "#0f1018" }
        }
      }

      MouseArea {
        anchors.fill: parent
        onClicked: mouse => console.log("harness: wallpaper click " + Math.round(mouse.x) + "," + Math.round(mouse.y))
      }
    }
  }

  FloatingWindow {
    title: "amplify-cover"
    color: "#e8e3d8"
    implicitWidth: 640
    implicitHeight: 720

    Text {
      anchors.centerIn: parent
      text: "application window"
      color: "#3b3a36"
      font.pixelSize: 28
    }
  }
}
