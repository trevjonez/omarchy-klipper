import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// Every camera on every configured printer, tiled. Opened by right-clicking
// the bar pill; clicking a tile hands that printer and camera to the
// fullscreen view.
//
// Fullscreen layer-shell for the same reasons as FullscreenVideo: several
// live feeds need the room, and it has to sit above the popups and hold the
// keyboard so Escape works.
PanelWindow {
  id: root

  property var service: null
  property bool open: false

  signal closeRequested()
  signal tileActivated(string printerId, int webcamIndex)

  function close() { root.closeRequested() }

  readonly property var tiles: service ? Model.cameraTiles(service.printers) : []
  readonly property int columns: Model.gridColumnsFor(tiles.length)
  readonly property int rows: Model.gridRowsFor(tiles.length, columns)

  readonly property int gap: Style.space(10)
  readonly property int margin: Style.space(20)
  // Uniform cells: each feed is letterboxed inside its own cell, so mixed
  // aspect ratios across printers don't produce a ragged grid.
  readonly property real cellWidth: columns > 0
    ? (width - margin * 2 - gap * (columns - 1)) / columns : 0
  readonly property real cellHeight: rows > 0
    ? (height - margin * 2 - headerRow.height - gap * rows) / rows : 0

  visible: open
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "omarchy-klipper-wall"
  WlrLayershell.layer: WlrLayer.Overlay
  // Prime with Exclusive so the surface takes focus the moment it maps (so
  // Escape works without clicking first), then settle on OnDemand. Holding
  // Exclusive makes Hyprland route *every* pointer event here regardless of
  // which output the cursor is over -- the same reason the shell's own
  // KeyboardPanel does not hold it. It also means anything that maps this
  // surface, including a test run, swallows the keyboard until it closes.
  property bool _focusPrimed: false

  WlrLayershell.keyboardFocus: open
    ? (_focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  Timer {
    id: focusPrimeTimer
    interval: 120
    repeat: false
    onTriggered: root._focusPrimed = true
  }

  anchors { top: true; bottom: true; left: true; right: true }

  Rectangle {
    anchors.fill: parent
    color: "black"
  }

  // Click anywhere that isn't a tile to dismiss. Declared first so tiles sit
  // above it and get their own clicks.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: root.close()
  }

  Item {
    id: headerRow
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: root.margin
    height: headerLabel.implicitHeight

    Text {
      id: headerLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      text: root.tiles.length === 0
        ? "No cameras on any configured printer"
        : "All cameras"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }

    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      text: "Esc to close"
      color: Color.foreground
      opacity: 0.35
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Grid {
    id: grid
    objectName: "cameraGrid"
    anchors.top: headerRow.bottom
    anchors.topMargin: root.gap
    anchors.horizontalCenter: parent.horizontalCenter
    columns: root.columns
    spacing: root.gap

    Repeater {
      model: root.tiles

      Item {
        id: tile
        required property var modelData
        width: root.cellWidth
        height: root.cellHeight

        readonly property var connection: root.service
          ? root.service.connectionFor(modelData.printerId) : null

        Rectangle {
          anchors.fill: parent
          color: Color.background
          opacity: 0.35
          radius: Style.cornerRadius
        }

        // Letterboxed within the cell, same rule as the fullscreen view.
        CameraView {
          id: feed
          anchors.centerIn: parent
          readonly property real ratio: tile.modelData.webcam.aspectRatio > 0
            ? tile.modelData.webcam.aspectRatio : 0.75
          width: Math.min(parent.width, parent.height / ratio)

          cameraName: ""
          streamUrl: tile.modelData.webcam.streamUrl
          snapshotUrl: tile.modelData.webcam.snapshotUrl
          flipHorizontal: tile.modelData.webcam.flipHorizontal
          flipVertical: tile.modelData.webcam.flipVertical
          rotationDeg: tile.modelData.webcam.rotation
          aspectRatio: ratio
          foreground: Color.foreground
        }

        // Name and status on a translucent backing: over a bright bed or a
        // white print, plain text is unreadable.
        Rectangle {
          id: labelBox
          objectName: "tileLabel"
          anchors.left: feed.left
          anchors.bottom: feed.bottom
          anchors.margins: Style.space(8)
          radius: Style.cornerRadius
          color: Color.background
          opacity: 0.72
          width: labelColumn.implicitWidth + Style.space(16)
          height: labelColumn.implicitHeight + Style.space(10)
        }

        Column {
          id: labelColumn
          anchors.left: labelBox.left
          anchors.top: labelBox.top
          anchors.margins: Style.space(5)
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            text: tile.modelData.cameraName === ""
              ? tile.modelData.printerName
              : tile.modelData.printerName + " · " + tile.modelData.cameraName
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: {
              var c = tile.connection
              if (!c) return "Not connected"
              var label = Model.stateLabel(c.state)
              return Model.jobInProgress(c.state) ? label + " · " + c.progress + "%" : label
            }
            color: {
              var tone = tile.connection ? Model.stateTone(tile.connection.state) : "urgent"
              if (tone === "urgent") return Color.urgent
              if (tone === "active") return Color.accent
              return Color.foreground
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          id: tileHover
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          hoverEnabled: true
          onClicked: root.tileActivated(tile.modelData.printerId, tile.modelData.webcamIndex)
        }

        // Hover outline, so a tile reads as clickable.
        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 2
          border.color: Color.accent
          visible: tileHover.containsMouse
        }
      }
    }
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: root.open
    Keys.onEscapePressed: root.close()
  }

  onOpenChanged: {
    if (open) {
      _focusPrimed = false
      focusPrimeTimer.restart()
      Qt.callLater(function() { keys.forceActiveFocus() })
    } else {
      _focusPrimed = false
    }
  }
}
