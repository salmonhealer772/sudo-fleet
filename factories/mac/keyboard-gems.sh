#!/usr/bin/env bash
set -euo pipefail

# factories/mac/keyboard-gems.sh — the good/weird macOS keyboard features, made
# idempotent + reversible, plus a hazard detector for the exact class of
# breakage that bit us 2026-10-01 (a hidutil UserKeyMapping that remapped a
# Command key to Fn, silently killing every ⌘ shortcut).
#
# Runs on the lima host as root; reaches the Mac over the key-based SSH that
# factories/mac/up.sh established (aidanmcohen@192.168.5.2). It never needs
# sudo on the Mac (there is no passwordless sudo there), and it NEVER uses the
# global `hidutil property --set '{"UserKeyMapping":…}'` form — that form
# overwrites per-device mappings (verified 2026-10-02: a global set/clear wiped
# the operator's existing per-device Control/Option→Command remap). Every
# hidutil write here is per-device and MERGES with whatever is already present.
#
# Gems (each individually opt-in by flag; `--safe` = only the safe set):
#   --key-repeat          KeyRepeat=2, InitialKeyRepeat=15   (SAFE)
#   --press-hold          ApplePressAndHoldEnabled=false     (SAFE, lose accents)
#   --fn-standard         com.apple.keyboard.fnState=true    (DEBATABLE)
#   --capslock-escape     Caps Lock → Escape  (per-device)   (DEBATABLE)
#   --capslock-control    Caps Lock → Control (per-device)   (DEBATABLE)
#   --safe                == --key-repeat --press-hold
#   --revert [gem …]      undo ours (no arg = undo everything we applied)
#   --detect              hazard detector only (no changes)
#   --cheatsheet          print the non-obvious native shortcut sheet
#
# The hazard detector ALWAYS runs first (global + per-device UserKeyMapping),
# and warns loudly on any mapping whose source is a Command key and whose
# destination is not a Command key — i.e. anything that eats ⌘.
#
# Everything is idempotent (re-run = no change) and individually reversible.
# Prior values are recorded to ~/.sudofleet-keyboard-gems.state on the Mac so
# --revert restores exactly what was there before, not a guessed default.

# ── Hardcoded Mac facts (verified live 2026-10-02 — do not re-derive) ────────
MAC_USER="aidanmcohen"
MAC_IP="192.168.5.2"
# The operator's external keyboard ("Gaming Keyboard", BY Tech). This is the
# device whose per-device UserKeyMapping we read/merge (it already carries an
# intentional Control→Command / Option→Command remap we must preserve).
KBD_VID="0x258A"
KBD_PID="0x010C"
# State file ON THE MAC recording each gem's prior value (so --revert restores
# exactly what was there, not a guessed default).
STATE_FILE="/Users/$MAC_USER/.sudofleet-keyboard-gems.state"
# Temporary python helper shipped to the Mac for hidutil read/merge/write.
PY="/tmp/kg_hidutil.py"

# The Mac's login shell is zsh: a remote command containing a bare word that
# starts with '=' dies with 'zsh:1: ==FOO=== not found'. Every remote command
# below avoids '=' markers; complex payloads are base64'd and piped through.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

PASS=0
FAIL=0
note_ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
note_bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

