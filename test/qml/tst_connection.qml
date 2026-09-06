import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// The core of the realtime path: a PrinterConnection opens a websocket,
// subscribes, applies the snapshot, and then merges the partial
// notify_status_update deltas Moonraker pushes afterwards. The delta
// assertion is the important one -- a snapshot-only implementation would pass
// everything else here.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))

  // Stand-in for Service. PrinterConnection only ever calls these three.
  property QtObject service: QtObject {
    property int schemePins: 0
    function pinPrinterScheme(id, scheme) { schemePins++ }
    function setDisplaySensors(id, entries) {}
    function sendNotification(id, notif) {}
  }

  Plugin.Harness { id: h }

  Plugin.PrinterConnection {
    id: conn
    printerId: "p1"
    service: root.service
    printers: [{
      // No scheme stored, so the connection has to settle one and report it
      // back -- the state a freshly-added printer is actually in.
      id: "p1", name: "Mock", host: "127.0.0.1", port: root.mockPort,
      scheme: "", apiKey: "", webcams: [],
      displaySensors: [
        { object: "extruder" },
        { object: "heater_bed" },
        { object: "bme280 Chamber", field: "humidity" }
      ]
    }]
  }

  Component.onCompleted: {
    h.waitFor("connects and subscribes", function() { return conn.reachable }, function() {
      h.checkEq("state from print_stats", conn.state, "printing")
      h.checkEq("filename from print_stats", conn.filename, "demo.gcode")
      h.checkEq("progress scaled to percent", conn.progress, 42)
      h.checkEq("print duration", conn.printDurationSec, 120)

      // Sensors are keyed by Klipper object name, including the space-bearing
      // "<type> <name>" form, and carry every field the object reported --
      // not just the one field the printer is configured to display.
      var ext = conn.sensors["extruder"]
      h.checkEq("extruder temperature", ext ? ext.temperature : null, 210.4)
      h.checkEq("extruder target", ext ? ext.target : null, 215)

      var bed = conn.sensors["heater_bed"]
      h.checkEq("heater_bed temperature", bed ? bed.temperature : null, 59.8)

      var cham = conn.sensors["bme280 Chamber"]
      h.check("multi-field sensor object present", cham !== undefined && cham !== null)
      h.checkEq("bme280 humidity", cham ? cham.humidity : null, 18.5)
      h.checkEq("bme280 carries temperature too", cham ? cham.temperature : null, 34.2)

      // An object the printer reports but this printer isn't configured to
      // display should not be subscribed to at all.
      h.check("unselected object not subscribed",
              conn.sensors["temperature_sensor Ambient"] === undefined,
              "got " + JSON.stringify(conn.sensors["temperature_sensor Ambient"]))

      // Now the delta path: change state server-side and confirm the partial
      // update merges onto the snapshot instead of replacing it.
      pokeMock.command = ["curl", "-fsS", "-o", "/dev/null",
        "http://127.0.0.1:" + root.mockPort + "/__mock/state?state=complete&progress=1"]
      pokeMock.running = true

      h.waitFor("delta updates state", function() { return conn.state === "complete" }, function() {
        h.checkEq("delta updated progress", conn.progress, 100)
        // Merged, not replaced: nothing in the delta mentioned the extruder.
        var still = conn.sensors["extruder"]
        h.checkEq("snapshot sensors survive a delta", still ? still.temperature : null, 210.4)
        h.check("unpinned printer gets its scheme recorded", root.service.schemePins >= 1,
                "pinPrinterScheme calls: " + root.service.schemePins)

        // Host CPU/RAM rides the same socket, pushed without a subscription.
        h.waitFor("host stats arrive unasked", function() { return conn.hasHostStats }, function() {
          h.checkEq("cpu is the host, not moonraker's own process", conn.hostCpuPercent, 42)
          h.checkEq("memory used", conn.hostMemUsedKb, 1100000)
          h.checkEq("memory total", conn.hostMemTotalKb, 3999000)
          h.done()
        })
      })
    })
  }

  // Drives the mock's state-change endpoint so the test can assert on a
  // pushed delta rather than only the initial subscribe reply.
  Process { id: pokeMock; running: false; command: [] }
}
