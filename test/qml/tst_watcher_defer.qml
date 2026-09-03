import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// "Defer scans while printing": a scan parses the whole file on the printer's
// own CPU, so a busy printer holds its queue until the job ends. Also covers
// the 404 classification -- a printer that simply doesn't have the file is a
// skip, not a failure.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))
  readonly property string watchDir: Quickshell.env("WATCH_DIR")

  Plugin.Harness { id: h; budgetMs: 45000 }

  // Mutable so the test can end the "print" and watch the queue drain.
  QtObject { id: busyConn; property bool reachable: true; property string state: "printing" }

  QtObject {
    id: fakeService
    property var appSettings: ({
      gcodeWatchDir: root.watchDir, gcodeWatchEnabled: true,
      deferScanWhilePrinting: true, lastSeenEpoch: 1
    })
    property var printers: [{ id: "a", name: "A", host: "127.0.0.1", port: root.mockPort, scheme: "http", apiKey: "" }]
    function connectionFor(id) { return busyConn }
    function setAppSettings(patch) {
      var merged = {}
      for (var k in appSettings) merged[k] = appSettings[k]
      for (var j in patch) merged[j] = patch[j]
      appSettings = merged
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
    h.waitFor("watcher running", function() { return watcher.status.indexOf("Watching") === 0 }, function() {
      sh.command = ["bash", "-c", "printf ';g\\n' > '" + root.watchDir + "/held.gcode'"]
      sh.running = true

      // The file is recorded straight away, showing the busy printer as
      // queued. Staying silent until the scan finished was the old behaviour,
      // and it made a deliberately held queue indistinguishable from a stuck
      // one -- which is the whole reason this is reported per printer now.
      h.waitFor("held work is visible immediately", function() {
        return root.stateOf(root.rowFor("held.gcode"), "A") === "queued"
      }, function() {
        h.check("status says the scan is held",
                watcher.status.indexOf("held until a printer is free") !== -1,
                watcher.status)
        h.checkEq("row is flagged as still pending",
                  root.rowFor("held.gcode").worst, "pending")

        // Job ends: the queue drains without another filesystem event.
        busyConn.state = "ready"

        h.waitFor("held scan runs once the printer is idle", function() {
          return root.stateOf(root.rowFor("held.gcode"), "A") !== "queued"
        }, function() {
          // The mock answers 404 for this scenario: the printer's gcodes root
          // does not contain the file, which is a skip rather than a failure.
          h.checkEq("404 reported as missing, not failed",
                    root.stateOf(root.rowFor("held.gcode"), "A"), "missing")
          h.check("row is not flagged as a failure",
                  root.rowFor("held.gcode").worst !== "failed",
                  root.rowFor("held.gcode").worst)
          h.done()
        }, 30000)
      }, 20000)
    })
  }
}
