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
  // One record per file, newest first and capped, each tracking every printer
  // separately: relPath -> { at, printers: { printerId: state } } where state
  // is queued | scanning | ok | missing | failed. A single rolled-up count was
  // both less useful and actively wrong -- a re-enqueued file reset it, so
  // completions from the previous batch drove it to zero early and reported a
  // finished scan that had not happened.
  property var _files: ({})
  property var _order: []
  readonly property int _maxRows: 8

  // Rendered form for the settings panel, rebuilt whenever the underlying
  // records or the printer list change.
  readonly property var activity: buildActivity(_files, _order,
                                                service ? service.printers : [])

  function buildActivity(files, order, printers) {
    var rows = []
    for (var i = 0; i < order.length; i++) {
      var rel = order[i]
      var rec = files[rel]
      if (!rec) continue
      var entries = []
      var worst = "ok"
      for (var p = 0; p < printers.length; p++) {
        var st = rec.printers[printers[p].id]
        if (st === undefined) continue
        entries.push({ name: Model.printerDisplayName(printers[p]), state: st })
        if (st === "failed") worst = "failed"
        else if (worst !== "failed" && (st === "queued" || st === "scanning")) worst = "pending"
      }
      rows.push({ file: rel, at: rec.at, note: rec.note || "", printers: entries, worst: worst })
    }
    return rows
  }

  function _setFileState(relPath, printerId, state) {
    var files = _files
    if (!files[relPath]) return
    files[relPath].printers[printerId] = state
    _files = files
    _filesChanged()
  }

  // Files seen but not yet turned into scan jobs. A slicer that writes then
  // renames emits both close_write and moved_to for one file, so events are
  // coalesced over a short window rather than queued as they arrive.
  property var _pending: ({})
  // Flat list of {relPath, printerId} still to run, drained one at a time.
  property var _queue: []
  property var _current: null
  property bool _backoff: false

  // A first-ever enable has no "last seen" mark, and `find -newermt @0` would
  // match the entire share — 740 files x 4 printers is hours of parsing. So
  // the first enable starts watching from now, and only subsequent starts
  // sweep for what landed while the shell was down.
  readonly property int _maxCatchUp: 50

  // Device id of the watched directory when the current inotifywait started.
  // On an autofs/network share the mount is dropped when idle and recreated on
  // next access; the watches inotifywait holds belong to the *old* mount and
  // are silently dead afterwards. The process keeps running and reports
  // nothing, so this is checked periodically and the watcher restarted.
  property string _watchDevice: ""
  property int _lastSweepEpoch: 0

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
  // Without this an inotifywait outlives the shell that started it and is
  // reparented to systemd, leaving duplicate watchers on every reload.
  Component.onDestruction: watchProcess.running = false

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
    else { beginObserving(); commitSeenMark() }
  }

  function statusIdle() {
    if (watchDir === "") return "No folder set"
    if (_lastSweepEpoch === 0) return "Watching " + watchDir
    return "Watching " + watchDir + " · last checked "
      + Qt.formatDateTime(new Date(_lastSweepEpoch * 1000), "hh:mm")
  }

  function stopWatching() {
    _backoff = false
    failed = false
    _pending = ({})
    status = watchDir === "" ? "No folder set" : "Not watching"
  }

  // Timestamp captured when the current batch started being observed. Marking
  // "seen" with the time the batch *finished* would skip anything written
  // while the scans were running, because the next sweep looks for files newer
  // than the mark.
  property int _observedAt: 0

  function beginObserving() {
    if (_observedAt === 0) _observedAt = Math.floor(Date.now() / 1000)
  }

  function commitSeenMark() {
    var mark = _observedAt !== 0 ? _observedAt : Math.floor(Date.now() / 1000)
    _observedAt = 0
    if (service) service.setAppSettings({ lastSeenEpoch: mark })
  }

  // ---------------------------------------------------------------- reconcile

  // inotify is the fast path, not the only one. It cannot see a write made
  // from another machine on the same share, and its watches die silently when
  // an autofs mount is recycled underneath it. A periodic sweep for files
  // newer than the last mark closes both gaps, and re-arms the watcher if the
  // mount changed.
  function reconcile() {
    if (!enabled || deviceProcess.running || catchUpProcess.running) return
    deviceProcess.command = ["stat", "-c", "%d", watchDir]
    deviceProcess.running = true
  }

  Process {
    id: deviceProcess
    running: false
    command: []
    stdout: StdioCollector { id: deviceStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // Directory has gone away entirely (share unmounted and not
        // remounting, or deleted). Say so rather than claiming to watch it.
        root.failed = true
        root.status = "Cannot reach " + root.watchDir
        return
      }
      var device = String(deviceStdout.text || "").trim()
      if (root._watchDevice !== "" && device !== root._watchDevice) {
        // The share was remounted: whatever inotifywait is holding is stale.
        root._watchDevice = device
        root.restartWatchProcess()
      } else if (root._watchDevice === "") {
        root._watchDevice = device
      }
      root.failed = false
      root.runCatchUp()
    }
  }

  Timer {
    id: reconcileTimer
    interval: 120000
    repeat: true
    running: root.enabled
    onTriggered: root.reconcile()
  }

  // ---------------------------------------------------------------- discovery

  function noteFile(absPath) {
    var rel = Model.relativeGcodePath(watchDir, absPath)
    if (!rel) return
    beginObserving()
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

    var files = _files
    var order = _order
    var queue = _queue.slice()
    var added = 0

    for (var p = 0; p < relPaths.length; p++) {
      var rel = relPaths[p]

      // Already tracked with work outstanding: leave it alone. Re-adding it
      // would queue a second set of jobs for the same file, which is how the
      // queue used to grow without bound while a printer was busy.
      if (_hasOutstandingWork(files[rel])) continue

      var rec = { at: Qt.formatDateTime(new Date(), "hh:mm"), printers: {}, note: "" }
      if (targets.length === 0) {
        // Moonraker parses whatever metadata it is missing when its own file
        // manager starts, so a fleet that is entirely offline heals itself on
        // next boot. Recording the skip is more honest than dropping the file.
        rec.note = "No printers reachable"
      }
      for (var t = 0; t < targets.length; t++) {
        rec.printers[targets[t]] = "queued"
        queue.push({ relPath: rel, printerId: targets[t] })
      }

      files[rel] = rec
      order = [rel].concat(order.filter(function(x) { return x !== rel })).slice(0, _maxRows)
      added++
    }

    _files = files
    _order = order
    _queue = queue

    // Observation is complete the moment a batch is recorded, so the mark
    // advances here rather than when the scans finish. Gating it on a drained
    // queue meant a single deferred printer held the mark back forever, and
    // every sweep re-discovered the same files.
    if (added > 0) commitSeenMark()

    drain()
  }

  function _hasOutstandingWork(rec) {
    if (!rec) return false
    for (var id in rec.printers) {
      if (rec.printers[id] === "queued" || rec.printers[id] === "scanning") return true
    }
    return false
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
      // Everything left is blocked on a printer that is printing or offline.
      // Hold it and re-check; the queue is small and entirely in memory. The
      // per-file rows below say which machine each one is waiting on, so this
      // line only has to say that something is waiting.
      status = _queue.length + " scan" + (_queue.length === 1 ? "" : "s")
        + " held until a printer is free"
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
    _setFileState(job.relPath, job.printerId, "scanning")
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
      var state = result.ok ? "ok" : (result.notFound ? "missing" : "failed")
      _setFileState(job.relPath, job.printerId, state)
      if (state === "failed" && _files[job.relPath]) {
        var files = _files
        files[job.relPath].note = result.error
        _files = files
        _filesChanged()
      }
    }
    if (_queue.length === 0 && _current === null) status = statusIdle()
    drain()
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
  function restartWatchProcess() {
    watchProcess.running = false
    Qt.callLater(function() { root.syncWatchProcess() })
  }

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
      if (root._queue.length === 0) root.status = root.statusIdle()
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
    beginObserving()
    catchUpProcess.command = Model.catchUpArgs(watchDir, settings.lastSeenEpoch)
    catchUpProcess.running = true
  }

  Process {
    id: catchUpProcess
    running: false
    command: []
    stdout: StdioCollector { id: catchUpStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.commitSeenMark(); return }
      root._lastSweepEpoch = Math.floor(Date.now() / 1000)
      var lines = String(catchUpStdout.text || "").split("\n")
      var files = []
      for (var i = 0; i < lines.length; i++) {
        var rel = Model.relativeGcodePath(root.watchDir, lines[i])
        if (rel) files.push(rel)
      }
      if (files.length === 0) { root.commitSeenMark(); root.status = root.statusIdle(); return }
      // Cap rather than let a clock jump or a bulk copy enqueue hundreds of
      // multi-second parses; say so instead of silently truncating.
      if (files.length > root._maxCatchUp) {
        root.status = (files.length - root._maxCatchUp) + " older files skipped"
          + " (catch-up is capped at " + root._maxCatchUp + ")"
        files = files.slice(0, root._maxCatchUp)
      }
      root.enqueue(files)
    }
  }
}
