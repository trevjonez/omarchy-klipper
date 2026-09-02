import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Which mouse button on the bar pill opens what.
//
// This is the one behaviour that has no IPC equivalent, so it used to be
// covered only by a ydotool test that could not run without a system-wide
// uinput rule. Instead it calls WidgetButton.triggerPress(), which is exactly
// what the pill's own MouseArea calls on a click -- the same dispatch, minus
// the compositor delivering the event. Whether a compositor routes a middle
// click to a layer-shell widget is Omarchy's concern, not this plugin's.
ShellRoot {
  id: root

  // Generous: stages and loads the whole shell module tree alongside the rest
  // of the suite, so a budget overrun here is a false failure.
  Harness { id: h; budgetMs: 60000 }

  property var panel: null

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

  function pill() { return findByName(panel, "barPill") }

  // Snapshot of what is currently showing, so each assertion can state the
  // whole picture rather than one flag at a time.
  function shown() {
    return (panel.opened ? "popup " : "")
         + (panel.settingsOpen ? "settings " : "")
         + (panel.cameraWallOpen ? "wall " : "")
         + (panel.fullscreenPrinterId !== "" ? "fullscreen " : "")
  }

  function press(button) { pill().triggerPress(button) }

  Component.onCompleted: {
    var c = Qt.createComponent(Qt.resolvedUrl("Panel.qml"))
    if (c.status === Component.Error) {
      h.check("panel loads", false, c.errorString())
      h.done()
      return
    }
    root.panel = c.createObject(root, {})
    h.check("panel loads", root.panel !== null)
    if (!root.panel) { h.done(); return }

    h.waitFor("bar pill exists", function() { return root.pill() !== null },
              function() { root.checkButtons() })
  }

  function checkButtons() {
    h.checkEq("nothing open at rest", shown(), "")

    press(Qt.LeftButton)
    h.checkEq("left opens the printer popup", shown(), "popup ")
    press(Qt.LeftButton)
    h.checkEq("left again closes it", shown(), "")

    press(Qt.MiddleButton)
    h.checkEq("middle opens app settings", shown(), "settings ")
    press(Qt.MiddleButton)
    h.checkEq("middle again closes it", shown(), "")

    press(Qt.RightButton)
    h.checkEq("right opens the camera wall", shown(), "wall ")
    press(Qt.RightButton)
    h.checkEq("right again closes it", shown(), "")

    // The three are mutually exclusive: switching between them must never
    // leave two surfaces stacked.
    press(Qt.LeftButton)
    press(Qt.MiddleButton)
    h.checkEq("middle replaces the printer popup", shown(), "settings ")

    press(Qt.RightButton)
    h.checkEq("right replaces app settings", shown(), "wall ")

    press(Qt.LeftButton)
    h.checkEq("left replaces the camera wall", shown(), "popup ")

    // And the reverse order, which is how the stacking bug showed up.
    press(Qt.RightButton)
    press(Qt.MiddleButton)
    h.checkEq("middle replaces the camera wall", shown(), "settings ")

    // Opening a feed fullscreen dismisses whatever was showing.
    panel.openFullscreenCamera("nope", 0)
    h.checkEq("fullscreen takes over from the popup", shown(), "fullscreen ")

    panel.openCameraWall()
    h.checkEq("the wall takes over from fullscreen", shown(), "wall ")

    h.done()
  }
}
