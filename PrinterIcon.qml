import QtQuick
import qs.Commons
import qs.Ui

// Minimal geometric render of a 3D printer: an enclosure frame, a gantry rail
// near the top, and a toolhead that sweeps left-to-right along the rail as
// `progress` advances. Drawn natively (no Nerd Font glyph, no SVG) so it
// renders crisply at bar-icon sizes and never risks a missing-glyph tofu box
// — the same reasoning the Tailscale plugin's TailscaleIcon.qml gives for its
// own native dot-grid render.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  // 0-100. The toolhead sits at the left rest position when not sweeping.
  property real progress: 0
  property bool sweeping: false
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real strokeWidth: Math.max(1, root.iconSize * 0.09)
  readonly property real frameMargin: root.iconSize * 0.08
  readonly property real headSize: Math.max(2, root.iconSize * 0.2)
  readonly property real railY: root.iconSize * 0.28
  readonly property real railLeft: root.frameMargin + root.headSize / 2
  readonly property real railRight: root.iconSize - root.frameMargin - root.headSize / 2
  readonly property real headFraction: root.sweeping ? Math.max(0, Math.min(100, root.progress)) / 100 : 0

  // Enclosure outline.
  Rectangle {
    anchors.fill: parent
    anchors.margins: root.frameMargin
    radius: Math.max(1, root.iconSize * 0.1)
    color: "transparent"
    border.width: root.strokeWidth
    border.color: root.color
  }

  // Gantry rail the toolhead travels along.
  Rectangle {
    x: root.railLeft - width / 2
    y: root.railY - height / 2
    width: root.railRight - root.railLeft
    height: Math.max(1, root.strokeWidth * 0.6)
    color: root.color
    opacity: 0.55
  }

  // Toolhead.
  Rectangle {
    width: root.headSize
    height: root.headSize
    radius: width / 4
    color: root.color
    x: root.railLeft + (root.railRight - root.railLeft) * root.headFraction - width / 2
    y: root.railY - height / 2

    Behavior on x {
      enabled: root.sweeping
      NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }
  }

  // Print bed.
  Rectangle {
    anchors.bottom: parent.bottom
    anchors.bottomMargin: root.frameMargin + root.strokeWidth
    anchors.horizontalCenter: parent.horizontalCenter
    width: root.iconSize - root.frameMargin * 2 - root.strokeWidth * 2
    height: Math.max(1, root.strokeWidth * 0.8)
    color: root.color
    opacity: 0.85
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
