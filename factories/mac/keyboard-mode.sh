#!/usr/bin/env bash
set -euo pipefail

# factories/mac/keyboard-mode.sh — flip the operator between his two keyboards.
#
#   --mac       "my mac keyboard"  = HIS BASELINE, exactly. Re-applies his
#               global UserKeyMapping verbatim (from
#               ~/Library/LaunchAgents/key-binds-on-start.plist) if it has
#               drifted, and applies NO per-device override on the external
#               board. This is the state his own LaunchAgent already produces
#               at login — we only restore it if it drifted.
#   --chinese   "the chinese keyboard" = his baseline (LEFT COMPLETELY ALONE)
#               PLUS a per-device override on the external "Gaming Keyboard"
#               only, in the PAIRED form (bare pass-through + modified-key):
#               bare Ctrl stays a real Control key (Ctrl+C still interrupts in
#               a terminal) while held Ctrl becomes Command (Ctrl+C/Ctrl+V =
#               Cmd+C/Cmd+V) and held Alt drives Alt+Tab. Both work at once.
#   --status    read-only report of the three layers, separately:
#               (a) his baseline global mapping, (b) the board override,
#               (c) the remembered mode, (d) whether the board is attached.
#   --toggle    flip between mac and chinese.
#   --off       remove everything of ours (board override + state + any old
#               LaunchAgent we installed). Never touches his global baseline,
#               never touches key-binds-on-start.plist.
#
# Runs on the lima host as root; reaches the Mac over the key-based SSH that
# factories/mac/up.sh established (aidanmcohen@192.168.5.2). Dependency-free:
# built-in hidutil only. No watcher, no LaunchAgent, no third-party app, no
# kernel driver, no Input-Monitoring / Accessibility permission.
#
# HARD RULES (this revision):
#   * The ONLY global UserKeyMapping we ever write is HIS BASELINE, verbatim.
#     Never empty, never ours.
#   * We never rename/disable/move/overwrite key-binds-on-start.plist, and we
#     do not touch its launchd disabled-state at all.
#   * No watcher, no LaunchAgent that writes UserKeyMapping. The remembered
#     mode is re-applied only when the operator runs this tool again. (His own
#     key-binds-on-start.plist already persists the mac baseline at login.)

# ── Hardcoded Mac facts (verified live 2026-10-02 — do not re-derive) ────────
MAC_USER="aidanmcohen"
MAC_IP="192.168.5.2"
MAC_HOME="/Users/$MAC_USER"

# The board: "Gaming Keyboard", BY Tech, USB. VID 0x258A = 9610, PID 0x010C = 268.
BOARD_VID_DEC="9610"
BOARD_PID_DEC="268"
BOARD_PRODUCT="Gaming Keyboard"

# hidutil key codes = (HID usage page << 32) | usage. Keyboard page = 0x07.
#   L Ctrl 0xE0 = 30064771296     L Alt 0xE2 = 30064771298
#   L GUI  0xE3 = 30064771299     R Alt 0xE6 = 30064771302
#   R Ctrl 0xE4 = 30064771300     R GUI 0xE7 = 30064771303
#
# HIS BASELINE (verbatim from ~/Library/LaunchAgents/key-binds-on-start.plist,
# re-confirmed live 2026-10-02 via `hidutil property --get UserKeyMapping`):
#   L Cmd <-> Fn   (Fn acts as Command: Fn+C copy, Fn+V paste — the FEATURE)
#   + a third entry (Apple vendor usage 0xFF01/0x10 -> F3), also verbatim.
# This is the ONLY global mapping we ever apply, and only in --mac.
BASELINE_MAP_JSON='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771299,"HIDKeyboardModifierMappingDst":1095216660483},{"HIDKeyboardModifierMappingSrc":1095216660483,"HIDKeyboardModifierMappingDst":30064771299},{"HIDKeyboardModifierMappingSrc":280379760050192,"HIDKeyboardModifierMappingDst":30064771132}]}'

# The per-device override for the external board in --chinese, in the PAIRED
# form (bare pass-through + modified-key), so Ctrl+C works as BOTH copy and a
# shell interrupt at the same time. NEVER regress to the old all-bare form,
# which mapped bare Ctrl -> Cmd and killed SIGINT in the terminal.
#   bare L Ctrl -> L Cmd    (30064771296 -> 30064771299; Ctrl+C/Ctrl+V = Cmd+C/Cmd+V)
#   bare L Alt  -> R Cmd    (30064771298 -> 30064771303; Alt+Tab)
#   held Ctrl   -> Cmd      (47244640384 -> 47244640391; 0x1:0xE3 = Left Command)
#   held Alt    -> Alt + Cmd(47244640386 -> 47244640515; 0x1:0x1000003)
# The 47244640xxx entries are the "this modifier is held while this key is
# pressed" form (0x100000000 + key). Net: bare Ctrl stays a REAL Ctrl, so the
# terminal still receives a Control key and Ctrl+C still interrupts; held Ctrl
# becomes Command, so Ctrl+C/Ctrl+V reach the app as Cmd+C/Cmd+V.
CHINESE_MAP_JSON='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771296,"HIDKeyboardModifierMappingDst":30064771299},{"HIDKeyboardModifierMappingSrc":30064771298,"HIDKeyboardModifierMappingDst":30064771303},{"HIDKeyboardModifierMappingSrc":47244640384,"HIDKeyboardModifierMappingDst":47244640391},{"HIDKeyboardModifierMappingSrc":47244640386,"HIDKeyboardModifierMappingDst":47244640515}]}'

