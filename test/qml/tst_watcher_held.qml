import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// Regression: a printer that stayed busy poisoned the whole watcher.
//
// The "seen" mark was only committed once the scan queue fully drained, but
// "defer scans while printing" guarantees it will not drain while a printer is
// printing. So the mark never advanced, every periodic sweep re-found the same
// files, and enqueue() reset the per-file counter while the previous batch's
// jobs were still queued -- which drove that counter to zero early and
// reported "scanned on N printers" for scans that had not run, while the queue
// grew without bound.
//
// Two printers: one permanently printing, one idle.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))
  readonly property string watchDir: Quickshell.env("WATCH_DIR")

  Plugin.Harness { id: h; budgetMs: 60000 }

  QtObject { id: busy; property bool reachable: true; property string state: "printing" }
  QtObject { id: idle; property bool reachable: true; property string state: "standby" }

  property int seenMark: 1
  // Counting commits, not comparing timestamps: the startup catch-up commits
  // once on its own, and second-resolution stamps can repeat within a batch,
  // so "the number is bigger" proves nothing.
  property int markCommits: 0
  property int commitsBeforeDrop: 0

  QtObject {
    id: fakeService
    property var appSettings: ({
      gcodeWatchDir: root.watchDir, gcodeWatchEnabled: true,
      deferScanWhilePrinting: true, lastSeenEpoch: 1
    })
    property var printers: [
      { id: "busy", name: "Busy", host: "127.0.0.1", port: root.mockPort, scheme: "http", apiKey: "" },
      { id: "idle", name: "Idle", host: "127.0.0.1", port: root.mockPort, scheme: "http", apiKey: "" }
    ]
    function connectionFor(id) { return id === "busy" ? busy : idle }
    function setAppSettings(patch) {
      var merged = {}
      for (var k in appSettings) merged[k] = appSettings[k]
      for (var j in patch) merged[j] = patch[j]
      appSettings = merged
      if (patch.lastSeenEpoch !== undefined) {
        root.seenMark = patch.lastSeenEpoch
        root.markCommits++
      }
    }
  }

  Plugin.GcodeWatcher { id: watcher; service: fakeService }

  Process { id: sh; running: false; command: [] }

  function rowFor(name) {
    for (var i = 0; i < watcher.activity.length; i++)
      if (watcher.activity[i].file === name) return watcher.activity[i]
    return null
  }

  function stateOf(row, printerName) {
    if (!row) return "none"
    for (var i = 0; i < row.printers.length; i++)
      if (row.printers[i].name === printerName) return row.printers[i].state
    return "none"
  }

  Component.onCompleted: {
    h.waitFor("watcher starts", function() { return watcher.status.indexOf("Watching") === 0 }, function() {
      root.commitsBeforeDrop = root.markCommits
      sh.command = ["bash", "-c", "printf ';g\\n' > '" + root.watchDir + "/held.gcode'"]
      sh.running = true

      h.waitFor("idle printer scans it", function() {
        return root.stateOf(root.rowFor("held.gcode"), "Idle") === "ok"
      }, function() {
        h.checkEq("busy printer is held, not scanned",
                  root.stateOf(root.rowFor("held.gcode"), "Busy"), "queued")

        // The mark must be committed even though a job is still queued. This
        // is the fix: gating the commit on a drained queue pinned it at its
        // old value for as long as any printer kept printing, so every restart
        // re-discovered everything written since.
        h.check("seen mark committed despite the held job",
                root.markCommits > root.commitsBeforeDrop,
                "commits before drop " + root.commitsBeforeDrop
                  + ", now " + root.markCommits)

        // Sweeping again must not duplicate the file or re-queue its printers.
        var before = watcher.activity.length
        watcher.reconcile()
        h.waitFor("a second sweep completes", function() { return !watcher.failed }, function() {
          h.checkEq("no duplicate row for the same file", watcher.activity.length, before)
          h.checkEq("idle printer not re-queued",
                    root.stateOf(root.rowFor("held.gcode"), "Idle"), "ok")
          h.checkEq("busy printer still shows exactly one held job",
                    root.stateOf(root.rowFor("held.gcode"), "Busy"), "queued")

          // Job finishes: the held work must then run, without another event.
          busy.state = "standby"
          h.waitFor("held job runs once the printer frees up", function() {
            return root.stateOf(root.rowFor("held.gcode"), "Busy") === "ok"
          }, function() { h.done() }, 30000)
        }, 20000)
      }, 25000)
    })
  }
}
