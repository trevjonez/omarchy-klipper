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
# floating window, so the popup and fullscreen tests fail with geometry that
# means nothing. Do not add it back as a fallback.
#
# Nesting a compositor inside the session was tried and rejected: Hyprland's
# Wayland backend maps a real window, which blacks out the screen for the
# length of the run. It remains available via TEST_NESTED=1.
#
# Hyprland cannot provide (1) at all: since 0.4x it uses Aquamarine rather than
# wlroots, WLR_BACKENDS is ignored, and with no seat to attach to it aborts
# with "CBackend::create() failed!" (verified on 0.56.2).

HEADLESS_PID=""
# Set when this script started the compositor, so the ui tier can reuse it
# instead of nesting a third one inside it.
export TEST_OWNED_DISPLAY=0
export TEST_OWNED_HIS=""

_headless_teardown() {
  if [[ -n "$HEADLESS_PID" ]]; then
    kill "$HEADLESS_PID" 2>/dev/null
    wait "$HEADLESS_PID" 2>/dev/null
    HEADLESS_PID=""
# Set when this script started the compositor, so the ui tier can reuse it
# instead of nesting a third one inside it.
export TEST_OWNED_DISPLAY=0
export TEST_OWNED_HIS=""
  fi
}

# Watches the runtime dir for a wayland socket that wasn't there before.
_await_new_socket() {
  local before="$1" runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" logfile="$2"
  for _ in $(seq 1 150); do
    if ! kill -0 "$HEADLESS_PID" 2>/dev/null; then
      echo "compositor exited immediately:" >&2
      tail -15 "$logfile" >&2
      return 1
    fi
    local now candidate
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

_start_compositor() {
  local kind="$1" conf logdir before runtime
  conf="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hyprland-headless.conf"
  logdir="$(mktemp -d)"
  runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  before="$(ls "$runtime" 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort)"

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
  esac
  HEADLESS_PID=$!
  _await_new_socket "$before" "$logdir/comp.log" || return 1
  TEST_OWNED_DISPLAY=1
  local i his_now
  for i in $(seq 1 50); do
    his_now="$(ls "$runtime/hypr" 2>/dev/null | sort)"
    TEST_OWNED_HIS="$(comm -13 <(echo "$his_before") <(echo "$his_now") | head -1)"
    [[ -n "$TEST_OWNED_HIS" ]] && break
    sleep 0.1
  done
  echo "started $kind on $WAYLAND_DISPLAY (pid $HEADLESS_PID)"
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

  Install a headless-capable compositor to run this tier over SSH or in CI:

      sudo pacman -S sway

  Or run the suite from inside a desktop session. The unit tier needs none
  of this: ./test/run.sh --unit
MSG
  return 1
}
