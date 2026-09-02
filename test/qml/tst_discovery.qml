import QtQuick
import Quickshell
import "." as Plugin

// A printer added before the sensor-picker existed, or one just added now,
// has no display selection. Rather than showing no temperatures at all until
// someone opens Edit, the first successful connect seeds the selection from
// whatever the printer says is controllable.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))

  Plugin.Harness { id: h; budgetMs: 30000 }

  property var seeded: null

  property QtObject service: QtObject {
    function pinPrinterScheme(id, scheme) {}
    function sendNotification(id, notif) {}
    function setDisplaySensors(id, entries) { root.seeded = entries }
  }

  Plugin.PrinterConnection {
    id: conn
    printerId: "p1"
    service: root.service
    printers: [{
      id: "p1", name: "Fresh", host: "127.0.0.1", port: root.mockPort,
      scheme: "http", apiKey: "", webcams: [],
      displaySensors: []   // never customized
    }]
  }

  function names() {
    var out = []
    for (var i = 0; i < (root.seeded || []).length; i++) out.push(root.seeded[i].object)
    out.sort()
    return out
  }

  Component.onCompleted: {
    h.waitFor("connects", function() { return conn.reachable }, function() {
      h.waitFor("empty selection triggers discovery",
                function() { return root.seeded !== null }, function() {
        var got = root.names()

        // Heaters only: things with a controllable target. The mock also
        // reports a bme280 and a temperature_sensor, which are read-only and
        // must be left for the user to opt into.
        h.checkEq("seeds exactly the heaters", JSON.stringify(got),
                  JSON.stringify(["extruder", "heater_bed", "heater_generic drybox"]))
        h.check("read-only sensor not auto-selected", got.indexOf("bme280 Chamber") === -1)
        h.check("temperature_sensor not auto-selected", got.indexOf("temperature_sensor Ambient") === -1)

        // Whole-object entries: a heater's temperature and target are shown
        // together, so no per-field key is written.
        var anyField = false
        for (var i = 0; i < root.seeded.length; i++) if (root.seeded[i].field !== undefined) anyField = true
        h.check("heaters seeded as whole-object entries", !anyField, JSON.stringify(root.seeded))
        h.done()
      })
    })
  }
}
