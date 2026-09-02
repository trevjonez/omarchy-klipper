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

  Component.onCompleted: {
    h.waitFor("watcher running", function() { return watcher.status.indexOf("Watching") === 0 }, function() {
      sh.command = ["bash", "-c", "printf ';g\\n' > '" + root.watchDir + "/held.gcode'"]
      sh.running = true

      h.waitFor("queue reports waiting for a free printer",
                function() { return watcher.status.indexOf("waiting for a free printer") !== -1 }, function() {

        h.check("nothing recorded while deferred", watcher.activity.length === 0,
                "activity: " + JSON.stringify(watcher.activity))

        // Job ends: the queue should drain without another filesystem event.
        busyConn.state = "ready"

        h.waitFor("queue drains once the printer is idle",
                  function() { return watcher.activity.length > 0 }, function() {
          var a = watcher.activity[0]
          h.checkEq("deferred file eventually scanned", a.file, "held.gcode")
          // Mock is configured to answer 404 for this scenario.
          h.checkEq("404 reported as a skip, not a failure", a.text, "1 didn't have the file")
          h.checkEq("skip is toned warn, not error", a.tone, "warn")
          h.done()
        }, 30000)
      }, 20000)
    })
  }
}
