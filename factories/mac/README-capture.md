# mac key-capture — real HID keypress capture on the Mac

`hid-capture.sh` reads, from the lima host, exactly what the external keyboard
(VID `0x258A` / PID `0x010C`, product string `Gaming Keyboard`, vendor string
`BY Tech`) sends for every physical key — the ground truth behind the report
that the key physically right of the left Shift key behaves as **Up arrow**.

It is an *instrument*, not a fix: it observes and logs, and never changes a
keyboard setting, remap, or plist.

## Mechanism — what it uses and why

macOS ships **no native HID monitor** (`hidutil` can read properties but cannot
watch input values), so a small program is genuinely required here. On the Mac
(`swiftc` 6.3.3, CommandLineTools present, Python 3.9.6 present, no Karabiner)
we picked, from least-to-most invasive, the first thing that works with **no
GUI step and no install**:

- **Chosen: a compiled Swift / IOKit one-shot.** `IOHIDManager` +
  `IOHIDManagerRegisterInputValueCallback` is the native, first-class macOS API
  for reading raw HID input values, and it needs **no root, no Accessibility /
  Input-Monitoring permission, and no GUI prompt** — it reads the physical
  device's HID reports as the plain ssh user (`aidanmcohen`). `swiftc` is
  already present (CLT installed), so compiling a one-shot is a build, not an
  install. The listener matches on VID/PID (so it sees only this keyboard,
  never "any keyboard"), registers a callback, and runs a CFRunLoop.
- **Rejected: Python `ctypes` → IOKit.** Zero-compile, but the ABI bridge must
  hand-define CF/IOHID types *and* keep a live reference to every C callback
  function pointer (Python GC will otherwise free the callback and crash the
  interpreter mid-stream). More fragile for no real gain.
- **Rejected: JXA / `osascript` ObjC bridge.** `osascript`'s JavaScript
  automation has no clean IOKit bridge; you'd end up shelling out to the same
  compiled program anyway.

The Swift source is embedded inside `hid-capture.sh`, shipped to the Mac over
SSH, and compiled there with `swiftc -swift-version 5 -O` on each `start`. No
binary or source is checked into the repo.

## The device, as IOKit sees it (verified live)

The filter `vid=0x258A pid=0x010C` matches **exactly two** HID interfaces —
both are captured, because a keypress may arrive on either:

| `iface` (registry id) | usage | role |
|---|---|---|
| `0x100001fda` | page `0x01` usage `0x06` | boot-protocol keyboard (8-byte report) |
| `0x100001fd8` | page `0x01` usage `0x80` | composite interface (NKRO bitmap + consumer + system + mouse) |

## Run it

Runs on the **lima host as root** (it reaches the Mac over the key-based SSH
that `factories/mac/up.sh` already set up):

```bash
sudo bash factories/mac/hid-capture.sh start          # default log /tmp/hid-capture.log
sudo bash factories/mac/hid-capture.sh start /tmp/my.log
```

`start` refuses if a listener is already running (run `stop` first). It:

1. writes + compiles the Swift instrument on the Mac,
2. probes the device and **prints the attached external keyboard before it
   starts** (it aborts if nothing matches the VID/PID filter),
3. launches the listener in the background, detached from the SSH session,
4. verifies the process is alive and the log shows `READY waiting-for-input-events`,
5. prints a PASS/FAIL summary.

The listener keeps writing to the named file **on the Mac** (`/tmp/hid-capture.log`
by default), so it survives the SSH pipe: the operator presses keys on the Mac
while the capture collects independently.

## Read the output

Each line is one key event with these fields:

```
<UTC timestamp> iface=0x100001fda page=0x07 usage=0x001C value=1 mods=0x00 name=Y
```

- `<UTC timestamp>` — ISO-8601 UTC with milliseconds.
- `iface` — which HID interface the event came from (`0x100001fda` boot keyboard
  or `0x100001fd8` composite).
- `page` / `usage` — the HID usage page and usage. Keyboard keys are page
  `0x07`; `usage=0x52` **is Up arrow**. Consumer buttons are page `0x0C`,
  system/power page `0x01`.
- `value` — `1` = press, `0` = release (mouse/axis values can be larger).
- `mods` — the current modifier mask as an 8-bit HID modifier byte (bit 0 =
  LeftControl … bit 7 = RightGUI), tracked from the device's own modifier
  events. `0x02` = LeftShift held.
- `name` — human-readable key name (letters, digits, arrows, modifiers, F-keys,
  and common consumer/system usages; unknown usages print as hex).

The boot-protocol interface also emits array-slot chatter (`usage=0xFFFFFFFF`,
`usage=0x00/0x01`) alongside each real key event; those are **filtered out** so
one physical key = one clean line. Pass `--raw` to the compiled binary directly
to see the unfiltered stream if the array behavior itself needs debugging.

A press of the mystery key will show its true usage. If the theory holds, the
operator will see `usage=0x52 name=UpArrow` for that physical key.

## Stop it

```bash
sudo bash factories/mac/hid-capture.sh stop
```

`stop` kills by pid file and by `pkill -x hid-capture`, then confirms the
process is gone. Check state at any time with:

```bash
sudo bash factories/mac/hid-capture.sh status
```

## Gotchas

- The Mac's login shell is **zsh**: a remote command containing a bare word
  that starts with `=` (e.g. `echo ===FOO===`) dies with
  `zsh:1: ==FOO=== not found`. The script avoids `=` markers.
- The script never needs `sudo` **on the Mac** — `IOHIDManager` reads raw HID
  input as the plain ssh user. (`sudo -n` on the Mac is not even available.)
- **Modifier mask is device-derived and starts at `0x00`.** If a modifier is
  already held before the listener starts (e.g. Shift was down before
  `start`), the mask reflects it only from the next press/release of that
  modifier. Press-and-hold modifiers *during* the capture track correctly.
- If pressing keys produces no new lines but the log shows `READY`, check that
  the device is still the one matched by the VID/PID filter (`status` shows the
  `ATTACHED` header from the last start).
