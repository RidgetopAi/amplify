import QtQuick

// The needs-you basin (Direction C "Current"): a warm pool in the lower right
// holding every human-needed item, most urgent first. Each row opens the exact
// place: the Amp thread, or the record at <mandrel>/r/<id8>. Read-only.
// One per screen; all of them share one BasinFeed.
Item {
  id: basin

  required property var feed
  property bool animate: true
  // AMPLIFY_TRACE=1: the pool and each row log their drawn axes (plugin/motion/Trace.qml).
  property bool trace: false
  property int maxRows: 5
  readonly property alias hitItem: list
  readonly property int count: feed.rows.length
  readonly property bool replay: !!(feed.activeScene && feed.activeScene.meta && feed.activeScene.meta.mode === "replay")
  signal opened(string url)
  // The pool's program, for the ready line (Service.qml); none while the pool is hidden (no rows).
  function shaders() { return pool.visible ? [pool] : [] }

  // Warm is reserved for humans; these never follow the theme.
  readonly property color warm: "#ff9e74"
  readonly property color lost: "#e0786a"
  readonly property string mono: "JetBrainsMono Nerd Font"

  width: 500
  height: header.height + 12 + list.height

  // Keyed ListModel so rows glide instead of rebuilding every refresh.
  ListModel { id: rowsModel }
  function sync(rows) {
    var want = {}
    for (var i = 0; i < rows.length && i < maxRows; i++) want[rows[i].key] = true
    for (var j = rowsModel.count - 1; j >= 0; j--) if (!want[rowsModel.get(j).key]) rowsModel.remove(j)
    for (var k = 0; k < rows.length && k < maxRows; k++) {
      var r = rows[k], at = -1
      for (var m = 0; m < rowsModel.count; m++) if (rowsModel.get(m).key === r.key) { at = m; break }
      var o = { key: r.key, kind: r.kind, label: r.label, title: r.title, meta: r.meta + (r.waited ? " · waiting " + r.waited : ""),
                url: r.url || "", go: r.go, rank: r.rank }
      if (at < 0) rowsModel.insert(k, o)
      else { if (at !== k) rowsModel.move(at, k, 1); rowsModel.set(k, o) }
    }
  }
  Connections { target: basin.feed; function onRowsChanged() { basin.sync(basin.feed.rows) } }
  Component.onCompleted: sync(feed.rows)

  Loader {
    active: basin.trace
    sourceComponent: Trace {
      comp: "basin"; part: "pool"; ident: "pool"
      v: ({ opacity: pool.opacity, length: pool.fill, x: pool.time, "x:rate": basin.animate && pool.visible ? 1 : 0, "opacity:to": basin.count ? 1 : 0,
            "length:to": Math.min(1, basin.count / 4) })
    }
  }

  ShaderEffect {
    id: pool
    anchors.centerIn: list
    width: basin.width * 1.7; height: Math.max(300, list.height * 1.9)
    opacity: basin.count ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { enabled: basin.animate; NumberAnimation { duration: 1400; easing.type: Easing.InOutSine } }
    property real time: 4.0
    property real fill: Math.min(1, basin.count / 4)
    property real alarm: basin.count && basin.feed.rows[0].kind === "lost" ? 1 : 0
    property real aspect: width / height
    property color warm: basin.warm
    property color lost: basin.lost
    Behavior on fill { enabled: basin.animate; NumberAnimation { duration: 1600; easing.type: Easing.OutCubic } }
    fragmentShader: Qt.resolvedUrl("pool.frag.qsb")
    NumberAnimation on time {
      id: poolClock
      running: basin.animate && pool.visible
      from: 0; to: 3600; duration: 3600 * 1000; loops: Animation.Infinite
    }
  }

  Item {
    id: header
    width: parent.width; height: 46
    Text {
      id: headline
      x: 6; y: 0
      text: basin.count === 0 ? "Nothing needs you" : basin.count === 1 ? "1 thing needs you" : basin.count + " things need you"
      color: basin.count ? "#ffe1cf" : "#8b94a5"
      font.pixelSize: 20; font.weight: basin.count ? Font.DemiBold : Font.Medium; font.letterSpacing: -0.2
      Behavior on color { enabled: basin.animate; ColorAnimation { duration: 900 } }
    }
    Text {
      x: 7; anchors.top: headline.bottom; anchors.topMargin: 3
      text: ("by urgency · one click to the exact place" + (basin.replay ? " · replayed snapshot" : "")).toUpperCase()
      color: basin.count ? "#8a6f63" : "#4a5263"; font.family: basin.mono; font.pixelSize: 10; font.letterSpacing: 1.2
    }
  }

  ListView {
    id: list
    y: header.height + 12
    width: parent.width
    height: contentHeight
    interactive: false
    spacing: 9
    model: rowsModel

    // Still mode (AMPLIFY_STILL=1): rows and the pool take their place at once.
    add: Transition {
      enabled: basin.animate
      ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 1100; easing.type: Easing.OutCubic }
        NumberAnimation { property: "y"; from: -26; duration: 1400; easing.type: Easing.OutCubic }
      }
    }
    remove: Transition { enabled: basin.animate; NumberAnimation { property: "opacity"; to: 0; duration: 600 } }
    displaced: Transition { enabled: basin.animate; NumberAnimation { properties: "x,y"; duration: 900; easing.type: Easing.OutCubic } }
    move: Transition { enabled: basin.animate; NumberAnimation { properties: "x,y"; duration: 900; easing.type: Easing.OutCubic } }

    delegate: Item {
      id: row
      required property int index
      required property string key
      required property string kind
      required property string label
      required property string title
      required property string meta
      required property string url
      required property string go
      readonly property bool isLost: kind === "lost"
      readonly property color tint: isLost ? basin.lost : basin.warm
      width: list.width; height: 64
      Loader {
        active: basin.trace
        sourceComponent: Trace {
          comp: "basin"; part: "row"; ident: String(row.key || "").slice(0, 24).replace(/\s/g, "_")
          v: ({ y: row.y, opacity: row.opacity, "y:to": row.index * (row.height + list.spacing), "opacity:to": 1,
                halo: haloRing.visible ? haloRing.opacity : 0, "halo:on": basin.animate && row.index === 0 ? 1 : 0 })
        }
      }

      Rectangle {
        anchors.fill: parent
        radius: 12
        border.width: 1
        border.color: Qt.rgba(row.tint.r, row.tint.g, row.tint.b, mouse.containsMouse ? 0.55 : 0.22)
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Qt.rgba(row.tint.r, row.tint.g, row.tint.b, mouse.containsMouse ? 0.22 : 0.14) }
          GradientStop { position: 0.42; color: mouse.containsMouse ? Qt.rgba(0.11, 0.07, 0.063, 0.84) : Qt.rgba(0.078, 0.055, 0.055, 0.7) }
          GradientStop { position: 1.0; color: Qt.rgba(0.06, 0.045, 0.047, 0.66) }
        }
        Behavior on border.color { ColorAnimation { duration: 180 } }
      }

      // Urgency badge: rank 1 breathes, later ranks cool slightly.
      Rectangle {
        id: badge
        x: 12; anchors.verticalCenter: parent.verticalCenter
        width: 28; height: 28; radius: 14
        color: row.isLost ? basin.lost : row.index === 0 ? basin.warm : row.index === 1 ? "#f3b48f" : "#d9a58c"
        opacity: row.index >= 2 ? 0.85 : 1
        Text {
          anchors.centerIn: parent
          text: row.index + 1
          color: "#2a160e"; font.pixelSize: 12; font.bold: true
        }
        Rectangle {
          id: haloRing
          anchors.centerIn: parent
          width: parent.width + 10; height: width; radius: width / 2
          color: "transparent"; border.width: 1; border.color: badge.color
          visible: row.index === 0
          SequentialAnimation on opacity {
            running: basin.animate && row.index === 0; loops: Animation.Infinite
            NumberAnimation { from: 0.08; to: 0.5; duration: 1600; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.5; to: 0.08; duration: 1600; easing.type: Easing.InOutSine }
          }
        }
      }

      Column {
        anchors.left: badge.right; anchors.leftMargin: 12
        anchors.right: goPill.left; anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        Text {
          text: row.label.toUpperCase()
          color: row.isLost ? "#e7a49a" : "#e9a888"
          font.family: basin.mono; font.pixelSize: 10; font.letterSpacing: 1.4
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          text: row.title
          color: "#fff1e8"; font.pixelSize: 14
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          text: row.meta
          color: "#b08f80"; font.family: basin.mono; font.pixelSize: 11
        }
      }

      Rectangle {
        id: goPill
        anchors.right: parent.right; anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        width: goText.implicitWidth + 18; height: 26; radius: 8
        color: mouse.containsMouse ? Qt.rgba(1, 0.62, 0.45, 0.12) : "transparent"
        border.width: 1; border.color: Qt.rgba(1, 0.78, 0.67, mouse.containsMouse ? 0.6 : 0.3)
        Text {
          id: goText
          anchors.centerIn: parent
          text: row.go + " ↗"
          color: "#ffd9c2"; font.family: basin.mono; font.pixelSize: 12
        }
      }

      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: row.url !== ""
        onClicked: {
          console.log("amplify: basin open " + row.url)
          basin.opened(row.url)
          Qt.openUrlExternally(row.url)
        }
      }
    }
  }
}