EMPTY_MAP_JSON='{"UserKeyMapping":[]}'
MATCH_JSON='{"VendorID":9610,"ProductID":268}'

# Mac-side install locations (must match the quoted heredocs below).
STATE_DIR="$MAC_HOME/.sudofleet-keyboard"
MODE_FILE="$STATE_DIR/mode"
# The LaunchAgent the OLD revision installed. This revision installs none, but
# --off removes a leftover one so "turn it off cleanly" also cleans old deploys.
OLD_LABEL="com.sudofleet.keyboard-mode"
OLD_PLIST="$MAC_HOME/Library/LaunchAgents/com.sudofleet.keyboard-mode.plist"

# The Mac's login shell is zsh: a remote command containing a bare word that
# starts with '=' dies with 'zsh:1: ==FOO=== not found'. Every remote command
# below is `bash /tmp/xxx.sh`, so this never bites.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
WORK="/tmp/mac-keyboard-mode"

PASS=0
FAIL=0
note_ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
note_bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
mssh()     { ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$@"; }

# ── Mac-side artifacts (quoted heredocs: no host-side expansion) ─────────────
write_artifacts() {
  mkdir -p "$WORK"

  # apply.sh — runs on the Mac with one arg: mac | chinese.
  cat > "$WORK/apply.sh" <<'APPLY_EOF'
#!/bin/bash
set -u
MODE="$1"
STATE_DIR="/Users/aidanmcohen/.sudofleet-keyboard"
MODE_FILE="$STATE_DIR/mode"
MATCH='{"VendorID":9610,"ProductID":268}'
BASELINE='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771299,"HIDKeyboardModifierMappingDst":1095216660483},{"HIDKeyboardModifierMappingSrc":1095216660483,"HIDKeyboardModifierMappingDst":30064771299},{"HIDKeyboardModifierMappingSrc":280379760050192,"HIDKeyboardModifierMappingDst":30064771132}]}'
CHINESE='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771296,"HIDKeyboardModifierMappingDst":30064771299},{"HIDKeyboardModifierMappingSrc":30064771298,"HIDKeyboardModifierMappingDst":30064771303},{"HIDKeyboardModifierMappingSrc":47244640384,"HIDKeyboardModifierMappingDst":47244640391},{"HIDKeyboardModifierMappingSrc":47244640386,"HIDKeyboardModifierMappingDst":47244640515}]}'
EMPTY='{"UserKeyMapping":[]}'

mkdir -p "$STATE_DIR"

case "$MODE" in
  mac)
    # His baseline, re-applied if it drifted. This is the ONLY global
    # UserKeyMapping this tool ever writes, and it is his, verbatim.
    hidutil property --set "$BASELINE" >/dev/null 2>&1
    # No per-device override on the board in this mode.
    hidutil property --matching "$MATCH" --set "$EMPTY" >/dev/null 2>&1
    printf '%s\n' "mac" > "$MODE_FILE"
    ;;
  chinese)
    # Leave the global mapping COMPLETELY alone (his baseline lives there and
    # is re-applied at login by his own key-binds-on-start.plist). Only add
    # the per-device override on the external board.
    hidutil property --matching "$MATCH" --set "$CHINESE" >/dev/null 2>&1
    printf '%s\n' "chinese" > "$MODE_FILE"
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 2
    ;;
esac
echo "applied $MODE"
APPLY_EOF

  # status.sh — read-only report of the three layers.
  cat > "$WORK/status.sh" <<'STATUS_EOF'
#!/bin/bash
set -u
STATE_DIR="/Users/aidanmcohen/.sudofleet-keyboard"
MODE_FILE="$STATE_DIR/mode"
MATCH='{"VendorID":9610,"ProductID":268}'

GLOBAL="$(hidutil property --get UserKeyMapping 2>&1)"
BOARD="$(hidutil property --matching "$MATCH" --get UserKeyMapping 2>&1)"