mssh() { ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$@"; }

# mac_exec: run the script on stdin on the Mac via zsh (base64 transport).
mac_exec() {
  local b; b="$(base64 -w0)"
  mssh "echo '$b' | base64 -d | zsh"
}
# mac_put: write the stdin bytes to a file on the Mac (base64 transport).
mac_put() { # $1 = remote path
  local b; b="$(base64 -w0)"
  mssh "echo '$b' | base64 -d > '$1'"
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

# ── Embedded Python: hidutil read/merge/write + hazard scan ──────────────────
# Standard library only; runs on the Mac (python3 from CLT). Handles the openstep
# plist that `hidutil property --get UserKeyMapping` prints, plus the table form
# that `--matching … --get` prints. Never touches the global set form.
KG_PY=$(cat <<'PYEOF'
import subprocess, re, sys, json

MATCH = '{"VendorID":0x258A,"ProductID":0x010C}'
CMD = {"30064771299": "Left Command", "30064771303": "Right Command"}
FN  = "1095216660483"
NAMES = {
    "30064771296": "Left Control", "30064771297": "Left Shift",
    "30064771298": "Left Option",  "30064771299": "Left Command",
    "30064771300": "Right Control","30064771301": "Right Shift",
    "30064771302": "Right Option", "30064771303": "Right Command",
    "30064771129": "Caps Lock",    "30064771113": "Escape",
    "1095216660483": "Fn/Globe",
}
def name(v):
    s = str(v)
    return NAMES.get(s, "0x%X" % int(s))

def run(args):
    return subprocess.run(args, capture_output=True, text=True)

def parse_pairs(text):
    pat = re.compile(
        r"HIDKeyboardModifierMappingDst\s*=\s*(\d+);\s*"
        r"HIDKeyboardModifierMappingSrc\s*=\s*(\d+);", re.S)
    pairs, seen = [], set()
    for dst, src in pat.findall(text):
        if (src, dst) not in seen:
            seen.add((src, dst)); pairs.append((src, dst))
    return pairs

def get_global():
    return parse_pairs(run(["hidutil", "property", "--get",
                            "UserKeyMapping"]).stdout)

def get_perdevice():
    return parse_pairs(run(["hidutil", "property", "--matching", MATCH,
                            "--get", "UserKeyMapping"]).stdout)

def payload(pairs):
    arr = [{"HIDKeyboardModifierMappingSrc": int(s),
            "HIDKeyboardModifierMappingDst": int(d)} for s, d in pairs]
    return json.dumps({"UserKeyMapping": arr})

def set_perdevice(pairs):
    return run(["hidutil", "property", "--matching", MATCH, "--set",
                payload(pairs)]).returncode

def scan():
    hazards, info = [], []
    for s, d in get_global():
        if s in CMD and d not in CMD:
            hazards.append(("global", s, d))
    for s, d in get_perdevice():
        if s in CMD and d not in CMD:
            hazards.append(("per-device", s, d))
        elif d in CMD and s not in CMD:
            info.append((s, d))
    return hazards, info

def do_detect():
    hazards, info = scan()
    if hazards:
        print("HAZARD %d" % len(hazards))
        for scope, s, d in hazards:
            sev = "CRITICAL (Command→Fn kills every ⌘ shortcut)" if d == FN \
                  else "WARNING (Command→non-Command eats ⌘)"
            print("  %-10s %s → %s  [%s]" % (scope, name(s), name(d), sev))
    else:
        print("HAZARD 0")
    if info:
        print("INFO %d existing non-hazard remap(s) on the external keyboard (a non-Command modifier repurposed into Command — eats ⌃/⌥, leaves ⌘ intact; left untouched):" % len(info))
        for s, d in info:
            print("  %s → %s" % (name(s), name(d)))
    return 0

def caps(target):
    tgt = {"escape": "30064771113", "control": "30064771296"}[target]
    pairs = get_perdevice()
    if ("30064771129", tgt) in pairs:
        print("ALREADY-APPLIED caps→%s" % target); return 0
    for s, d in pairs:
        if s == "30064771129":
            print("CONFLICT: Caps Lock already remapped to %s — not overriding" % name(d))
            return 2
    pairs.append(("30064771129", tgt))
    rc = set_perdevice(pairs)
    print("APPLIED caps→%s" % target if rc == 0 else "ERROR writing mapping")
    return rc

def caps_revert(target):
    tgt = {"escape": "30064771113", "control": "30064771296"}[target]
    pairs = get_perdevice()
    new = [(s, d) for s, d in pairs if not (s == "30064771129" and d == tgt)]
    if len(new) == len(pairs):
        print("NOT-APPLIED caps→%s (nothing to revert)" % target); return 0
    rc = set_perdevice(new)
    print("REVERTED caps→%s" % target if rc == 0 else "ERROR writing mapping")
    return rc

mode = sys.argv[1] if len(sys.argv) > 1 else "detect"
if mode == "detect":
    sys.exit(do_detect())
elif mode == "caps_apply":
    sys.exit(caps(sys.argv[2]))
elif mode == "caps_revert":
    sys.exit(caps_revert(sys.argv[2]))
else:
    print("UNKNOWN mode"); sys.exit(3)
PYEOF
)

# ship_py: ensure the python helper is present on the Mac.
ship_py() { printf '%s' "$KG_PY" | mac_put "$PY"; }

# ── defaults / state helpers (run on the Mac) ────────────────────────────────
defaults_get() { mssh "defaults read -g $1 2>/dev/null" 2>/dev/null || true; }
state_get()    { mssh "grep \"^$1=\" $STATE_FILE 2>/dev/null | head -1 | cut -d= -f2-" 2>/dev/null || true; }

state_set() { # $1 key  $2 value
  local k="$1" v="$2"
  mac_exec <<EOF
f="$STATE_FILE"
touch "\$f" 2>/dev/null || true
grep -v "^$k=" "\$f" 2>/dev/null > "\$f.tmp" || true
echo "$k=$v" >> "\$f.tmp"
mv "\$f.tmp" "\$f"
EOF
}
state_del() { # $1 key
  local k="$1"
  mac_exec <<EOF
f="$STATE_FILE"
grep -v "^$k=" "\$f" 2>/dev/null > "\$f.tmp" || true
mv "\$f.tmp" "\$f" 2>/dev/null || true
EOF
}

# ── gem: key-repeat ──────────────────────────────────────────────────────────
gem_key_repeat_apply() {
  echo "→ key-repeat: KeyRepeat=2, InitialKeyRepeat=15 (fastest GUI-safe rate)"
  local kr ir
  kr="$(defaults_get KeyRepeat)"; ir="$(defaults_get InitialKeyRepeat)"
  if [[ -z "$(state_get keyrepeat_before)" ]]; then
    state_set keyrepeat_before "${kr:-UNSET}"
    state_set initialkeyrepeat_before "${ir:-UNSET}"
  fi
  if mssh "defaults write -g KeyRepeat -int 2 && defaults write -g InitialKeyRepeat -int 15" >/dev/null 2>&1; then
    note_ok "KeyRepeat/InitialKeyRepeat set to 2/15"
  else
    note_bad "failed to set KeyRepeat/InitialKeyRepeat"
  fi
  echo "      (logout or restart to take effect)"
}
gem_key_repeat_revert() {
  echo "→ revert key-repeat"
  local kr ir
  kr="$(state_get keyrepeat_before)"; ir="$(state_get initialkeyrepeat_before)"
  if [[ -z "$kr" && -z "$ir" ]]; then
    note_ok "key-repeat: not applied (no record), nothing to revert"; return 0
  fi
  if [[ "$kr" == "UNSET" ]]; then mssh "defaults delete -g KeyRepeat 2>/dev/null" >/dev/null 2>&1 || true
  else mssh "defaults write -g KeyRepeat -int $kr" >/dev/null 2>&1 || true; fi
  if [[ "$ir" == "UNSET" ]]; then mssh "defaults delete -g InitialKeyRepeat 2>/dev/null" >/dev/null 2>&1 || true
  else mssh "defaults write -g InitialKeyRepeat -int $ir" >/dev/null 2>&1 || true; fi
  state_del keyrepeat_before; state_del initialkeyrepeat_before
  note_ok "key-repeat reverted (KeyRepeat=${kr:-UNSET}, InitialKeyRepeat=${ir:-UNSET})"
}

# ── gem: press-hold ──────────────────────────────────────────────────────────
gem_press_hold_apply() {
  echo "→ press-hold: disable the press-and-hold accent popup"
  local v; v="$(defaults_get ApplePressAndHoldEnabled)"
  if [[ -z "$(state_get presshold_before)" ]]; then
    state_set presshold_before "${v:-UNSET}"
  fi
  if mssh "defaults write -g ApplePressAndHoldEnabled -bool false" >/dev/null 2>&1; then
    note_ok "ApplePressAndHoldEnabled=false (tradeoff: you lose hold-for-accents)"
  else
    note_bad "failed to set ApplePressAndHoldEnabled"
  fi
  echo "      (logout or relaunch apps to take effect)"
}
gem_press_hold_revert() {
  echo "→ revert press-hold"
  local v; v="$(state_get presshold_before)"
  if [[ -z "$v" ]]; then
    note_ok "press-hold: not applied (no record), nothing to revert"; return 0
  fi
  if [[ "$v" == "UNSET" ]]; then mssh "defaults delete -g ApplePressAndHoldEnabled 2>/dev/null" >/dev/null 2>&1 || true
  elif [[ "$v" == "1" ]]; then mssh "defaults write -g ApplePressAndHoldEnabled -bool true" >/dev/null 2>&1 || true
  else mssh "defaults write -g ApplePressAndHoldEnabled -bool false" >/dev/null 2>&1 || true; fi
  state_del presshold_before
  note_ok "press-hold reverted (ApplePressAndHoldEnabled=${v})"
}

# ── gem: fn-standard ─────────────────────────────────────────────────────────
gem_fn_standard_apply() {
  echo "→ fn-standard: F1,F2… as standard function keys (com.apple.keyboard.fnState=true)"
  local v; v="$(defaults_get com.apple.keyboard.fnState)"
  if [[ -z "$(state_get fnstate_before)" ]]; then
    state_set fnstate_before "${v:-UNSET}"
  fi
  if mssh "defaults write -g com.apple.keyboard.fnState -bool true" >/dev/null 2>&1; then
    note_ok "fnState=true (tradeoff: media/brightness keys now need the fn key)"
  else
    note_bad "failed to set com.apple.keyboard.fnState"
  fi
}
gem_fn_standard_revert() {
  echo "→ revert fn-standard"
  local v; v="$(state_get fnstate_before)"
  if [[ -z "$v" ]]; then
    note_ok "fn-standard: not applied (no record), nothing to revert"; return 0
  fi
  if [[ "$v" == "UNSET" ]]; then mssh "defaults delete -g com.apple.keyboard.fnState 2>/dev/null" >/dev/null 2>&1 || true
  elif [[ "$v" == "1" ]]; then mssh "defaults write -g com.apple.keyboard.fnState -bool true" >/dev/null 2>&1 || true
  else mssh "defaults write -g com.apple.keyboard.fnState -bool false" >/dev/null 2>&1 || true; fi
  state_del fnstate_before
  note_ok "fn-standard reverted (fnState=${v})"
}

# ── gem: capslock (escape / control) ─────────────────────────────────────────
gem_capslock_apply() {
  local target="$1"
  echo "→ capslock-${target}: Caps Lock → ${target^} (per-device, external keyboard only)"
  ship_py
  local out; out="$(mssh "python3 $PY caps_apply $target" 2>&1)" || true
  printf '%s\n' "$out" | sed 's/^/      /'
  case "$out" in
    ALREADY-APPLIED*|APPLIED*)
      note_ok "capslock-${target} applied (immediate; session-only — see README for persistence)" ;;
    CONFLICT*)
      note_bad "capslock-${target} skipped: an existing Caps Lock remap is present" ;;
    *)
      note_bad "capslock-${target} failed: $out" ;;
  esac
}
gem_capslock_revert() {
  local target="$1"
  echo "→ revert capslock-${target}"
  ship_py
  local out; out="$(mssh "python3 $PY caps_revert $target" 2>&1)" || true
  printf '%s\n' "$out" | sed 's/^/      /'
  case "$out" in
    REVERTED*|NOT-APPLIED*) note_ok "capslock-${target} reverted" ;;
    *)                      note_bad "capslock-${target} revert failed: $out" ;;
  esac
}

