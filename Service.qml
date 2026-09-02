import QtQuick
import Quickshell
import Quickshell.Io
import QtQml.Models
import "Model.js" as Model

// Coordinates the configured printer list (persisted to disk) and one
// persistent PrinterConnection (websocket) per configured printer — not
// just the active one, so switching printers is instant (no request in
// flight) and a background printer's print-finished/error notification
// fires the moment it happens rather than up to a poll interval later.
// This Item itself owns only: printer config CRUD, webcam-list fetching
// (still HTTP — orthogonal to status streaming), pause/resume/cancel/e-stop/
// restart-firmware actions (also still HTTP — one-shot user actions, not a
// latency-sensitive stream), and the add/edit form's Test button. Live
// status display properties are thin pass-throughs to whichever
// PrinterConnection matches activePrinterId.
Item {
  id: root

  property var settings: ({})

  // ---- configured printers -------------------------------------------------
  property var printers: []
  property string activePrinterId: ""
  readonly property var activePrinter: Model.findPrinter(printers, activePrinterId)

  // Stable id list so the Instantiator below only recreates PrinterConnection
  // instances (and their websockets) when a printer is actually added or
  // removed — never on the routine printers[] rewrites that scheme/webcam
  // pinning already do on every successful poll.
  property var printerIds: []

  function syncPrinterIds() {
    var ids = printers.map(function(p) { return p.id })
    var currentKey = printerIds.slice().sort().join(",")
    var newKey = ids.slice().sort().join(",")
    if (currentKey !== newKey) printerIds = ids
  }

  onPrintersChanged: syncPrinterIds()

  function connectionFor(id) {
    if (!id) return null
    for (var i = 0; i < connections.count; i++) {
      var obj = connections.objectAt(i)
      if (obj && obj.printerId === id) return obj
    }
    return null
  }

  Instantiator {
    id: connections
    model: root.printerIds
    delegate: PrinterConnection {
      printerId: modelData
      printers: root.printers
      service: root
    }
  }

  readonly property var activeConnection: connectionFor(activePrinterId)

  // ---- live status of the active printer — pass-throughs to its connection
  readonly property bool reachable: activeConnection ? activeConnection.reachable : false
  readonly property string state: activeConnection ? activeConnection.state : ""
  readonly property string message: activeConnection ? activeConnection.message : ""
  readonly property int progress: activeConnection ? activeConnection.progress : 0
  readonly property string filename: activeConnection ? activeConnection.filename : ""
  readonly property real printDurationSec: activeConnection ? activeConnection.printDurationSec : 0
  readonly property var hotend: activeConnection ? activeConnection.hotend : ({ actual: null, target: null })
  readonly property var bed: activeConnection ? activeConnection.bed : ({ actual: null, target: null })
  // Enabled cameras for the active printer, from /server/webcams/list.
  // Refreshed far less often than status — cameras essentially never change.
  // Unrelated to the websocket status stream, so this stays HTTP-polled.
  property var webcams: []

  // ---- action feedback ------------------------------------------------------
  property string actionStatus: ""
  // "" | "cancel" | "estop" — a destructive action armed by one press, run by
  // a second press within confirmTimer's window.
  property string pendingConfirm: ""

  // ---- test-connection (add/edit form) -----------------------------------
  property bool testing: false
  property bool testSuccess: false
  property string testStatus: ""
  property string testedHostname: ""
  property string testedScheme: ""
  // Bumped on every completed test (success or failure) so a caller can react
  // even when testSuccess stays the same across repeated clicks.
  property int testSequence: 0
  property var _testFields: null
  property var _testSchemeQueue: []
  property string _testCurrentScheme: ""

  readonly property string printerName: activePrinter ? Model.printerDisplayName(activePrinter) : ""
  readonly property int remainingSec: Model.estimateRemainingSec(progress, printDurationSec) || 0
  readonly property bool hasRemainingEstimate: Model.estimateRemainingSec(progress, printDurationSec) !== null

  function stateLabel() { return Model.stateLabel(root.state) }
  function stateTone() { return Model.stateTone(root.state) }
  function formatDuration(sec) { return Model.formatDuration(sec) }

  // Scheme for one-shot HTTP calls (webcams fetch, actions): whatever this
  // printer's connection has already pinned, else a plain http guess — these
  // aren't latency-sensitive and only ever run once a printer is already
  // showing live status (so its real scheme has normally been pinned by
  // then), so no probing dance needed here the way the websocket connection
  // itself has to do it for a never-before-seen printer.
  function preferredScheme(printer) {
    return (printer && (printer.scheme === "http" || printer.scheme === "https")) ? printer.scheme : "http"
  }

  function sendNotification(printerId, notif) {
    var key = printerId + "|" + notif.headline
    if (persisted.notifiedFor === key) return
    persisted.notifiedFor = key
    Quickshell.execDetached(["omarchy-notification-send", "-u", notif.urgency, notif.headline, notif.body])
  }

  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-klipper"
    property string notifiedFor: ""
  }

  // ---------------------------------------------------------------- webcams

  function fetchWebcams() {
    if (!activePrinter || webcamsProcess.running) return
    webcamsProcess.command = ["curl", "-fsS", "--max-time", "4"]
      .concat(Model.apiKeyHeaderArgs(activePrinter))
      .concat([Model.webcamsUrl(activePrinter, preferredScheme(activePrinter))])
    webcamsProcess.running = true
  }

  Timer {
    // Cameras essentially never change, so this polls far slower than status.
    id: webcamsTimer
    interval: 60000
    repeat: true
    running: root.activePrinter !== null
    triggeredOnStart: true
    onTriggered: root.fetchWebcams()
  }

  Process {
    id: webcamsProcess
    running: false
    command: []
    stdout: StdioCollector { id: webcamsStdout; waitForEnd: true }
    stderr: StdioCollector { id: webcamsStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(webcamsStdout.text || "")
      if (exitCode !== 0 || stdout === "") return // leave the cached list showing rather than collapsing it
      var parsed = Model.parseWebcamsResponse(stdout, root.activePrinter, preferredScheme(root.activePrinter))
      root.webcams = parsed
      // Persisted per-printer so the panel can size the camera area
      // correctly the instant this printer is selected again, before this
      // (slow, 60s) fetch has had a chance to run.
      if (root.activePrinter) root.pinWebcams(root.activePrinterId, parsed)
    }
  }

  // Only rewrites printers.json when the cached list actually changed, so a
  // healthy printer's 60s refresh doesn't write to disk every tick.
  function pinWebcams(id, webcams) {
    var list = printers.slice()
    for (var i = 0; i < list.length; i++) {
      if (list[i].id !== id) continue
      if (JSON.stringify(list[i].webcams || []) === JSON.stringify(webcams)) return
      list[i] = { id: list[i].id, name: list[i].name, host: list[i].host, port: list[i].port, scheme: list[i].scheme, apiKey: list[i].apiKey, webcams: webcams }
      printers = list
      persistPrinters()
      return
    }
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
    var scheme = preferredScheme(activePrinter)
    if (state === "printing") runAction(Model.actionUrl(activePrinter, "/printer/print/pause", scheme), "Pausing…")
    else if (state === "paused") runAction(Model.actionUrl(activePrinter, "/printer/print/resume", scheme), "Resuming…")
  }

  function requestCancel() {
    if (!activePrinter) return
    if (pendingConfirm === "cancel") {
      pendingConfirm = ""
      confirmTimer.stop()
      runAction(Model.actionUrl(activePrinter, "/printer/print/cancel", preferredScheme(activePrinter)), "Cancelling…")
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
      runAction(Model.actionUrl(activePrinter, "/printer/emergency_stop", preferredScheme(activePrinter)), "Emergency stop sent")
      return
    }
    pendingConfirm = "estop"
    actionStatus = "Press again to confirm EMERGENCY STOP"
    confirmTimer.restart()
  }

  function restartFirmware() {
    if (!activePrinter) return
    runAction(Model.actionUrl(activePrinter, "/printer/firmware_restart", preferredScheme(activePrinter)), "Restarting Klipper…")
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
    if (activePrinterId === printer.id) fetchWebcams()
    return true
  }

  function updatePrinter(id, fields) {
    var list = printers.slice()
    var updated = null
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        updated = Model.normalizePrinter(fields, id)
        // The edit form only ever carries name/host/port/apiKey — a cached
        // camera list has to be carried over explicitly or every edit would
        // silently blank it out (and re-trigger the layout jump this cache
        // exists to avoid) until the next 60s fetch.
        updated.webcams = list[i].webcams || []
        list[i] = updated
        break
      }
    }
    if (!updated) return
    printers = list
    persistPrinters()
    if (id === activePrinterId) webcams = updated.webcams
  }

  function removePrinter(id) {
    var list = printers.filter(function(p) { return p.id !== id })
    printers = list
    if (activePrinterId === id) {
      activePrinterId = list.length > 0 ? list[0].id : ""
      webcams = activePrinterId ? (Model.findPrinter(list, activePrinterId).webcams || []) : []
    }
    persistPrinters()
    if (activePrinterId) fetchWebcams()
  }

  function setActivePrinter(id) {
    if (id === activePrinterId || !Model.findPrinter(printers, id)) return
    activePrinterId = id
    // Seed from this printer's own cached camera list (persisted by
    // pinWebcams) rather than clearing to [] — reserves the right amount of
    // popup space immediately instead of the layout jumping once the fresh
    // (slow, 60s) fetch below completes. Status itself needs no such
    // seeding/refresh kick — the printer already has its own persistent
    // connection live in the background, so switching is just re-pointing
    // which one the UI reads from.
    webcams = Model.findPrinter(printers, id).webcams || []
    persistPrinters()
    // webcamsTimer's `running` binding stays true across a printer switch
    // (activePrinter never goes null), so triggeredOnStart never re-fires —
    // fetch explicitly instead of waiting up to 60s for the next slow tick.
    fetchWebcams()
  }

  // Records the scheme a PrinterConnection just discovered works, so it
  // (and the HTTP-based webcam/action calls) never have to probe again.
  function pinPrinterScheme(id, scheme) {
    var list = printers.slice()
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        list[i] = { id: list[i].id, name: list[i].name, host: list[i].host, port: list[i].port, scheme: scheme, apiKey: list[i].apiKey, webcams: list[i].webcams || [] }
        break
      }
    }
    printers = list
    persistPrinters()
  }

  function persistPrinters() {
    printersFile.setText(Model.serializePrinters({ activePrinterId: activePrinterId, printers: printers }))
  }

  // ---------------------------------------------------------------- test connection

  // Probes the host/port/apiKey currently typed into the add/edit form —
  // before it's ever saved — against /printer/info. Tries the scheme in the
  // host field if the user gave one, otherwise both in turn. Exposes
  // testedHostname so the panel can offer to fill in a blank Name field.
  function resetTestState() {
    testing = false
    testSuccess = false
    testStatus = ""
    testedHostname = ""
    testedScheme = ""
    testProcess.running = false
  }

  function testConnection(fields) {
    if (testProcess.running) return
    var normalized = Model.normalizePrinter(fields, "test")
    if (!normalized.host) {
      testSuccess = false
      testStatus = "Enter a host first"
      testSequence++
      return
    }
    testing = true
    testSuccess = false
    testStatus = "Testing…"
    testedHostname = ""
    testedScheme = ""
    _testFields = normalized
    _testSchemeQueue = normalized.scheme ? [normalized.scheme] : Model.SCHEME_PROBE_ORDER.slice()
    runNextTestAttempt()
  }

  function runNextTestAttempt() {
    if (_testSchemeQueue.length === 0) {
      testing = false
      testSuccess = false
      testStatus = "Could not connect"
      testSequence++
      return
    }
    _testCurrentScheme = _testSchemeQueue.shift()
    testProcess.command = ["curl", "-fsS", "--max-time", "4"]
      .concat(Model.apiKeyHeaderArgs(_testFields))
      .concat([Model.infoUrl(_testFields, _testCurrentScheme)])
    testProcess.running = true
  }

  Process {
    id: testProcess
    running: false
    command: []
    stdout: StdioCollector { id: testStdout; waitForEnd: true }
    stderr: StdioCollector { id: testStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(testStdout.text || "")
      var parsed = exitCode === 0 && stdout !== "" ? Model.parseInfoResponse(stdout) : { ok: false }
      if (!parsed.ok) {
        root.runNextTestAttempt()
        return
      }
      root.testing = false
      root.testSuccess = true
      root.testedScheme = root._testCurrentScheme
      root.testedHostname = parsed.hostname || ""
      root.testStatus = parsed.state === "ready"
        ? ("Connected" + (root.testedHostname ? " — " + root.testedHostname : ""))
        : ("Connected — Klipper is " + parsed.state)
      root.testSequence++
    }
  }

  function applyPrintersState(parsed) {
    printers = parsed.printers
    activePrinterId = parsed.activePrinterId
    var current = Model.findPrinter(printers, activePrinterId)
    webcams = current ? (current.webcams || []) : []
    fetchWebcams()
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
