#!/usr/bin/env bash
# Middle-click on the bar pill opens the settings popup, left-click opens the
# printer popup. This is the only behavior in the plugin that cannot be reached
# over IPC, so it is the only test that needs synthetic input.
#
# Clicks land in the nested compositor, never on the developer's real desktop.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v ydotool >/dev/null; then
  ui_log "SKIP: ydotool not installed (omarchy dev install ydoo)"
  exit 0
fi

ui_start || exit 1
rc=0

# The pill is the only bar widget, at the right end of the bar, and the bar is
# the full width of the nested output at its bottom edge.
read -r W H < <(WAYLAND_DISPLAY="$UI_DISPLAY" HYPRLAND_INSTANCE_SIGNATURE="$UI_HIS" \
  hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys;m=json.load(sys.stdin)[0];print(m["width"],m["height"])')
[[ -z "${W:-}" ]] && { ui_log "could not read nested output size"; exit 1; }
PILL_X=$(( W - 20 ))
PILL_Y=$(( H - 13 ))

click() {  # click <button>   1=left 2=right 3=middle
  WAYLAND_DISPLAY="$UI_DISPLAY" ydotool mousemove --absolute -x "$PILL_X" -y "$PILL_Y" 2>/dev/null
  sleep 0.3
  WAYLAND_DISPLAY="$UI_DISPLAY" ydotool click "$1" 2>/dev/null
  sleep 1.2
}

ui_ipc close; ui_ipc closeSettings; sleep 0.8
ui_assert_layers 0 "starts with nothing open" || rc=1

click 0xC0   # middle
ui_assert_layers 1 "middle-click opens a popup" || rc=1
# closeSettings only dismisses the settings popup, so this identifies which
# popup middle-click actually opened.
ui_ipc closeSettings; sleep 1
ui_assert_layers 0 "middle-click opened the settings popup" || rc=1

click 0xC0
sleep 0.3
click 0xC0
ui_assert_layers 0 "middle-click again closes it" || rc=1

click 0xC0
ui_assert_layers 1 "settings popup open before left-click" || rc=1
click 0xC0   # reset via toggle
sleep 0.3

click 0x40   # left
ui_assert_layers 1 "left-click opens a popup" || rc=1
ui_ipc closeSettings; sleep 1
ui_assert_layers 1 "left-click opened the printer popup, not settings" || rc=1

[[ $rc -ne 0 ]] && ui_shot middleclick-failure
exit $rc
