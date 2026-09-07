import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// A feed nobody is looking at must not touch the printer's camera. Every view
// that shows one -- popup, camera wall, fullscreen -- keeps its CameraView
// alive when closed rather than destroying it, so without the active gate a
// closed view goes on polling a snapshot every second forever, and enough of
// those at once is what makes the Pi's camera service start answering 502.
//
// Driven through the snapshot path (no streamUrl): the assertion is about
// request traffic, which needs no media backend to observe.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))
  readonly property string requestLog: Quickshell.env("REQUEST_LOG")

  Plugin.Harness { id: h; budgetMs: 30000 }

  property int snapshots: 0

  // Counts snapshot fetches the mock has actually served.
  function refreshCount() {
    if (counter.running) return
    counter.command = ["bash", "-c", "grep -c '\"path\":\"/webcam/\"' '" + root.requestLog + "' || true"]
    counter.running = true
  }

  Process {
    id: counter
    running: false
    command: []
    stdout: StdioCollector { id: counterOut; waitForEnd: true }
    onExited: root.snapshots = parseInt(String(counterOut.text || "0").trim()) || 0
  }

  Plugin.CameraView {
    id: feed
    width: 320
    active: false
    streamUrl: ""
    snapshotUrl: "http://127.0.0.1:" + root.mockPort + "/webcam/?action=snapshot"
  }

  Component.onCompleted: {
    // Give an inactive feed long enough that a 1fps poll would be obvious.
    h.waitFor("inactive feed settles", function() { root.refreshCount(); return root.snapshots >= 0 }, function() {
      idleTimer.start()
    })
  }

  Timer {
    id: idleTimer
    interval: 2500
    onTriggered: {
      root.refreshCount()
      h.waitFor("count read back", function() { return !counter.running }, function() {
        h.checkEq("a closed view fetches nothing", root.snapshots, 0)

        // Opening it starts the feed, and the first frame is immediate rather
        // than a poll interval away.
        feed.active = true
        h.waitFor("an open view fetches", function() {
          root.refreshCount()
          return root.snapshots > 0
        }, function() {
          var whileOpen = root.snapshots
          feed.active = false
          // Whatever was in flight may still land, so allow one straggler.
          h.waitFor("closing stops it again", function() { return !counter.running }, function() {
            var atClose = root.snapshots
            stopTimer.settled = atClose
            stopTimer.start()
          })
        }, 10000)
      })
    }
  }

  Timer {
    id: stopTimer
    property int settled: 0
    interval: 2500
    onTriggered: {
      root.refreshCount()
      h.waitFor("final count", function() { return !counter.running }, function() {
        h.check("no polling after it closes again", root.snapshots <= stopTimer.settled + 1,
                "was " + stopTimer.settled + ", now " + root.snapshots)

        h.done()
      })
    }
  }
}
