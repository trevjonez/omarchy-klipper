import QtQuick
import QtQuick.Controls
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
  moduleName: "io.github.trevjonez.klipper"
  ipcTarget: "io.github.trevjonez.klipper"
  // This file declares its own IpcHandler on the same target so the settings
  // popup gets IPC functions alongside the printer popup's.
  manageIpc: false

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

  // App settings live in their own popup on middle-click, separate from the
  // printer popup. Both are anchored to the same bar pill; the bar's popout
  // coordinator keys off KeyboardPanel.owner, so giving the settings panel a
  // distinct owner (settingsOwner below) is what makes opening one close the
  // other.
  property bool settingsOpen: false

  // Fullscreen camera view. Identified by printer + webcam index rather than
  // by the webcam record, so the same view serves the all-cameras panel later.
  property string fullscreenPrinterId: ""
  property int fullscreenWebcamIndex: 0

  // All-cameras wall, on right-click.
  property bool cameraWallOpen: false

  // Only one of the four views is ever showing. Every entry point clears the
  // rest through here rather than each remembering the others, which is how
  // left-click came to leave the camera wall stacked behind the popup.
  function dismissAllViews() {
    close()
    settingsOpen = false
    cameraWallOpen = false
    fullscreenPrinterId = ""
  }

  function openCameraWall() {
    dismissAllViews()
    cameraWallOpen = true
  }

  function openFullscreenCamera(printerId, index) {
    dismissAllViews()
    fullscreenWebcamIndex = index
    fullscreenPrinterId = printerId
  }

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

  // Working copy of the fullscreen-overlay selection while the edit form is
  // open, applied by Save like every other field in the form.
  property var editingVideoOverlays: []

  function isOverlaySelected(key) {
    return editingVideoOverlays.indexOf(key) !== -1
  }

  function toggleOverlaySelection(key) {
    var list = editingVideoOverlays.slice()
    var idx = list.indexOf(key)
    if (idx !== -1) list.splice(idx, 1)
    else list.push(key)
    editingVideoOverlays = list
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
    editingVideoOverlays = Model.DEFAULT_VIDEO_OVERLAYS.slice()
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
    editingVideoOverlays = (p.videoOverlays || []).slice()
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
    editingVideoOverlays = []
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function requestRemovePrinter() {
    if (editingPrinterId === "") return
    if (!confirmRemovePrinter) { confirmRemovePrinter = true; return }
    var id = editingPrinterId
    cancelEditPrinter()
    printer.removePrinter(id)
  }

  // The record being edited, so the form can tell whether this printer has
  // any cameras at all.
  readonly property var editingPrinter: editingPrinterId === ""
    ? null : Model.findPrinter(printer.printers, editingPrinterId)
  readonly property int editingWebcamCount:
    editingPrinter && editingPrinter.webcams ? editingPrinter.webcams.length : 0

  function currentFormFields() {
    return { name: nameField.text, host: hostField.text, port: portField.text,
             apiKey: apiKeyField.text, displaySensors: editingSensorSelection,
             videoOverlays: editingVideoOverlays }
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
    objectName: "barPill"
    bar: root.bar
    iconComponent: iconComp
    tooltipText: printer.activePrinter ? (printer.printerName + " — " + printer.stateLabel()) : "Klipper — no printer configured"

    onPressed: function(b) {
      // Each button toggles its own view and dismisses the others, so the
      // pill always lands on exactly one thing showing or nothing.
      if (b === Qt.MiddleButton) {
        var settingsWereOpen = root.settingsOpen
        root.dismissAllViews()
        root.settingsOpen = !settingsWereOpen
      } else if (b === Qt.RightButton) {
        var wallWasOpen = root.cameraWallOpen
        root.dismissAllViews()
        root.cameraWallOpen = !wallWasOpen
      } else {
        var popupWasOpen = root.opened
        root.dismissAllViews()
        if (!popupWasOpen) root.open()
      }
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

      // ScrollView, not a bare Flickable: the shell's own audio and network
      // panels use it, so the wheel behaves the way every other panel on the
      // system does and the scrollbar is the themed one rather than something
      // hand-rolled. A raw Flickable scrolls with flick physics on a mouse
      // wheel, which feels nothing like the rest of the desktop.
      ScrollView {
        id: scroll
        objectName: "printerScroll"
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: content.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scroll.contentItem
          property: "interactive"
          value: content.implicitHeight > scroll.height
        }

        Column {
          id: content
          width: scroll.availableWidth
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

          Rectangle {
            width: parent.width - parent.leftPadding - parent.rightPadding
            height: Style.spacing.hairline
            color: root.foreground
            opacity: 0.12
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
              visible: printer.jobInProgress
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
              visible: printer.jobInProgress
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

                  required property int index

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openFullscreenCamera(printer.activePrinterId, parent.index)
                  }
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

            // Flow, not Row: button labels change with state ("Cancel" ->
            // "Confirm cancel", "E-STOP" -> "Confirm E-STOP") and an errored
            // print shows four at once, which overflowed the panel and clipped
            // the last button. Wrapping keeps them all reachable at any panel
            // width, font size or display scale.
            Flow {
              objectName: "heroActions"
              width: parent.width
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

              // Only for printers whose Moonraker has a [power] device.
              KlipperButton {
                visible: printer.hasPowerControl && printer.powerStatus === "off"
                buttonText: "Power on"
                onClicked: printer.setPower(true)
              }
              KlipperButton {
                visible: printer.hasPowerControl && printer.powerStatus === "on"
                // Shown but disabled mid-print when the device is configured
                // locked_while_printing: Moonraker would refuse it, and hiding
                // the button entirely just looks like the feature vanished.
                enabled: printer.powerTogglable
                buttonText: printer.pendingConfirm === "poweroff" ? "Confirm power off" : "Power off"
                urgent: printer.pendingConfirm === "poweroff"
                onClicked: printer.requestPowerOff()
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

            // ---- fullscreen video overlays -----------------------------
            // Only meaningful for a printer that actually has a camera, so
            // the whole section stays out of the way otherwise.
            Column {
              visible: root.editingWebcamCount > 0
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "Fullscreen video overlays"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Text {
                text: "Drawn over this printer's camera when opened fullscreen."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width
              }

              Repeater {
                model: Model.VIDEO_OVERLAY_FIELDS

                Item {
                  id: overlayRow
                  required property var modelData
                  width: parent.width
                  height: overlayRowContent.implicitHeight + Style.space(4)

                  Row {
                    id: overlayRowContent
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Rectangle {
                      width: Style.space(14)
                      height: Style.space(14)
                      radius: 3
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.isOverlaySelected(overlayRow.modelData.key) ? Color.accent : "transparent"
                      border.width: 1
                      border.color: root.isOverlaySelected(overlayRow.modelData.key) ? Color.accent : Qt.darker(root.foreground, 1.6)
                    }
                    Text {
                      text: overlayRow.modelData.label
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleOverlaySelection(overlayRow.modelData.key)
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

            Flow {
              objectName: "editFormButtons"
              width: parent.width
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

  CameraWall {
    id: cameraWall
    service: printer
    open: root.cameraWallOpen
    onCloseRequested: root.cameraWallOpen = false
    onTileActivated: function(printerId, webcamIndex) {
      root.openFullscreenCamera(printerId, webcamIndex)
    }
  }

  FullscreenVideo {
    id: fullscreenVideo
    service: printer
    printerId: root.fullscreenPrinterId
    webcamIndex: root.fullscreenWebcamIndex
    open: root.fullscreenPrinterId !== ""
    onCloseRequested: root.fullscreenPrinterId = ""
  }

  // KeyboardPanel.owner doubles as the bar's popout-coordinator key, so the
  // settings panel needs an owner distinct from `root` for the bar to treat
  // the two popups as rivals and close one when the other opens. It only has
  // to answer close().
  QtObject {
    id: settingsOwner
    property bool popoutSwitchClosing: false
    function close() { root.settingsOpen = false }
  }

  // The base Panel's own IpcHandler only knows about the printer popup, so
  // take over the target (manageIpc: false above) to expose the settings
  // popup on it too — it can then be bound to a key like any other Omarchy
  // panel instead of being reachable only by middle-clicking the bar pill.
  IpcHandler {
    target: root.ipcTarget

    // These go through dismissAllViews for the same reason the mouse buttons
    // do: only one view is ever showing, and an entry point that clears only
    // the views it happens to know about leaves the others stacked behind it.
    function open(): void { root.dismissAllViews(); root.open() }
    function close(): void { root.dismissAllViews() }
    function show(): void { open() }
    function hide(): void { close() }
    function toggle(): void {
      var wasOpen = root.opened
      root.dismissAllViews()
      if (!wasOpen) root.open()
    }

    function openSettings(): void { root.dismissAllViews(); root.settingsOpen = true }
    // Deliberately not dismissAllViews: this closes the settings popup only,
    // which is what makes it usable as "close that specific popup".
    function closeSettings(): void { root.settingsOpen = false }
    function toggleSettings(): void {
      var wasOpen = root.settingsOpen
      root.dismissAllViews()
      root.settingsOpen = !wasOpen
    }

    // Fullscreen the active printer's first camera, so it can be bound to a
    // key rather than only reachable by clicking the feed in the popup.
    function fullscreen(): void {
      if (printer.activePrinterId !== "") root.openFullscreenCamera(printer.activePrinterId, 0)
    }
    function closeFullscreen(): void { root.fullscreenPrinterId = "" }

    function cameras(): void { root.openCameraWall() }
    function closeCameras(): void { root.cameraWallOpen = false }
  }

  KeyboardPanel {
    id: settingsPanel
    anchorItem: button
    bar: root.bar
    owner: settingsOwner
    open: root.settingsOpen
    focusTarget: settingsKeyCatcher
    contentWidth: settingsPanel.fittedContentWidth(Style.space(360))
    contentHeight: settingsPanel.fittedContentHeight(settingsContent.implicitHeight)

    // Seed the draft from what's persisted each time the panel opens, so a
    // dismissed edit doesn't linger into the next open.
    onOpenChanged: if (open) watchDirField.text = printer.appSettings.gcodeWatchDir

    PanelKeyCatcher {
      id: settingsKeyCatcher
      anchors.fill: parent
      blocked: watchDirField.activeFocus
      onCloseRequested: root.settingsOpen = false
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    ScrollView {
      id: settingsScroll
      objectName: "settingsScroll"
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: settingsContent.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
      Binding {
        target: settingsScroll.contentItem
        property: "interactive"
        value: settingsContent.implicitHeight > settingsScroll.height
      }

      Column {
        id: settingsContent
        width: settingsScroll.availableWidth
        spacing: Style.space(14)
        topPadding: Style.space(16)
        bottomPadding: Style.space(16)
        leftPadding: Style.space(16)
        rightPadding: Style.space(16)

        Text {
          text: "Klipper settings"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Column {
          width: parent.width - parent.leftPadding - parent.rightPadding
          spacing: Style.space(8)

          Text {
            text: "G-CODE WATCH FOLDER"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Text {
            text: "When a printer reads G-code from a network share, a file written from another machine never reaches its file watcher, so Moonraker never parses the metadata. Point this at that share and new files get scanned on every reachable printer."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: watchDirField
              width: parent.width - saveWatchDir.implicitWidth - Style.space(8)
              placeholderText: "e.g. /mnt/unraid/GCodes (blank to disable)"
              foreground: root.foreground
              font.family: root.fontFamily
              Keys.onReturnPressed: root.saveWatchDir()
              Keys.onEscapePressed: root.settingsOpen = false
            }

            KlipperButton {
              id: saveWatchDir
              anchors.verticalCenter: parent.verticalCenter
              buttonText: "Save"
              onClicked: root.saveWatchDir()
            }
          }

          SettingCheck {
            width: parent.width
            label: "Watch for new G-code"
            // Shows whether watching is actually happening, not just whether
            // it's wanted — the flag stays set while a folder is missing.
            checked: printer.appSettings.gcodeWatchEnabled && printer.appSettings.gcodeWatchDir !== ""
            enabledRow: printer.appSettings.gcodeWatchDir !== ""
            onToggled: printer.setAppSettings({ gcodeWatchEnabled: !printer.appSettings.gcodeWatchEnabled })
          }

          SettingCheck {
            width: parent.width
            label: "Defer scans while printing"
            description: "A scan parses the whole file on the printer's own CPU. Holds new files until the job finishes."
            checked: printer.appSettings.deferScanWhilePrinting
            enabledRow: true
            onToggled: printer.setAppSettings({ deferScanWhilePrinting: !printer.appSettings.deferScanWhilePrinting })
          }

          Text {
            text: printer.watcher.status
            color: printer.watcher.failed ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            width: parent.width
          }
        }

        Rectangle {
          width: parent.width - parent.leftPadding - parent.rightPadding
          height: Style.spacing.hairline
          color: root.foreground
          opacity: 0.12
          visible: printer.watcher.activity.length > 0
        }

        Column {
          width: parent.width - parent.leftPadding - parent.rightPadding
          spacing: Style.space(6)
          visible: printer.watcher.activity.length > 0

          Text {
            text: "RECENT SCANS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Repeater {
            model: printer.watcher.activity

            // One row per file, then a line per printer underneath. A single
            // rolled-up "scanned on N printers" could not say *which* machines
            // were done and which were still waiting on a running print, which
            // made a held queue look like a stuck one.
            Column {
              required property var modelData
              width: parent.width
              spacing: Style.space(2)
              bottomPadding: Style.space(6)

              Text {
                visible: modelData.file !== ""
                text: modelData.at + "  " + modelData.file
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
                width: parent.width
              }

              Text {
                visible: modelData.note !== ""
                text: modelData.note
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width
              }

              Repeater {
                model: modelData.printers

                Row {
                  required property var modelData
                  spacing: Style.space(6)
                  leftPadding: Style.space(4)

                  Text {
                    text: root.scanGlyph(parent.modelData.state)
                    color: root.scanColor(parent.modelData.state)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: parent.modelData.name
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: root.scanLabel(parent.modelData.state)
                    color: root.scanColor(parent.modelData.state)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // Per-printer scan state, shown under each watched file.
  function scanGlyph(state) {
    if (state === "ok") return "\u2713"        // check
    if (state === "failed") return "\u2717"    // cross
    if (state === "scanning") return "\u25b6"  // triangle
    if (state === "missing") return "\u2013"   // dash
    return "\u25cb"                            // hollow circle: queued
  }

  function scanLabel(state) {
    if (state === "ok") return "scanned"
    if (state === "failed") return "failed"
    if (state === "scanning") return "scanning\u2026"
    if (state === "missing") return "doesn't have it"
    return "waiting"
  }

  function scanColor(state) {
    if (state === "failed") return Color.urgent
    if (state === "ok") return Color.accent
    if (state === "scanning") return Color.accent
    return root.dim
  }

  function saveWatchDir() {
    printer.setAppSettings({ gcodeWatchDir: watchDirField.text })
  }

  // Checkbox row matching the edit form's sensor picker — same square, same
  // full-row click target — with an optional second line of explanation.
  component SettingCheck: Item {
    id: check
    property string label: ""
    property string description: ""
    property bool checked: false
    property bool enabledRow: true
    signal toggled()

    implicitHeight: checkColumn.implicitHeight + Style.space(4)
    opacity: enabledRow ? 1 : 0.45

    Row {
      id: checkColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Rectangle {
        width: Style.space(14)
        height: Style.space(14)
        radius: 3
        y: Style.space(2)
        color: check.checked ? Color.accent : "transparent"
        border.width: 1
        border.color: check.checked ? Color.accent : Qt.darker(root.foreground, 1.6)
      }

      Column {
        width: parent.width - Style.space(22)
        spacing: Style.space(2)

        Text {
          text: check.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          visible: check.description !== ""
          text: check.description
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: check.enabledRow
      cursorShape: Qt.PointingHandCursor
      onClicked: check.toggled()
    }
  }

  component KlipperButton: Rectangle {
    id: btn
    property string buttonText: ""
    property bool urgent: false
    // Item.enabled already blocks the click, but on its own it looks exactly
    // like an enabled button that does nothing when pressed, so it is dimmed
    // and loses the pointer cursor too.
    signal clicked()

    opacity: btn.enabled ? 1 : 0.4
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
      cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (btn.enabled) btn.clicked()
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
