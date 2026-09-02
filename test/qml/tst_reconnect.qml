import QtQuick
import Quickshell
import "." as Plugin

// Moonraker restarts, the Pi reboots, the network blips. The connection must
// notice, report the printer offline rather than showing stale readings, and
// come back on its own without anyone reopening the panel.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))

  Plugin.Harness { id: h; budgetMs: 40000 }

  property QtObject service: QtObject {
    function pinPrinterScheme(id, scheme) {}
    function setDisplaySensors(id, entries) {}
    function sendNotification(id, notif) {}
  }

  Plugin.PrinterConnection {
    id: conn
    printerId: "p1"
    service: root.service
    printers: [{
      id: "p1", name: "Mock", host: "127.0.0.1", port: root.mockPort,
      scheme: "http", apiKey: "", webcams: [], displaySensors: [{ object: "extruder" }]
    }]
  }

  Component.onCompleted: {
    h.waitFor("initial connect", function() { return conn.reachable }, function() {
      h.check("has a reading before the drop", conn.sensors["extruder"] !== undefined)

      // The mock is configured to hang up shortly after each subscribe.
      h.waitFor("drop is noticed", function() { return !conn.reachable }, function() {
        h.checkEq("reports offline rather than a stale state", conn.state, "offline")
        h.checkEq("stale progress cleared", conn.progress, 0)
        h.checkEq("stale filename cleared", conn.filename, "")
        h.check("stale sensor readings cleared",
                JSON.stringify(conn.sensors) === "{}", JSON.stringify(conn.sensors))

        // Reconnect is on a 5s timer, and the mock keeps dropping, so this
        // may catch either side of the cycle -- what matters is that it comes
        // back at all rather than staying dead after one failure.
        h.waitFor("reconnects on its own", function() { return conn.reachable }, function() {
          h.done()
        }, 25000)
      }, 15000)
    })
  }
}
