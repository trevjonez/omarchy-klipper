import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Holds all Klipper/Moonraker state: the configured printer list (persisted
// to disk), the live status of whichever printer is active, and the
// pause/resume/cancel/e-stop/restart actions. Structured like the first-party
// Tailscale plugin's Service.qml — one Item owning Timers/Processes, read and
// driven by Panel.qml.
Item {
  id: root

  property var settings: ({})

  // ---- configured printers -------------------------------------------------
  property var printers: []
  property string activePrinterId: ""
  readonly property var activePrinter: Model.findPrinter(printers, activePrinterId)

  // ---- live status of the active printer -----------------------------------
  property bool reachable: false
  property string state: ""
  property string message: ""
  property int progress: 0
  property string filename: ""
  property real printDurationSec: 0
  property var hotend: ({ actual: null, target: null })
  property var bed: ({ actual: null, target: null })
  property bool refreshing: false
  property string lastError: ""

  // ---- action feedback ------------------------------------------------------
  property string actionStatus: ""
  // "" | "cancel" | "estop" — a destructive action armed by one press, run by
  // a second press within confirmTimer's window.
  property string pendingConfirm: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 3, 1, 60)
  readonly property bool busy: statusProcess.running || actionProcess.running
  readonly property string printerName: activePrinter ? Model.printerDisplayName(activePrinter) : ""
  readonly property int remainingSec: Model.estimateRemainingSec(progress, printDurationSec) || 0
  readonly property bool hasRemainingEstimate: Model.estimateRemainingSec(progress, printDurationSec) !== null

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function stateLabel() { return Model.stateLabel(root.state) }
  function stateTone() { return Model.stateTone(root.state) }
  function formatDuration(sec) { return Model.formatDuration(sec) }

  // ---------------------------------------------------------------- polling

  function refresh() {
    if (!activePrinter) {
      resetStatus("")
      return
    }
    if (statusProcess.running) return
    refreshing = true
    var printer = activePrinter
    statusProcess.command = ["curl", "-fsS", "--max-time", "4"]
      .concat(Model.apiKeyHeaderArgs(printer))
      .concat([Model.queryUrl(printer)])
    statusProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.restart()
  }

  function resetStatus(withState) {
    reachable = false
    state = withState
    message = ""
    progress = 0
    filename = ""
    printDurationSec = 0
    hotend = { actual: null, target: null }
    bed = { actual: null, target: null }
  }

  function applyOffline(reason) {
    resetStatus("offline")
    message = reason || "Unreachable"
    lastError = message
  }

  function applyParsedStatus(parsed) {
    var notif = Model.notificationForTransition(root.state, parsed.state, root.printerName, parsed.filename, parsed.message)
    reachable = true
    lastError = ""
    state = parsed.state
    message = parsed.message
    progress = parsed.progress
    filename = parsed.filename
    printDurationSec = parsed.printDurationSec
    hotend = parsed.hotend
    bed = parsed.bed
    if (notif) sendNotification(notif)
  }

  function sendNotification(notif) {
    var key = root.activePrinterId + "|" + notif.headline
    if (persisted.notifiedFor === key) return
    persisted.notifiedFor = key
    Quickshell.execDetached(["omarchy-notification-send", "-u", notif.urgency, notif.headline, notif.body])
  }

  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-klipper"
    property string notifiedFor: ""
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.activePrinter !== null
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // A hung curl (printer mid-reboot, flaky wifi) must not silently freeze
    // the pill on stale data forever — reap it well inside the refresh
    // interval so the next tick starts clean. Same idea as Tailscale's
    // pollWatchdog.
    id: pollWatchdog
    interval: 10000
    repeat: false
    onTriggered: if (statusProcess.running) statusProcess.running = false
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: confirmTimer
    interval: 4000
    repeat: false
    onTriggered: { root.pendingConfirm = ""; root.actionStatus = "" }
  }

  Timer {
    id: delayedRefresh
    interval: 500
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || "")
      if (exitCode !== 0 || stdout === "") {
        root.applyOffline("Unreachable")
        return
      }
      var parsed = Model.parseStatusResponse(stdout)
      if (!parsed.ok) {
        root.applyOffline(parsed.error || "Bad response from Moonraker")
        return
      }
      root.applyParsedStatus(parsed)
    }
  }

  // ---------------------------------------------------------------- actions

  function runAction(url, label) {
    if (!activePrinter || actionProcess.running) return
    actionStatus = label || ""
    actionProcess.command = ["curl", "-fsS", "--max-time", "5", "-X", "POST"]
      .concat(Model.apiKeyHeaderArgs(activePrinter))
      .concat([url])
    actionProcess.running = true
  }

  function togglePauseResume() {
    if (!activePrinter) return
    if (state === "printing") runAction(Model.actionUrl(activePrinter, "/printer/print/pause"), "Pausing…")
    else if (state === "paused") runAction(Model.actionUrl(activePrinter, "/printer/print/resume"), "Resuming…")
  }

  function requestCancel() {
    if (!activePrinter) return
    if (pendingConfirm === "cancel") {
      pendingConfirm = ""
      confirmTimer.stop()
      runAction(Model.actionUrl(activePrinter, "/printer/print/cancel"), "Cancelling…")
      return
    }
    pendingConfirm = "cancel"
    actionStatus = "Press cancel again to confirm"
    confirmTimer.restart()
  }

  function requestEmergencyStop() {
    if (!activePrinter) return
    if (pendingConfirm === "estop") {
      pendingConfirm = ""
      confirmTimer.stop()
      runAction(Model.actionUrl(activePrinter, "/printer/emergency_stop"), "Emergency stop sent")
      return
    }
    pendingConfirm = "estop"
    actionStatus = "Press again to confirm EMERGENCY STOP"
    confirmTimer.restart()
  }

  function restartFirmware() {
    if (!activePrinter) return
    runAction(Model.actionUrl(activePrinter, "/printer/firmware_restart"), "Restarting Klipper…")
  }

  function cancelPendingConfirm() {
    pendingConfirm = ""
    actionStatus = ""
    confirmTimer.stop()
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var stderr = String(actionStderr.text || actionStdout.text || "Command failed")
        root.actionStatus = stderr.replace(/\s+/g, " ").trim().substring(0, 140)
        actionStatusTimer.restart()
      } else {
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }

  // ---------------------------------------------------------------- printer management

  function generateId() {
    return "p" + Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36)
  }

  function addPrinter(fields) {
    var host = fields ? String(fields.host || "").trim() : ""
    if (host === "") return false
    var printer = Model.normalizePrinter(fields, generateId())
    var list = printers.slice()
    list.push(printer)
    printers = list
    if (!activePrinterId) activePrinterId = printer.id
    persistPrinters()
    if (activePrinterId === printer.id) refresh()
    return true
  }

  function updatePrinter(id, fields) {
    var list = printers.slice()
    var changed = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        list[i] = Model.normalizePrinter(fields, id)
        changed = true
        break
      }
    }
    if (!changed) return
    printers = list
    persistPrinters()
    if (id === activePrinterId) refresh()
  }

  function removePrinter(id) {
    var list = printers.filter(function(p) { return p.id !== id })
    printers = list
    if (activePrinterId === id) {
      activePrinterId = list.length > 0 ? list[0].id : ""
      resetStatus("")
      statusProcess.running = false
    }
    persistPrinters()
    if (activePrinterId) refresh()
  }

  function setActivePrinter(id) {
    if (id === activePrinterId || !Model.findPrinter(printers, id)) return
    activePrinterId = id
    statusProcess.running = false
    resetStatus("")
    persistPrinters()
    refresh()
  }

  function persistPrinters() {
    printersFile.setText(Model.serializePrinters({ activePrinterId: activePrinterId, printers: printers }))
  }

  function applyPrintersState(parsed) {
    printers = parsed.printers
    activePrinterId = parsed.activePrinterId
    refresh()
  }

  Process {
    id: ensureDirProcess
    command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/state/omarchy-klipper"]
    running: true
    onExited: printersFile.reload()
  }

  FileView {
    id: printersFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy-klipper/printers.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyPrintersState(Model.parsePrinters(text()))
    onLoadFailed: root.applyPrintersState(Model.parsePrinters(""))
    onFileChanged: reload()
  }
}
