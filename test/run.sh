#!/usr/bin/env bash
# Test runner for the Klipper Omarchy plugin.
#
#   ./test/run.sh              unit + qml (the default suite)
#   ./test/run.sh --unit       Model.js only; needs nothing but node
#   ./test/run.sh --qml        integration only; needs a Wayland session
#   ./test/run.sh --ui         popup/window tests in a nested shell
#   ./test/run.sh --lint       qmllint + omarchy-plugin-validate
#   ./test/run.sh --all        everything
#
# The qml tier hosts the real components in `qs` against a mock Moonraker, so
# the websocket, curl and inotify paths run for real. It needs a Wayland
# display; without one the runner starts a headless Hyprland just for the run
# (see lib/headless.sh) so the suite also works over SSH or in CI.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_UNIT=0 RUN_QML=0 RUN_UI=0 RUN_LINT=0 UPDATE_GOLDENS=0
if [[ $# -eq 0 ]]; then
  RUN_UNIT=1 RUN_QML=1
else
  for arg in "$@"; do
    case "$arg" in
      --unit) RUN_UNIT=1 ;;
      --qml) RUN_QML=1 ;;
      --ui) RUN_UI=1 ;;
      --lint) RUN_LINT=1 ;;
      --all) RUN_UNIT=1 RUN_QML=1 RUN_UI=1 RUN_LINT=1 ;;
      --update-goldens) UPDATE_GOLDENS=1 ;;
      *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
  done
fi
export UPDATE_GOLDENS

