# Shared setup for the UI tier.
#
# Runs a second Omarchy shell inside a nested compositor with an isolated HOME,
# so these tests never touch the developer's real bar, real plugin config or
# real printers -- and, for the ydotool tests, so synthetic clicks cannot land
# in a real window. (That already went wrong once in this project, which is why
# the isolation is not optional.)
#
# Instances are addressed by pid: the real shell and this one share a config
# path, so `qs ipc --path` would be ambiguous between them.

set -uo pipefail

UI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UI_STAGE=""
UI_COMP_PID=""
UI_SHELL_PID=""
UI_DISPLAY=""
UI_HIS=""

ui_log() { printf '      %s\n' "$*"; }

ui_stop() {
  [[ -n "$UI_SHELL_PID" ]] && kill "$UI_SHELL_PID" 2>/dev/null
  [[ -n "$UI_COMP_PID" ]] && kill "$UI_COMP_PID" 2>/dev/null
  wait "$UI_SHELL_PID" 2>/dev/null
  wait "$UI_COMP_PID" 2>/dev/null
  [[ -n "$UI_STAGE" ]] && rm -rf "$UI_STAGE"
  UI_SHELL_PID=""; UI_COMP_PID=""; UI_STAGE=""
}

# Builds an isolated HOME containing just this plugin and a one-widget bar.
ui_build_stage() {
  UI_STAGE="$(mktemp -d)"
  mkdir -p "$UI_STAGE/.config/omarchy/plugins" "$UI_STAGE/.local/state/omarchy-klipper"

  mkdir -p "$UI_STAGE/.config/omarchy/plugins/io.github.trevjonez.klipper"
  cp "$UI_ROOT"/*.qml "$UI_ROOT"/Model.js "$UI_ROOT"/manifest.json \
     "$UI_STAGE/.config/omarchy/plugins/io.github.trevjonez.klipper/"

  # A single bar widget, so the pill's position is deterministic and the
  # cropped screenshot region is stable across runs. The bar sits at the
  # bottom so its popups open upward, away from Hyprland's own advisory
  # overlays ("started without start-hyprland", ".conf will be removed"),
  # which render across the top of the screen and would otherwise land inside
  # the captured region and churn the goldens.
  cat > "$UI_STAGE/.config/omarchy/shell.json" <<'JSON'
{
  "_comment": "idle is set a day out, not 0: these are seconds since idle began, so 0 fires immediately and locks the screen",
  "version": 1,
  "idle": { "screensaver": 86400, "lock": 86400 },
  "bar": {
    "position": "bottom",
    "transparent": false,
    "layout": { "left": [], "center": [], "right": [ { "id": "io.github.trevjonez.klipper" } ] }
  },
  "plugins": []
}
JSON

  # A printer pointed at a closed port: unreachable, but present, so the
  # switcher and status area render deterministically with no network at all.
  cat > "$UI_STAGE/.local/state/omarchy-klipper/printers.json" <<'JSON'
{
  "activePrinterId": "t1",
  "settings": { "gcodeWatchDir": "", "gcodeWatchEnabled": false,
                "deferScanWhilePrinting": true, "lastSeenEpoch": 1 },
  "printers": [
    { "id": "t1", "name": "TestPrinter", "host": "127.0.0.1", "port": 1,
      "scheme": "http", "apiKey": "", "webcams": [], "displaySensors": [] }
  ]
}
JSON
}

ui_start() {
  ui_build_stage
  trap ui_stop EXIT

  # This tier will NOT run against the developer's own session. It starts a
  # second Omarchy shell and drives it through the camera wall and the
  # fullscreen view, both of which are full-screen layer surfaces that take
  # keyboard focus -- on a live desktop that blanks the screen mid-run. An
  # earlier version also shipped `idle: 0` in its generated shell.json, which
  # is "zero seconds since idle began", so it locked the screen too.
  #
  # It needs Hyprland specifically, because its assertions read mapped layer
  # surfaces through `hyprctl layers` and sway exposes no equivalent. It also
  # cannot nest Hyprland inside the runner's sway: Hyprland 0.56 requires
  # xdg_wm_base <= 5 and sway 1.12 advertises 6, so it aborts with
  # "CBackend::create() failed!".
  #
  # So it runs only when the runner has given it an isolated Hyprland
  # (TEST_NESTED=1) and skips otherwise. What it uniquely covers -- the plugin
  # loading in a real shell -- is worth having, but not at the cost of taking
  # over someone's desktop. The behaviour it asserts is covered headlessly by
  # tst_barbuttons and tst_camerawall in the qml tier.
  if [[ "${TEST_OWNED_KIND:-}" != "nested-hyprland" || -z "${TEST_OWNED_HIS:-}" ]]; then
    ui_log "SKIP: needs an isolated Hyprland (hyprctl); sway cannot provide one."
    ui_log "      Re-run with TEST_NESTED=1 to get it -- that nests Hyprland in"
    ui_log "      your session, which blanks the screen while it runs."
    return 2
  fi

  UI_DISPLAY="$WAYLAND_DISPLAY"
  UI_HIS="$TEST_OWNED_HIS"
  ui_start_shell
  return $?
}

ui_start_shell() {
  local i
  # Deliberately not `qs -n`: the real shell is already running this same
  # config path, and -n would make this instance exit as a duplicate.
  HOME="$UI_STAGE" WAYLAND_DISPLAY="$UI_DISPLAY" \
    qs -p /usr/share/omarchy/shell >"$UI_STAGE/shell.log" 2>&1 &
  UI_SHELL_PID=$!

  for i in $(seq 1 150); do
    kill -0 "$UI_SHELL_PID" 2>/dev/null || { ui_log "shell died"; tail -10 "$UI_STAGE/shell.log"; return 1; }
    if qs ipc --pid "$UI_SHELL_PID" show 2>/dev/null | grep -q '^target io.github.trevjonez.klipper'; then
      ui_log "shell up on $UI_DISPLAY (pid $UI_SHELL_PID)"
      sleep 1   # let the bar finish its first paint
      return 0
    fi
    sleep 0.2
  done
  ui_log "plugin never registered in the nested shell"
  tail -10 "$UI_STAGE/shell.log"
  return 1
}

ui_ipc() { qs ipc --pid "$UI_SHELL_PID" call io.github.trevjonez.klipper "$@" >/dev/null 2>&1; }

# Number of popup surfaces this plugin currently has mapped in the nested
# compositor.
#
# Assertions in this tier are structural rather than pixel-based. The nested
# output inherits the host window's size so stored golden images would be
# machine-specific, and the popup card does not rasterise in a nested session
# even though its layer surface maps correctly -- but the layer surface is
# exactly what "the popup is open" means, and it is stable everywhere.
ui_panel_layers() {
  WAYLAND_DISPLAY="$UI_DISPLAY" HYPRLAND_INSTANCE_SIGNATURE="$UI_HIS" \
    hyprctl layers 2>/dev/null | grep -c "namespace: omarchy-keyboard-panel"
}

# The all-cameras wall and the fullscreen feed are their own layer surfaces,
# distinct from the popups, so each can be counted independently.
ui_wall_layers() {
  WAYLAND_DISPLAY="$UI_DISPLAY" HYPRLAND_INSTANCE_SIGNATURE="$UI_HIS" \
    hyprctl layers 2>/dev/null | grep -c "namespace: omarchy-klipper-wall"
}

ui_fullscreen_layers() {
  WAYLAND_DISPLAY="$UI_DISPLAY" HYPRLAND_INSTANCE_SIGNATURE="$UI_HIS" \
    hyprctl layers 2>/dev/null | grep -c "namespace: omarchy-klipper-fullscreen"
}

ui_assert_count() {
  local want="$1" got="$2" label="$3"
  if [[ "$got" == "$want" ]]; then ui_log "ok: $label"; return 0; fi
  ui_log "FAIL: $label -- expected $want, found $got"
  return 1
}

ui_assert_layers() {
  local want="$1" label="$2" got
  got="$(ui_panel_layers)"
  if [[ "$got" == "$want" ]]; then ui_log "ok: $label"; return 0; fi
  ui_log "FAIL: $label -- expected $want popup surface(s), found $got"
  return 1
}

# Screenshot kept for eyeballing a failure, not for assertions.
ui_shot() {
  WAYLAND_DISPLAY="$UI_DISPLAY" grim "/tmp/klipper-ui-$1.png" 2>/dev/null
}