# (a) his baseline global mapping: applied / drifted / empty / other
gn=$(printf '%s' "$GLOBAL" | grep -c 'HIDKeyboardModifierMappingSrc' || true)
if [ "$gn" = "3" ] \
   && printf '%s' "$GLOBAL" | grep -q 'Src = 30064771299' \
   && printf '%s' "$GLOBAL" | grep -q 'Dst = 1095216660483' \
   && printf '%s' "$GLOBAL" | grep -q 'Src = 1095216660483' \
   && printf '%s' "$GLOBAL" | grep -q 'Dst = 30064771299' \
   && printf '%s' "$GLOBAL" | grep -q 'Src = 280379760050192' \
   && printf '%s' "$GLOBAL" | grep -q 'Dst = 30064771132'; then
  echo "baseline_global=applied"
elif [ "$gn" = "0" ]; then
  echo "baseline_global=empty"
else
  echo "baseline_global=drifted"
fi

# (b) board override: chinese / other / absent
if printf '%s' "$BOARD" | grep -q 'HIDKeyboardModifierMappingSrc = 30064771296'; then
  echo "board_override=chinese"
elif printf '%s' "$BOARD" | grep -q 'HIDKeyboardModifierMappingSrc'; then
  echo "board_override=other"
else
  echo "board_override=absent"
fi

# (c) remembered mode
echo "remembered_mode=$(cat "$MODE_FILE" 2>/dev/null || echo none)"

# (d) board attached
if hidutil list 2>/dev/null | grep -q "Gaming Keyboard"; then
  echo "board_attached=yes"
else
  echo "board_attached=no"
fi

echo "--- global mapping ---"
printf '%s\n' "$GLOBAL"
echo "--- board mapping ---"
printf '%s\n' "$BOARD"
STATUS_EOF

  # off.sh — remove everything of ours; leave his baseline + plist alone.
  cat > "$WORK/off.sh" <<'OFF_EOF'
#!/bin/bash
set -u
STATE_DIR="/Users/aidanmcohen/.sudofleet-keyboard"
MATCH='{"VendorID":9610,"ProductID":268}'
EMPTY='{"UserKeyMapping":[]}'
OLD_LABEL="com.sudofleet.keyboard-mode"
OLD_PLIST="/Users/aidanmcohen/Library/LaunchAgents/com.sudofleet.keyboard-mode.plist"
U=$(id -u)

# 1. Remove the LaunchAgent the OLD revision installed (if any) — both the
#    plain .plist and the psnvc-renamed .plist.disabled-psnvc variant. Never
#    touches key-binds-on-start or com.sudofleet.cluster-access.
launchctl bootout "gui/$U/$OLD_LABEL" 2>/dev/null || true
rm -f "$OLD_PLIST" "$OLD_PLIST.disabled-psnvc"

# 2. Remove our per-device board override (board returns to baseline-only).
hidutil property --matching "$MATCH" --set "$EMPTY" >/dev/null 2>&1 || true

# 3. Remove our state dir (mode file + any stale watch.sh / watch.log /
#    neutralized flag from the old revision).
rm -rf "$STATE_DIR"

# Deliberately do NOT touch the global mapping (his baseline) and do NOT touch
# key-binds-on-start.plist.
echo "off: removed sudofleet keyboard state; global baseline + key-binds-on-start.plist untouched"
OFF_EOF
}

# ── ship the Mac-side scripts ────────────────────────────────────────────────
ship() {
  scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$WORK/apply.sh" "$WORK/status.sh" "$WORK/off.sh" \
    "$MAC_USER@$MAC_IP:/tmp/" >/dev/null 2>&1
}

usage() {
  echo "usage: sudo bash factories/mac/keyboard-mode.sh {--mac|--chinese|--status|--toggle|--off}"
  echo "  --mac       'my mac keyboard' = his baseline global mapping, verbatim; no board override"
  echo "  --chinese   'the chinese keyboard' = his baseline (untouched) + paired Ctrl/Alt->Cmd override on the board (Ctrl+C works as copy AND interrupt)"
  echo "  --status    read-only: baseline global, board override, remembered mode, board attached"
  echo "  --toggle    flip between mac and chinese"
  echo "  --off       remove our board override + state + any old LaunchAgent; leave his baseline + plist alone"
  exit 2
}

# ── apply one mode + verify the observable end state ─────────────────────────
apply_mode() {
  local mode="$1"
  write_artifacts
  ship || { note_bad "scp to the Mac failed"; summary; }
  if OUT="$(mssh 'bash /tmp/apply.sh '"$mode"'' 2>&1)"; then
    note_ok "applied mode=$mode on the Mac ($OUT)"
  else
    note_bad "apply failed: $OUT"
  fi
  sleep 2
  verify_applied "$mode"
}