# ── hazard detector ──────────────────────────────────────────────────────────
detect_hazards() {
  echo "→ hazard detector: scan global + per-device UserKeyMapping for Command-eaters"
  ship_py
  local out; out="$(mssh "python3 $PY detect" 2>&1)" || true
  printf '%s\n' "$out" | sed 's/^/      /'
  if printf '%s\n' "$out" | grep -q '^HAZARD [1-9]'; then
    note_bad "Command-eater mapping(s) detected — every ⌘ shortcut may be dead on that scope"
  elif printf '%s\n' "$out" | grep -q '^HAZARD 0'; then
    note_ok "no Command-eater mapping present (global + external-keyboard per-device)"
  else
    note_bad "hazard scan produced no parseable result (is hidutil available on the Mac?)"
  fi
}

# ── cheat sheet ──────────────────────────────────────────────────────────────
cheatsheet() {
  cat <<'EOF'
Non-obvious native macOS shortcuts (no changes made — just print them):

  ⌃⌘Space        emoji / character picker (also: single-press the fn/Globe key)
  ⌘⇧.            show/hide hidden files in Finder and open/save dialogs
  ⌃⌘F            toggle fullscreen for the frontmost window
  ⌘`             cycle windows of the frontmost app (⌘⇧` reverse)
  ⌥ (hold)       while a menu is open, reveals alternate/hidden menu items
                 (e.g. "Close Window"→"Close All", "Sleep"→"Restart", …)
  ⌘⌥Esc          Force Quit dialog
  ⌥← / ⌥→        move cursor word-by-word;   ⌥⌫ delete previous word
  ⌘← / ⌘→        move to start/end of line;   ⌘⌫ delete to start of line
  ⌘⇧/            open the Help menu search (jump to any menu item by typing)
  ⌃⌘Q            lock the screen
  ⌃F2            focus the menu bar;  ⌃F3 focus the Dock;  ⌃F4 cycle windows
  ⌃F7            toggle Full Keyboard Access (Tab reaches every control)
  ⌥⇧+Vol/Bri     fine (¼-step) volume / brightness adjustment
  ⌘⇧3 / ⌘⇧4 / ⌘⇧5  screenshot: full / selection / capture UI
