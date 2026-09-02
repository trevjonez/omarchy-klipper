import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "Model.js" as Model

// The all-cameras wall: one tile per camera across every printer, each
// labelled and each handing off the right printer and camera when clicked.
ShellRoot {
  id: root

  // Generous: this stages and loads the whole shell module tree alongside the
  // rest of the suite, so it is among the likeliest to be starved on a busy
  // machine. A budget overrun here is a false failure.
  Harness { id: h; budgetMs: 60000 }

  property var lastTile: null
  property int closeRequests: 0

  // Deliberately mixed: one camera, none, and two -- so the wall has to
  // flatten rather than assume one feed per printer.
  property var fakePrinters: [
    { id: "a", name: "Voron", webcams: [mk(0.75)], displaySensors: [], videoOverlays: [] },
    { id: "b", name: "NoCam", webcams: [], displaySensors: [], videoOverlays: [] },
    { id: "c", name: "MK3", webcams: [mk(0.75), mk(0.5625)], displaySensors: [], videoOverlays: [] }
  ]

  function mk(ratio) {
    return { name: "cam", streamUrl: "", snapshotUrl: "", flipHorizontal: false,
             flipVertical: false, rotation: 0, aspectRatio: ratio }
  }

  QtObject {
    id: readyConn
    property bool reachable: true
    property string state: "standby"
    property int progress: 0
  }

  QtObject {
    id: fakeService
    property var printers: root.fakePrinters
    function connectionFor(id) { return readyConn }
  }

  property var wall: null

  function grid() {
    return wall && wall.contentItem ? findByName(wall.contentItem, "cameraGrid") : null
  }

  // Grid.children includes the Repeater, which is not a tile.
  function tilesIn(g) {
    var out = []
    for (var i = 0; i < g.children.length; i++) {
      if (g.children[i].modelData !== undefined) out.push(g.children[i])
    }
    return out
  }

  function findByName(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findByName(kids[i], name)
      if (found) return found
    }
    return null
  }

  function hasVisibleText(item, needle) {
    if (!item) return false
    if (item.text !== undefined && item.visible && String(item.text).indexOf(needle) !== -1) return true
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) if (hasVisibleText(kids[i], needle)) return true
    return false
  }

  Component.onCompleted: {
    var c = Qt.createComponent(Qt.resolvedUrl("CameraWall.qml"))
    if (c.status === Component.Error) {
      h.check("camera wall loads", false, c.errorString())
      h.done()
      return
    }
    root.wall = c.createObject(root, { service: fakeService, open: true })
    h.check("camera wall loads", root.wall !== null)
    if (!root.wall) { h.done(); return }

    root.wall.closeRequested.connect(function() { root.closeRequests++ })
    root.wall.tileActivated.connect(function(printerId, webcamIndex) {
      root.lastTile = { printerId: printerId, webcamIndex: webcamIndex }
    })

    h.waitFor("grid is laid out", function() {
      var g = root.grid()
      return g !== null && g.children.length > 0 && g.width > 0
    }, function() { root.checkTiles() })
  }

  function checkTiles() {
    var g = grid()
    var tiles = tilesIn(g)
    // Three cameras across three printers, one of which has none.
    h.checkEq("one tile per camera, not per printer", tiles.length, 3)
    h.checkEq("grid is square-ish", root.wall.columns, 2)

    h.check("every tile has a size", tiles[0].width > 0 && tiles[0].height > 0,
            tiles[0].width + "x" + tiles[0].height)

    // Each tile's feed is letterboxed inside its cell rather than overflowing.
    var overflow = 0
    for (var i = 0; i < tiles.length; i++) {
      var cell = tiles[i]
      for (var j = 0; j < cell.children.length; j++) {
        var kid = cell.children[j]
        if (kid.aspectRatio === undefined) continue
        if (kid.width > cell.width + 1 || kid.height > cell.height + 1) overflow++
      }
    }
    h.checkEq("no feed overflows its cell", overflow, 0)

    checkLabels()
  }

  function checkLabels() {
    var g = grid()
    h.check("tiles are labelled with the printer name", hasVisibleText(g, "Voron"))
    h.check("a camera-less printer contributes no tile", !hasVisibleText(g, "NoCam"))
    h.check("status is shown alongside the name", hasVisibleText(g, "Ready"))

    // Contrast backing behind the label -- plain text over a bright bed is
    // unreadable, which is the whole reason the box exists.
    var box = findByName(g, "tileLabel")
    h.check("label has a backing box", box !== null)
    h.check("backing box is translucent, not opaque",
            box !== null && box.opacity > 0 && box.opacity < 1,
            box ? String(box.opacity) : "none")

    // A printer with two cameras disambiguates them; a printer with one does
    // not need to.
    h.check("multi-camera printer labels each feed", hasVisibleText(g, "MK3 · cam"))

    checkActivation()
  }

  function checkActivation() {
    var g = grid()
    // Simulate a click on the last tile: it must report the second camera of
    // the third printer, not a flat index into the tile list.
    var tile = tilesIn(g)[2]
    var area = null
    for (var i = 0; i < tile.children.length; i++) {
      if (tile.children[i].containsMouse !== undefined) area = tile.children[i]
    }
    h.check("tile has a click target", area !== null)
    if (area) area.clicked(null)

    h.waitFor("clicking a tile reports its printer and camera",
              function() { return root.lastTile !== null }, function() {
      h.checkEq("reports the right printer", root.lastTile.printerId, "c")
      h.checkEq("reports the right camera index", root.lastTile.webcamIndex, 1)
      root.checkClose()
    })
  }

  function checkClose() {
    wall.close()
    h.checkEq("close asks its owner to close", root.closeRequests, 1)
    h.check("close does not clobber the open property", wall.open === true,
            "open is now " + wall.open)
    h.done()
  }
}
