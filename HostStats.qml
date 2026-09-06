import QtQuick
import qs.Commons
import "Model.js" as Model

// CPU and memory for the machine Moonraker runs on -- usually the Pi driving
// the printer, which is worth a glance because a pegged CPU or an exhausted
// host is what a stuttering print looks like before it fails.
//
// One component for both the popup and the fullscreen overlay: they differ
// only in palette and scale, which is the same split CameraView already uses.
// The readings arrive as plain values rather than as a Service or a
// PrinterConnection, so each view hands over what it has without this needing
// to know which.
//
// Width is set by the caller: the popup stretches to the panel, the overlay
// takes the same fixed width as the progress bar it sits under.
Column {
  id: root

  property int cpuPercent: -1
  property int memUsedKb: -1
  property int memTotalKb: -1

  property color foreground: Color.foreground
  property color dim: Qt.darker(Color.foreground, 1.3)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int labelSize: Style.font.caption
  property int valueSize: Style.font.bodySmall
  property int barHeight: Style.space(4)

  // A host reports neither, one, or both: an older Moonraker has no
  // system_cpu_usage at all, and memory can be missing where CPU is not.
  readonly property var bars: {
    var out = []
    if (cpuPercent >= 0)
      out.push({ label: "CPU", value: cpuPercent + "%", fraction: cpuPercent / 100 })
    if (memTotalKb > 0 && memUsedKb >= 0) {
      out.push({ label: "RAM",
                 value: Model.formatMemory(memUsedKb) + " / " + Model.formatMemory(memTotalKb),
                 fraction: Model.memoryFraction(memUsedKb, memTotalKb) })
    }
    return out
  }

  spacing: Style.space(6)
  visible: bars.length > 0

  Repeater {
    model: root.bars

    Item {
      required property var modelData

      width: root.width
      height: barLabel.implicitHeight + root.barHeight + Style.space(3)

      Text {
        id: barLabel
        textFormat: Text.PlainText
        anchors.left: parent.left
        text: parent.modelData.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
        font.letterSpacing: 1
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.baseline: barLabel.baseline
        text: parent.modelData.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.valueSize
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.barHeight
        radius: height / 2
        color: root.foreground
        opacity: 0.15

        Rectangle {
          readonly property real fraction: Math.max(0, Math.min(1, parent.parent.modelData.fraction))
          width: parent.width * fraction
          height: parent.height
          radius: parent.radius
          // Past three quarters the host has no headroom left, which is the
          // one state worth catching an eye rather than blending in.
          color: fraction >= 0.75 ? Color.urgent : root.accent
        }
      }
    }
  }
}
