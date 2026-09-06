import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

// The Moonraker API key must reach the printer without ever appearing in a
// process command line -- /proc/<pid>/cmdline is readable by other local users
// on a normal system. ApiCurl feeds it to curl on stdin instead; this proves
// both halves: the key is absent from argv, and it still arrives as a header.
ShellRoot {
  id: root

  readonly property int mockPort: parseInt(Quickshell.env("MOCK_PORT"))
  readonly property string apiKey: "s3cr3t-key"

  Plugin.Harness { id: h; budgetMs: 20000 }

  readonly property var printer: ({
    id: "p1", name: "Voron", host: "127.0.0.1", port: root.mockPort,
    scheme: "http", apiKey: root.apiKey, webcams: [], displaySensors: []
  })

  Plugin.ApiCurl {
    id: curl
    stdout: StdioCollector { id: out; waitForEnd: true }
    stderr: StdioCollector { id: err; waitForEnd: true }
  }

  Plugin.ApiCurl {
    id: keyless
    stdout: StdioCollector { id: keylessOut; waitForEnd: true }
  }

  function infoUrl() { return "http://127.0.0.1:" + root.mockPort + "/printer/info" }

  Component.onCompleted: {
    curl.run(["curl", "-fsS", "--max-time", "5", root.infoUrl()], root.printer)

    var argv = JSON.stringify(curl.command)
    h.check("the key is not in argv", argv.indexOf(root.apiKey) === -1, argv)
    h.check("curl is told to read its config from stdin", argv.indexOf("--config") !== -1, argv)

    h.waitFor("the request finishes", function() { return !curl.running }, function() {
      // If stdin were never closed, curl would sit waiting for the rest of its
      // config until the timeout instead of answering.
      h.check("moonraker answered", String(out.text || "").indexOf("mock-printer") !== -1,
              String(out.text || "") + String(err.text || ""))

      // A printer with no key must not grow a --config it never writes to,
      // which would leave curl waiting on an stdin nobody feeds.
      keyless.run(["curl", "-fsS", "--max-time", "5", root.infoUrl()],
                  { id: "p2", name: "Open", host: "127.0.0.1", port: root.mockPort, scheme: "http", apiKey: "" })
      h.check("no config argument without a key",
              JSON.stringify(keyless.command).indexOf("--config") === -1, JSON.stringify(keyless.command))
      h.waitFor("the keyless request finishes", function() { return !keyless.running }, function() {
        h.check("moonraker answered that one too",
                String(keylessOut.text || "").indexOf("mock-printer") !== -1, String(keylessOut.text || ""))
        h.done()
      })
    })
  }
}
