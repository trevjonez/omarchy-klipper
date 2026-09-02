import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// Regression: the real startup order is "watcher constructed, settings arrive
// later" -- Service reads printers.json through a FileView, so appSettings is
// empty for the first moments of every session.
//
// With `running` and `command` as separate bindings, QML was free to
// re-evaluate `running` before `command`, launching inotifywait with the
// previous (empty) directory: "No files specified to watch!". This starts with
// no configuration at all and only then supplies a folder.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))
  readonly property string watchDir: Quickshell.env("WATCH_DIR")

  Plugin.Harness { id: h; budgetMs: 40000 }

  QtObject {
    id: fakeService
    // Exactly what Service exposes before its state file has loaded.
    property var appSettings: ({
      gcodeWatchDir: "", gcodeWatchEnabled: true,
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

  QtObject { id: conn; property bool reachable: true; property string state: "ready" }

  Plugin.GcodeWatcher { id: watcher; service: fakeService }

  Process { id: sh; running: false; command: [] }

  Component.onCompleted: {
    // Polled rather than read inline: this root's Component.onCompleted can
    // run before the watcher's own, so its startup status isn't settled yet.
    h.waitFor("idle status names the missing folder",
              function() { return watcher.status === "No folder set" }, function() {
      h.check("not flagged as failed before configuration", !watcher.failed, watcher.status)

      // Settings arrive, as they would when printers.json finishes loading.
      fakeService.setAppSettings({ gcodeWatchDir: root.watchDir })
      root.afterConfigured()
    }, 5000)
  }

  function afterConfigured() {
    h.waitFor("starts watching once a folder arrives",
              function() { return watcher.status.indexOf("Watching") === 0 }, function() {

      h.check("no inotifywait argument error", !watcher.failed, watcher.status)
      h.check("status names the configured folder",
              watcher.status.indexOf(root.watchDir) !== -1, watcher.status)

      // Prove it is really watching that directory, not merely claiming to.
      sh.command = ["bash", "-c", "printf ';g\\n' > '" + root.watchDir + "/late.gcode'"]
      sh.running = true

      h.waitFor("file dropped after late configuration is scanned",
                function() { return watcher.activity.length > 0 }, function() {
        h.checkEq("scanned the right file", watcher.activity[0].file, "late.gcode")
        h.done()
      }, 20000)
    }, 15000)
  }
}
