import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "Model.js" as Model

// The fullscreen camera view: does it pick the right feed, letterbox it to fit
// whatever the screen is, show exactly the overlays the printer selected, and
// close without breaking the binding that reopens it.
ShellRoot {
  id: root

  // Generous: these tests stage and load the whole shell module tree, and
  // run alongside the rest of the suite, so they are the ones most likely to
  // be starved on a busy machine. A budget overrun here is a false failure.
  Harness { id: h; budgetMs: 60000 }

  property int closeRequests: 0
  property string activeId: "p1"

  // Two printers so the view has to resolve the one it was given rather than
  // just taking the first.
  property var fakePrinters: [
    { id: "p0", name: "Other", host: "127.0.0.1", port: 1, scheme: "http", apiKey: "",
      webcams: [{ name: "Wrong", streamUrl: "", snapshotUrl: "", flipHorizontal: false,
                  flipVertical: false, rotation: 0, aspectRatio: 0.75 }],
      displaySensors: [], videoOverlays: [] },
    { id: "p1", name: "Voron", host: "127.0.0.1", port: 1, scheme: "http", apiKey: "",
      webcams: [
        { name: "Cam A", streamUrl: "", snapshotUrl: "", flipHorizontal: false,
          flipVertical: false, rotation: 0, aspectRatio: 0.75 },
        { name: "Cam B", streamUrl: "", snapshotUrl: "", flipHorizontal: false,
          flipVertical: false, rotation: 0, aspectRatio: 0.5625 }
      ],
      displaySensors: [{ object: "extruder" }],
      videoOverlays: ["name", "progress"] }
  ]

  QtObject {
    id: fakeConn
    property bool reachable: true
    property string state: "printing"
    property string filename: "job.gcode"
    property int progress: 42
    property real printDurationSec: 600
    property var sensors: ({ "extruder": { temperature: 210, target: 215 } })
  }

  QtObject {
    id: fakeService
    property var printers: root.fakePrinters
    function connectionFor(id) { return fakeConn }
  }

  // Created explicitly rather than with a Loader: FullscreenVideo is a
  // PanelWindow, and Loader only instantiates Items.
  property var viewObj: null

  function view() { return viewObj }

  // Finds a visible Text anywhere under the view whose content matches.
  function hasVisibleText(item, needle) {
    if (!item) return false
    if (item.text !== undefined && item.visible && String(item.text).indexOf(needle) !== -1) return true
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) if (hasVisibleText(kids[i], needle)) return true
    return false
  }

  Component.onCompleted: {
    var c = Qt.createComponent(Qt.resolvedUrl("FullscreenVideo.qml"))
    if (c.status === Component.Error) {
      h.check("fullscreen view loads", false, c.errorString())
      h.done()
      return
    }
    root.viewObj = c.createObject(root, {
      service: fakeService, printerId: "p1", webcamIndex: 0, open: true
    })
    if (root.viewObj) root.viewObj.closeRequested.connect(function() { root.closeRequests++ })

    h.waitFor("fullscreen view loads", function() {
      return root.view() !== null && root.view().width > 0
    }, function() { root.checkFeed() })
  }

  function checkFeed() {
    var v = view()
    h.check("resolves the printer it was given, not the first one",
            v.printer !== null && v.printer.id === "p1",
            JSON.stringify(v.printer ? v.printer.id : null))
    h.checkEq("selects the requested camera", v.webcam ? v.webcam.name : "", "Cam A")

    // Letterboxing: the feed must fit inside the screen on both axes at any
    // aspect ratio, rather than overflowing and cropping the picture.
    h.waitFor("feed is laid out", function() { return root.feedItem() !== null && root.feedItem().width > 0 },
      function() {
        var f = root.feedItem()
        h.check("4:3 feed fits the screen width", f.width <= v.width + 1,
                f.width + " vs " + v.width)
        h.check("4:3 feed fits the screen height", f.height <= v.height + 1,
                f.height + " vs " + v.height)

        // A 16:9 feed on the same screen must also fit -- different ratio,
        // same invariant.
        v.webcamIndex = 1
        h.waitFor("switches to the second camera",
                  function() { return v.webcam && v.webcam.name === "Cam B" }, function() {
          var g = root.feedItem()
          h.check("16:9 feed fits the screen width", g.width <= v.width + 1,
                  g.width + " vs " + v.width)
          h.check("16:9 feed fits the screen height", g.height <= v.height + 1,
                  g.height + " vs " + v.height)
          root.checkOverlays()
        })
      })
  }

  // A PanelWindow keeps its visual tree under contentItem, not children.
  function feedItem() {
    var v = view()
    if (!v || !v.contentItem) return null
    var kids = v.contentItem.children
    for (var i = 0; i < kids.length; i++) {
      if (kids[i].aspectRatio !== undefined) return kids[i]
    }
    return null
  }

  function checkOverlays() {
    var v = view()
    // This printer selected name + progress only.
    h.check("shows the selected printer name", hasVisibleText(v.contentItem, "Voron"))
    h.check("shows the selected progress", hasVisibleText(v.contentItem, "42%"))
    h.check("hides the unselected filename", !hasVisibleText(v.contentItem, "job.gcode"))
    h.check("hides the unselected elapsed time", !hasVisibleText(v.contentItem, "Elapsed"))
    h.check("hides the unselected ETA", !hasVisibleText(v.contentItem, "ETA"))

    // Turning one on makes it appear without touching anything else.
    var printers = root.fakePrinters.slice()
    printers[1] = Model.clonePrinterWith(printers[1], { videoOverlays: ["name", "progress", "elapsed"] })
    root.fakePrinters = printers
    fakeService.printers = printers

    h.waitFor("selecting elapsed time reveals it",
              function() { return root.hasVisibleText(v.contentItem, "Elapsed") }, function() {
      h.check("previously selected overlays still shown", root.hasVisibleText(v.contentItem, "Voron"))
      root.checkIdle()
    })
  }

  // An idle printer has no progress to report: showing a 0% bar next to
  // "Ready" reads as a stalled print.
  function checkIdle() {
    var v = view()
    fakeConn.state = "standby"   // what Moonraker reports when idle
    fakeConn.progress = 0
    h.waitFor("progress hidden when the printer is idle",
              function() { return !root.hasVisibleText(v.contentItem, "0%") }, function() {
      h.check("elapsed hidden when idle", !root.hasVisibleText(v.contentItem, "Elapsed"))
      h.check("printer name still shown when idle", root.hasVisibleText(v.contentItem, "Voron"))

      // Paused is still a job, so it keeps its progress.
      fakeConn.state = "paused"
      fakeConn.progress = 42
      h.waitFor("progress returns while paused",
                function() { return root.hasVisibleText(v.contentItem, "42%") },
                function() { root.checkClose() })
    })
  }

  function checkClose() {
    var v = view()
    v.close()
    h.checkEq("close asks its owner to close", root.closeRequests, 1)
    // The owner binds `open`; the view must not have written to it itself, or
    // that binding is destroyed and the view can never be shown again.
    h.check("close does not clobber the open property", v.open === true,
            "open is now " + v.open)
    h.done()
  }
}
