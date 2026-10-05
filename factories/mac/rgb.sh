#!/usr/bin/env bash
set -euo pipefail

# factories/mac/rgb.sh — reactive RGB for the external SinoWealth "Gaming
# Keyboard" (VID 0x258A / PID 0x010C, AULA F75, model id 0xCD).
#
# Runs on the lima host as root, reaches the Mac over the key-based SSH that
# factories/mac/up.sh established (aidanmcohen@192.168.5.2). On the Mac it
# compiles the Swift program rgb.swift and drives the board's single 520-byte
# HID feature report (report id 0x06) for per-LED colour, plus an IOHIDManager
# input callback for live keypresses.
#
# Subcommands:
#   start [R G B]    launch the reactive effect: idle colour + white ripple on
#                    keypress (default idle 20 40 120). Detached on the Mac.
#   stop             stop the running effect (pid file + pkill), confirm gone.
#   solid R G B      steady solid colour (detached, until stop).
#   off              lights out (black, detached, until stop).
#   probe            read-only: enumerate interfaces + query the model id.
#   selftest         prove GET+SET+INPUT live: model id, colour frames, 6s listen.
#   map [--auto N]   light each LED one at a time (advance on keypress, or fixed
#                    N ms) to build/confirm the LED index -> key map.
#   status           running-or-not + tail the effect log.
#
# No sudo on the Mac: IOHIDManager reads raw HID input and IOHIDDeviceSetReport
# writes feature reports as the plain ssh user (verified live). No LaunchAgent,
# no KeepAlive, no watcher, no persistence — the effect is a plain foreground
# process (Aidan can run /tmp/rgb directly and Ctrl+C it). This script never
# touches hidutil UserKeyMapping or key-binds-on-start.plist.

# ── Hardcoded Mac facts (verified live 2026-10-05 — do not re-derive) ────────
MAC_USER="aidanmcohen"
MAC_IP="192.168.5.2"
MAC_SWIFT="/tmp/rgb.swift"
MAC_BIN="/tmp/rgb"
MAC_PID="/tmp/rgb.pid"
DEFAULT_LOG="/tmp/rgb.log"

TARGET_VID="0x258A"
TARGET_PID="0x010C"
PROC_NAME="rgb"

DEFAULT_IDLE="20 40 120"

# The Mac's login shell is zsh: a remote command containing a bare word that
# starts with '=' (e.g. echo ===FOO===) dies with 'zsh:1: ==FOO=== not found'.
# Everything below avoids '=' markers.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RGB_SWIFT="$SCRIPT_DIR/rgb/rgb.swift"

# ── helpers ───────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
note_ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
note_bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