FAILED=0
section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail()    { printf '\033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
pass()    { printf '\033[32mok\033[0m   %s\n' "$1"; }

# ---------------------------------------------------------------- lint

if [[ $RUN_LINT -eq 1 ]]; then
  section "lint"
  # Panel.qml is skipped deliberately: qmllint exits 255 with no diagnostic on
  # ANY file declaring IpcHandler (reproducible in a two-line file), so linting
  # it would report a failure that says nothing. It is covered by the ui tier
  # and by loading it in the shell instead.
  for f in CameraView.qml CameraWall.qml FullscreenVideo.qml GcodeWatcher.qml PrinterConnection.qml PrinterIcon.qml Service.qml; do
    if qmllint -I /usr/share/omarchy/shell -I /usr/lib/qt6/qml "$f" >/dev/null 2>&1; then
      pass "qmllint $f"
    else
      qmllint -I /usr/share/omarchy/shell -I /usr/lib/qt6/qml "$f"
      fail "qmllint $f"
    fi
  done
  if omarchy-plugin-validate . >/dev/null 2>&1; then pass "omarchy-plugin-validate"
  else omarchy-plugin-validate .; fail "omarchy-plugin-validate"; fi
fi

# ---------------------------------------------------------------- unit

if [[ $RUN_UNIT -eq 1 ]]; then
  section "unit (Model.js)"
  if node --test "test/unit/*.test.js"; then pass "node --test"; else fail "node --test"; fi
fi

# ---------------------------------------------------------------- qml

# Stages the components plus the harness and one scenario into a scratch dir,
# starts a mock Moonraker on an ephemeral port, and runs it under qs. Staging
# is required, not tidiness: Quickshell replaces any QML resolved from outside
# the config folder with `qrc:/qs-blackhole`, so the components have to sit
# beside the test that imports them.
run_qml_test() {
  local test_file="$1" name port stage log rc
  name="$(basename "$test_file" .qml)"
  stage="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" RETURN

  # A test that instantiates Panel.qml needs qs.Ui / qs.Commons, which
  # Quickshell resolves relative to the config folder -- so the shell's module
  # tree is staged alongside the plugin (1.9MB, cheap) rather than imported
  # from /usr/share, which the blackhole rule would reject.
  if [[ -f "test/qml/$name.needs-shell" ]]; then
    cp -r /usr/share/omarchy/shell/. "$stage/" 2>/dev/null
    cp CameraView.qml PrinterIcon.qml Panel.qml FullscreenVideo.qml CameraWall.qml "$stage/"
  fi

  cp Model.js PrinterConnection.qml GcodeWatcher.qml Service.qml "$stage/"
  cp test/qml/Harness.qml "$stage/"
  cp "$test_file" "$stage/"
  mkdir -p "$stage/home" "$stage/watch" "$stage/bin"
  cp test/mock/bin/omarchy-notification-send "$stage/bin/"

  # Per-test scenario knobs live next to the test as name.env.
  local envfile="test/qml/$name.env"
  local -a mock_env=()
  if [[ -f "$envfile" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      mock_env+=("$line")
    done < "$envfile"
  fi

  REQUEST_LOG="$stage/requests.jsonl" env "${mock_env[@]}" \
    REQUEST_LOG="$stage/requests.jsonl" MOCK_PORT=0 \
    node test/mock/moonraker.js > "$stage/port.txt" 2>"$stage/mock.err" &
  local mock_pid=$!

  # Wait for the mock to announce its port rather than sleeping a fixed time.
  port=""
  for _ in $(seq 1 100); do
    port="$(head -1 "$stage/port.txt" 2>/dev/null)"
    [[ -n "$port" ]] && break
    sleep 0.05
  done
  if [[ -z "$port" ]]; then
    kill "$mock_pid" 2>/dev/null
    fail "$name (mock never started: $(cat "$stage/mock.err" 2>/dev/null | head -2))"
    return
  fi

  log="$stage/out.log"
  MOCK_PORT="$port" \
  STAGE="$stage" \
  WATCH_DIR="$stage/watch" \
  NOTIFY_LOG="$stage/notifications.log" \
  REQUEST_LOG="$stage/requests.jsonl" \
  HOME="$stage/home" \
  PATH="$stage/bin:$PATH" \
    timeout 60 qs -p "$stage/$name.qml" >"$log" 2>&1
  rc=$?

  kill "$mock_pid" 2>/dev/null
  wait "$mock_pid" 2>/dev/null

  # qs logs QML console output with a DEBUG prefix; pull out our result lines.
  grep -oE '(PASS|FAIL|DONE) .*' "$log" | sed 's/^/    /'

  if [[ $rc -ne 0 ]]; then
    fail "$name (qs exit $rc)"
    # Anything the test logged that wasn't a result line, plus engine errors:
    # without this a console.log added while debugging is silently swallowed.
    grep -E 'ERROR|Error|qs-blackhole|DEBUG.*qml' "$log" \
      | grep -vE '(PASS|FAIL|DONE) ' | head -10 | sed 's/^/    | /'
    return
  fi

  # Optional second half: assert on what the server was actually asked for.
  if [[ -f "test/qml/$name.expect.js" ]]; then
    if REQUEST_LOG="$stage/requests.jsonl" NOTIFY_LOG="$stage/notifications.log" \
       node "test/qml/$name.expect.js"; then
      pass "$name (+ request log)"
    else
      fail "$name (request log)"
    fi
  else
    pass "$name"
  fi
}

if [[ $RUN_QML -eq 1 || $RUN_UI -eq 1 ]]; then
  # shellcheck source=lib/headless.sh
  source "$ROOT/test/lib/headless.sh"
  ensure_display || { echo "cannot obtain a Wayland display; skipping qml/ui tiers" >&2; exit 1; }
fi

if [[ $RUN_QML -eq 1 ]]; then
  section "qml integration (mock Moonraker)"
  for t in test/qml/tst_*.qml; do
    [[ -e "$t" ]] || continue
    run_qml_test "$t"
  done
fi

# ---------------------------------------------------------------- ui

if [[ $RUN_UI -eq 1 ]]; then
  section "ui (nested shell)"
  # Every test here drives the shell over IPC, so nothing needs ydotool or the
  # system-wide uinput rule it requires. Mouse-button dispatch on the bar pill
  # is covered in the qml tier by tst_barbuttons, which calls the same
  # triggerPress() the pill's own MouseArea calls.
  for t in test/ui/tst_*.sh; do
    [[ -e "$t" ]] || continue
    bash "$t"; local_rc=$?
    case $local_rc in
      0) pass "$(basename "$t" .sh)" ;;
      2) printf '\033[33mskip\033[0m %s\n' "$(basename "$t" .sh)" ;;
      *) fail "$(basename "$t" .sh)" ;;
    esac
  done
fi

printf '\n'
if [[ $FAILED -eq 0 ]]; then printf '\033[32mall green\033[0m\n'; else printf '\033[31mfailures above\033[0m\n'; fi
exit $FAILED
