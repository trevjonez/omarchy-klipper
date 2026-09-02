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

  property bool addingPrinter: false
  property string editingPrinterId: ""
  // "Remove printer" in the edit form is armed by one press, run by a
  // second — same double-press-to-confirm convention Service.qml already
  // uses for cancel/e-stop.
  property bool confirmRemovePrinter: false
  property int switcherIndex: 0
  // Keyboard-cursor highlight only appears once the keyboard is actually
  // used — same convention as the Network plugin's cursorActive. Without
  // this, switcherIndex's harmless default (0, i.e. the first row) reads as
  // a second, stuck-looking highlight on whichever printer is listed first,
  // independent of which one is actually active.
  property bool cursorActive: false

  function selectedSwitcherPrinter() {
    if (printer.printers.length === 0) return null
    var idx = Math.max(0, Math.min(switcherIndex, printer.printers.length - 1))
    return printer.printers[idx]
  }

  // Working copy of the sensor-picker's selection while the edit form is
  // open — only written back via commitPrinterForm's Save, like every other
  // field in the form.
  property var editingSensorSelection: []

  function isSensorSelected(object, field) {
    for (var i = 0; i < editingSensorSelection.length; i++) {
      var e = editingSensorSelection[i]
      if (e.object === object && (e.field || "") === (field || "")) return true
    }
    return false
  }

  function toggleSensorSelection(object, field) {
    var list = editingSensorSelection.slice()
    var idx = -1
    for (var i = 0; i < list.length; i++) {
      if (list[i].object === object && (list[i].field || "") === (field || "")) { idx = i; break }
    }
    if (idx !== -1) list.splice(idx, 1)
    else list.push(field ? { object: object, field: field } : { object: object })
    editingSensorSelection = list
  }

  // A multi-output sensor (bme280 etc.) becomes one selectable row per
  // field; anything else stays a single whole-object row.
  function flattenSensorRows(objectNames) {
    var rows = []
    var list = objectNames || []
    for (var i = 0; i < list.length; i++) {
      var name = list[i]
      var fields = Model.selectableFieldsFor(name)
      if (fields) {
        for (var j = 0; j < fields.length; j++) rows.push({ object: name, field: fields[j] })
      } else {
        rows.push({ object: name, field: "" })
      }
    }
    return rows
  }

  function startAddPrinter() {
    addingPrinter = true
    editingPrinterId = ""
    confirmRemovePrinter = false
    printer.resetTestState()
    editingSensorSelection = []
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
    confirmRemovePrinter = false
    printer.resetTestState()
    editingSensorSelection = (p.displaySensors || []).slice()
    // No live connection exists yet for a printer that doesn't exist until
    // Save, so this only ever runs for an already-configured printer —
    // it's already connected, so discovery can run immediately.
    printer.discoverSensorsFor(p)
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
    confirmRemovePrinter = false
    printer.resetTestState()
    printer.clearEditDiscovery()
    editingSensorSelection = []
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function requestRemovePrinter() {
    if (editingPrinterId === "") return
    if (!confirmRemovePrinter) { confirmRemovePrinter = true; return }
    var id = editingPrinterId
    cancelEditPrinter()
    printer.removePrinter(id)
  }

  function currentFormFields() {
    return { name: nameField.text, host: hostField.text, port: portField.text, apiKey: apiKeyField.text, displaySensors: editingSensorSelection }
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
        root.cursorActive = true
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
          // Always shown, even with zero printers — "+ Add printer" lives as
          // the list's own trailing row now rather than a separate footer.
          Column {
            width: parent.width - parent.leftPadding - parent.rightPadding
            spacing: Style.space(4)

            Repeater {
              model: printer.printers

              Rectangle {
                id: switcherRow
                required property var modelData
                required property int index
                readonly property bool isActive: modelData.id === printer.activePrinterId
                // Breaks out of content's left/right padding so the
                // hover/selected fill runs edge-to-edge instead of stopping
                // at the list's own inset — the content below (name, gear)
                // gets that same inset back explicitly, so only the paint,
                // not the layout, is full-bleed.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(16)
                height: switcherRowContent.implicitHeight + Style.spacing.rowPaddingX
                radius: Style.cornerRadius
                color: isActive
                  ? Style.selectedFillFor(root.foreground, Color.accent)
                  : (rowHoverArea.containsMouse || (root.cursorActive && index === root.switcherIndex) ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

                // Full-row hover detection (for the highlight above and the
                // gear's reveal-on-hover below) sits underneath the gear's
                // own, smaller mouse area — declared first, so it's beneath
                // in z-order and never steals a click meant for the gear.
                MouseArea {
                  id: rowHoverArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: printer.setActivePrinter(switcherRow.modelData.id)
                }

                Row {
                  id: switcherRowContent
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Rectangle {
                    width: Style.space(8)
                    height: Style.space(8)
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    // Every row gets a live connection now, not just the
                    // active one — free bonus of always-on per-printer
                    // websockets: you can see who's online before switching.
                    readonly property var connection: printer.connectionFor(switcherRow.modelData.id)
                    color: connection && connection.reachable ? Color.accent : root.dim
                  }

                  Text {
                    text: Model.printerDisplayName(switcherRow.modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                GearIcon {
                  id: gearButton
                  // Only the selected printer's gear stays put — everyone
                  // else's only appears while its row is actually hovered,
                  // so the list doesn't read as five gears at rest.
                  visible: switcherRow.isActive || rowHoverArea.containsMouse
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  color: gearArea.containsMouse ? root.foreground : root.dim

                  MouseArea {
                    id: gearArea
                    // Larger than the icon itself — a comfortable click
                    // target without changing the icon's own visual size.
                    anchors.centerIn: parent
                    width: parent.width + Style.space(12)
                    height: parent.height + Style.space(12)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startEditPrinter(switcherRow.modelData)
                  }
                }
              }
            }

            Item {
              id: addPrinterRow
              width: parent.width
              height: addPrinterContent.implicitHeight + Style.spacing.rowPaddingX

              Rectangle {
                // Same edge-to-edge break-out as the printer rows above.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(16)
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                radius: Style.cornerRadius
                color: addPrinterArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
              }

              Row {
                id: addPrinterContent
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: "+"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: "Add printer"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: addPrinterArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.startAddPrinter()
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

            Flow {
              width: parent.width
              spacing: Style.space(20)
              visible: printer.activePrinter && printer.activePrinter.displaySensors.length > 0

              Repeater {
                model: printer.activePrinter ? printer.activePrinter.displaySensors : []

                Column {
                  required property var modelData
                  spacing: Style.space(2)
                  Text {
                    text: Model.sensorFieldLabel(modelData.object, modelData.field).toUpperCase()
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }
                  Text {
                    text: Model.formatSensorEntry(printer.sensors[modelData.object], modelData.field)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
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

            // ---- sensors to display (existing printers only — a new one
            // has no live connection to discover against until it's saved).
            Column {
              visible: root.editingPrinterId !== ""
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "Sensors to display"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Text {
                visible: printer.editDiscoveryLoading
                text: "Checking what this printer has…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                visible: !printer.editDiscoveryLoading && printer.editDiscoveryHeaters.length === 0 && printer.editDiscoverySensors.length === 0
                text: "Could not read this printer's sensors — make sure it's reachable, then reopen Edit."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                width: parent.width
              }

              Text {
                visible: printer.editDiscoveryHeaters.length > 0
                text: "HEATERS"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Repeater {
                model: printer.editDiscoveryHeaters

                Item {
                  id: heaterRow
                  required property string modelData
                  width: parent.width
                  height: heaterRowContent.implicitHeight + Style.space(4)

                  Row {
                    id: heaterRowContent
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Rectangle {
                      width: Style.space(14)
                      height: Style.space(14)
                      radius: 3
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.isSensorSelected(heaterRow.modelData, "") ? Color.accent : "transparent"
                      border.width: 1
                      border.color: root.isSensorSelected(heaterRow.modelData, "") ? Color.accent : Qt.darker(root.foreground, 1.6)
                    }
                    Text {
                      text: Model.sensorLabel(heaterRow.modelData)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleSensorSelection(heaterRow.modelData, "")
                  }
                }
              }

              Text {
                visible: printer.editDiscoverySensors.length > 0
                text: "OTHER SENSORS"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Repeater {
                // A multi-output sensor (bme280 etc.) expands into one row
                // per field instead of one row for the whole object, per
                // Model.selectableFieldsFor.
                model: root.flattenSensorRows(printer.editDiscoverySensors)

                Item {
                  id: sensorRow
                  required property var modelData
                  width: parent.width
                  height: sensorRowContent.implicitHeight + Style.space(4)

                  Row {
                    id: sensorRowContent
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Rectangle {
                      width: Style.space(14)
                      height: Style.space(14)
                      radius: 3
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.isSensorSelected(sensorRow.modelData.object, sensorRow.modelData.field) ? Color.accent : "transparent"
                      border.width: 1
                      border.color: root.isSensorSelected(sensorRow.modelData.object, sensorRow.modelData.field) ? Color.accent : Qt.darker(root.foreground, 1.6)
                    }
                    Text {
                      text: Model.sensorFieldLabel(sensorRow.modelData.object, sensorRow.modelData.field)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleSensorSelection(sensorRow.modelData.object, sensorRow.modelData.field)
                  }
                }
              }
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
              KlipperButton {
                visible: root.editingPrinterId !== ""
                buttonText: root.confirmRemovePrinter ? "Confirm remove" : "Remove printer"
                urgent: true
                onClicked: root.requestRemovePrinter()
              }
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

  // Custom-drawn (not a font glyph) for the same reason PrinterIcon.qml is:
  // guaranteed to render identically everywhere, no tofu risk on a theme
  // font that happens not to carry a gear character. Two overlapping
  // squares (one plain, one rotated 45°) make an 8-pointed star; a circle
  // sized to cover their flat edges but not their corners leaves exactly
  // those 8 corners poking out as teeth, plus a small hole punched through
  // the middle in the popup's own background color.
  component GearIcon: Item {
    id: gear
    property color color: root.dim
    implicitWidth: Style.space(16)
    implicitHeight: Style.space(16)
    width: implicitWidth
    height: implicitHeight

    // 8 small squares (slightly rounded, not sharp points) evenly spaced
    // around the hub, each half-covered by the hub circle below so only
    // its outer half pokes out as a flat-topped tooth — reads as a cog,
    // not a spiky star, at this size.
    readonly property real toothSize: width * 0.22
    readonly property real toothCenterDistance: width * 0.35

    Repeater {
      model: 8
      Rectangle {
        required property int index
        width: gear.toothSize
        height: gear.toothSize
        radius: width * 0.2
        color: gear.color
        x: gear.width / 2 + gear.toothCenterDistance * Math.cos(index * Math.PI / 4) - width / 2
        y: gear.height / 2 + gear.toothCenterDistance * Math.sin(index * Math.PI / 4) - height / 2
      }
    }

    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.62
      height: width
      radius: width / 2
      color: gear.color
    }
    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.28
      height: width
      radius: width / 2
      color: Color.popups.background
    }
  }
}
