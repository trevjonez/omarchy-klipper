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
  hotend/bed temperatures. The printer switcher shows live reachability
  for every configured printer, not just the active one.
- Pause, resume, cancel (confirm), emergency stop (confirm), and restart
  Klipper after an error.
- Multiple printers: add as many as you like, switch which one is shown
  in the bar from the popup.
- Desktop notification when any configured printer's print completes, is
  cancelled, or errors — whether or not it's the one currently selected.
- Add/edit form has a "Test" button: it hits Moonraker before you save,
  fills the Name field in from the printer's own reported hostname if you
  left it blank, and pins down http vs https for you.
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

Printers are stored at `~/.local/state/omarchy-klipper/printers.json` and
managed entirely from the popup (add/edit/remove, switch active printer) —
no manual file editing needed.

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