EOF
}

usage() {
  cat <<'EOF'
usage: sudo bash factories/mac/keyboard-gems.sh [flags]

  Apply (each opt-in; combine freely):
    --key-repeat         faster key repeat (SAFE)
    --press-hold         disable press-and-hold accent popup (SAFE)
    --safe               == --key-repeat --press-hold
    --fn-standard        F1-F12 as standard function keys (debatable)
    --capslock-escape    Caps Lock → Escape, external keyboard (debatable)
    --capslock-control   Caps Lock → Control, external keyboard (debatable)

  Undo / inspect:
    --revert [gem …]     undo ours; no arg = undo everything we applied
    --detect             hazard detector only (no changes)
    --cheatsheet         print the non-obvious shortcut sheet
    --help               this text

The Command-eater hazard detector runs first in every mode.
EOF
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "error: must run as root" >&2; exit 2
  fi

  local mode="apply"
  local -a apply_gems=() revert_gems=()
  local saw_action=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)        usage; exit 0 ;;
      --detect|--check) mode="detect"; saw_action=1 ;;
      --cheatsheet)     mode="cheatsheet"; saw_action=1 ;;
      --key-repeat)     apply_gems+=(key_repeat); saw_action=1 ;;
      --press-hold)     apply_gems+=(press_hold); saw_action=1 ;;
      --fn-standard)    apply_gems+=(fn_standard); saw_action=1 ;;
      --capslock-escape)  apply_gems+=(capslock_escape); saw_action=1 ;;
      --capslock-control) apply_gems+=(capslock_control); saw_action=1 ;;
      --safe)           apply_gems+=(key_repeat press_hold); saw_action=1 ;;
      --revert)
        mode="revert"; saw_action=1; shift
        if [[ $# -gt 0 ]]; then revert_gems=("$@"); else revert_gems=(all); fi
        break
        ;;
      *) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    esac
    shift
  done

  echo "mac-keyboard-gems: macOS keyboard features (idempotent + reversible)"
  echo "  Mac: $MAC_USER@$MAC_IP"
  echo ""

  # Preflight: the Mac must be reachable before we touch anything.
  if ! mssh 'hostname' >/dev/null 2>&1; then
    echo "  ✗ cannot reach Mac at $MAC_USER@$MAC_IP (run factories/mac/up.sh first?)"
    summary
    exit 1
  fi

  # The hazard detector always runs first.
  detect_hazards
  echo ""

  case "$mode" in
    detect|cheatsheet)
      [[ "$mode" == "cheatsheet" ]] && cheatsheet
      summary
      ;;

    apply)
      if [[ "$saw_action" == "0" ]]; then usage; exit 0; fi
      if [[ "${#apply_gems[@]}" == "0" ]]; then
        echo "nothing to apply"; summary; exit 0
      fi
      for g in "${apply_gems[@]}"; do
        case "$g" in
          key_repeat)      gem_key_repeat_apply ;;
          press_hold)      gem_press_hold_apply ;;
          fn_standard)     gem_fn_standard_apply ;;
          capslock_escape) gem_capslock_apply escape ;;
          capslock_control) gem_capslock_apply control ;;
        esac
        echo ""
      done
      summary
      ;;

    revert)
      if [[ "${revert_gems[0]:-}" == "all" ]]; then
        revert_gems=(key_repeat press_hold fn_standard capslock_escape capslock_control)
      fi
      for g in "${revert_gems[@]}"; do
        case "$g" in
          key-repeat|key_repeat)      gem_key_repeat_revert ;;
          press-hold|press_hold)      gem_press_hold_revert ;;
          fn-standard|fn_standard)    gem_fn_standard_revert ;;
          capslock-escape|capslock_escape)   gem_capslock_revert escape ;;
          capslock-control|capslock_control) gem_capslock_revert control ;;
          safe)                       gem_key_repeat_revert; gem_press_hold_revert ;;
          *) echo "  ✗ unknown gem to revert: $g"; FAIL=$((FAIL+1)) ;;
        esac
        echo ""
      done
      summary
      ;;
  esac
}

main "$@"
