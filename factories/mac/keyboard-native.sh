#!/usr/bin/env bash
set -euo pipefail

# factories/mac/keyboard-native.sh — make macOS treat the external Chinese OEM
# keyboard (BY Tech "Gaming Keyboard", VID 0x258A / PID 0x010C, SinoWealth) as
# its OWN native physical layout, so every key types what is printed on the
# keycap, with no imposed Apple remapping.
#
# WHAT IT DOES
#   Sets the per-device keyboard TYPE for this one keyboard in macOS's
#   /Library/Preferences/com.apple.keyboardtype.plist, under the record key
#   "268-9610-0" (product 268 = 0x010C, vendor 9610 = 0x258A, location 0).
#   macOS keyboard types: 40 = ANSI, 41 = ISO, 42 = JIS. The current on-disk
#   value is 41 (ISO); the default target is 40 (ANSI) — see the evidence note
#   below and README-keyboard.md. A Python (plistlib) mutation changes ONLY that
#   one key and preserves every other keyboard's entry.
#
# WHAT IT DOES NOT DO
#   - Does NOT touch the enabled input source (U.S., KeyboardLayout ID 0).
#   - Does NOT touch hidutil UserKeyMapping unless --clear-remaps is passed.
#     The remaps are inventoried and reported on every run, never silently
#     changed.
#
# LAYOUT EVIDENCE (not silent assumption)
#   The definitive ANSI/ISO/JIS signal is the keyboard's HID report descriptor,
#   but the keyboard is NOT currently connected, so it cannot be read live. The
#   evidence for ANSI (40) is: (1) the two other external keyboards on this Mac
#   are already typed ANSI (40) and are the operator's working boards; (2) this
#   board is a generic SinoWealth "Gaming Keyboard" — Chinese-mainland OEM
#   boards of this class ship ANSI (long Left Shift, horizontal Enter) with
#   US-English + Chinese legends; (3) the operator's intent ("do what this
#   Chinese keyboard layout is") with the U.S. input source = an ANSI board
#   typing its keycaps with zero remapping. NOT proven from the device: if in
#   doubt, confirm with the single key immediately to the RIGHT of Left Shift —
#   ANSI = "Z", ISO = an extra "\|" key, JIS = different. Override the default
#   with --layout if that keypress proves otherwise.
#
# RUNS ON: the lima host, as root. Reaches the Mac over SSH (key-based,
#   BatchMode, user aidanmcohen). Reading the plist needs no privilege (it is
#   world-readable). WRITING it needs root on the Mac: sudo over SSH
#   (passwordless sudo, or a password via MAC_SUDO_PASSWORD / --sudo-password).
#   NOTE: the virtiofs mount /mnt/mac runs as aidanmcohen, NOT root, so it
#   cannot write the root-owned /Library/Preferences — sudo is the only path.
#
# COST TO APPLY
#   The keyboard type is read by macOS only when the keyboard is (re)enumerated;
#   there is no HID daemon to restart that re-reads it. The keyboard is
#   currently disconnected, so the change simply persists and takes effect the
#   next time it is plugged in. If it were connected, apply = unplug/replug it
#   (or log out/in, or reboot). No GUI step. The plist write itself is the
#   whole mechanism.
#
# USAGE
#   sudo bash factories/mac/keyboard-native.sh                  # set ANSI (default)
#   sudo bash factories/mac/keyboard-native.sh --layout iso     # set ISO instead
#   sudo bash factories/mac/keyboard-native.sh --layout jis     # set JIS instead
#   sudo bash factories/mac/keyboard-native.sh --value 41       # set explicit type
#   sudo bash factories/mac/keyboard-native.sh --revert         # restore prior value
#   sudo bash factories/mac/keyboard-native.sh --clear-remaps   # also clear global remaps
#   sudo bash factories/mac/keyboard-native.sh --dry-run        # report only, change nothing
#
#   MAC_SUDO_PASSWORD=… sudo -E bash …/keyboard-native.sh       # non-interactive sudo

# ── Hardcoded Mac + keyboard facts (verified live 2026-10-02 — do not re-derive) ─
MAC_USER="aidanmcohen"
MAC_IP="192.168.5.2"
PLIST="/Library/Preferences/com.apple.keyboardtype.plist"
KBD_KEY="268-9610-0"                 # product 268 (0x010C) - vendor 9610 (0x258A) - 0
DEFAULT_REVERT_VALUE="41"            # last-known on-disk value before any change (ISO)

# macOS keyboard types: 40 = ANSI, 41 = ISO, 42 = JIS.
declare -A LAYOUT_TYPE=([ansi]=40 [iso]=41 [jis]=42)
DEFAULT_LAYOUT="ansi"

