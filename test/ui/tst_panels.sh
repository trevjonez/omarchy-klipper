#!/usr/bin/env bash
# Popup lifecycle in a real shell: each popup opens, and opening one dismisses
# the other rather than stacking on top of it. Driven over IPC, so no synthetic
# input is required.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ui_start || exit 1
rc=0

ui_ipc close; ui_ipc closeSettings; sleep 1
ui_assert_layers 0 "no popup open at rest" || rc=1

ui_ipc open; sleep 1
ui_assert_layers 1 "left-click popup opens" || rc=1

# The important one: the settings popup must replace the printer popup.
# Two surfaces here would mean the bar's popout coordinator stopped swapping
# them and they are stacked.
ui_ipc openSettings; sleep 1
ui_assert_layers 1 "settings popup replaces the printer popup" || rc=1

# closeSettings is popup-specific, so it doubles as a probe for *which* popup
# is open: it dismisses the settings popup and ignores the printer one.
ui_ipc closeSettings; sleep 1
ui_assert_layers 0 "settings popup is the one that was open" || rc=1

ui_ipc open; sleep 1
ui_ipc closeSettings; sleep 1
ui_assert_layers 1 "closeSettings leaves the printer popup alone" || rc=1

# Plain close is deliberately "dismiss whatever is showing", so a key bound to
# it always gets the popup off screen.
ui_ipc close; sleep 1
ui_assert_layers 0 "close dismisses whichever popup is open" || rc=1

ui_ipc open; sleep 0.6
ui_ipc openSettings; sleep 0.4
ui_ipc close; sleep 1
ui_assert_layers 0 "rapid open/switch/close leaves nothing stuck open" || rc=1

[[ $rc -ne 0 ]] && ui_shot failure
exit $rc
