# Obtains a Wayland display for the qs-hosted tests.
#
# `qs` aborts with "cannot open display" without one. Three cases:
#
#   1. A session is already running -- use it. The tests spawn their own qs
#      instances against a mock server and never touch the real bar, so this
#      is both safe and much faster than starting another compositor.
#   2. TEST_NESTED=1 -- start a nested compositor inside that session and run
#      there instead. Used by the ui tier, so synthetic clicks land in an
#      isolated compositor rather than on the developer's real windows.
#   3. No session at all (SSH, CI) -- start a headless compositor.
#
# Case 3 needs cage or sway. Hyprland cannot do it: since 0.4x it uses
# Aquamarine rather than wlroots, WLR_BACKENDS is ignored, and with no seat to
# attach to it aborts with "CBackend::create() failed!" (verified on 0.56.2).
# Hyprland works fine *nested*, which is why case 2 still uses it.

HEADLESS_PID=""

_headless_teardown() {
  if [[ -n "$HEADLESS_PID" ]]; then
    kill "$HEADLESS_PID" 2>/dev/null
    wait "$HEADLESS_PID" 2>/dev/null
    HEADLESS_PID=""
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
    cage)
      WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
        cage -- sleep infinity >"$logdir/comp.log" 2>&1 &
      ;;
    sway)
      WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
        sway -c /dev/null >"$logdir/comp.log" 2>&1 &
      ;;
  esac
  HEADLESS_PID=$!
  _await_new_socket "$before" "$logdir/comp.log" || return 1
  echo "started $kind on $WAYLAND_DISPLAY (pid $HEADLESS_PID)"
}

ensure_display() {
  local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local have_session=0
  [[ -n "${WAYLAND_DISPLAY:-}" && -S "$runtime/${WAYLAND_DISPLAY}" ]] && have_session=1

  if [[ $have_session -eq 1 && "${TEST_NESTED:-0}" != "1" ]]; then
    return 0
  fi

  if [[ $have_session -eq 1 ]]; then
    # Nesting for isolation; Hyprland is fine as a nested client.
    command -v Hyprland >/dev/null && _start_compositor nested-hyprland && return 0
    echo "TEST_NESTED=1 but no nestable compositor found; using the current session" >&2
    return 0
  fi

  for kind in cage sway; do
    command -v "$kind" >/dev/null && _start_compositor "$kind" && return 0
  done

  cat >&2 <<'MSG'
No Wayland session, and no compositor available to start one.

  qs needs a display, and Hyprland cannot provide one headlessly: since it
  moved to Aquamarine it ignores WLR_BACKENDS and aborts without a seat.

  Install a headless-capable compositor to run this tier over SSH or in CI:

      sudo pacman -S cage

  Or run the suite from inside a desktop session. The unit tier needs none
  of this: ./test/run.sh --unit
MSG
  return 1
}