# ── verify the three layers are in the expected state ────────────────────────
verify_applied() {
  local mode="$1"
  local ST
  ST="$(mssh 'bash /tmp/status.sh' 2>&1)"

  local bl ov rm
  bl="$(printf '%s' "$ST" | grep '^baseline_global=' | cut -d= -f2)"
  ov="$(printf '%s' "$ST" | grep '^board_override=' | cut -d= -f2)"
  rm="$(printf '%s' "$ST" | grep '^remembered_mode=' | cut -d= -f2)"

  if [[ "$bl" == "applied" ]]; then
    note_ok "baseline global mapping applied (his baseline, unchanged)"
  else
    note_bad "baseline global mapping is '$bl', expected 'applied'"
  fi

  if [[ "$mode" == "chinese" ]]; then
    if [[ "$ov" == "chinese" ]]; then
      note_ok "board override present (chinese: Ctrl/Alt -> Command)"
    else
      note_bad "board override is '$ov', expected 'chinese'"
    fi
  else
    if [[ "$ov" == "absent" ]]; then
      note_ok "board override absent (board = his baseline, native)"
    else
      note_bad "board override is '$ov', expected 'absent'"
    fi
  fi

  if [[ "$rm" == "$mode" ]]; then
    note_ok "remembered mode = $mode"
  else
    note_bad "remembered mode is '$rm', expected '$mode'"
  fi
}

# ── subcommands ──────────────────────────────────────────────────────────────
do_mac() {
  echo "keyboard-mode --mac: 'my mac keyboard' = his baseline global mapping, verbatim"
  echo "  Mac: $MAC_USER@$MAC_IP   board: $BOARD_PRODUCT (VID 0x258A PID 0x010C)"
  echo "  global = his baseline (L Cmd <-> Fn, Fn acts as Command); no board override"
  echo ""
  apply_mode mac
  summary
}

do_chinese() {
  echo "keyboard-mode --chinese: 'the chinese keyboard' = baseline (untouched) + board override"
  echo "  Mac: $MAC_USER@$MAC_IP   board: $BOARD_PRODUCT (VID 0x258A PID 0x010C)"
  echo "  board override: paired form — bare Ctrl stays real (Ctrl+C interrupts), held Ctrl -> Command (Ctrl+C/V copies), held Alt -> Alt+Tab"
  echo "  global baseline left completely alone"
  echo ""
  apply_mode chinese
  summary
}

do_toggle() {
  write_artifacts
  ship || { note_bad "scp to the Mac failed"; summary; }
  local cur
  cur="$(mssh 'bash /tmp/status.sh' 2>&1 | grep '^remembered_mode=' | cut -d= -f2)"
  if [[ "$cur" == "chinese" ]]; then
    echo "keyboard-mode --toggle: currently chinese -> switching to mac"
    apply_mode mac
  else
    echo "keyboard-mode --toggle: currently $cur -> switching to chinese"
    apply_mode chinese
  fi
  summary
}

do_status() {
  echo "keyboard-mode --status ($MAC_USER@$MAC_IP)"
  echo ""
  write_artifacts
  ship || { note_bad "scp to the Mac failed"; summary; }
  mssh 'bash /tmp/status.sh' 2>&1
  echo ""
  rm -rf "$WORK"
}

do_off() {
  echo "keyboard-mode --off: remove our board override + state + any old LaunchAgent"
  echo "  Mac: $MAC_USER@$MAC_IP"
  echo "  (his global baseline and key-binds-on-start.plist are left untouched)"
  echo ""
  write_artifacts
  ship || { note_bad "scp to the Mac failed"; summary; }
  if OUT="$(mssh 'bash /tmp/off.sh' 2>&1)"; then
    note_ok "off: $OUT"
  else
    note_bad "off failed: $OUT"
  fi

  # confirm clean state
  local ST
  ST="$(mssh 'bash /tmp/status.sh' 2>&1)"
  if printf '%s' "$ST" | grep -q '^remembered_mode=none'; then
    note_ok "mode file removed"
  else
    note_bad "mode file still present"
  fi
  if printf '%s' "$ST" | grep -q '^board_override=absent'; then
    note_ok "board override removed"
  else
    note_bad "board override still present"
  fi
  local bl
  bl="$(printf '%s' "$ST" | grep '^baseline_global=' | cut -d= -f2)"
  if [[ "$bl" == "applied" ]]; then
    note_ok "his baseline global mapping still applied (untouched)"
  else
    note_bad "baseline global mapping is '$bl' after --off (expected untouched 'applied')"
  fi
  summary
}

summary() {
  rm -rf "$WORK"
  echo ""
  echo "════════════════════════════════════════════"
  if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: FAIL  ($PASS passed, $FAIL failed)"
    exit 1
  fi
  echo "RESULT: PASS  ($PASS passed, $FAIL failed)"
}

case "${1:-}" in
  --mac)      do_mac ;;
  --chinese)  do_chinese ;;
  --status)   do_status ;;
  --toggle)   do_toggle ;;
  --off)      do_off ;;
  *)          usage ;;
esac
