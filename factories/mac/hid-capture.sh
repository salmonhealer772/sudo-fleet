#!/usr/bin/env bash
set -euo pipefail

# factories/mac/hid-capture.sh — real HID keypress capture on the Mac.
#
# Runs on the lima host as root. Reaches the Mac over the key-based SSH that
# factories/mac/up.sh established (aidanmcohen@192.168.5.2). On the Mac it
# compiles a small Swift/IOKit one-shot and runs it as a background listener
# that logs ONE LINE PER KEY EVENT from the external keyboard, filtered to
# VID 0x258A / PID 0x010C (BY Tech "Gaming Keyboard") — never "any keyboard".
#
# Subcommands:
#   start [logfile]   compile + launch the listener, log to the Mac-side file
#                     (default /tmp/hid-capture.log). Refuses if already running.
#   stop              kill the listener, confirm it stopped.
#   status            report running-or-not + tail the log.
#
# No sudo is needed on the Mac: IOHIDManager reads raw HID input values as the
# plain ssh user. No GUI step, no install (only the already-present CLT/swiftc).
# This script never changes any keyboard setting, remap, or plist — it only
# observes.

# ── Hardcoded Mac facts (verified live 2026-10-02 — do not re-derive) ────────
MAC_USER="aidanmcohen"
MAC_IP="192.168.5.2"
MAC_SWIFT="/tmp/hid-capture.swift"
MAC_BIN="/tmp/hid-capture"
MAC_PID="/tmp/hid-capture.pid"
DEFAULT_LOG="/tmp/hid-capture.log"

TARGET_VID="0x258A"
TARGET_PID="0x010C"
PROC_NAME="hid-capture"

# The Mac's login shell is zsh: a remote command containing a bare word that
# starts with '=' (e.g. echo ===FOO===) dies with 'zsh:1: ==FOO=== not found'.
# Everything below avoids '=' markers.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

# ── Embedded Swift source (compiled on the Mac with swiftc -swift-version 5) ──
SWIFT_SRC=$(cat <<'SWIFT_EOF'
import Foundation
import Darwin
import IOKit
import IOKit.hid

let TARGET_VENDOR_ID = 0x258A
let TARGET_PRODUCT_ID = 0x010C

var modifierMask: UInt8 = 0
var headerPrinted = false

let tsFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return f
}()

func ts() -> String { tsFmt.string(from: Date()) }

func entryID(_ device: IOHIDDevice) -> UInt64 {
    let service = IOHIDDeviceGetService(device)
    var eid: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &eid)
    return eid
}

func pInt(_ device: IOHIDDevice, _ key: String) -> Int? {
    guard let v = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber else { return nil }
    return v.intValue
}
func pStr(_ device: IOHIDDevice, _ key: String) -> String? {
    return IOHIDDeviceGetProperty(device, key as CFString) as? String
}

func describe(_ device: IOHIDDevice) -> String {
    let eid = entryID(device)
    let vid = pInt(device, kIOHIDVendorIDKey) ?? 0
    let pid = pInt(device, kIOHIDProductIDKey) ?? 0
    let up = pInt(device, kIOHIDDeviceUsagePageKey) ?? pInt(device, kIOHIDPrimaryUsagePageKey) ?? 0
    let u = pInt(device, kIOHIDDeviceUsageKey) ?? pInt(device, kIOHIDPrimaryUsageKey) ?? 0
    let product = pStr(device, kIOHIDProductKey) ?? "?"
    let mfr = pStr(device, kIOHIDManufacturerKey) ?? "?"
    return String(format: "iface=0x%llx vid=0x%04x pid=0x%04x usagePage=0x%02x usage=0x%02x product=\"%@\" vendor=\"%@\"",
                  eid, vid, pid, up, u, product, mfr)
}

