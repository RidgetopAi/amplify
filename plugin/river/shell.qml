import Quickshell
import Quickshell.Wayland
import QtQuick


// River alone on every screen, for screenshots and design review:
//   quickshell -p plugin/river
// The plugin mounts the same River from Service.qml.
ShellRoot {
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      color: "#05080b"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "amplify-river-preview"
      WlrLayershell.layer: WlrLayer.Bottom

      River {
        anchors.fill: parent
        // env-read: AMPLIFY_STILL=1 freezes motion (deterministic screenshots).
        animate: Quickshell.env("AMPLIFY_STILL") !== "1"
        // env-read: AMPLIFY_RIVER_TRACE=1 logs each moving row's drawn positions (shot.sh trajectory gates).
        trace: Quickshell.env("AMPLIFY_RIVER_TRACE") === "1"
      }
    }
  }
}
