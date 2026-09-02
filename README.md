# Klipper tray for Omarchy

A native [Omarchy](https://omarchy.org) shell bar widget for monitoring and
controlling Klipper 3D printers through [Moonraker](https://moonraker.readthedocs.io/)
— the same API [Mainsail](https://docs.mainsail.xyz/) and
[Fluidd](https://docs.fluidd.xyz/) use, so if your printer already serves
either of those web UIs, this plugin can talk to it too.

## Features

- Real-time status: a persistent, subscribed websocket connection to
  *every* configured printer (not just the one showing in the bar) via
  Moonraker's JSON-RPC API. Switching printers is instant — no request in
  flight, the data's already live — and a background printer's print
  finishing/erroring is caught and notified the moment Moonraker reports
  it, not on the next poll.
- Bar pill showing printer state at a glance (idle / printing / paused /
  error / unreachable), with the toolhead sweeping the icon's rail
  proportional to print progress.
- Popup with live progress, elapsed/remaining time, filename, and
  temperatures. Defaults to whatever's controllable (hotend, bed, any
  extra heaters like a heated chamber or drybox) — edit a printer to pick
  from everything else it exposes (chamber/ambient temps, humidity,
  pressure, individually per field for a sensor that reports more than
  one). The printer switcher shows live reachability for every configured
  printer, not just the active one.
- Pause, resume, cancel (confirm), emergency stop (confirm), and restart
  Klipper after an error.
- Multiple printers: add as many as you like, switch which one is shown
  in the bar from the popup.
- Desktop notification when any configured printer's print completes, is
  cancelled, or errors — whether or not it's the one currently selected.
- Add/edit form has a "Test" button: it hits Moonraker before you save,
  fills the Name field in from the printer's own reported hostname if you
  left it blank, and pins down http vs https for you.
- G-code metadata watcher (middle-click the bar icon for settings). If your
  printers read G-code from a network share, a file you write from another
  machine never reaches their file watchers, so Moonraker never parses its
  metadata — the file shows up with no thumbnail, no estimated time, no
  filament usage. Point the watcher at that share and each new `.gcode`
  landing there is scanned on every reachable printer automatically.
- Live webcam feed(s) inline in the popup, when the printer has one —
  discovered automatically via Moonraker, correctly oriented per its own
  flip/rotation settings. Falls back to a periodically-refreshed still
  image if a feed can't be decoded as video.

## Requirements

- A Klipper printer with Moonraker running and reachable on your network.
- `curl` (already present on every Omarchy install).
- `qt6-websockets` and `qt6-multimedia` — install with
  `sudo pacman -S qt6-websockets qt6-multimedia` if either isn't already
  on your system.
- `inotify-tools`, only if you use the G-code watcher
  (`sudo pacman -S inotify-tools`).
- If Moonraker's `[authorization]` section is configured with trusted
  clients only, generate an API key from Mainsail/Fluidd's settings page
  and paste it into the printer's entry — otherwise leave it blank.

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy-klipper.git --enable
```

Or manually:

```bash
git clone https://github.com/<you>/omarchy-klipper.git ~/.config/omarchy/plugins/klipper
omarchy plugin enable klipper
```

Click the printer icon in the bar, then "+ Add printer" to configure your
first printer (host/IP is required; name, port, and API key are optional —
port defaults to Moonraker's standard 7125). The Host field accepts a bare
host/IP, a `host:port`, or a full URL — a plain host tries http then https
automatically and remembers whichever answered; pasting an explicit
`https://…` URL pins that scheme instead of probing.

## Configuration

Printers and app settings are stored at
`~/.local/state/omarchy-klipper/printers.json` and managed entirely from the
popups (add/edit/remove, switch active printer) — no manual file editing
needed.

Left-click the bar icon for the printer popup, middle-click for app settings.
Both are also on IPC, so you can bind them to a key:

```bash
qs -p /usr/share/omarchy/shell ipc call klipper toggle
qs -p /usr/share/omarchy/shell ipc call klipper toggleSettings
```

### G-code watcher

Set the watch folder to the directory your slicer exports into — the same
one your printers mount as their G-code root. When a `.gcode` (or `.g`,
`.gco`, `.ufp`, `.nc`) file lands there, the plugin calls Moonraker's
`/server/files/metascan` for it on every printer that's currently
reachable, so the metadata is parsed as if the printer's own file watcher
had seen the write.

- Paths are used relative to the watch folder, so it must correspond to
  each printer's own G-code root for a file to be found.
- Subdirectories are watched too, including ones created after the watcher
  starts. Hidden directories (`.Trash-1000`, `.thumbs`) are skipped.
- Scans run one at a time; a scan parses the whole file on the printer's
  CPU. "Defer scans while printing" (on by default) holds new files for a
  busy printer until its job finishes.
- A printer that's offline when a file lands is skipped — Moonraker parses
  whatever metadata it's missing when it next starts up, so it catches up
  on its own.
- Files that land while the shell isn't running are picked up on next
  start, capped at 50 per sweep so a bulk copy can't queue hours of work.
  The first time you enable the watcher it starts from that moment rather
  than scanning your whole existing library.

## Uninstall

```bash
omarchy plugin disable klipper
rm -rf ~/.config/omarchy/plugins/klipper
```

## Scope

This is a monitoring/control tray, not a full print manager: it does not
browse or upload G-code files, or track print history. Start prints from
Mainsail/Fluidd/your slicer as usual — once a print is running, this
plugin tracks and controls it.

Camera feeds assume the standard crowsnest/Mainsail/Fluidd setup, where the
webcam is served from the web UI's own default port (80/443) rather than
Moonraker's API port — not currently configurable if your setup differs.