func keyName(page: UInt32, usage: UInt32) -> String {
    if page == 0x07 {
        switch usage {
        case 0x04...0x1D: return String(UnicodeScalar(UInt8(0x41 + (usage - 0x04))))
        case 0x1E...0x26: return String(UnicodeScalar(UInt8(0x31 + (usage - 0x1E))))
        case 0x27: return "0"
        case 0x28: return "Return"
        case 0x29: return "Escape"
        case 0x2A: return "Backspace"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x2D: return "-"
        case 0x2E: return "="
        case 0x2F: return "["
        case 0x30: return "]"
        case 0x31: return "Backslash"
        case 0x32: return "NonUSHash"
        case 0x33: return ";"
        case 0x34: return "'"
        case 0x35: return "Grave"
        case 0x36: return ","
        case 0x37: return "."
        case 0x38: return "/"
        case 0x39: return "CapsLock"
        case 0x3A: return "F1"; case 0x3B: return "F2"; case 0x3C: return "F3"
        case 0x3D: return "F4"; case 0x3E: return "F5"; case 0x3F: return "F6"
        case 0x40: return "F7"; case 0x41: return "F8"; case 0x42: return "F9"
        case 0x43: return "F10"; case 0x44: return "F11"; case 0x45: return "F12"
        case 0x46: return "PrintScreen"
        case 0x47: return "ScrollLock"
        case 0x48: return "Pause"
        case 0x49: return "Insert"
        case 0x4A: return "Home"
        case 0x4B: return "PageUp"
        case 0x4C: return "DeleteForward"
        case 0x4D: return "End"
        case 0x4E: return "PageDown"
        case 0x4F: return "RightArrow"
        case 0x50: return "LeftArrow"
        case 0x51: return "DownArrow"
        case 0x52: return "UpArrow"
        case 0x53: return "NumLock"
        case 0x54: return "KeypadSlash"
        case 0x55: return "KeypadAsterisk"
        case 0x56: return "KeypadMinus"
        case 0x57: return "KeypadPlus"
        case 0x58: return "KeypadEnter"
        case 0x59: return "Keypad1"; case 0x5A: return "Keypad2"; case 0x5B: return "Keypad3"
        case 0x5C: return "Keypad4"; case 0x5D: return "Keypad5"; case 0x5E: return "Keypad6"
        case 0x5F: return "Keypad7"; case 0x60: return "Keypad8"; case 0x61: return "Keypad9"
        case 0x62: return "Keypad0"
        case 0x63: return "KeypadDot"
        case 0x64: return "NonUSBackslash"
        case 0x65: return "Application"
        case 0x66: return "Power"
        case 0x67: return "KeypadEquals"
        case 0x68: return "F13"; case 0x69: return "F14"; case 0x6A: return "F15"
        case 0x6B: return "F16"; case 0x6C: return "F17"; case 0x6D: return "F18"
        case 0x6E: return "F19"; case 0x6F: return "F20"; case 0x70: return "F21"
        case 0x71: return "F22"; case 0x72: return "F23"; case 0x73: return "F24"
        case 0x74: return "KeyboardExecute"
        case 0x75: return "KeyboardHelp"
        case 0x76: return "KeyboardMenu"
        case 0x77: return "KeyboardSelect"
        case 0x78: return "KeyboardStop"
        case 0x79: return "KeyboardAgain"
        case 0x7A: return "KeyboardUndo"
        case 0x7B: return "KeyboardCut"
        case 0x7C: return "KeyboardCopy"
        case 0x7D: return "KeyboardPaste"
        case 0x7E: return "KeyboardFind"
        case 0x7F: return "KeyboardMute"
        case 0x80: return "KeyboardVolumeUp"
        case 0x81: return "KeyboardVolumeDown"
        case 0xE0: return "LeftControl"
        case 0xE1: return "LeftShift"
        case 0xE2: return "LeftAlt"
        case 0xE3: return "LeftGUI"
        case 0xE4: return "RightControl"
        case 0xE5: return "RightShift"
        case 0xE6: return "RightAlt"
        case 0xE7: return "RightGUI"
        default: return String(format: "0x%04X", usage)
        }
    }
    if page == 0x0C {
        switch usage {
        case 0xB5: return "ScanNextTrack"
        case 0xB6: return "ScanPreviousTrack"
        case 0xCD: return "PlayPause"
        case 0xE2: return "Mute"
        case 0xE9: return "VolumeIncrement"
        case 0xEA: return "VolumeDecrement"
        case 0x0223: return "AC_Home"
        default: return String(format: "0x%04X", usage)
        }
    }
    if page == 0x01 {
        switch usage {
        case 0x81: return "SystemPowerDown"
        case 0x82: return "SystemSleep"
        case 0x83: return "SystemWakeUp"
        default: return String(format: "0x%04X", usage)
        }
    }
    return String(format: "0x%04X", usage)
}

