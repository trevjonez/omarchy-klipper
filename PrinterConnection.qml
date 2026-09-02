import QtQuick
import QtWebSockets
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
  // Back-reference so this connection can report scheme discoveries and
  // hand off notifications through the same dedup path every other
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
  property var hotend: ({ actual: null, target: null })
  property var bed: ({ actual: null, target: null })

  property var _rawStatus: ({})
  property string _prevState: ""
  property bool everConnected: false
  property string schemeGuess: (printer && printer.scheme) || "http"
  property bool _triedFallbackScheme: false

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
    hotend = { actual: null, target: null }
    bed = { actual: null, target: null }
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
    hotend = extracted.hotend
    bed = extracted.bed
    if (notif && service) service.sendNotification(printerId, notif)
  }

  WebSocket {
    id: sock
    url: root.wsUrl
    active: false

    onStatusChanged: {
      if (status === WebSocket.Open) {
        sendTextMessage(Model.subscribeRequestJson())
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
        root.everConnected = true
        root._rawStatus = subscribed
        root.applyStatus(Model.extractStatus(subscribed))
        return
      }
      var delta = Model.parseNotifyStatusUpdate(message)
      if (delta) {
        root._rawStatus = Model.mergeStatusObjects(root._rawStatus, delta)
        root.applyStatus(Model.extractStatus(root._rawStatus))
      }
    }
  }

  Timer {
    id: reconnectTimer
    repeat: false
    onTriggered: root.reconnectNow()
  }

  Component.onCompleted: if (wsUrl !== "") reconnectNow()
  Component.onDestruction: sock.active = false
}
