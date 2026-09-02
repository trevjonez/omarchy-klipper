import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// Regression: after an emergency stop and a firmware restart, the panel stayed
// stuck reading "Klipper shut down" forever.
//
// Moonraker discards every client subscription when Klippy disconnects
// (klippy_connection.py: `self.subscriptions = {}`) but leaves the websocket
// open, so nothing reconnects and no further status ever arrives. Recovery is
// announced only as notify_klippy_ready, which has to be acted on by
// re-subscribing.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))

  Plugin.Harness { id: h; budgetMs: 45000 }

  property QtObject service: QtObject {
    function pinPrinterScheme(id, scheme) {}
    function setDisplaySensors(id, entries) {}
    function sendNotification(id, notif) {}
  }

  Process { id: poke; running: false; command: [] }
  function pokeMock(query) {
    poke.command = ["curl", "-fsS", "-o", "/dev/null",
      "http://127.0.0.1:" + root.mockPort + "/__mock/state?" + query]
    poke.running = true
  }

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
    h.waitFor("connected and printing", function() {
      return conn.reachable && conn.state === "printing"
    }, function() {

      // Emergency stop: Klippy goes down and the subscription dies with it.
      root.pokeMock("klippy=shutdown")

      h.waitFor("shutdown is reflected", function() {
        return conn.state === "klippy_shutdown"
      }, function() {
        h.check("still connected to Moonraker itself", conn.reachable,
                "the websocket should stay open; only Klippy went down")

        // Firmware restart. Moonraker announces notify_klippy_ready and
        // nothing else -- no status arrives until we re-subscribe.
        root.pokeMock("klippy=ready&state=standby")

        h.waitFor("recovers once Klipper is back", function() {
          return conn.state === "standby"
        }, function() {
          h.check("status is live again, not frozen on the shutdown",
                  conn.state.indexOf("klippy_") !== 0, conn.state)

          // And the stream really is flowing again, not a one-off reply.
          root.pokeMock("state=printing&progress=0.5")
          h.waitFor("further updates still arrive", function() {
            return conn.state === "printing" && conn.progress === 50
          }, function() {
            h.check("sensor readings restored after re-subscribe",
                    conn.sensors["extruder"] !== undefined,
                    JSON.stringify(conn.sensors))
            h.done()
          }, 15000)
        }, 20000)
      }, 15000)
    })
  }
}