WORKER_PATH="/tmp/kbd-native-worker.py"
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.keyboard-native.state"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo ""; echo "── $* ──"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

PASS=0; FAIL=0
note_ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
note_bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── argument parsing ───────────────────────────────────────────────────────────
LAYOUT="$DEFAULT_LAYOUT"
MODE="apply"          # apply | revert
TARGET=""             # explicit integer for --value (overrides --layout)
CLEAR_REMAPS=0
DRY_RUN=0
REVERT_VALUE=""       # explicit value for --revert --value N
SUDO_PASSWORD="${MAC_SUDO_PASSWORD:-}"
usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --layout) LAYOUT="${2:?--layout needs ansi|iso|jis}"; shift 2 ;;
    --value)  TARGET="${2:?--value needs an integer}"; shift 2 ;;
    --revert) MODE="revert"; shift ;;
    --clear-remaps) CLEAR_REMAPS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --sudo-password) SUDO_PASSWORD="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$TARGET" ]] && TARGET_TYPE="$TARGET" || TARGET_TYPE="${LAYOUT_TYPE[$LAYOUT]:?unknown layout: $LAYOUT (use ansi|iso|jis)}"

# ── remote helpers ─────────────────────────────────────────────────────────────
run_mac() {
  # $@ = command to run on the Mac as aidanmcohen (no sudo). Captures stdout.
  ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$@"
}
run_mac_sudo() {
  # $1 = command string to run on the Mac under sudo.
  local cmd="$1"
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "sudo -S -p '' sh -c '$cmd'" <<<"$SUDO_PASSWORD"
  else
    ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "sudo -n sh -c '$cmd'"
  fi
}

# ── install the Python worker on the Mac (idempotent) ──────────────────────────
install_worker() {
  ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "cat > $WORKER_PATH" <<'WORKER_PY'
#!/usr/bin/env python3
import json, os, plistlib, re, subprocess, sys

PLIST = "/Library/Preferences/com.apple.keyboardtype.plist"
KBD_KEY = "268-9610-0"
AGENT = os.path.expanduser("~/Library/LaunchAgents/key-binds-on-start.plist")

def load():
    with open(PLIST, "rb") as f:
        return plistlib.load(f)

def save(p):
    with open(PLIST, "wb") as f:
        plistlib.dump(p, f, fmt=plistlib.FMT_BINARY)

NAMES = {
    (0x07, 0xE3): "Left Command",
    (0x07, 0x3C): "F2",
    (0xFF, 0x03): "Apple Fn",
    (0xFF01, 0x10): "Vendor key 0xFF01:0x10",
}

def fmt(v):
    page, usage = v >> 32, v & 0xFFFFFFFF
    n = NAMES.get((page, usage))
    return ("%s (0x%X:0x%X)" % (n, page, usage)) if n else ("0x%X:0x%X" % (page, usage))

def hidutil_get():
    r = subprocess.run(["hidutil", "property", "--get", "UserKeyMapping"],
                       capture_output=True, text=True)
    if r.stdout.strip() in ("", "()", "(\n)"):
        return []
    tf = "/tmp/kbd-remaps.plist"
    open(tf, "w").write(r.stdout)
    c = subprocess.run(["plutil", "-convert", "json", "-o", "-", tf],
                       capture_output=True, text=True)
    try:
        return json.loads(c.stdout) if c.stdout.strip() else []
    except Exception:
        return []

def agent_mappings():
    if not os.path.exists(AGENT):
        return None
    try:
        with open(AGENT, "rb") as f:
            p = plistlib.load(f)
        args = p.get("ProgramArguments", [])
        blob = args[-1] if args else ""
        data = json.loads(blob)
        return data.get("UserKeyMapping", [])
    except Exception as e:
        return {"error": str(e)}

def main():
    cmd = sys.argv[1]
    if cmd == "read":
        p = load()
        d = p.get("keyboardtype", {})
        print("DICT=%s" % json.dumps({k: d[k] for k in sorted(d)}))
        print("CURRENT=%s" % d.get(KBD_KEY, "<absent>"))
        r = subprocess.run(["ioreg", "-r", "-l", "-w", "0"], capture_output=True, text=True)
        print("CONNECTED=%s" % ("yes" if re.search(r'"VendorID" = 9610\b', r.stdout) else "no"))
    elif cmd == "apply":
        target = int(sys.argv[2])
        p = load()
        d = p.setdefault("keyboardtype", {})
        prior = d.get(KBD_KEY)
        d[KBD_KEY] = target
        save(p)
        print("PRIOR=%s" % prior)
        print("NEW=%s" % target)
    elif cmd == "remaps":
        live = hidutil_get()
        print("LIVE_COUNT=%d" % len(live))
        for m in live:
            print("LIVE %s -> %s" % (fmt(m.get("HIDKeyboardModifierMappingSrc")),
                                     fmt(m.get("HIDKeyboardModifierMappingDst"))))
        ag = agent_mappings()
        if ag is None:
            print("AGENT_PRESENT=no")
        elif isinstance(ag, dict) and "error" in ag:
            print("AGENT_PRESENT=yes")
            print("AGENT_PARSE_ERROR=%s" % ag["error"])
        else:
            print("AGENT_PRESENT=yes")
            print("AGENT_PATH=%s" % AGENT)
            print("AGENT_COUNT=%d" % len(ag))
            for m in ag:
                print("AGENT %s -> %s" % (fmt(m.get("HIDKeyboardModifierMappingSrc")),
                                          fmt(m.get("HIDKeyboardModifierMappingDst"))))
    elif cmd == "clear-remaps":
        # 1. stop the launch agent (ignore "not loaded")
        subprocess.run(["launchctl", "unload", AGENT], capture_output=True)
        # 2. neutralize persistence by renaming the plist out of LaunchAgents/
        if os.path.exists(AGENT):
            os.rename(AGENT, AGENT + ".disabled")
            print("AGENT_DISABLED=%s.disabled" % AGENT)
        else:
            print("AGENT_ABSENT=noop")
        # 3. clear live mappings
        subprocess.run(["hidutil", "property", "--set", "UserKeyMapping", "()"],
                       capture_output=True)
        print("LIVE_CLEARED=done")
    else:
        sys.exit("unknown cmd: " + cmd)

if __name__ == "__main__":
    main()
WORKER_PY
  if [[ $? -ne 0 ]]; then note_bad "failed to install worker on the Mac"; return 1; fi
  note_ok "worker installed on Mac ($WORKER_PATH)"
}

