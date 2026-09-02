import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Single entry point acting as both the bar pill (BarIconButton) and its
// popup (KeyboardPanel) — the same shape as the first-party Tailscale plugin,
// chosen for the same reason: a custom-drawn, state-colored icon needs full
// control over the bar slot rather than the generic label-only BarIconButton
// wiring the Weather plugin uses.
Panel {
  id: root
  moduleName: "klipper"
  ipcTarget: "klipper"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property color iconColor: {
    var tone = printer.stateTone()
    if (tone === "urgent") return Color.urgent
    if (tone === "active") return Color.accent
    return foreground
  }

  property bool managingPrinters: false
  property bool addingPrinter: false
  property string editingPrinterId: ""
  property int switcherIndex: 0

  function selectedSwitcherPrinter() {
    if (printer.printers.length === 0) return null
    var idx = Math.max(0, Math.min(switcherIndex, printer.printers.length - 1))
    return printer.printers[idx]
  }

  function startAddPrinter() {
    managingPrinters = false
    addingPrinter = true
    editingPrinterId = ""
    printer.resetTestState()
    Qt.callLater(function() {
      nameField.text = ""
      hostField.text = ""
      portField.text = String(Model.DEFAULT_PORT)
      apiKeyField.text = ""
      hostField.forceActiveFocus()
    })
  }

  function startEditPrinter(p) {
    if (!p) return
    addingPrinter = true
    editingPrinterId = p.id
    printer.resetTestState()
    Qt.callLater(function() {
      nameField.text = p.name
      hostField.text = p.host
      portField.text = String(p.port)
      apiKeyField.text = p.apiKey
      hostField.forceActiveFocus()
    })
  }

  function cancelEditPrinter() {
    addingPrinter = false
    editingPrinterId = ""
    printer.resetTestState()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function currentFormFields() {
    return { name: nameField.text, host: hostField.text, port: portField.text, apiKey: apiKeyField.text }
  }

  function testCurrentForm() {
    printer.testConnection(currentFormFields())
  }

  function commitPrinterForm() {
    var fields = currentFormFields()
    if (String(fields.host || "").trim() === "") return
    // A successful test already knows a working scheme for this exact
    // host/port/key — carry it over so the printer is pinned immediately
    // instead of probing again on its first live poll.
    if (printer.testSuccess) fields.scheme = printer.testedScheme
    if (editingPrinterId !== "") printer.updatePrinter(editingPrinterId, fields)
    else printer.addPrinter(fields)
    cancelEditPrinter()
  }

  // A successful test that ran while the Name field was still blank fills it
  // in from the printer's own reported hostname — saves typing, and reacts
  // even if the user re-tests after editing the host.
  Connections {
    target: printer
    function onTestSequenceChanged() {
      if (printer.testSuccess && nameField.text.trim() === "" && printer.testedHostname !== "")
        nameField.text = printer.testedHostname
    }
  }

  Service {
    id: printer
    settings: root.settings
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    bar: root.bar
    iconComponent: iconComp
    tooltipText: printer.activePrinter ? (printer.printerName + " — " + printer.stateLabel()) : "Klipper — no printer configured"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) printer.refresh()
      else root.toggle()
    }
  }

  Component {
    id: iconComp
    PrinterIcon {
      iconSize: Style.font.icon
      color: root.iconColor
      progress: printer.progress
      sweeping: printer.state === "printing"
      warning: printer.stateTone() === "urgent"
      opacity: (!printer.activePrinter || printer.state === "" || printer.state === "offline") ? 0.55 : 1.0
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.addingPrinter
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (printer.printers.length === 0 || dy === 0) return
        root.switcherIndex = Math.max(0, Math.min(root.switcherIndex + dy, printer.printers.length - 1))
      }
      onActivateRequested: {
        var p = root.selectedSwitcherPrinter()
        if (p) printer.setActivePrinter(p.id)
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(14)
          topPadding: Style.space(16)
          bottomPadding: Style.space(16)
          leftPadding: Style.space(16)
          rightPadding: Style.space(16)

          // ---- printer switcher ----
          // Shown for a single configured printer too — otherwise there is
          // no row to hang Edit/Remove off of once "Manage printers" is on.
          Column {
            visible: printer.printers.length > 0
            width: parent.width - parent.leftPadding - parent.rightPadding
            spacing: Style.space(4)

            Repeater {
              model: printer.printers

              Rectangle {
                id: switcherRow
                required property var modelData
                required property int index
                width: parent.width
                height: switcherRowContent.implicitHeight + Style.spacing.rowPaddingX
                radius: Style.cornerRadius
                color: modelData.id === printer.activePrinterId
                  ? Style.selectedFillFor(root.foreground, Color.accent)
                  : (index === root.switcherIndex ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

                Row {
                  id: switcherRowContent
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Rectangle {
                    width: Style.space(8)
                    height: Style.space(8)
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: switcherRow.modelData.id === printer.activePrinterId && printer.reachable ? Color.accent : root.dim
                  }

                  Text {
                    text: Model.printerDisplayName(switcherRow.modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Row {
                  visible: root.managingPrinters
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  Text {
                    text: "Edit"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.startEditPrinter(switcherRow.modelData) }
                  }
                  Text {
                    text: "Remove"
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: printer.removePrinter(switcherRow.modelData.id) }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  visible: !root.managingPrinters
                  cursorShape: Qt.PointingHandCursor
                  onClicked: printer.setActivePrinter(switcherRow.modelData.id)
                }
              }
            }
          }

          // ---- empty state ----
          Text {
            visible: printer.printers.length === 0 && !root.addingPrinter
            width: parent.width - parent.leftPadding - parent.rightPadding
            text: "No printers configured yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---- hero: active printer status ----
          Column {
            visible: printer.activePrinter !== null && !root.addingPrinter
            width: parent.width - parent.leftPadding - parent.rightPadding
            spacing: Style.space(8)

            Text {
              visible: printer.printers.length > 1
              text: printer.printerName
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              text: printer.state === "" ? "Checking…" : printer.stateLabel()
              color: root.iconColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              visible: printer.filename !== ""
              text: printer.filename
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideMiddle
              width: parent.width
            }

            Item {
              visible: printer.state === "printing" || printer.state === "paused"
              width: parent.width
              height: Style.space(6)

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: root.foreground
                opacity: 0.15
              }

              Rectangle {
                width: parent.width * (printer.progress / 100)
                height: parent.height
                radius: height / 2
                color: Color.accent
              }
            }

            Row {
              visible: printer.state === "printing" || printer.state === "paused"
              spacing: Style.space(16)

              Text {
                text: printer.progress + "%"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: "Elapsed " + printer.formatDuration(printer.printDurationSec)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: printer.hasRemainingEstimate
                text: "ETA " + printer.formatDuration(printer.remainingSec)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              visible: printer.message !== ""
              text: printer.message
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Row {
              spacing: Style.space(28)

              Column {
                spacing: Style.space(2)
                Text { text: "HOTEND"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                Text {
                  text: printer.hotend.actual !== null ? (Math.round(printer.hotend.actual) + "° / " + Math.round(printer.hotend.target || 0) + "°") : "—"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
              Column {
                spacing: Style.space(2)
                Text { text: "BED"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                Text {
                  text: printer.bed.actual !== null ? (Math.round(printer.bed.actual) + "° / " + Math.round(printer.bed.target || 0) + "°") : "—"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            Column {
              visible: printer.webcams.length > 0
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: printer.webcams

                CameraView {
                  required property var modelData
                  width: parent.width
                  cameraName: printer.webcams.length > 1 ? modelData.name : ""
                  streamUrl: modelData.streamUrl
                  snapshotUrl: modelData.snapshotUrl
                  flipHorizontal: modelData.flipHorizontal
                  flipVertical: modelData.flipVertical
                  rotationDeg: modelData.rotation
                  aspectRatio: modelData.aspectRatio
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
              }
            }

            Text {
              visible: printer.actionStatus !== ""
              text: printer.actionStatus
              color: printer.pendingConfirm !== "" ? Color.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: printer.pendingConfirm !== ""
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Row {
              spacing: Style.space(10)

              KlipperButton {
                visible: printer.state === "printing" || printer.state === "paused"
                buttonText: printer.state === "printing" ? "Pause" : "Resume"
                onClicked: printer.togglePauseResume()
              }
              KlipperButton {
                visible: printer.state === "printing" || printer.state === "paused"
                buttonText: printer.pendingConfirm === "cancel" ? "Confirm cancel" : "Cancel"
                urgent: printer.pendingConfirm === "cancel"
                onClicked: printer.requestCancel()
              }
              KlipperButton {
                buttonText: printer.pendingConfirm === "estop" ? "Confirm E-STOP" : "E-STOP"
                urgent: true
                onClicked: printer.requestEmergencyStop()
              }
              KlipperButton {
                visible: printer.state === "klippy_error" || printer.state === "klippy_shutdown" || printer.state === "error"
                buttonText: "Restart Klipper"
                onClicked: printer.restartFirmware()
              }
            }
          }

          Rectangle {
            visible: !root.addingPrinter && (printer.printers.length > 0 || printer.activePrinter !== null)
            width: parent.width - parent.leftPadding - parent.rightPadding
            height: Style.spacing.hairline
            color: root.foreground
            opacity: 0.12
          }

          // ---- add/edit printer form ----
          Column {
            visible: root.addingPrinter
            width: parent.width - parent.leftPadding - parent.rightPadding
            spacing: Style.space(8)

            Text {
              text: root.editingPrinterId !== "" ? "Edit printer" : "Add printer"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Name (optional)"
              foreground: root.foreground
              font.family: root.fontFamily
              Keys.onEscapePressed: root.cancelEditPrinter()
            }
            TextField {
              id: hostField
              width: parent.width
              placeholderText: "Host, IP, or URL (required)"
              foreground: root.foreground
              font.family: root.fontFamily
              Keys.onReturnPressed: root.commitPrinterForm()
              Keys.onEscapePressed: root.cancelEditPrinter()
            }
            Text {
              text: "Plain host tries http then https automatically; paste a full https://… URL to pin one."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }
            TextField {
              id: portField
              width: parent.width
              placeholderText: "Moonraker port (default " + Model.DEFAULT_PORT + ")"
              foreground: root.foreground
              font.family: root.fontFamily
              Keys.onReturnPressed: root.commitPrinterForm()
              Keys.onEscapePressed: root.cancelEditPrinter()
            }
            TextField {
              id: apiKeyField
              width: parent.width
              placeholderText: "API key (optional)"
              foreground: root.foreground
              font.family: root.fontFamily
              Keys.onReturnPressed: root.commitPrinterForm()
              Keys.onEscapePressed: root.cancelEditPrinter()
            }

            Text {
              visible: printer.testStatus !== ""
              text: printer.testStatus
              color: printer.testing ? root.dim : (printer.testSuccess ? Color.accent : Color.urgent)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Row {
              spacing: Style.space(10)
              KlipperButton { buttonText: printer.testing ? "Testing…" : "Test"; onClicked: root.testCurrentForm() }
              KlipperButton { buttonText: root.editingPrinterId !== "" ? "Save" : "Add"; onClicked: root.commitPrinterForm() }
              KlipperButton { buttonText: "Cancel"; onClicked: root.cancelEditPrinter() }
            }
          }

          // ---- footer actions ----
          Row {
            visible: !root.addingPrinter
            spacing: Style.space(16)

            Text {
              text: "+ Add printer"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.startAddPrinter() }
            }
            Text {
              visible: printer.printers.length > 0
              text: root.managingPrinters ? "Done managing" : "Manage printers"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.managingPrinters = !root.managingPrinters }
            }
          }
        }
      }
    }
  }

  component KlipperButton: Rectangle {
    id: btn
    property string buttonText: ""
    property bool urgent: false
    signal clicked()
    implicitWidth: label.implicitWidth + Style.space(20)
    implicitHeight: Style.space(30)
    radius: Style.cornerRadius
    color: mouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    border.width: 1
    border.color: btn.urgent ? Color.urgent : Qt.darker(root.foreground, 1.6)

    Text {
      id: label
      anchors.centerIn: parent
      text: btn.buttonText
      color: btn.urgent ? Color.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: btn.urgent
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: btn.clicked()
    }
  }
}
