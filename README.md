# Klipper tray for Omarchy

A native [Omarchy](https://omarchy.org) shell bar widget for monitoring and
controlling Klipper 3D printers through [Moonraker](https://moonraker.readthedocs.io/)
— the same API [Mainsail](https://docs.mainsail.xyz/) and
[Fluidd](https://docs.fluidd.xyz/) use, so if your printer already serves
either of those web UIs, this plugin can talk to it too.

## Features

- Bar pill showing printer state at a glance (idle / printing / paused /
  error / unreachable), with the toolhead sweeping the icon's rail
  proportional to print progress.
- Popup with live progress, elapsed/remaining time, filename, and
  hotend/bed temperatures.
- Pause, resume, cancel (confirm), emergency stop (confirm), and restart
  Klipper after an error.
- Multiple printers: add as many as you like, switch which one is active
  (polled and shown in the bar) from the popup.
- Desktop notification when a print completes, is cancelled, or errors.

## Requirements

- A Klipper printer with Moonraker running and reachable on your network.
- `curl` (already present on every Omarchy install).
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
port defaults to Moonraker's standard 7125).

## Configuration

Printers are stored at `~/.local/state/omarchy-klipper/printers.json` and
managed entirely from the popup (add/edit/remove, switch active printer) —
no manual file editing needed.

The status refresh interval (default 3 seconds) is set the same way as
other first-party widgets with a tunable interval, by editing this widget's
entry in `~/.config/omarchy/shell.json`:

```jsonc
{
  "key": "refreshIntervalSec",
  "value": 3
}
```

## Uninstall

```bash
omarchy plugin disable klipper
rm -rf ~/.config/omarchy/plugins/klipper
```

## Scope

This is a monitoring/control tray, not a full print manager: it does not
browse or upload G-code files, show a webcam feed, or track print history.
Start prints from Mainsail/Fluidd/your slicer as usual — once a print is
running, this plugin tracks and controls it.
