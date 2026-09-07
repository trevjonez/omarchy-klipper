import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// Fullscreen view of one camera, with the printer's chosen fields drawn over
// it. Opened by clicking a feed in the printer popup, and later by clicking a
// tile in the all-cameras panel — so it takes a printerId and a webcam index
// and resolves everything itself, rather than having values pushed in by
// whichever view happened to open it.
//
// Its own layer-shell window on the overlay layer: the popups are already
// overlay surfaces, and a fullscreen feed has to sit above them and take the
// keyboard so Escape works.
PanelWindow {
  id: root

  property var service: null
  property string printerId: ""
  property int webcamIndex: 0
  property bool open: false

  readonly property var printer: service ? Model.findPrinter(service.printers, printerId) : null
  readonly property var connection: service && printerId !== "" ? service.connectionFor(printerId) : null
  readonly property var webcams: printer && printer.webcams ? printer.webcams : []
  readonly property var webcam: webcamIndex >= 0 && webcamIndex < webcams.length ? webcams[webcamIndex] : null
  readonly property var overlays: printer && printer.videoOverlays ? printer.videoOverlays : []

  function shows(key) { return overlays.indexOf(key) !== -1 }

  // Progress, elapsed and ETA only mean something while a job is running, so
  // selecting them does not force a "0%" bar onto an idle printer.
  readonly property bool jobInProgress:
    connection ? Model.jobInProgress(connection.state) : false

  // Signals rather than assigning to `open`: the owner binds `open` to its own
  // state, and writing to it here would break that binding, so the view could
  // be dismissed once and then never reopen.
  signal closeRequested()

  function close() { root.closeRequested() }

  visible: open && webcam !== null
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "omarchy-klipper-fullscreen"
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

  // Fully opaque: at anything less the desktop shows through the letterbox
  // bars beside the feed, which reads as a rendering fault rather than a
  // deliberate effect.
  Rectangle {
    anchors.fill: parent
    color: "black"
  }

  // Letterboxed: CameraView derives its height from its width and the feed's
  // aspect ratio, so pick whichever width makes the result fit the screen.
  CameraView {
    id: feed
    anchors.centerIn: parent
    readonly property real ratio: root.webcam && root.webcam.aspectRatio > 0 ? root.webcam.aspectRatio : 0.75
    width: Math.min(parent.width, parent.height / ratio)

    active: root.open
    cameraName: ""
    streamUrl: root.webcam ? root.webcam.streamUrl : ""
    snapshotUrl: root.webcam ? root.webcam.snapshotUrl : ""
    flipHorizontal: root.webcam ? root.webcam.flipHorizontal : false
    flipVertical: root.webcam ? root.webcam.flipVertical : false
    rotationDeg: root.webcam ? root.webcam.rotation : 0
    aspectRatio: ratio
    foreground: Color.foreground
  }

  // Translucent backing so text stays readable over any frame — a light print
  // on a light bed washes out plain white text completely.
  Rectangle {
    id: infoCard
    visible: infoColumn.children.length > 0 && infoColumn.height > 0
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.margins: Style.space(24)
    radius: Style.cornerRadius
    color: Color.background
    opacity: 0.72
    width: infoColumn.implicitWidth + Style.space(28)
    height: infoColumn.implicitHeight + Style.space(20)
  }

  Column {
    id: infoColumn
    anchors.left: infoCard.left
    anchors.top: infoCard.top
    anchors.margins: Style.space(10)
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      visible: root.shows("name")
      text: root.printer ? Model.printerDisplayName(root.printer) : ""
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      visible: root.shows("status")
      text: root.connection ? Model.stateLabel(root.connection.state) : ""
      color: {
        var tone = root.connection ? Model.stateTone(root.connection.state) : "normal"
        if (tone === "urgent") return Color.urgent
        if (tone === "active") return Color.accent
        return Color.foreground
      }
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      visible: root.shows("filename") && root.connection && root.connection.filename !== ""
      text: root.connection ? root.connection.filename : ""
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
      width: Math.min(implicitWidth, root.width / 3)
    }

    // Progress gets a bar as well as a number: at a glance across the room
    // the bar is the readable part.
    Item {
      visible: root.shows("progress") && root.jobInProgress
      width: Style.space(220)
      height: progressLabel.implicitHeight + Style.space(8)

      Text {
        id: progressLabel
        textFormat: Text.PlainText
        text: (root.connection ? root.connection.progress : 0) + "%"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(4)
        radius: height / 2
        color: Qt.darker(Color.foreground, 2.2)

        Rectangle {
          width: parent.width * ((root.connection ? root.connection.progress : 0) / 100)
          height: parent.height
          radius: parent.radius
          color: Color.accent
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.shows("elapsed") && root.jobInProgress
      text: "Elapsed " + Model.formatDuration(root.connection ? root.connection.printDurationSec : 0)
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      visible: root.shows("remaining") && root.jobInProgress
      text: {
        var c = root.connection
        var left = c ? Model.estimateRemainingSec(c.progress, c.printDurationSec) : null
        return left ? "ETA " + Model.formatDuration(left) : "ETA —"
      }
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    HostStats {
      // Same fixed width as the progress bar above, so the card keeps one
      // edge rather than growing to whatever the numbers happen to be.
      visible: root.shows("host")
      width: Style.space(220)
      cpuPercent: root.shows("host") && root.connection ? root.connection.hostCpuPercent : -1
      memUsedKb: root.connection ? root.connection.hostMemUsedKb : -1
      memTotalKb: root.shows("host") && root.connection ? root.connection.hostMemTotalKb : -1
      valueSize: Style.font.caption
      dim: Qt.darker(Color.foreground, 1.3)
    }

    // The same selection the popup shows, so the fullscreen view doesn't need
    // its own sensor picker.
    Flow {
      visible: root.shows("temps")
      width: Style.space(260)
      spacing: Style.space(12)

      Repeater {
        model: root.shows("temps") && root.printer ? (root.printer.displaySensors || []) : []

        Text {
          textFormat: Text.PlainText
          required property var modelData
          readonly property var reading: root.connection && root.connection.sensors
            ? root.connection.sensors[modelData.object] : null
          text: Model.sensorFieldLabel(modelData.object, modelData.field) + " "
                + Model.formatSensorEntry(reading, modelData.field)
          color: Qt.darker(Color.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(18)
    text: "Esc or click to close"
    color: Color.foreground
    opacity: 0.35
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  MouseArea {
    anchors.fill: parent
    // Below the info card in z-order is irrelevant here — a click anywhere,
    // including on the overlay text, should dismiss.
    z: 2
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: root.close()
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: root.open
    Keys.onEscapePressed: root.close()
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Q || event.key === Qt.Key_F11) {
        root.close()
        event.accepted = true
      }
    }
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
