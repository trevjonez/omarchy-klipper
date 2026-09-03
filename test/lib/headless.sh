# Obtains a Wayland display for the qs-hosted tests.
#
# `qs` aborts with "cannot open display" without one.
#
# Preference order:
#
#   1. sway on its headless backend -- a virtual output, invisible, fully
#      isolated, and it implements wlr-layer-shell. Preferred even when a
#      desktop session is running, because these tests instantiate the real
#      FullscreenVideo, CameraWall and the shell's popups, which map
#      layer-shell surfaces that take keyboard focus as they map. Against the
#      live session that swallows whatever the developer is typing.
#   2. The current session, if sway is not installed. Works, but WILL eat the
#      occasional keystroke while the suite runs.
#
# cage is deliberately NOT used despite also having a headless backend: it is a
# kiosk compositor and does not implement wlr-layer-shell. qs reports "Failed
# to initialize layershell integration" and every panel falls back to a 500x500
# floating window, so the popup and fullscreen tests fail on geometry that
# means nothing. Do not add it back as a fallback.
#
# Hyprland cannot provide (1) at all: since 0.4x it uses Aquamarine rather than
# wlroots, WLR_BACKENDS is ignored, and with no seat to attach to it aborts
# with "CBackend::create() failed!" (verified on 0.56.2). It also cannot nest
# inside sway -- Hyprland 0.56 requires xdg_wm_base <= 5 and sway 1.12
# advertises 6 -- so the ui tier, which needs `hyprctl`, steps back onto the
# session's own Hyprland instead. See test/ui/lib.sh.

HEADLESS_PID=""

# The developer's own display, remembered before we swap in a headless one, so
# the ui tier can step back onto it (see test/ui/lib.sh).
export TEST_SESSION_DISPLAY="${WAYLAND_DISPLAY:-}"

# Which compositor this script started. The ui tier needs Hyprland
# specifically -- its assertions read mapped layer surfaces through
# `hyprctl layers`, and sway exposes no equivalent -- so it can only reuse this
# display when it is a Hyprland one.
export TEST_OWNED_KIND=""
export TEST_OWNED_HIS=""

_headless_teardown() {
  if [[ -n "$HEADLESS_PID" ]]; then
    kill "$HEADLESS_PID" 2>/dev/null
    wait "$HEADLESS_PID" 2>/dev/null
    HEADLESS_PID=""
  fi
}

# Watches the runtime dir for a wayland socket that wasn't there before.
_await_new_socket() {
  local before="$1" logfile="$2"
  local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local i now candidate
  for i in $(seq 1 150); do
    if ! kill -0 "$HEADLESS_PID" 2>/dev/null; then
      echo "compositor exited immediately:" >&2
      tail -15 "$logfile" >&2
      return 1
    fi
    now="$(ls "$runtime" 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort)"
    candidate="$(comm -13 <(echo "$before") <(echo "$now") | head -1)"
    if [[ -n "$candidate" ]]; then
      export WAYLAND_DISPLAY="$candidate"
      return 0
    fi
    sleep 0.1
  done
  echo "compositor never created a wayland socket:" >&2
  tail -15 "$logfile" >&2
  return 1
}

# Hyprland's instance signature, so `hyprctl` addresses the instance we just
# started rather than the developer's live session.
_await_hyprland_signature() {
  local before="$1"
  local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local i now
  for i in $(seq 1 50); do
    now="$(ls "$runtime/hypr" 2>/dev/null | sort)"
    TEST_OWNED_HIS="$(comm -13 <(echo "$before") <(echo "$now") | head -1)"
    [[ -n "$TEST_OWNED_HIS" ]] && return 0
    sleep 0.1
  done
  return 1
}

_start_compositor() {
  local kind="$1" conf logdir before his_before runtime
  conf="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hyprland-headless.conf"
  logdir="$(mktemp -d)"
  runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  before="$(ls "$runtime" 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort)"
  his_before="$(ls "$runtime/hypr" 2>/dev/null | sort)"

  trap _headless_teardown EXIT
  case "$kind" in
    nested-hyprland)
      # The config deliberately has no exec-once entries: pointing a nested
      # Hyprland at the user's real config would start a second full desktop.
      Hyprland -c "$conf" >"$logdir/comp.log" 2>&1 &
      ;;
    sway)
      WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
        sway -c /dev/null >"$logdir/comp.log" 2>&1 &
      ;;
    *)
      echo "unknown compositor kind: $kind" >&2
      return 1
      ;;
  esac
  HEADLESS_PID=$!
  _await_new_socket "$before" "$logdir/comp.log" || return 1

  TEST_OWNED_KIND="$kind"
  [[ "$kind" == "nested-hyprland" ]] && _await_hyprland_signature "$his_before"

  echo "started $kind on $WAYLAND_DISPLAY (pid $HEADLESS_PID)"
  return 0
}

ensure_display() {
  local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local have_session=0
  [[ -n "${WAYLAND_DISPLAY:-}" && -S "$runtime/${WAYLAND_DISPLAY}" ]] && have_session=1

  # A headless compositor is preferred even inside a session: it is a virtual
  # output, so the tests' layer-shell surfaces never reach the real desktop.
  if command -v sway >/dev/null; then
    _start_compositor sway && return 0
  fi

  if [[ $have_session -eq 1 && "${TEST_NESTED:-0}" == "1" ]]; then
    command -v Hyprland >/dev/null && _start_compositor nested-hyprland && return 0
  fi

  if [[ $have_session -eq 1 ]]; then
    echo "NOTE: no headless compositor available, running against your session." >&2
    echo "      The suite maps surfaces that take keyboard focus and may eat a" >&2
    echo "      keystroke. Install one with: sudo pacman -S sway" >&2
    return 0
  fi

  cat >&2 <<'MSG'
No Wayland session, and no compositor available to start one.

  qs needs a display, and Hyprland cannot provide one headlessly: since it
  moved to Aquamarine it ignores WLR_BACKENDS and aborts without a seat.

  Install a headless-capable compositor that implements layer-shell:

      sudo pacman -S sway

  Or run the suite from inside a desktop session. The unit tier needs none
  of this: ./test/run.sh --unit
MSG
  return 1
}
