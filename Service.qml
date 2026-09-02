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
  // Enabled cameras for the active printer, from /server/webcams/list.
  // Refreshed far less often than status — cameras essentially never change.
  property var webcams: []

  // ---- action feedback ------------------------------------------------------
  property string actionStatus: ""
  // "" | "cancel" | "estop" — a destructive action armed by one press, run by
  // a second press within confirmTimer's window.
  property string pendingConfirm: ""

  // ---- scheme detection -------------------------------------------------
  // Used only while the active printer has no scheme pinned (neither typed
  // into the host field nor learned yet). Reset whenever the active printer
  // changes; the first successful poll pins the winning scheme onto the
  // printer record so later polls never have to probe again.
  property string schemeGuess: "http"
  property bool _triedFallbackScheme: false

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

  // The scheme actually used for the next request: the printer's own pinned
  // scheme when it has one, else whichever one is currently being probed.
  function activeScheme() {
    return (activePrinter && (activePrinter.scheme === "http" || activePrinter.scheme === "https"))
      ? activePrinter.scheme : schemeGuess
  }

  function refresh() {
    if (!activePrinter) {
      resetStatus("")
      return
    }
    if (statusProcess.running) return
    refreshing = true
    var printer = activePrinter
    var scheme = activeScheme()
    statusProcess.command = ["curl", "-fsS", "--max-time", "4"]
      .concat(Model.apiKeyHeaderArgs(printer))
      .concat([Model.queryUrl(printer, scheme)])
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

  // ---------------------------------------------------------------- webcams

  function fetchWebcams() {
    if (!activePrinter || webcamsProcess.running) return
    webcamsProcess.command = ["curl", "-fsS", "--max-time", "4"]
      .concat(Model.apiKeyHeaderArgs(activePrinter))
      .concat([Model.webcamsUrl(activePrinter, activeScheme())])
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
      var parsed = Model.parseWebcamsResponse(stdout, root.activePrinter, root.activeScheme())
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
      var printerHasPinnedScheme = root.activePrinter && (root.activePrinter.scheme === "http" || root.activePrinter.scheme === "https")

      if (exitCode !== 0 || stdout === "") {
        // No scheme pinned yet and we haven't tried the other one this
        // round — flip and retry once before giving up as unreachable.
        if (!printerHasPinnedScheme && !root._triedFallbackScheme) {
          root._triedFallbackScheme = true
          root.schemeGuess = root.schemeGuess === "http" ? "https" : "http"
          root.refresh()
          return
        }
        root._triedFallbackScheme = false
        root.applyOffline("Unreachable")
        return
      }

      root._triedFallbackScheme = false
      var parsed = Model.parseStatusResponse(stdout)
      if (!parsed.ok) {
        root.applyOffline(parsed.error || "Bad response from Moonraker")
        return
      }
      // Learned a working scheme for a printer that didn't have one pinned —
      // persist it so every later poll goes straight there instead of
      // probing twice each time.
      if (!printerHasPinnedScheme) root.pinPrinterScheme(root.activePrinterId, root.schemeGuess)
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
    var scheme = activeScheme()
    if (state === "printing") runAction(Model.actionUrl(activePrinter, "/printer/print/pause", scheme), "Pausing…")
    else if (state === "paused") runAction(Model.actionUrl(activePrinter, "/printer/print/resume", scheme), "Resuming…")
  }

  function requestCancel() {
    if (!activePrinter) return
    if (pendingConfirm === "cancel") {
      pendingConfirm = ""
      confirmTimer.stop()
      runAction(Model.actionUrl(activePrinter, "/printer/print/cancel", activeScheme()), "Cancelling…")
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
      runAction(Model.actionUrl(activePrinter, "/printer/emergency_stop", activeScheme()), "Emergency stop sent")
      return
    }
    pendingConfirm = "estop"
    actionStatus = "Press again to confirm EMERGENCY STOP"
    confirmTimer.restart()
  }

  function restartFirmware() {
    if (!activePrinter) return
    runAction(Model.actionUrl(activePrinter, "/printer/firmware_restart", activeScheme()), "Restarting Klipper…")
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
    if (id === activePrinterId) {
      webcams = updated.webcams
      refresh()
    }
  }

  function removePrinter(id) {
    var list = printers.filter(function(p) { return p.id !== id })
    printers = list
    if (activePrinterId === id) {
      activePrinterId = list.length > 0 ? list[0].id : ""
      resetStatus("")
      webcams = activePrinterId ? (Model.findPrinter(list, activePrinterId).webcams || []) : []
      statusProcess.running = false
      webcamsProcess.running = false
    }
    persistPrinters()
    if (activePrinterId) {
      refresh()
      fetchWebcams()
    }
  }

  function setActivePrinter(id) {
    if (id === activePrinterId || !Model.findPrinter(printers, id)) return
    activePrinterId = id
    statusProcess.running = false
    webcamsProcess.running = false
    resetStatus("")
    // Seed from this printer's own cached camera list (persisted by
    // pinWebcams) rather than clearing to [] — reserves the right amount of
    // popup space immediately instead of the layout jumping once the fresh
    // (slow, 60s) fetch below completes.
    webcams = Model.findPrinter(printers, id).webcams || []
    schemeGuess = "http"
    _triedFallbackScheme = false
    persistPrinters()
    refresh()
    // webcamsTimer's `running` binding stays true across a printer switch
    // (activePrinter never goes null), so triggeredOnStart never re-fires —
    // fetch explicitly instead of waiting up to 60s for the next slow tick.
    fetchWebcams()
  }

  // Records the scheme that just answered so future polls skip probing.
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
