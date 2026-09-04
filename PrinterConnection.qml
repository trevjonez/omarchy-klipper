import QtQuick
import QtWebSockets
import Quickshell.Io
import "Model.js" as Model

// One persistent, subscribed websocket connection per *configured* printer
// (not just the active one) — this is what makes switching printers instant
// (no request in flight, the data's already live) and lets a background
// printer's print-finished/error notification fire the moment it happens,
// not up to a poll interval later. One instance per printerId, created and
// torn down only when a printer is actually added/removed (see Service.qml's
// printerIds/Instantiator) — never recreated by routine printers[] rewrites
// like scheme/webcam-cache pinning.
Item {
  id: root

  property string printerId: ""
  property var printers: []
  // Back-reference so this connection can report scheme/sensor discoveries
  // and hand off notifications through the same dedup path every other
  // notification already uses, without duplicating that logic here.
  property var service: null

  readonly property var printer: Model.findPrinter(printers, printerId)
  readonly property string printerName: printer ? Model.printerDisplayName(printer) : ""

  property bool reachable: false
  property string state: ""
  property string message: ""
  property int progress: 0
  property string filename: ""
  property real printDurationSec: 0
  // Keyed by object name (e.g. "extruder", "bme280 Ambient") — one entry
  // per subscribed object regardless of how many of its fields the printer
  // is actually configured to display.
  property var sensors: ({})

  // Moonraker's [power] component is optional. Empty name means this printer
  // has none, and every power affordance stays hidden.
  property string powerDevice: ""
  property string powerStatus: ""
  property bool powerLockedWhilePrinting: false
  readonly property bool hasPowerControl: powerDevice !== ""

  property var _rawStatus: ({})
  property string _prevState: ""
  property bool everConnected: false
  property string schemeGuess: (printer && printer.scheme) || "http"
  property bool _triedFallbackScheme: false

  // De-duplicated object names to subscribe to. Recomputes on every
  // printers[] rewrite (new printer object reference), but only actually
  // *changes* value when the selection itself changed, thanks to the
  // sorted-join comparison below.
  readonly property var sensorObjectNames: uniqueSensorObjects(printer ? printer.displaySensors : [])

  function uniqueSensorObjects(entries) {
    var seen = {}
    var names = []
    var list = entries || []
    for (var i = 0; i < list.length; i++) {
      var name = list[i].object
      if (seen[name]) continue
      seen[name] = true
      names.push(name)
    }
    return names
  }

  onSensorObjectNamesChanged: if (sock.status === WebSocket.Open) sock.sendTextMessage(Model.subscribeRequestJson(sensorObjectNames))

  // Only reconnects when the resolved URL actually changes — printer is
  // recomputed (new object reference) on every printers[] rewrite, but the
  // built string is byte-identical unless host/port/scheme/apiKey actually
  // changed, and QML suppresses a change signal for an unchanged string.
  readonly property string wsUrl: printer ? Model.websocketUrl(printer, schemeGuess) : ""

  onWsUrlChanged: if (wsUrl !== "") reconnectNow()

  function reconnectNow() {
    sock.active = false
    Qt.callLater(function() { if (root.wsUrl !== "") sock.active = true })
  }

  function resetLiveStatus(withState) {
    reachable = false
    state = withState
    message = ""
    progress = 0
    filename = ""
    printDurationSec = 0
    sensors = {}
  }

  function applyStatus(extracted) {
    if (!extracted || !extracted.ok) return
    var notif = Model.notificationForTransition(_prevState, extracted.state, printerName, extracted.filename, extracted.message)
    _prevState = extracted.state
    reachable = true
    state = extracted.state
    message = extracted.message
    progress = extracted.progress
    filename = extracted.filename
    printDurationSec = extracted.printDurationSec
    sensors = extracted.sensors
    if (notif && service) service.sendNotification(printerId, notif)
  }

  WebSocket {
    id: sock
    url: root.wsUrl
    active: false

    onStatusChanged: {
      if (status === WebSocket.Open) {
        sendTextMessage(Model.subscribeRequestJson(root.sensorObjectNames))
        // Independent of the subscribe: with the printer switched off at the
        // wall Klippy is down and subscribe fails, which is the exact moment
        // the power state matters most.
        root.discoverPower()
        return
      }
      if (status === WebSocket.Closed || status === WebSocket.Error) {
        // Printer never answered at all and no scheme is pinned yet — try
        // the other one before giving up as unreachable, same one-shot
        // fallback shape the old HTTP polling used.
        var printerHasPinnedScheme = root.printer && (root.printer.scheme === "http" || root.printer.scheme === "https")
        if (!root.everConnected && !printerHasPinnedScheme && !root._triedFallbackScheme) {
          root._triedFallbackScheme = true
          root.schemeGuess = root.schemeGuess === "http" ? "https" : "http"
          reconnectTimer.interval = 200
          reconnectTimer.restart()
          return
        }
        root.resetLiveStatus("offline")
        reconnectTimer.interval = 5000
        reconnectTimer.restart()
      }
    }

    onTextMessageReceived: function(message) {
      var subscribed = Model.parseSubscribeResponse(message)
      if (subscribed) {
        root._triedFallbackScheme = false
        if (root.service && root.printer && !(root.printer.scheme === "http" || root.printer.scheme === "https"))
          root.service.pinPrinterScheme(root.printerId, root.schemeGuess)
        var firstConnect = !root.everConnected
        root.everConnected = true
        root._rawStatus = subscribed
        root.applyStatus(Model.extractStatus(subscribed, root.sensorObjectNames))
        // A printer with no display selection yet (brand new, or upgraded
        // from before this feature existed) gets one seeded automatically —
        // the connection already exists either way, so there's no reason to
        // make the user open Edit just to see any temperature at all.
        if (firstConnect && root.printer && (!root.printer.displaySensors || root.printer.displaySensors.length === 0))
          root.triggerAutoDiscover()
        return
      }
      // Klippy's lifecycle, which Moonraker reports separately from status.
      // It discards every subscription when Klippy disconnects but keeps this
      // websocket open, so nothing further arrives until we ask again.
      // Power changes arrive on this same socket, including ones made from
      // Mainsail or a physical switch.
      var subscribeError = Model.parseSubscribeError(message)
      if (subscribeError !== null) {
        root.everConnected = true
        root.reachable = true
        root.state = "klippy_disconnected"
        root.message = subscribeError
        root.progress = 0
        root.filename = ""
        root.sensors = {}
        if (root.service && root.printer
            && !(root.printer.scheme === "http" || root.printer.scheme === "https"))
          root.service.pinPrinterScheme(root.printerId, root.schemeGuess)
        resubscribeTimer.restart()
        return
      }

      var power = Model.parsePowerChanged(message)
      if (power) {
        root.applyPowerDevice(power)
        return
      }

      var lifecycle = Model.parseKlippyLifecycle(message)
      if (lifecycle !== null) {
        root.onKlippyLifecycle(lifecycle)
        return
      }

      var delta = Model.parseNotifyStatusUpdate(message)
      if (delta) {
        root._rawStatus = Model.mergeStatusObjects(root._rawStatus, delta)
        root.applyStatus(Model.extractStatus(root._rawStatus, root.sensorObjectNames))
      }
    }
  }

  function applyPowerDevice(device) {
    powerDevice = device.device
    powerStatus = device.status
    powerLockedWhilePrinting = device.lockedWhilePrinting
  }

  // One-shot on connect. A printer with no [power] section answers 404, which
  // is the normal case rather than an error worth reporting.
  function discoverPower() {
    if (!printer || powerProcess.running) return
    powerProcess.command = ["curl", "-fsS", "--max-time", "5"]
      .concat(Model.apiKeyHeaderArgs(printer))
      .concat([Model.powerDevicesUrl(printer, schemeGuess)])
    powerProcess.running = true
  }

  Process {
    id: powerProcess
    running: false
    command: []
    stdout: StdioCollector { id: powerStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var devices = Model.parsePowerDevices(String(powerStdout.text || ""))
      if (devices.length > 0) root.applyPowerDevice(devices[0])
    }
  }

  function onKlippyLifecycle(event) {
    if (event === "ready") {
      // Subscriptions did not survive the restart; ask again or the panel
      // stays frozen on whatever it last saw.
      resubscribe()
      return
    }
    // Klippy is down. Reflect it immediately rather than waiting for a status
    // update that cannot arrive, and keep asking until it comes back.
    state = event === "shutdown" ? "klippy_shutdown" : "klippy_disconnected"
    message = event === "shutdown" ? "Klipper shut down" : "Klipper disconnected"
    progress = 0
    filename = ""
    resubscribeTimer.restart()
  }

  function resubscribe() {
    if (sock.status === WebSocket.Open) sock.sendTextMessage(Model.subscribeRequestJson(sensorObjectNames))
  }

  // Safety net for a missed notify_klippy_ready — if this connection was
  // opened while Klippy was already down, or the event was lost, the panel
  // would otherwise never recover on its own.
  Timer {
    id: resubscribeTimer
    interval: 10000
    repeat: true
    running: root.reachable && root.state.indexOf("klippy_") === 0
    onTriggered: root.resubscribe()
  }

  Timer {
    id: reconnectTimer
    repeat: false
    onTriggered: root.reconnectNow()
  }

  // One-shot: fetches this printer's full object list to seed a sensible
  // default display selection (its controllable heaters) the first time it
  // ever connects with none configured. Owned per-connection rather than
  // routed through Service so N printers connecting for the first time at
  // once (e.g. on shell startup) don't contend for one shared process.
  function triggerAutoDiscover() {
    if (!printer || autoDiscoverProcess.running) return
    autoDiscoverProcess.command = ["curl", "-fsS", "--max-time", "5"]
      .concat(Model.apiKeyHeaderArgs(printer))
      .concat([Model.objectsListUrl(printer, schemeGuess)])
    autoDiscoverProcess.running = true
  }

  Process {
    id: autoDiscoverProcess
    running: false
    command: []
    stdout: StdioCollector { id: autoDiscoverStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(autoDiscoverStdout.text || "")
      var names = exitCode === 0 && stdout !== "" ? Model.parseObjectsList(stdout) : []
      var heaters = Model.discoverSensors(names).heaters
      // Empty means either discovery failed (offline mid-connect, odd) or
      // this printer genuinely has no heaters Moonraker will admit to —
      // either way, leaving displaySensors at [] tries again on the next
      // fresh connect rather than persisting a false "nothing to show."
      if (heaters.length > 0 && root.service)
        root.service.setDisplaySensors(root.printerId, heaters.map(function(name) { return { object: name } }))
    }
  }

  Component.onCompleted: if (wsUrl !== "") reconnectNow()
  Component.onDestruction: sock.active = false
}
