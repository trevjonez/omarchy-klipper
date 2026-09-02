import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Watches a directory for newly-landed G-code and asks every reachable printer
// to re-read that file's metadata.
//
// Why this exists: the fleet's G-code arrives by writing to a network share
// that each printer mounts as its own gcodes root. Moonraker watches that root
// with inotify, but a write made from a *different* client of the same share
// produces no inotify event on the printer — so the file shows up in the file
// list (which walks the filesystem) with no metadata behind it: no thumbnail,
// no estimated time, no filament usage. Moonraker's own
// /server/files/metascan is exactly the "parse this file now" call that the
// missing event would have triggered, so this watches the share from the
// machine that *does* see the write and makes that call on the printers' behalf.
Item {
  id: root

  property var service: null

  readonly property var settings: service ? service.appSettings : Model.normalizeAppSettings(null)
  readonly property string watchDir: settings.gcodeWatchDir
  // Wanting to watch and having somewhere to watch are stored separately (see
  // Model.normalizeAppSettings); watching needs both.
  readonly property bool enabled: settings.gcodeWatchEnabled && watchDir !== ""
  readonly property bool deferWhilePrinting: settings.deferScanWhilePrinting

  // Human-readable state for the settings panel. Anything that goes wrong here
  // is invisible by nature (a watcher that isn't running looks exactly like a
  // watcher with nothing to do), so every failure path writes a status.
  property string status: "Not watching"
  property bool failed: false
  // Newest first, capped — one row per file, summarizing all printers.
  property var activity: []

  // Files seen but not yet turned into scan jobs. A slicer that writes then
  // renames emits both close_write and moved_to for one file, so events are
  // coalesced over a short window rather than queued as they arrive.
  property var _pending: ({})
  // Flat list of {relPath, printerId} still to run, drained one at a time.
  property var _queue: []
  // relPath -> {pending, ok, notFound, failed, lastError}, so an activity row
  // is only emitted once every printer has answered for that file.
  property var _fileState: ({})
  property var _current: null
  property bool _backoff: false

  // A first-ever enable has no "last seen" mark, and `find -newermt @0` would
  // match the entire share — 740 files x 4 printers is hours of parsing. So
  // the first enable starts watching from now, and only subsequent starts
  // sweep for what landed while the shell was down.
  readonly property int _maxCatchUp: 50

  onEnabledChanged: {
    if (enabled) startWatching()
    else stopWatching()
    syncWatchProcess()
  }
  onWatchDirChanged: {
    if (enabled) startWatching()
    syncWatchProcess()
  }
  on_BackoffChanged: syncWatchProcess()
  Component.onCompleted: {
    // stopWatching() rather than leaving the property default, so the idle
    // status distinguishes "no folder configured" from "configured but off".
    if (enabled) startWatching()
    else stopWatching()
    syncWatchProcess()
  }

  function startWatching() {
    _backoff = false
    failed = false
    status = "Starting…"
    if (settings.lastSeenEpoch > 0) runCatchUp()
    else markSeenNow()
  }

  function stopWatching() {
    _backoff = false
    failed = false
    _pending = ({})
    status = watchDir === "" ? "No folder set" : "Not watching"
  }

  function markSeenNow() {
    if (service) service.setAppSettings({ lastSeenEpoch: Math.floor(Date.now() / 1000) })
  }

  // ---------------------------------------------------------------- discovery

  function noteFile(absPath) {
    var rel = Model.relativeGcodePath(watchDir, absPath)
    if (!rel) return
    var pending = _pending
    pending[rel] = true
    _pending = pending
    coalesceTimer.restart()
  }

  function flushPending() {
    var files = Object.keys(_pending)
    _pending = ({})
    if (files.length === 0) return
    enqueue(files)
  }

  function enqueue(relPaths) {
    if (!service) return
    var targets = []
    for (var i = 0; i < service.printers.length; i++) {
      var conn = service.connectionFor(service.printers[i].id)
      if (conn && conn.reachable) targets.push(service.printers[i].id)
    }
    if (targets.length === 0) {
      // Nothing to scan against right now. Moonraker parses whatever metadata
      // it's missing when its own file_manager starts up, so a fleet that's
      // entirely offline heals itself on next boot — recording the skip is
      // more honest than silently dropping the file.
      for (var f = 0; f < relPaths.length; f++) pushActivity(relPaths[f], "No printers reachable", "warn")
      return
    }
    var queue = _queue.slice()
    var stateMap = _fileState
    for (var p = 0; p < relPaths.length; p++) {
      stateMap[relPaths[p]] = { pending: targets.length, ok: 0, notFound: 0, failed: 0, lastError: "" }
      for (var t = 0; t < targets.length; t++) queue.push({ relPath: relPaths[p], printerId: targets[t] })
    }
    _fileState = stateMap
    _queue = queue
    drain()
  }

  // ---------------------------------------------------------------- scanning

  function runnableIndex() {
    for (var i = 0; i < _queue.length; i++) {
      var conn = service ? service.connectionFor(_queue[i].printerId) : null
      if (!conn || !conn.reachable) continue
      if (deferWhilePrinting && conn.state === "printing") continue
      return i
    }
    return -1
  }

  function drain() {
    if (_current !== null || _queue.length === 0) return
    var idx = runnableIndex()
    if (idx === -1) {
      // Everything left is blocked on a printer that's printing or offline.
      // Hold it and re-check — the queue is small and entirely in memory.
      status = _queue.length + " scan" + (_queue.length === 1 ? "" : "s") + " waiting for a free printer"
      retryTimer.restart()
      return
    }
    var queue = _queue.slice()
    var job = queue.splice(idx, 1)[0]
    _queue = queue
    _current = job
    var printer = Model.findPrinter(service.printers, job.printerId)
    if (!printer) {
      finishJob({ ok: false, notFound: false, error: "printer removed" })
      return
    }
    status = "Scanning " + job.relPath + " on " + Model.printerDisplayName(printer) + "…"
    // A large file on a Pi takes seconds to parse and Moonraker answers only
    // once it's done, so the timeout is generous and jobs run strictly one at
    // a time — metascan holds Moonraker's file-manager lock while it works.
    scanProcess.command = ["curl", "-sS", "-X", "POST", "--max-time", "120", "-w", "\n%{http_code}"]
      .concat(Model.apiKeyHeaderArgs(printer))
      .concat([Model.metascanUrl(printer, job.relPath)])
    scanProcess.running = true
  }

  function finishJob(result) {
    var job = _current
    _current = null
    if (job) {
      var stateMap = _fileState
      var entry = stateMap[job.relPath]
      if (entry) {
        entry.pending--
        if (result.ok) entry.ok++
        else if (result.notFound) entry.notFound++
        else { entry.failed++; entry.lastError = result.error }
        if (entry.pending <= 0) {
          delete stateMap[job.relPath]
          pushActivity(job.relPath, summarize(entry), entry.failed > 0 ? "error" : (entry.ok > 0 ? "ok" : "warn"))
        }
      }
      _fileState = stateMap
    }
    if (_queue.length === 0 && _current === null) {
      markSeenNow()
      status = "Watching " + watchDir
    }
    drain()
  }

  function summarize(entry) {
    var parts = []
    if (entry.ok > 0) parts.push("scanned on " + entry.ok + " printer" + (entry.ok === 1 ? "" : "s"))
    if (entry.notFound > 0) parts.push(entry.notFound + " didn't have the file")
    if (entry.failed > 0) parts.push(entry.failed + " failed: " + entry.lastError)
    return parts.join(", ")
  }

  function pushActivity(relPath, text, tone) {
    var list = activity.slice()
    list.unshift({ file: relPath, text: text, tone: tone, at: Qt.formatDateTime(new Date(), "hh:mm") })
    activity = list.slice(0, 8)
  }

  Process {
    id: scanProcess
    running: false
    command: []
    stdout: StdioCollector { id: scanStdout; waitForEnd: true }
    onExited: function(exitCode) {
      // -w appends the status code as a final line after the response body.
      var out = String(scanStdout.text || "")
      var cut = out.lastIndexOf("\n")
      var httpCode = cut === -1 ? out : out.slice(cut + 1)
      var body = cut === -1 ? "" : out.slice(0, cut)
      root.finishJob(Model.parseMetascanResult(exitCode, httpCode, body))
    }
  }

  Timer {
    id: coalesceTimer
    interval: 1500
    repeat: false
    onTriggered: root.flushPending()
  }

  Timer {
    id: retryTimer
    interval: 15000
    repeat: false
    onTriggered: root.drain()
  }

  // ---------------------------------------------------------------- watching

  // Started imperatively rather than by binding `running` and `command`
  // separately: those are independent bindings, and when the settings arrive
  // asynchronously (FileView loading printers.json at startup) QML is free to
  // re-evaluate `running` before `command`. That started inotifywait with the
  // previous, empty directory — "No files specified to watch!".
  function syncWatchProcess() {
    watchProcess.running = false
    if (!enabled || _backoff) return
    Qt.callLater(function() {
      if (!root.enabled || root._backoff || root.watchDir === "") return
      watchProcess.command = Model.inotifyArgs(root.watchDir)
      watchProcess.running = true
    })
  }

  Process {
    id: watchProcess
    running: false
    command: []
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.noteFile(line) }
    }
    stderr: StdioCollector { id: watchStderr; waitForEnd: true }
    onStarted: {
      root.failed = false
      if (root._queue.length === 0) root.status = "Watching " + root.watchDir
    }
    onExited: {
      // inotifywait only exits on its own if it couldn't watch — an unmounted
      // autofs path or a typo. Back off and retry rather than letting the
      // `running` binding restart it in a tight loop.
      if (!root.enabled) return
      root.failed = true
      root.status = String(watchStderr.text || "").split("\n")[0] || ("Cannot watch " + root.watchDir)
      root._backoff = true
      watchRetryTimer.restart()
    }
  }

  Timer {
    id: watchRetryTimer
    interval: 30000
    repeat: false
    onTriggered: root._backoff = false
  }

  // ---------------------------------------------------------------- catch-up

  function runCatchUp() {
    if (catchUpProcess.running) return
    catchUpProcess.command = Model.catchUpArgs(watchDir, settings.lastSeenEpoch)
    catchUpProcess.running = true
  }

  Process {
    id: catchUpProcess
    running: false
    command: []
    stdout: StdioCollector { id: catchUpStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.markSeenNow(); return }
      var lines = String(catchUpStdout.text || "").split("\n")
      var files = []
      for (var i = 0; i < lines.length; i++) {
        var rel = Model.relativeGcodePath(root.watchDir, lines[i])
        if (rel) files.push(rel)
      }
      if (files.length === 0) { root.markSeenNow(); return }
      // Cap rather than let a clock jump or a bulk copy enqueue hundreds of
      // multi-second parses; say so instead of silently truncating.
      if (files.length > root._maxCatchUp) {
        root.pushActivity("", (files.length - root._maxCatchUp) + " older files skipped (catch-up capped at " + root._maxCatchUp + ")", "warn")
        files = files.slice(0, root._maxCatchUp)
      }
      root.enqueue(files)
    }
  }
}
