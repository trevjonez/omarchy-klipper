import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// Regression: the watcher went permanently deaf and never said so.
//
// The watch directory was an autofs CIFS share. When it idled out and
// remounted, the inotify watches inotifywait held belonged to the old mount.
// The process kept running and reported nothing ever again, while the panel
// still said "Watching" -- so a G-code file dropped hours later was silently
// never scanned.
//
// inotify cannot be relied on alone here (it also cannot see a write made from
// another machine on the same share), so a periodic sweep has to find whatever
// the event stream missed. This kills the watcher's inotifywait outright to
// simulate the deafness, then checks the sweep still picks the file up.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))
  readonly property string watchDir: Quickshell.env("WATCH_DIR")

  Plugin.Harness { id: h; budgetMs: 60000 }

  QtObject { id: conn; property bool reachable: true; property string state: "standby" }

  QtObject {
    id: fakeService
    property var appSettings: ({
      gcodeWatchDir: root.watchDir, gcodeWatchEnabled: true,
      deferScanWhilePrinting: false, lastSeenEpoch: 1
    })
    property var printers: [{ id: "a", name: "A", host: "127.0.0.1", port: root.mockPort, scheme: "http", apiKey: "" }]
    function connectionFor(id) { return conn }
    function setAppSettings(patch) {
      var merged = {}
      for (var k in appSettings) merged[k] = appSettings[k]
      for (var j in patch) merged[j] = patch[j]
      appSettings = merged
    }
  }

  Plugin.GcodeWatcher { id: watcher; service: fakeService }

  Process { id: sh; running: false; command: [] }
  function run(script) { sh.command = ["bash", "-c", script]; sh.running = true }

  function activityFor(name) {
    for (var i = 0; i < watcher.activity.length; i++)
      if (watcher.activity[i].file === name) return watcher.activity[i]
    return null
  }

  Component.onCompleted: {
    h.waitFor("watcher starts", function() { return watcher.status.indexOf("Watching") === 0 }, function() {

      // Go deaf exactly the way a remount does: the process is gone, but
      // nothing tells the watcher that.
      root.run("pkill -f 'inotifywait.*" + root.watchDir + "' || true")

      h.waitFor("inotify is gone", function() { return !sh.running }, function() {
        // A file lands while nothing is listening.
        root.run("printf ';g\\n' > '" + root.watchDir + "/deaf.gcode'")

        h.waitFor("file exists", function() { return !sh.running }, function() {
          h.check("no event was delivered", root.activityFor("deaf.gcode") === null,
                  "activity: " + JSON.stringify(watcher.activity))

          // The periodic sweep is what has to save this. Drive it directly
          // rather than waiting out the two-minute timer.
          watcher.reconcile()

          h.waitFor("sweep finds what the event stream missed",
                    function() { return root.activityFor("deaf.gcode") !== null }, function() {
            var a = root.activityFor("deaf.gcode")
            h.checkEq("scanned on the reachable printer", a.text, "scanned on 1 printer")
            h.check("sweep timestamp recorded", watcher._lastSweepEpoch > 0)
            h.check("status reports when it last checked",
                    watcher.status.indexOf("last checked") !== -1, watcher.status)
            h.check("not flagged as failed", !watcher.failed, watcher.status)
            h.done()
          }, 30000)
        })
      })
    })
  }
}
