import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// The full Service against a real state file: FileView, atomic writes, the
// printer CRUD and the app settings blob. HOME is redirected to the stage
// directory by the runner, so this touches no real config.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))

  Plugin.Harness { id: h; budgetMs: 40000 }
  Plugin.Service { id: svc }

  function idsOf(list) {
    var out = []
    for (var i = 0; i < list.length; i++) out.push(list[i].name)
    return out.join(",")
  }

  Component.onCompleted: {
    // The state file doesn't exist yet; Service creates the directory and
    // starts from an empty list rather than failing.
    h.waitFor("starts empty with no state file", function() {
      return svc.printers.length === 0 && svc.activePrinterId === ""
    }, function() {

      svc.addPrinter({ name: "First", host: "127.0.0.1", port: root.mockPort })
      h.checkEq("printer added", svc.printers.length, 1)
      h.checkEq("first printer becomes active", svc.activePrinterId, svc.printers[0].id)

      svc.addPrinter({ name: "Second", host: "127.0.0.1", port: root.mockPort })
      h.checkEq("second printer added", svc.printers.length, 2)
      h.checkEq("active printer unchanged by an add", svc.activePrinterId, svc.printers[0].id)

      var firstId = svc.printers[0].id
      var secondId = svc.printers[1].id

      svc.setActivePrinter(secondId)
      h.checkEq("active printer switches", svc.activePrinterId, secondId)

      // An edit must not silently drop fields the form doesn't know about --
      // this is exactly what clonePrinterWith exists to prevent.
      svc.updatePrinter(firstId, { name: "Renamed", host: "127.0.0.1", port: root.mockPort })
      h.checkEq("rename applied", svc.printers[0].name, "Renamed")
      h.checkEq("id preserved across an edit", svc.printers[0].id, firstId)

      svc.setAppSettings({ gcodeWatchDir: "/tmp/watch-me", deferScanWhilePrinting: false })
      h.checkEq("setting stored", svc.appSettings.gcodeWatchDir, "/tmp/watch-me")
      h.checkEq("setting merge keeps other keys", svc.appSettings.deferScanWhilePrinting, false)
      h.check("watcher auto-enables once a folder is set", svc.appSettings.gcodeWatchEnabled)

      // Everything above should now be on disk. Read the file back from the
      // filesystem rather than from a FileView: FileView can't watch a path
      // that doesn't exist yet, and this file is created during the test.
      h.waitFor("state file written", function() {
        readFile()
        return root.fileText.indexOf("Renamed") !== -1
      }, function() {
        var parsed = JSON.parse(root.fileText)
        h.checkEq("both printers persisted", parsed.printers.length, 2)
        h.checkEq("active printer persisted", parsed.activePrinterId, secondId)
        h.checkEq("settings persisted", parsed.settings.gcodeWatchDir, "/tmp/watch-me")
        h.checkEq("settings merge persisted", parsed.settings.deferScanWhilePrinting, false)

        svc.removePrinter(secondId)
        h.checkEq("printer removed", svc.printers.length, 1)
        h.checkEq("removing the active printer reselects", svc.activePrinterId, firstId)

        // Two events from one printer must leave one toast, not two: the id
        // handed back by the first send is what the second one replaces.
        // tst_service_state.expect.js asserts the -r on the real command line.
        svc.sendNotification(firstId, { urgency: "normal", headline: "ToastA", body: "one" })
        h.waitFor("notification id comes back from the send", function() {
          return svc.notificationIds[firstId] > 0
        }, function() {
          var firstToast = svc.notificationIds[firstId]
          svc.sendNotification(firstId, { urgency: "normal", headline: "ToastB", body: "two" })
          h.waitFor("the replacement send completes", function() {
            return svc.notificationIds[firstId] > 0 && svc.notificationIds[firstId] !== firstToast
          }, function() { h.done() })
        })
      })
    })
  }

  // Reads the same file Service writes, to prove persistence rather than
  // just in-memory state.
  property string fileText: ""
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy-klipper/printers.json"

  function readFile() {
    if (catProcess.running) return
    catProcess.command = ["cat", root.statePath]
    catProcess.running = true
  }

  Process {
    id: catProcess
    running: false
    command: []
    stdout: StdioCollector { id: catOut; waitForEnd: true }
    onExited: function(code) { root.fileText = code === 0 ? String(catOut.text || "") : "" }
  }
}
