import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// Pause/resume/cancel/e-stop/firmware-restart. These are the buttons where
// hitting the wrong endpoint has real consequences on a machine with a hot
// nozzle, so the assertion that matters is in tst_actions.expect.js: which URL
// was actually requested, in what order.
//
// Actions share one Process in Service, so they are issued strictly in
// sequence, gated on the mock actually having received the previous one.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))
  readonly property string requestLog: Quickshell.env("REQUEST_LOG")

  Plugin.Harness { id: h; budgetMs: 40000 }
  Plugin.Service { id: svc }

  property int posts: 0

  // Counts POSTs the mock has logged. Every action is a POST and nothing else
  // in this scenario posts, so this is an exact "has it arrived yet" signal.
  function refreshPosts() {
    if (counter.running) return
    counter.command = ["bash", "-c", "grep -c '\"method\":\"POST\"' '" + root.requestLog + "' || true"]
    counter.running = true
  }

  Process {
    id: counter
    running: false
    command: []
    stdout: StdioCollector { id: counterOut; waitForEnd: true }
    onExited: root.posts = parseInt(String(counterOut.text || "0").trim()) || 0
  }

  // Each step names how many POSTs should have arrived once it has settled.
  property var steps: []
  property int stepIndex: 0

  function runNextStep() {
    if (stepIndex >= steps.length) { h.done(); return }
    var step = steps[stepIndex]
    stepIndex++
    step.go()
    h.waitFor(step.name, function() {
      root.refreshPosts()
      return root.posts === step.expectPosts
    }, function() { root.runNextStep() }, 10000)
  }

  Component.onCompleted: {
    svc.addPrinter({ name: "Mock", host: "127.0.0.1", port: root.mockPort })

    h.waitFor("printer connected and printing", function() {
      return svc.reachable && svc.state === "printing"
    }, function() {
      root.steps = [
        // One button whose meaning depends on state: mid-print it must pause.
        { name: "pause reaches the printer", expectPosts: 1,
          go: function() { svc.togglePauseResume() } },

        // Both destructive actions are double-press-to-confirm. The first
        // press must arm only -- if it reached the printer, a stray click
        // would cancel a running job.
        { name: "first cancel press sends nothing", expectPosts: 1,
          go: function() {
            svc.requestCancel()
            h.checkEq("cancel armed", svc.pendingConfirm, "cancel")
          } },
        { name: "second cancel press sends", expectPosts: 2,
          go: function() { svc.requestCancel() } },

        { name: "first e-stop press sends nothing", expectPosts: 2,
          go: function() {
            svc.requestEmergencyStop()
            h.checkEq("e-stop armed", svc.pendingConfirm, "estop")
          } },
        { name: "second e-stop press sends", expectPosts: 3,
          go: function() { svc.requestEmergencyStop() } },

        // Not confirm-guarded: restarting firmware on an errored printer is
        // the recovery path, and gating it would be friction with no upside.
        { name: "firmware restart sends immediately", expectPosts: 4,
          go: function() { svc.restartFirmware() } }
      ]
      root.runNextStep()
    })
  }
}
