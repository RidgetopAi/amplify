import QtQuick
import "panes.js" as P

// The panes (task bc45ee1d): live stats (open sessions, lanes, activity rate, waiting on you),
// the newest context, decision and task with their full titles, a project switcher across the
// Mandrel projects and quick links to Mandrel and Amp. Read-only: every row opens
// <base>/r/<id8> (viewer contract 22d73eeb) or a link. One per screen, above the basin.
// Nothing here animates (no Behavior, Animation or Timer): the panes redraw only when what they
// show changes, so with the data unchanged they draw no frame. A rebuild that yields the same
// model (the basin's 15 s rebuild) is dropped before it reaches the delegates.
Item {
  id: panes

  // Anything with activeScene (buildScene output), now (the scene clock, ms) and rows
  // (the basin's needs-you rows): the BasinFeed in Service.qml, or a test sheet's stand-in.
  required property var feed
  property string screenName: ""
  // The switcher's list of projects is open (the header button toggles it; a test sheet sets it).
  property bool switcherOpen: false
  signal opened(string url)

  readonly property color cool: "#9fb4d8"
  readonly property color ink: "#e3e9f4"
  readonly property color dim: "#7d8799"
  readonly property color warm: "#ff9e74"
  readonly property string mono: "JetBrainsMono Nerd Font"

  property var model: P.buildPanes(null, {})
  property string _json: ""
  function refresh() {
    var m = P.buildPanes(feed.activeScene, { now: feed.now, needsYou: feed.rows })
    var j = JSON.stringify(m)
    if (j === _json) return
    _json = j
    model = m
    console.log("amplify: panes" + (screenName ? "@" + screenName : "") + " project=" + m.project
                + " " + m.stats.map(function (s) { return s.key + "=" + s.value }).join(" ")
                + " latest=" + m.latest.map(function (r) { return r.url || "-" }).join(","))
  }
  Connections {
    target: panes.feed
    function onActiveSceneChanged() { panes.refresh() }
    function onRowsChanged() { panes.refresh() }
    function onNowChanged() { panes.refresh() }
  }
  Component.onCompleted: refresh()

  function open(url) {
    if (!url) return
    console.log("amplify: panes open " + url)
    panes.opened(url)
    Qt.openUrlExternally(url)
  }

  // Compact, above the river band (it owns the middle of the screen edge to edge); the host
  // narrows it on small screens.
  width: 640
  // The open switcher's list may be taller than the body: the panes grow to hold it, so it stays
  // inside the window's input mask (Service.qml masks the panes' bounds).
  height: Math.max(body.y + body.height, panes.switcherOpen ? popup.y + popup.height : 0) + 14

  Rectangle {
    anchors.fill: parent
    radius: 16
    color: Qt.rgba(0.035, 0.045, 0.065, 0.93)   // nearly opaque: river vessels pass under it
    border.width: 1; border.color: Qt.rgba(0.62, 0.7, 0.85, 0.13)
  }

  // ------------------------------------------------------------ header: switcher + links
  Item {
    id: header
    x: 16; y: 12; width: parent.width - 32; height: 40

    Rectangle {
      id: switcher
      width: Math.min(header.width - links.width - 12, switcherRow.implicitWidth + 24); height: 40; radius: 10
      color: switcherMouse.containsMouse || panes.switcherOpen ? Qt.rgba(0.62, 0.7, 0.85, 0.1) : "transparent"
      border.width: 1; border.color: Qt.rgba(0.62, 0.7, 0.85, switcherMouse.containsMouse || panes.switcherOpen ? 0.45 : 0.22)
      Row {
        id: switcherRow
        x: 12; anchors.verticalCenter: parent.verticalCenter; spacing: 10
        Column {
          anchors.verticalCenter: parent.verticalCenter
          Text { text: "PROJECT"; color: panes.dim; font.family: panes.mono; font.pixelSize: 9; font.letterSpacing: 1.4 }
          Text {
            text: panes.model.project + "  " + (panes.switcherOpen ? "▴" : "▾")
            color: panes.ink; font.pixelSize: 15; font.weight: Font.DemiBold
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: panes.model.projectNote
          color: panes.dim; font.family: panes.mono; font.pixelSize: 10
        }
      }
      MouseArea {
        id: switcherMouse
        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onClicked: panes.switcherOpen = !panes.switcherOpen
      }
    }

    Row {
      id: links
      anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 8
      Repeater {
        model: panes.model.links
        Rectangle {
          id: link
          required property var modelData
          width: linkText.implicitWidth + 20; height: 30; radius: 8
          color: linkMouse.containsMouse ? Qt.rgba(0.62, 0.7, 0.85, 0.12) : "transparent"
          border.width: 1; border.color: Qt.rgba(0.62, 0.7, 0.85, linkMouse.containsMouse ? 0.6 : 0.28)
          opacity: link.modelData.url ? 1 : 0.45
          Text {
            id: linkText
            anchors.centerIn: parent
            text: link.modelData.label + " ↗"
            color: "#d4def0"; font.family: panes.mono; font.pixelSize: 12
          }
          MouseArea {
            id: linkMouse
            anchors.fill: parent; hoverEnabled: true; enabled: link.modelData.url !== ""
            cursorShape: Qt.PointingHandCursor
            onClicked: panes.open(link.modelData.url)
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ body: stats, lanes, latest
  Column {
    id: body
    x: 16; y: header.y + header.height + 10; width: parent.width - 32
    spacing: 8

    Grid {
      id: stats
      columns: 4; columnSpacing: 8
      // Every tile as tall as the tallest: a note that does not fit on one line wraps, whole,
      // instead of being cut (task 32f5427b: "most in verifying · 12 merged" in JetBrains Mono).
      property real tileHeight: 66
      function fit() {
        var h = 66
        for (var i = 0; i < tiles.count; i++) { var t = tiles.itemAt(i); if (t) h = Math.max(h, t.need) }
        tileHeight = h
      }
      Repeater {
        id: tiles
        model: panes.model.stats
        onItemAdded: stats.fit()
        onItemRemoved: stats.fit()
        Rectangle {
          id: tile
          required property var modelData
          readonly property real need: tileCol.y + tileCol.implicitHeight + 7
          onNeedChanged: stats.fit()
          width: (body.width - 3 * stats.columnSpacing) / 4; height: stats.tileHeight; radius: 11
          readonly property color tint: tile.modelData.warm ? panes.warm : panes.cool
          color: Qt.rgba(tile.tint.r, tile.tint.g, tile.tint.b, tile.modelData.warm ? 0.12 : 0.05)
          border.width: 1; border.color: Qt.rgba(tile.tint.r, tile.tint.g, tile.tint.b, tile.modelData.warm ? 0.4 : 0.14)
          Column {
            id: tileCol
            x: 12; y: 7; width: parent.width - 24; spacing: 1
            Text {
              text: tile.modelData.value
              color: tile.modelData.warm ? "#ffe1cf" : panes.ink
              font.pixelSize: 22; font.weight: Font.DemiBold
            }
            Text {
              width: parent.width; elide: Text.ElideRight
              text: tile.modelData.label.toUpperCase()
              color: tile.modelData.warm ? "#e9a888" : panes.cool
              font.family: panes.mono; font.pixelSize: 9; font.letterSpacing: 1.1
            }
            Text {
              id: note
              width: parent.width; wrapMode: Text.Wrap
              text: tile.modelData.note
              color: tile.modelData.warm ? "#b08f80" : panes.dim
              font.family: panes.mono; font.pixelSize: 10
              // The note as laid out, for the whole-note check (plugin/basin/test/shot.sh):
              // "<lines> <truncated> <natural width> <width> <bottom in the tile> <tile height>".
              readonly property string laid: [lineCount, truncated ? 1 : 0, Math.ceil(implicitWidth), Math.floor(width),
                Math.round(tileCol.y + y + height), Math.round(tile.height)].join(" ")
              onLaidChanged: console.log("amplify: panes" + (panes.screenName ? "@" + panes.screenName : "") + " note "
                                         + tile.modelData.key + " " + laid + " " + text)
            }
          }
        }
      }
    }

    // Tasks per lane (decision c1f75776), the same lanes the river draws.
    Row {
      spacing: 6
      Repeater {
        model: panes.model.lanes
        Text {
          required property var modelData
          text: modelData.lane.toUpperCase() + " " + modelData.count
          color: modelData.count ? panes.cool : "#4a5263"
          font.family: panes.mono; font.pixelSize: 10; font.letterSpacing: 0.8
        }
      }
    }

    Text {
      text: "LATEST · ONE CLICK TO THE RECORD"
      color: panes.dim; font.family: panes.mono; font.pixelSize: 10; font.letterSpacing: 1.2
    }

    Repeater {
      model: panes.model.latest
      Rectangle {
        id: rec
        required property var modelData
        width: body.width; height: recCol.implicitHeight + 14; radius: 9
        color: recMouse.containsMouse ? Qt.rgba(0.62, 0.7, 0.85, 0.09) : Qt.rgba(0.62, 0.7, 0.85, 0.035)
        border.width: 1; border.color: Qt.rgba(0.62, 0.7, 0.85, recMouse.containsMouse ? 0.4 : 0.1)
        Column {
          id: recCol
          x: 12; y: 7; width: parent.width - 24 - (recGo.visible ? recGo.width + 10 : 0)
          spacing: 2
          Row {
            spacing: 10
            Text {
              text: rec.modelData.label
              color: panes.cool; font.family: panes.mono; font.pixelSize: 9; font.letterSpacing: 1.3
            }
            Text {
              visible: rec.modelData.meta !== ""
              text: rec.modelData.meta
              color: panes.dim; font.family: panes.mono; font.pixelSize: 9
            }
          }
          // The whole title, wrapped, never cut (the done-when asks for full titles).
          Text {
            id: recTitle
            width: parent.width; wrapMode: Text.Wrap
            text: rec.modelData.title
            color: rec.modelData.empty ? panes.dim : panes.ink
            font.pixelSize: 13; font.italic: rec.modelData.empty
            // The title as drawn, for the full-title check (plugin/panes/test/shot.sh).
            function drawn() { console.log("amplify: panes" + (panes.screenName ? "@" + panes.screenName : "") + " title "
                                           + rec.modelData.kind + " truncated=" + truncated + " " + text) }
            onTextChanged: drawn()
            onTruncatedChanged: drawn()
            Component.onCompleted: drawn()
          }
        }
        Text {
          id: recGo
          visible: rec.modelData.url !== ""
          anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
          text: "/r/" + (rec.modelData.url.split("/r/")[1] || "") + " ↗"
          color: recMouse.containsMouse ? "#d4def0" : panes.dim; font.family: panes.mono; font.pixelSize: 11
        }
        MouseArea {
          id: recMouse
          anchors.fill: parent; hoverEnabled: true; enabled: rec.modelData.url !== ""
          cursorShape: Qt.PointingHandCursor
          onClicked: panes.open(rec.modelData.url)
        }
      }
    }
  }

  // ------------------------------------------------------------ the switcher's project list
  // Over the body, inside the panes' bounds (so the window mask needs no second region).
  // Read-only: a project opens its record in Mandrel (<base>/r/<id8>); the viewer token is
  // project-scoped, so the desktop keeps showing the project it is bound to.
  Rectangle {
    id: popup
    visible: panes.switcherOpen
    x: 10; y: header.y + header.height + 6; z: 2
    width: parent.width - 20; height: popupCol.implicitHeight + 20
    radius: 12
    color: "#080b10"
    border.width: 1; border.color: Qt.rgba(0.62, 0.7, 0.85, 0.3)
    // Swallow clicks between rows so they do not reach the records underneath.
    MouseArea { anchors.fill: parent }
    Column {
      id: popupCol
      x: 12; y: 10; width: parent.width - 24; spacing: 8
      Text {
        text: "SWITCH PROJECT · OPENS IT IN MANDREL"
        color: panes.dim; font.family: panes.mono; font.pixelSize: 10; font.letterSpacing: 1.2
      }
      Text {
        visible: panes.model.projects.length === 0
        text: "No projects visible to this viewer"
        color: panes.dim; font.pixelSize: 13; font.italic: true
      }
      Grid {
        id: plist
        columns: 2; columnSpacing: 8; rowSpacing: 4
        Repeater {
          model: panes.model.projects
          Rectangle {
            id: proj
            required property var modelData
            width: (popupCol.width - plist.columnSpacing) / 2; height: 28; radius: 7
            color: proj.modelData.current ? Qt.rgba(0.62, 0.7, 0.85, 0.16)
                 : projMouse.containsMouse ? Qt.rgba(0.62, 0.7, 0.85, 0.08) : "transparent"
            border.width: proj.modelData.current ? 1 : 0; border.color: Qt.rgba(0.62, 0.7, 0.85, 0.45)
            Rectangle {
              x: 9; anchors.verticalCenter: parent.verticalCenter
              width: 6; height: 6; radius: 3
              color: proj.modelData.current ? panes.cool : "transparent"
              border.width: 1; border.color: Qt.rgba(0.62, 0.7, 0.85, 0.5)
            }
            Text {
              x: 22; width: parent.width - 30 - projId.width; anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: proj.modelData.name
              color: proj.modelData.current ? panes.ink : "#c2cbdb"
              font.pixelSize: 12; font.weight: proj.modelData.current ? Font.DemiBold : Font.Normal
            }
            Text {
              id: projId
              anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
              text: proj.modelData.id8 || ""
              color: "#5a6375"; font.family: panes.mono; font.pixelSize: 9
            }
            MouseArea {
              id: projMouse
              anchors.fill: parent; hoverEnabled: true; enabled: proj.modelData.url !== ""
              cursorShape: Qt.PointingHandCursor
              onClicked: { panes.switcherOpen = false; panes.open(proj.modelData.url) }
            }
          }
        }
      }
    }
  }
}
