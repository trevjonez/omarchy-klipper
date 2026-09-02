import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// A finished print must reach the user even when its printer isn't the one on
// screen. Exercises the transition detection in PrinterConnection and, via
// tst_notification.expect.js, the actual command line Service would run.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))

  Plugin.Harness { id: h; budgetMs: 30000 }

  property var seen: []

  property QtObject service: QtObject {
    function pinPrinterScheme(id, scheme) {}
    function setDisplaySensors(id, entries) {}
    // Mirrors Service.sendNotification's real behavior closely enough to
    // assert on: hand the notification to omarchy-notification-send, which
    // the test stages as a stub earlier on PATH.
    function sendNotification(printerId, notif) {
      var list = root.seen.slice()
      list.push(notif)
      root.seen = list
      notifyProcess.command = ["omarchy-notification-send", "-u", notif.urgency, notif.headline, notif.body]
      notifyProcess.running = true
    }
  }

  Process { id: notifyProcess; running: false; command: [] }
  Process { id: poke; running: false; command: [] }

  Plugin.PrinterConnection {
    id: conn
    printerId: "p1"
    service: root.service
    printers: [{
      id: "p1", name: "Voron", host: "127.0.0.1", port: root.mockPort,
      scheme: "http", apiKey: "", webcams: [], displaySensors: [{ object: "extruder" }]
    }]
  }

  Component.onCompleted: {
    h.waitFor("connected while printing", function() {
      return conn.reachable && conn.state === "printing"
    }, function() {
      h.check("no notification merely for being mid-print", root.seen.length === 0,
              JSON.stringify(root.seen))

      poke.command = ["curl", "-fsS", "-o", "/dev/null",
        "http://127.0.0.1:" + root.mockPort + "/__mock/state?state=complete&progress=1"]
      poke.running = true

      h.waitFor("completion produces a notification", function() { return root.seen.length > 0 }, function() {
        var n = root.seen[0]
        h.check("headline names the printer", String(n.headline).indexOf("Voron") !== -1, n.headline)
        h.check("body names the file", String(n.body).indexOf("demo.gcode") !== -1, n.body)
        // Give the stub's write a moment to land before the runner reads it.
        h.waitFor("notification command ran", function() { return !notifyProcess.running }, function() {
          h.done()
        })
      })
    })
  }
}