let listOnly = CommandLine.arguments.contains("--list")
let rawOnly = CommandLine.arguments.contains("--raw")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let match: [String: Any] = [
    kIOHIDVendorIDKey: TARGET_VENDOR_ID,
    kIOHIDProductIDKey: TARGET_PRODUCT_ID,
]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

var seen: [UInt64: IOHIDDevice] = [:]

let matchCb: IOHIDDeviceCallback = { ctx, res, sender, device in
    let eid = entryID(device)
    let isNew = seen[eid] == nil
    seen[eid] = device
    if isNew && headerPrinted {
        print("\(ts()) ATTACH \(describe(device))")
        fflush(stdout)
    }
}
let removeCb: IOHIDDeviceCallback = { ctx, res, sender, device in
    let eid = entryID(device)
    seen.removeValue(forKey: eid)
    if headerPrinted {
        print("\(ts()) REMOVE \(describe(device))")
        fflush(stdout)
    }
}
let inputCb: IOHIDValueCallback = { ctx, res, sender, value in
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let device = IOHIDElementGetDevice(element)
    let eid = entryID(device)
    let v = IOHIDValueGetIntegerValue(value)

    // Track the HID modifier byte (keyboard page usages 0xE0..0xE7) so each
    // line reports the modifier state CURRENT at that event.
    if page == 0x07 && usage >= 0xE0 && usage <= 0xE7 {
        let bit = UInt8(usage - 0xE0)
        if v != 0 {
            modifierMask |= (1 << bit)
        } else {
            modifierMask &= ~(1 << bit)
        }
    }

    // The boot-protocol keyboard interface emits array-slot chatter alongside
    // each real key event: usage 0xFFFFFFFF (array item) and usage 0x00/0x01
    // (reserved/rollover). Skip those so one physical key == one clean line.
    // --raw shows them too.
    if !rawOnly && page == 0x07 && (usage == 0xFFFFFFFF || usage == 0x00 || usage == 0x01) {
        return
    }

    print(String(format: "%@ iface=0x%llx page=0x%02X usage=0x%04X value=%lld mods=0x%02X name=%@",
                 ts(), eid, page, usage, Int64(v), UInt32(modifierMask), keyName(page: page, usage: usage)))
    fflush(stdout)
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCb, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, removeCb, nil)
IOHIDManagerRegisterInputValueCallback(manager, inputCb, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openRes != kIOReturnSuccess {
    print("\(ts()) ERROR IOHIDManagerOpen returned 0x\(String(openRes, radix: 16))")
    exit(3)
}

if listOnly {
    // Spin the run loop briefly so the matching callback populates 'seen'.
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 2.0, false)
    let sorted = seen.values.sorted { entryID($0) < entryID($1) }
    print("MATCHED \(sorted.count)")
    for d in sorted { print("DEVICE \(describe(d))") }
    exit(sorted.isEmpty ? 2 : 0)
}

// Listener mode: collect currently-attached devices first, then print the header.
CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1.5, false)
let sorted = seen.values.sorted { entryID($0) < entryID($1) }
print("\(ts()) CAPTURE-START vid=0x\(String(format: "%04X", TARGET_VENDOR_ID)) pid=0x\(String(format: "%04X", TARGET_PRODUCT_ID)) matched=\(sorted.count)")
for d in sorted { print("\(ts()) ATTACHED \(describe(d))") }
if sorted.isEmpty {
    print("\(ts()) WARNING no matched device attached — filter vid=0x258A pid=0x010C matched nothing")
}
print("\(ts()) READY waiting-for-input-events")
fflush(stdout)
headerPrinted = true
CFRunLoopRun()
SWIFT_EOF
)

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
  echo "usage: sudo bash factories/mac/hid-capture.sh {start [logfile]|stop|status}"
  echo "  start [logfile]   compile + launch listener (default log $DEFAULT_LOG on the Mac)"
  echo "  stop              kill the listener"
  echo "  status            running-or-not + tail the log"
  exit 2
}

