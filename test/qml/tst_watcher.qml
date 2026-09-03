import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// The G-code watcher against a real directory: real inotifywait, real curl,
// real metascan requests to the mock. Asserts the filtering rules here and
// the resulting server traffic in tst_watcher.expect.js.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))
  readonly property string watchDir: Quickshell.env("WATCH_DIR")

  Plugin.Harness { id: h; budgetMs: 45000 }

  // Minimal stand-in for Service: two printers on the same mock, so a single
  // dropped file should produce one metascan per printer.
  QtObject {
    id: fakeService
    property var appSettings: ({
      gcodeWatchDir: root.watchDir,
      gcodeWatchEnabled: true,
      deferScanWhilePrinting: false,
      // Non-zero: a first-ever enable deliberately skips the catch-up sweep,
      // and this test is about live events, not catch-up.
      lastSeenEpoch: 1
    })
    property var printers: [
      { id: "a", name: "A", host: "127.0.0.1", port: root.mockPort, scheme: "http", apiKey: "" },
      { id: "b", name: "B", host: "127.0.0.1", port: root.mockPort, scheme: "http", apiKey: "" }
    ]
    function connectionFor(id) { return reachableConn }
    function setAppSettings(patch) {
      var merged = {}
      for (var k in appSettings) merged[k] = appSettings[k]
      for (var j in patch) merged[j] = patch[j]
      appSettings = merged
    }
  }

  QtObject { id: reachableConn; property bool reachable: true; property string state: "ready" }

  Plugin.GcodeWatcher { id: watcher; service: fakeService }


  // Per-printer state for one file in the activity list.
  function stateOf(row, printerName) {
    if (!row) return "none"
    for (var i = 0; i < row.printers.length; i++)
      if (row.printers[i].name === printerName) return row.printers[i].state
    return "none"
  }

  function allState(row) {
    if (!row || row.printers.length === 0) return "none"
    var seen = row.printers[0].state
    for (var i = 1; i < row.printers.length; i++)
      if (row.printers[i].state !== seen) return "mixed"
    return seen
  }

  function activityFor(name) {
    for (var i = 0; i < watcher.activity.length; i++)
      if (watcher.activity[i].file === name) return watcher.activity[i]
    return null
  }

  Process { id: sh; running: false; command: [] }
  function run(script, onDone) {
    sh.command = ["bash", "-c", script]
    sh.exited.connect(function once(code) { sh.exited.disconnect(once); if (onDone) onDone(code) })
    sh.running = true
  }

  Component.onCompleted: {
    h.waitFor("watcher reports it is watching",
              function() { return watcher.status.indexOf("Watching") === 0 }, function() {

      // A real gcode file at the watch root, a nested one, one in a directory
      // created *after* the watcher started, plus two that must be ignored:
      // a non-gcode extension and a file under a hidden directory.
      root.run(
        "cd '" + root.watchDir + "' && " +
        "printf ';g\\n' > root.gcode && " +
        "mkdir -p nested && printf ';g\\n' > nested/deep.gcode && " +
        "mkdir -p fresh_dir && sleep 0.6 && printf ';g\\n' > fresh_dir/new.gcode && " +
        "printf 'x\\n' > notes.txt && " +
        "mkdir -p .hidden && printf ';g\\n' > .hidden/skip.gcode", function() {

        h.waitFor("root file scanned", function() { return root.activityFor("root.gcode") !== null }, function() {
          h.waitFor("nested file scanned", function() { return root.activityFor("nested/deep.gcode") !== null }, function() {
            h.waitFor("file in a new subdirectory scanned",
                      function() { return root.activityFor("fresh_dir/new.gcode") !== null }, function() {

              var a = root.activityFor("root.gcode")
              h.checkEq("both printers listed", a ? a.printers.length : 0, 2)
              h.checkEq("both report scanned", root.allState(a), "ok")
              h.checkEq("row is not flagged pending or failed", a ? a.worst : "", "ok")

              h.check("non-gcode file ignored", root.activityFor("notes.txt") === null)
              h.check("hidden-directory file ignored", root.activityFor(".hidden/skip.gcode") === null)

              // Watcher marks progress so a later start doesn't re-sweep.
              h.check("lastSeenEpoch advanced", fakeService.appSettings.lastSeenEpoch > 1,
                      "epoch " + fakeService.appSettings.lastSeenEpoch)
              h.done()
            })
          })
        })
      })
    })
  }
}
