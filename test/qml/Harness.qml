import QtQuick

// Assertions, condition-polling and result reporting for the qs-hosted
// integration tests. Staged into the same directory as the components under
// test (Quickshell blackholes anything outside the config folder, so a test
// can't import this from a sibling path).
//
// Everything here polls rather than sleeps: these tests drive real sockets,
// real curl processes and real inotify, so fixed delays would either be slow
// or flaky. A test says what it is waiting *for*, and gets a named failure
// naming the unmet condition if it never arrives.
Item {
  id: harness

  property int passed: 0
  property int failed: 0
  // Backstop for a test that wedges entirely (never reaches done()).
  property int budgetMs: 20000

  function check(name, condition, detail) {
    if (condition) {
      passed++
      console.log("PASS " + name)
    } else {
      failed++
      console.log("FAIL " + name + (detail === undefined ? "" : " -- " + detail))
    }
    return condition
  }

  function checkEq(name, got, want) {
    return check(name, got === want, "got " + JSON.stringify(got) + ", want " + JSON.stringify(want))
  }

  // Polls `predicate` until true, then calls `onReady`. A predicate that never
  // becomes true fails the named check once, rather than hanging the run.
  function waitFor(name, predicate, onReady, timeoutMs) {
    _waits.push({
      name: name,
      predicate: predicate,
      onReady: onReady,
      deadline: Date.now() + (timeoutMs === undefined ? 8000 : timeoutMs)
    })
    poller.running = true
  }

  function done() {
    console.log("DONE " + passed + " passed, " + failed + " failed")
    Qt.exit(failed > 0 ? 1 : 0)
  }

  property var _waits: []

  Timer {
    id: poller
    interval: 50
    repeat: true
    running: false
    onTriggered: {
      if (harness._waits.length === 0) { running = false; return }
      var still = []
      var fire = []
      for (var i = 0; i < harness._waits.length; i++) {
        var w = harness._waits[i]
        var ok = false
        try { ok = !!w.predicate() } catch (e) { ok = false }
        if (ok) {
          harness.check(w.name, true)
          fire.push(w.onReady)
        } else if (Date.now() > w.deadline) {
          harness.check(w.name, false, "condition never became true")
          fire.push(w.onReady)
        } else {
          still.push(w)
        }
      }
      harness._waits = still
      // Fired after the list is rebuilt so a callback may enqueue new waits.
      for (var j = 0; j < fire.length; j++) if (fire[j]) fire[j]()
    }
  }

  Timer {
    interval: harness.budgetMs
    running: true
    repeat: false
    onTriggered: {
      console.log("FAIL harness-budget -- test did not call done() within " + harness.budgetMs + "ms")
      console.log("DONE " + harness.passed + " passed, " + (harness.failed + 1) + " failed")
      Qt.exit(1)
    }
  }
}
