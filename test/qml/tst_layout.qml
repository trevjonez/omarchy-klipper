import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Layout behaviour of the real Panel.qml: does content wrap instead of
// clipping, and does it scroll instead of being cut off.
//
// This loads the actual panel (the shell's own qs.Ui/qs.Commons modules are
// staged alongside it, see run.sh) and measures its layout. Layout is computed
// whether or not anything rasterises, so these assertions work in the nested
// test compositor where pixels do not appear.
//
// The bug that prompted the wrapping tests: the button rows were `Row`, so
// "Remove printer" ran past the panel edge and was unclickable. The one that
// prompted the scrolling tests: on a small or high-density display the panel
// is taller than the screen and the bottom is simply unreachable.
ShellRoot {
  id: root

  // Generous: these tests stage and load the whole shell module tree, and
  // run alongside the rest of the suite, so they are the ones most likely to
  // be starved on a busy machine. A budget overrun here is a false failure.
  Harness { id: h; budgetMs: 60000 }

  property var panel: null

  // Finds a named item anywhere in the panel's tree. objectName rather than id
  // because ids are file-private, and rather than a test-only hook because
  // objectName is ordinary QML.
  function findByName(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findByName(kids[i], name)
      if (found) return found
    }
    // Popups live in their own windows, hung off the panel rather than nested
    // in its visual children.
    var data = item.data || []
    for (var j = 0; j < data.length; j++) {
      if (data[j] === kids[j]) continue
      var alt = findByName(data[j], name)
      if (alt) return alt
    }
    return null
  }

  // No child may stick out past the container's right edge. This is the
  // clipping bug stated as an invariant.
  function widestChildEdge(flow) {
    var edge = 0
    for (var i = 0; i < flow.children.length; i++) {
      var c = flow.children[i]
      if (!c.visible || c.width <= 0) continue
      edge = Math.max(edge, c.x + c.width)
    }
    return edge
  }

  function widestChild(flow) {
    var w = 0
    for (var i = 0; i < flow.children.length; i++) {
      var c = flow.children[i]
      if (c.visible) w = Math.max(w, c.width)
    }
    return w
  }

  function visibleChildCount(flow) {
    var n = 0
    for (var i = 0; i < flow.children.length; i++) if (flow.children[i].visible) n++
    return n
  }

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

    root.panel.open()
    root.panel.startAddPrinter()

    h.waitFor("edit form is laid out", function() {
      var f = root.findByName(root.panel, "editFormButtons")
      return f !== null && f.width > 0 && root.visibleChildCount(f) > 0
    }, function() { root.checkButtons() })
  }

  function checkButtons() {
    var flow = findByName(panel, "editFormButtons")

    // At the panel's natural width nothing may overhang.
    h.check("buttons fit at the natural panel width",
            widestChildEdge(flow) <= flow.width + 1,
            "widest edge " + widestChildEdge(flow) + " vs width " + flow.width)

    var oneLine = flow.height
    // Just wide enough for the widest single button, so every button can fit
    // on a line of its own but they cannot share one. A Row would leave them
    // side by side and overhanging; a Flow must stack them.
    var narrow = widestChild(flow) + Style.space(4)

    flow.width = narrow
    // Re-layout is not synchronous with the width assignment, so measure once
    // the positioner has actually run.
    h.waitFor("narrow layout wraps onto more lines",
              function() { return flow.height > oneLine }, function() {
      h.check("buttons still fit once narrow",
              widestChildEdge(flow) <= flow.width + 1,
              "widest edge " + widestChildEdge(flow) + " vs width " + flow.width)

      // Narrower than any single button: nothing can fit, but the layout must
      // not collapse or drop children.
      flow.width = 20
      h.waitFor("still lays out when narrower than one button",
                function() { return flow.height > 0 }, function() {
        h.check("no children lost at extreme narrowness", visibleChildCount(flow) > 0)

        flow.width = 400
        h.waitFor("recovers when widened again",
                  function() { return widestChildEdge(flow) <= flow.width + 1 },
                  function() { root.checkHeroButtons() })
      })
    })
  }

  function checkHeroButtons() {
    panel.cancelEditPrinter()
    var hero = findByName(panel, "heroActions")
    // The hero row only exists once a printer is configured; with none, move
    // on rather than reporting a false failure.
    if (!hero || visibleChildCount(hero) === 0) {
      checkScrolling()
      return
    }
    hero.width = widestChild(hero) + Style.space(4)
    h.waitFor("hero actions fit when narrow", function() {
      return widestChildEdge(hero) <= hero.width + 1
    }, function() { root.checkScrolling() }, 5000)
  }

  function checkScrolling() {
    var view = findByName(panel, "printerScroll")
    h.check("printer popup uses a scroll view", view !== null)
    if (!view) { h.done(); return }

    // A ScrollView, not a bare Flickable: the shell's own panels use it, so
    // the wheel behaves like the rest of the desktop and the scrollbar is the
    // themed one. contentItem is the Flickable underneath.
    h.check("scroll view has a flickable content item",
            view.contentItem !== null && view.contentItem.contentHeight !== undefined)

    var contentHeight = view.contentItem.contentHeight
    h.check("content has real height", contentHeight > 0, "height " + contentHeight)

    // Simulate a short screen / high display scale: far less room than the
    // content needs. The content must become scrollable rather than being cut
    // off with no way to reach the rest.
    //
    // The view is anchored to fill its popup, and anchors win over an assigned
    // height, so they have to be released before the height means anything.
    view.anchors.fill = null
    view.height = Math.max(40, Math.floor(contentHeight / 4))
    h.waitFor("becomes scrollable when the screen is too short", function() {
      return view.contentItem.interactive === true
    }, function() {
      h.check("scrollable range covers the hidden content",
              view.contentItem.contentHeight > view.height,
              "content " + view.contentItem.contentHeight + " vs view " + view.height)

      // And the converse: given room, it must not trap the wheel by staying
      // interactive when there is nothing to scroll.
      view.height = view.contentItem.contentHeight + 200
      h.waitFor("stops being scrollable when everything fits", function() {
        return view.contentItem.interactive === false
      }, function() { h.done() }, 5000)
    }, 5000)
  }
}