# ── summary ────────────────────────────────────────────────────────────────────
summary() {
  echo ""
  echo "════════════════════════════════════════════"
  if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: FAIL  ($PASS passed, $FAIL failed)"
    return 1
  fi
  echo "RESULT: PASS  ($PASS passed, $FAIL failed)"
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "mac-keyboard-native: present the BY Tech 'Gaming Keyboard' as its native layout"
echo "  Mac: $MAC_USER@$MAC_IP"
echo "  record: $PLIST :: $KBD_KEY"
echo "  default layout: $LAYOUT -> type $TARGET_TYPE (40=ANSI, 41=ISO, 42=JIS)"

# ── [1] reach the Mac ──────────────────────────────────────────────────────────
step "reach the Mac"
if MAC_HOST="$(run_mac 'hostname' 2>&1)"; then
  note_ok "ssh answered: $(printf '%s' "$MAC_HOST" | tr '\n' ' ')"
else
  note_bad "ssh FAILED — exact error: $MAC_HOST"
  summary; exit 1
fi

# ── [2] install worker ─────────────────────────────────────────────────────────
step "install worker"
install_worker || { summary; exit 1; }

# ── [3] current state ──────────────────────────────────────────────────────────
step "current per-device keyboard type"
READ_OUT="$(run_mac "/usr/bin/python3 $WORKER_PATH read" 2>&1)" || { note_bad "read failed: $READ_OUT"; summary; exit 1; }
CURRENT="$(printf '%s' "$READ_OUT" | sed -n 's/^CURRENT=//p')"
CONNECTED="$(printf '%s' "$READ_OUT" | sed -n 's/^CONNECTED=//p')"
DICT="$(printf '%s' "$READ_OUT" | sed -n 's/^DICT=//p')"
note_ok "keyboardtype entries: $DICT"
if [[ "$CONNECTED" == "yes" ]]; then
  note_ok "this keyboard ($KBD_KEY) current type: $CURRENT (currently connected)"
else
  note_ok "this keyboard ($KBD_KEY) current type: $CURRENT (currently NOT connected)"
fi

# ── [4] remap inventory (report only — never changed here) ─────────────────────
step "global key-remap inventory (hidutil UserKeyMapping)"
REMAP_OUT="$(run_mac "/usr/bin/python3 $WORKER_PATH remaps" 2>&1)" || REMAP_OUT="remaps read failed: $REMAP_OUT"
echo "$REMAP_OUT" | sed 's/^/  /'
LIVE_COUNT="$(printf '%s' "$REMAP_OUT" | sed -n 's/^LIVE_COUNT=//p')"
AGENT_PRESENT="$(printf '%s' "$REMAP_OUT" | sed -n 's/^AGENT_PRESENT=//p')"
if [[ "${LIVE_COUNT:-0}" != "0" ]] || [[ "$AGENT_PRESENT" == "yes" ]]; then
  warn "non-native remaps detected (live=$LIVE_COUNT, agent=$AGENT_PRESENT) — NOT changed unless --clear-remaps"
else
  note_ok "no live remaps and no remap launch agent"
fi

# ── [5] clear remaps (only with --clear-remaps) ────────────────────────────────
if [[ "$CLEAR_REMAPS" == "1" ]]; then
  step "clear global key remaps (--clear-remaps)"
  if [[ "$DRY_RUN" == "1" ]]; then
    note_ok "dry-run: would unload+disable the launch agent and clear UserKeyMapping"
  else
    CLEAR_OUT="$(run_mac "/usr/bin/python3 $WORKER_PATH clear-remaps" 2>&1)" || CLEAR_OUT="clear failed: $CLEAR_OUT"
    echo "$CLEAR_OUT" | sed 's/^/  /'
    note_ok "remap clear executed"
    VERIFY="$(run_mac "hidutil property --get UserKeyMapping" 2>&1)"
    if printf '%s' "$VERIFY" | grep -q 'HIDKeyboardModifierMapping'; then
      note_bad "remaps still present after clear: $VERIFY"
    else
      note_ok "verify: UserKeyMapping is empty"
    fi
  fi
fi

# ── [6] keyboard type action ───────────────────────────────────────────────────
if [[ "$MODE" == "revert" ]]; then
  step "revert keyboard type to prior value"
  if [[ -n "$REVERT_VALUE" ]]; then
    PRIOR_V="$REVERT_VALUE"
  elif [[ -f "$STATE_FILE" ]]; then
    PRIOR_V="$(cat "$STATE_FILE")"
    note_ok "restoring prior value $PRIOR_V (from $STATE_FILE)"
  else
    PRIOR_V="$DEFAULT_REVERT_VALUE"
    warn "no state file — reverting to documented original value $PRIOR_V (ISO)"
  fi
  ACTION_VALUE="$PRIOR_V"
else
  step "set keyboard type ($LAYOUT -> $TARGET_TYPE)"
  ACTION_VALUE="$TARGET_TYPE"
fi

if [[ "$CURRENT" == "$ACTION_VALUE" ]]; then
  note_ok "already $ACTION_VALUE — no change needed (idempotent)"
else
  if [[ "$DRY_RUN" == "1" ]]; then
    note_ok "dry-run: would write $KBD_KEY = $ACTION_VALUE (currently $CURRENT)"
  else
    WRITE_OUT="$(run_mac_sudo "/usr/bin/python3 $WORKER_PATH apply $ACTION_VALUE" 2>&1)" \
      || { note_bad "write failed (sudo needed?) — error: $WRITE_OUT"; note_bad "manual: sudo defaults write $PLIST keyboardtype -dict-add \"$KBD_KEY\" -integer $ACTION_VALUE"; summary; exit 1; }
    echo "$WRITE_OUT" | sed 's/^/  /'
    note_ok "plist written"
    if [[ "$MODE" != "revert" ]]; then
      printf '%s\n' "$CURRENT" > "$STATE_FILE"   # capture prior for later --revert
      note_ok "prior value $CURRENT saved to $STATE_FILE"
    fi
  fi
fi

# ── [7] verify ─────────────────────────────────────────────────────────────────
step "verify effective per-device type"
VERIFY_OUT="$(run_mac "/usr/bin/python3 $WORKER_PATH read" 2>&1)" || VERIFY_OUT="verify read failed: $VERIFY_OUT"
VERIFY_CURRENT="$(printf '%s' "$VERIFY_OUT" | sed -n 's/^CURRENT=//p')"
if [[ "$DRY_RUN" == "1" ]]; then
  note_ok "dry-run: effective type remains $VERIFY_CURRENT (no write attempted)"
else
  if [[ "$VERIFY_CURRENT" == "$ACTION_VALUE" ]]; then
    note_ok "effective per-device type for $KBD_KEY is now $VERIFY_CURRENT"
  else
    note_bad "effective type is $VERIFY_CURRENT, expected $ACTION_VALUE"
  fi
fi

# ── [8] cost / apply note ──────────────────────────────────────────────────────
step "cost to apply"
if [[ "$CONNECTED" == "yes" ]]; then
  note_ok "keyboard is connected — unplug/replug it (or log out/in, or reboot) to apply."
else
  note_ok "keyboard is NOT connected — the new type applies on next connect."
fi
note_ok "no HID daemon restart exists that re-reads keyboardtype; enumeration is the trigger."

summary