ssh_run() { ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$1"; }
is_running() { ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "pgrep -x $PROC_NAME >/dev/null 2>&1" 2>/dev/null; }

abort_if_failed() {
  if [[ "$FAIL" -gt 0 ]]; then
    echo "ABORTED — $FAIL check(s) failed"
    exit 1
  fi
}

summary() {
  echo ""
  echo "════════════════════════════════════════════"
  if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: FAIL  ($PASS passed, $FAIL failed)"
    exit 1
  fi
  echo "RESULT: PASS  ($PASS passed, $FAIL failed)"
}

usage() {
  echo "usage: sudo bash factories/mac/rgb.sh {start [R G B]|stop|solid R G B|off|probe|selftest|map [--auto N]|status}"
  exit 2
}

# ── write_and_compile: ship rgb.swift to the Mac and compile it ───────────────
write_and_compile() {
  if [[ ! -f "$RGB_SWIFT" ]]; then
    echo "  ✗ source not found: $RGB_SWIFT"
    exit 1
  fi
  if ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "cat > '$MAC_SWIFT'" < "$RGB_SWIFT" \
      && ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "swiftc -swift-version 5 -O '$MAC_SWIFT' -o '$MAC_BIN'"; then
    note_ok "rgb.swift compiled to $MAC_BIN on the Mac"
  else
    note_bad "swift compile failed on the Mac (see error above)"
  fi
}

# ── launch a colour/effect command detached (nohup + pid file) ────────────────
launch_detached() {
  local MODE="$1"; shift
  local LOG="${1:-$DEFAULT_LOG}"
  echo "rgb: $MODE  ($MAC_USER@$MAC_IP, vid=$TARGET_VID pid=$TARGET_PID)"
  echo "  log: $LOG (on the Mac)"

  if is_running; then
    echo "  ✗ already running ($PROC_NAME) — run 'stop' first"
    exit 1
  fi

  write_and_compile
  abort_if_failed

  # sanity: confirm the RGB interface is attached before launching
  if ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$MAC_BIN probe 2>&1 | grep -q 'model_id ='"; then
    note_ok "RGB interface attached (model id query answered)"
  else
    note_bad "RGB interface not reachable (probe failed)"
  fi
  abort_if_failed

  if ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" \
      "nohup '$MAC_BIN' $MODE > '$LOG' 2>&1 & echo \$! > '$MAC_PID'" 2>/dev/null; then
    note_ok "launched ($MODE) — pid recorded at $MAC_PID on the Mac"
  else
    note_bad "failed to launch $MODE"
  fi

  sleep 2
  if is_running; then
    note_ok "process $PROC_NAME is running"
  else
    note_bad "process $PROC_NAME not running after launch — log tail: $(ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "tail -3 '$LOG' 2>/dev/null" 2>/dev/null | tr '\n' ' ')"
  fi
  summary
}

# ── stop ──────────────────────────────────────────────────────────────────────
do_stop() {
  echo "rgb: stop the effect on the Mac ($MAC_USER@$MAC_IP)"
  if ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" \
      "if [ -f '$MAC_PID' ]; then kill -INT \$(cat '$MAC_PID') 2>/dev/null || true; rm -f '$MAC_PID'; fi; pkill -x '$PROC_NAME' 2>/dev/null || true" 2>/dev/null; then
    note_ok "sent stop (pid file + pkill)"
  else
    note_bad "stop command failed"
  fi
  sleep 1
  if is_running; then
    note_bad "process $PROC_NAME still running"
  else
    note_ok "process $PROC_NAME stopped"
  fi
  summary
}

# ── status ────────────────────────────────────────────────────────────────────
do_status() {
  local LOG="${1:-$DEFAULT_LOG}"
  echo "rgb: status ($MAC_USER@$MAC_IP)"
  if is_running; then
    echo "  state: RUNNING"
  else
    echo "  state: NOT running"
  fi
  echo "  last lines of $LOG:"
  ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "tail -20 '$LOG' 2>/dev/null || echo '(no log yet)'" 2>/dev/null
}

# ── main ──────────────────────────────────────────────────────────────────────
CMD="${1:-}"
case "$CMD" in
  start)  launch_detached "ripple ${2:-$DEFAULT_IDLE} --fps 60" "${DEFAULT_LOG}" ;;
  solid)  launch_detached "solid $2 $3 $4" "${DEFAULT_LOG}" ;;
  off)    launch_detached "off" "${DEFAULT_LOG}" ;;
  stop)   do_stop ;;
  probe)
    write_and_compile
    abort_if_failed
    ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$MAC_BIN probe"
    ;;
  selftest)
    write_and_compile
    abort_if_failed
    ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$MAC_BIN selftest"
    ;;
  map)
    write_and_compile
    abort_if_failed
    echo "rgb: map mode — light each LED one at a time (log /tmp/rgb-map.log on the Mac)."
    echo "  Run interactively on the Mac instead if you want keypress-advance:  /tmp/rgb map"
    ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" \
      "nohup '$MAC_BIN' map ${2:+--auto $2} > /tmp/rgb-map.log 2>&1 & echo \$! > /tmp/rgb-map.pid" 2>/dev/null
    sleep 1
    note_ok "map mode launched — tail with: ssh $MAC_USER@$MAC_IP 'tail -f /tmp/rgb-map.log'"
    note_ok "stop with: sudo bash factories/mac/rgb.sh stop"
    summary
    ;;
  status) do_status "${2:-$DEFAULT_LOG}" ;;
  *) usage ;;
esac