# ── write_and_compile: ship the Swift source to the Mac and compile it ────────
write_and_compile() {
  if printf '%s' "$SWIFT_SRC" | base64 | ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" \
      "base64 -d > '$MAC_SWIFT' && swiftc -swift-version 5 -O '$MAC_SWIFT' -o '$MAC_BIN'"; then
    note_ok "swift source written + compiled to $MAC_BIN on the Mac"
  else
    note_bad "swift compile failed on the Mac (see error above)"
  fi
}

# ── start ─────────────────────────────────────────────────────────────────────
do_start() {
  local LOG="${1:-$DEFAULT_LOG}"
  echo "hid-capture: real HID keypress capture for vid=$TARGET_VID pid=$TARGET_PID"
  echo "  Mac: $MAC_USER@$MAC_IP   log: $LOG (on the Mac)"

  if is_running; then
    echo "  ✗ already running ($PROC_NAME) — run 'stop' first"
    exit 1
  fi

  write_and_compile
  abort_if_failed

  # Show the device attached BEFORE starting (the required pre-start proof).
  echo "→ probe: matched devices on the Mac"
  local LIST_OUT
  if LIST_OUT="$(ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$MAC_BIN --list" 2>&1)"; then
    if printf '%s' "$LIST_OUT" | grep -q '^MATCHED [1-9]'; then
      note_ok "external keyboard attached:"
      printf '%s\n' "$LIST_OUT" | grep '^DEVICE ' | sed 's/^/      /'
    else
      note_bad "no device matched vid=$TARGET_VID pid=$TARGET_PID (output: $(printf '%s' "$LIST_OUT" | tr '\n' ' '))"
    fi
  else
    note_bad "--list probe failed: $LIST_OUT"
  fi
  abort_if_failed

  # Launch the listener in the background, detached from the SSH session, so it
  # keeps collecting after this script returns. Redirect to the named log file.
  echo "→ launch listener (log: $LOG)"
  if ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" \
      "nohup '$MAC_BIN' > '$LOG' 2>&1 & echo \$! > '$MAC_PID'" 2>/dev/null; then
    note_ok "launched — pid recorded at $MAC_PID on the Mac"
  else
    note_bad "failed to launch listener"
  fi

  sleep 2

  echo "→ verify listener is up and waiting"
  if is_running; then
    note_ok "process $PROC_NAME is running"
  else
    note_bad "process $PROC_NAME not running after launch"
  fi
  if ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "grep -q 'READY waiting-for-input-events' '$LOG' 2>/dev/null" 2>/dev/null; then
    note_ok "log shows READY (listener is waiting for a real keypress)"
  else
    note_bad "log does not show READY — tail: $(ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "tail -5 '$LOG' 2>/dev/null" 2>/dev/null | tr '\n' ' ')"
  fi

  echo ""
  echo "  Capture is running. Press keys on the external keyboard now."
  echo "  Each key event is logged to $LOG on the Mac as:"
  echo "    <UTC ts> iface=0x… page=0x… usage=0x… value=… mods=0x… name=…"
  echo "  Stop with:  sudo bash factories/mac/hid-capture.sh stop"
  summary
}

# ── stop ──────────────────────────────────────────────────────────────────────
do_stop() {
  echo "hid-capture: stop the listener on the Mac ($MAC_USER@$MAC_IP)"
  if ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" \
      "if [ -f '$MAC_PID' ]; then kill \$(cat '$MAC_PID') 2>/dev/null || true; rm -f '$MAC_PID'; fi; pkill -x '$PROC_NAME' 2>/dev/null || true" 2>/dev/null; then
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
  echo "hid-capture: status ($MAC_USER@$MAC_IP)"
  if is_running; then
    echo "  state: RUNNING"
  else
    echo "  state: NOT running"
  fi
  echo "  last lines of $LOG:"
  ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "tail -20 '$LOG' 2>/dev/null || echo '(no log yet)'" 2>/dev/null
}

# ── main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
  start)  do_start "${2:-$DEFAULT_LOG}" ;;
  stop)   do_stop ;;
  status) do_status "${2:-$DEFAULT_LOG}" ;;
  *)      usage ;;
esac
