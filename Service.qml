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

  // ---- app settings --------------------------------------------------------
  // Deliberately not `settings` above — that one is the plugin host's manifest
  // blob. These are the plugin's own settings, edited from the middle-click
  // panel and persisted alongside the printer list.
  property var appSettings: Model.normalizeAppSettings(null)

  function setAppSettings(patch) {
    var merged = Model.normalizeAppSettings(appSettings)
    for (var key in patch) merged[key] = patch[key]
    appSettings = Model.normalizeAppSettings(merged)
    persistPrinters()
  }

  GcodeWatcher {
    id: gcodeWatcher
    service: root
  }

  readonly property var watcher: gcodeWatcher

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
  // Keyed by object name — see PrinterConnection.sensors.
  readonly property var sensors: activeConnection ? activeConnection.sensors : ({})
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

  // ---- power (Moonraker's optional [power] component) ----------------------
  readonly property bool hasPowerControl: activeConnection ? activeConnection.hasPowerControl : false
  readonly property string powerStatus: activeConnection ? activeConnection.powerStatus : ""
  readonly property bool powerLockedWhilePrinting:
    activeConnection ? activeConnection.powerLockedWhilePrinting : false
  // Moonraker rejects the change outright while printing when the device is
  // locked, so the button is disabled rather than left to fail.
  readonly property bool powerTogglable: Model.canTogglePower(
    activeConnection
      ? { status: powerStatus, lockedWhilePrinting: powerLockedWhilePrinting }
      : null,
    root.state)

  function setPower(on) {
    if (!activePrinter || !activeConnection || !activeConnection.hasPowerControl) return
    runAction(Model.powerActionUrl(activePrinter, activeConnection.powerDevice,
                                   on ? "on" : "off", preferredScheme(activePrinter)),
              on ? "Powering on…" : "Powering off…")
  }

  function requestPowerOff() {
    if (pendingConfirm === "poweroff") {
      pendingConfirm = ""
      confirmTimer.stop()
      setPower(false)
      return
    }
    pendingConfirm = "poweroff"
    actionStatus = "Press again to confirm power off"
    confirmTimer.restart()
  }

  readonly property bool jobInProgress: Model.jobInProgress(root.state)
  // Power-aware: a printer switched off at the wall reads "Printer off"
  // rather than "Klipper disconnected", which is true but useless.
  function stateLabel() { return Model.effectiveStateLabel(root.state, root.powerStatus) }
  function stateTone() { return Model.effectiveStateTone(root.state, root.powerStatus) }
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

  // Guards against re-sending the same notification for the same printer.
  // PrinterConnection already only calls this on an actual state transition,
  // so this is a backstop; it is keyed per printer because one global slot let
  // any printer's notification mask another's, and let a repeated event (stop,
  // restart, stop again) be swallowed because the silent recovery in between
  // never displaced the stored key.
  function sendNotification(printerId, notif) {
    var seen = {}
    try { seen = JSON.parse(persisted.notifiedFor || "{}") } catch (e) { seen = {} }
    if (!isPlainObject(seen)) seen = {}
    if (seen[printerId] === notif.headline) return
    seen[printerId] = notif.headline
    persisted.notifiedFor = JSON.stringify(seen)
    notifyQueue = notifyQueue.concat([{ printerId: printerId, notif: notif }])
    pumpNotifications()
  }

  // A printer owns at most one toast at a time: its next notification replaces
  // the previous one instead of stacking a second entry on the shade, so a
  // print that starts, finishes and then errors reads as one live line per
  // printer. The id to replace is only knowable from the notification daemon's
  // reply, so sends run as a real Process (-p prints the id) rather than
  // fire-and-forget, and queue behind each other because one Process carries
  // one send at a time.
  property var notificationIds: ({})
  property var notifyQueue: []

  function pumpNotifications() {
    if (notifyProcess.running || notifyQueue.length === 0) return
    var next = notifyQueue[0]
    notifyQueue = notifyQueue.slice(1)
    notifyProcess.printerId = next.printerId
    notifyProcess.command = Model.notificationArgs(next.notif, notificationIds[next.printerId] || 0)
    notifyProcess.running = true
  }

  Process {
    id: notifyProcess
    running: false
    command: []
    property string printerId: ""
    stdout: StdioCollector { id: notifyStdout; waitForEnd: true }
    onExited: function(exitCode) {
      // Whatever id came back is the one the *next* notification replaces; a
      // send that failed leaves nothing on screen to replace, so forget it and
      // let the next one open a fresh toast.
      var id = parseInt(String(notifyStdout.text || "").trim(), 10)
      if (exitCode === 0 && id > 0) root.notificationIds[notifyProcess.printerId] = id
      else delete root.notificationIds[notifyProcess.printerId]
      root.pumpNotifications()
    }
  }

  function isPlainObject(v) { return !!v && typeof v === "object" && !Array.isArray(v) }

  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-klipper"
    property string notifiedFor: ""
  }

  // ---------------------------------------------------------------- webcams

  function fetchWebcams() {
    if (!activePrinter || webcamsProcess.running) return
    webcamsProcess.run(["curl", "-fsS", "--max-time", "4",
                        Model.webcamsUrl(activePrinter, preferredScheme(activePrinter))], activePrinter)
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

  ApiCurl {
    id: webcamsProcess
    stdout: StdioCollector { id: webcamsStdout; waitForEnd: true }
    stderr: StdioCollector { id: webcamsStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(webcamsStdout.text || "")
      if (exitCode !== 0 || stdout === "") return // leave the cached list showing rather than collapsing it
      var parsed = Model.parseWebcamsResponse(stdout, root.activePrinter, preferredScheme(root.activePrinter))
      // Only reassign when the list actually changed. `webcams` is the model
      // the camera Repeater renders, so handing it a fresh array rebuilt every
      // delegate -- destroying and restarting each MediaPlayer -- once every
      // 60s poll, even though the answer was identical every time. That is
      // what kept resetting the stream.
      if (JSON.stringify(root.webcams) !== JSON.stringify(parsed)) root.webcams = parsed
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
      list[i] = Model.clonePrinterWith(list[i], { webcams: webcams })
      printers = list
      persistPrinters()
      return
    }
  }

  // Saves which sensor objects/fields a printer should display — either the
  // edit form's manual selection, or PrinterConnection's auto-seeded
  // heater defaults on a printer's first-ever successful connect.
  function setDisplaySensors(id, entries) {
    var list = printers.slice()
    for (var i = 0; i < list.length; i++) {
      if (list[i].id !== id) continue
      list[i] = Model.clonePrinterWith(list[i], { displaySensors: entries })
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
    actionProcess.run(["curl", "-fsS", "--max-time", "5", "-X", "POST", url], activePrinter)
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

  ApiCurl {
    id: actionProcess
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

  // ---------------------------------------------------------------- sensor discovery (edit form)

  // Ephemeral — only needed while the edit form's "sensors to display"
  // section is open, so this doesn't persist the way displaySensors itself
  // does. One request at a time is fine here (unlike PrinterConnection's
  // own auto-discover): a user can only have one edit form open at once.
  property bool editDiscoveryLoading: false
  property var editDiscoveryHeaters: []
  property var editDiscoverySensors: []

  function discoverSensorsFor(printer) {
    if (!printer || discoverProcess.running) return
    editDiscoveryLoading = true
    editDiscoveryHeaters = []
    editDiscoverySensors = []
    discoverProcess.run(["curl", "-fsS", "--max-time", "5",
                         Model.objectsListUrl(printer, preferredScheme(printer))], printer)
  }

  function clearEditDiscovery() {
    editDiscoveryLoading = false
    editDiscoveryHeaters = []
    editDiscoverySensors = []
    discoverProcess.running = false
  }

  ApiCurl {
    id: discoverProcess
    stdout: StdioCollector { id: discoverStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.editDiscoveryLoading = false
      var stdout = String(discoverStdout.text || "")
      var names = exitCode === 0 && stdout !== "" ? Model.parseObjectsList(stdout) : []
      var discovered = Model.discoverSensors(names)
      root.editDiscoveryHeaters = discovered.heaters
      root.editDiscoverySensors = discovered.sensors
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
        // fields carries the edit form's current state for everything it
        // actually edits — name/host/port/apiKey/displaySensors — but never
        // webcams (a read-only cache the form doesn't touch), so that has
        // to be explicitly carried over or every edit would blank it out
        // until the next 60s fetch.
        updated = Model.clonePrinterWith(Model.normalizePrinter(fields, id), { webcams: list[i].webcams || [] })
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
        list[i] = Model.clonePrinterWith(list[i], { scheme: scheme })
        break
      }
    }
    printers = list
    persistPrinters()
  }

  function persistPrinters() {
    // Whatever is at that path failed the ownership/type check, so it is not
    // ours to overwrite -- and writing would create a second copy of the API
    // keys next to a file we already refused to trust.
    if (stateError !== "") return
    _stateRevision++
    _pendingState = Model.serializePrinters({
      activePrinterId: activePrinterId,
      printers: printers,
      settings: appSettings
    })
    flushState()
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
    testProcess.run(["curl", "-fsS", "--max-time", "4",
                     Model.infoUrl(_testFields, _testCurrentScheme)], _testFields)
  }

  ApiCurl {
    id: testProcess
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
    appSettings = parsed.settings
    var current = Model.findPrinter(printers, activePrinterId)
    webcams = current ? (current.webcams || []) : []
    fetchWebcams()
  }

  // The state file carries each printer's Moonraker API key, so it is read and
  // written by two small scripts rather than by FileView: the read verifies the
  // file through the descriptor it then reads from, and the write creates the
  // replacement 0600 with the content on stdin, never in argv. See
  // Model.stateReadArgs / stateWriteArgs for what each one checks and why.
  // FileView stays on as the change watcher only -- it never reads or writes.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy-klipper"
  readonly property string statePath: stateDir + "/printers.json"
  // Non-empty when that path is not something we are willing to read. Nothing
  // is loaded and nothing is written while it is set: whatever is there is not
  // ours, so replacing it would destroy someone else's file and put a second
  // copy of the API keys somewhere we already refused to trust.
  property string stateError: ""

  // Newest content not yet written, and the content of the write in flight.
  // Saves arrive in bursts (add, select, persist a discovered scheme) and one
  // process carries one write, so the newest content waits its turn rather
  // than racing the one ahead of it.
  property string _pendingState: ""
  property string _writingState: ""

  // Bumped by every local change, and sampled when a read starts. A read is
  // asynchronous, so a printer added while one is in flight is newer than
  // whatever that read returns -- applying the file then would silently undo
  // the add. The revisions differing is exactly that case.
  property int _stateRevision: 0
  property int _readRevision: 0

  function reloadState() {
    if (stateReadProcess.running) return
    _readRevision = _stateRevision
    stateReadProcess.running = true
  }

  function flushState() {
    if (_pendingState === "" || stateWriteProcess.running) return
    _writingState = _pendingState
    _pendingState = ""
    stateWriteProcess.stdinEnabled = true
    stateWriteProcess.running = true
  }

  Process {
    id: stateReadProcess
    command: Model.stateReadArgs(root.stateDir, root.statePath)
    running: true
    stdout: StdioCollector { id: stateStdout; waitForEnd: true }
    onExited: function(exitCode) {
      // 3 is "no file yet", which is what a fresh install looks like.
      root.stateError = exitCode === 0 || exitCode === 3 ? ""
        : exitCode === 2
          ? "Refusing to read " + root.statePath + ": not a regular file owned by you"
          : "Could not secure " + root.stateDir + " (needs to be a directory you own, mode 700)"

      // Something changed while this read was running, so what came back is
      // already stale and is queued to be overwritten by it.
      if (root._stateRevision !== root._readRevision) return

      root.applyPrintersState(Model.parsePrinters(exitCode === 0 ? String(stateStdout.text || "") : ""))
    }
  }

  Process {
    id: stateWriteProcess
    command: Model.stateWriteArgs(root.statePath)
    running: false
    stdinEnabled: false
    onStarted: {
      write(root._writingState)
      // The script writes until EOF, so stdin has to be closed for the rename
      // to happen at all.
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root._writingState = ""
      if (exitCode === 2) root.stateError = "Refusing to write " + root.statePath + ": not a path we own"
      root.flushState()
    }
  }

  FileView {
    // Watcher only: never loaded, never written through. It exists so a state
    // file changed from outside (a hand edit) still reaches the panel, and the
    // re-read goes through the same verified path as the first one.
    id: printersFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: {
      // Our own write lands here too; re-reading what we just wrote is
      // harmless but pointless, and mid-write it would read the old content.
      if (stateWriteProcess.running || root._pendingState !== "") return
      root.reloadState()
    }
  }
}
