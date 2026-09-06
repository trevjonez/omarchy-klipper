import Quickshell.Io
import "Model.js" as Model

// A curl invocation that keeps the Moonraker API key out of the command line.
//
// A process's argv is world-readable through /proc on a normal multi-user
// system, so `-H "X-Api-Key: …"` hands the printer's credential to every local
// user for as long as the request runs. curl reads options from a config file
// instead, and `--config -` means stdin: the key travels down a pipe only this
// process and curl can see, and never appears in argv, in a log, or in curl's
// own error output.
//
// Otherwise this is an ordinary Process — callers keep their own stdout/stderr
// collectors and onExited handling, and start a request with run() rather than
// by assigning command and running.
Process {
  id: root

  // Held only between run() and the write below, so the value is not sitting
  // in a property any longer than the request itself.
  property string apiKey: ""

  running: false
  command: []

  // Runs `args` for `printer`, whose API key (if it has one) is delivered on
  // stdin. Returns false if a request is already in flight, matching the
  // "one at a time, drop the overlap" shape every caller already had.
  function run(args, printer) {
    if (running) return false
    apiKey = Model.apiKeyOf(printer)
    command = apiKey === "" ? args : args.concat(["--config", "-"])
    stdinEnabled = apiKey !== ""
    running = true
    return true
  }

  onStarted: {
    if (apiKey === "") return
    write(Model.curlApiKeyConfig(apiKey))
    apiKey = ""
    // curl reads its config to EOF before issuing the request, so stdin has to
    // be closed or the request never leaves.
    stdinEnabled = false
  }
}
