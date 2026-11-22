import QtQuick

// One orb: a ShaderEffect running the compiled orb.frag.qsb plus a circular
// MouseArea. The window mask in Service.qml is built from these items, so
// only the orb takes clicks; the rest of the desktop passes through.
Item {
  id: orb

  property string name: "orb"
  property color core: "#89b4fa"
  property color halo: "#cdd6f4"
  property real energy: 0
  property bool animate: true
  readonly property alias shaderStatus: fx.status
  readonly property alias shaderLog: fx.log
  readonly property alias hitItem: hit
  signal clicked(string name)

  ShaderEffect {
    id: fx
    anchors.fill: parent
    blending: true
    property real time: 2.3   // frozen frame when animate is false
    property real energy: orb.energy
    property color core: orb.core
    property color halo: orb.halo
    fragmentShader: Qt.resolvedUrl("shaders/orb.frag.qsb")

    NumberAnimation on time {
      running: orb.animate && orb.visible
      from: 0; to: 3600; duration: 3600 * 1000
      loops: Animation.Infinite
    }
  }

  MouseArea {
    id: hit
    anchors.centerIn: parent
    width: parent.width * 0.62; height: width
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      // Inscribed circle only, so the square corners stay inert.
      var dx = mouse.x - width / 2, dy = mouse.y - height / 2
      if (dx * dx + dy * dy <= width * width / 4) orb.clicked(orb.name)
    }
  }
}
