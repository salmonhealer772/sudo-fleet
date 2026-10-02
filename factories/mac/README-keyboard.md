# mac factory — make the Chinese OEM keyboard type as its own native layout

`keyboard-native.sh` makes macOS treat the external Chinese OEM keyboard
(**BY Tech "Gaming Keyboard"**, VID `0x258A` / PID `0x010C`, a SinoWealth-chip
board) as its **own native physical layout**, so every key types what is printed
on the keycap — with **no imposed Apple remapping**. It is the keyboard's
*physical type* being fixed here, not its input source.

## Run it

```bash
sudo bash factories/mac/keyboard-native.sh                 # set ANSI (default)
sudo bash factories/mac/keyboard-native.sh --layout iso    # ISO instead
sudo bash factories/mac/keyboard-native.sh --layout jis    # JIS instead
sudo bash factories/mac/keyboard-native.sh --value 41      # explicit type integer
sudo bash factories/mac/keyboard-native.sh --revert        # restore the prior value
sudo bash factories/mac/keyboard-native.sh --dry-run       # report only, change nothing
```

Runs on the **lima host as root**, reaches the Mac over **SSH** (key-based,
BatchMode, user `aidanmcohen@192.168.5.2`). Zero interactive prompts.

To run it fully non-interactively with a sudo password (the plist is a system
file, so writing it needs root on the Mac):

```bash
MAC_SUDO_PASSWORD='…' sudo -E bash factories/mac/keyboard-native.sh
```

If `aidanmcohen` ever gets passwordless sudo, the password is unnecessary —
the script tries `sudo -n` first, then falls back to the supplied password.

## What it guarantees

1. **One key, one change.** It sets exactly `keyboardtype."268-9610-0"` in
   `/Library/Preferences/com.apple.keyboardtype.plist` (product `268` / vendor
   `9610` / location `0`), via a `plistlib` mutation that preserves every other
   keyboard's entry and the binary-plist format. Nothing else in that file is
   touched.
2. **The enabled input source is left alone.** It is `U.S.` (KeyboardLayout ID
   0); the script never reads or writes input sources.
3. **Idempotent.** Re-running is a no-op once the value is already correct.
4. **Reversible.** `--revert` restores the exact prior value (captured to
   `factories/mac/.keyboard-native.state` on every successful apply, or the
   documented original `41` if no state file exists). `--revert --value N`
   restores an explicit value.
5. **The operator's key remaps are preserved, never touched.** Every run
   inventories the live `hidutil UserKeyMapping` and the launch agent that
   re-applies it, and reports it. That mapping — **Fn ↔ Command** (so **Fn+C
   copies and Fn+V pastes**, "like a windows keyboard") plus a vendor-key→F2
   entry — is the operator's **deliberate** configuration. The script has **no
   flag** that clears, renames, unloads, or overrides it, and it installs **no**
   launch agent of its own. It only ever reads those remaps to report them.
6. **Verified for real.** It reads the value back after writing and shows the
   effective per-device type; it fails loudly (non-zero) if the write did not
   take or sudo is unavailable.

## The layout evidence (ANSI, with the honest caveat)

The definitive ANSI/ISO/JIS signal is the keyboard's **HID report descriptor**.
The keyboard is **currently NOT connected**, so that descriptor cannot be read
live — the script states this rather than pretending.

The evidence for **ANSI (type 40)**:

1. The two *other* external keyboards on this Mac are already typed **ANSI
   (40)** and are the operator's working boards; this board is the odd one out.
2. The board is a generic **SinoWealth "Gaming Keyboard"** (BY Tech) —
   Chinese-mainland OEM boards of this class ship **ANSI** (long Left Shift,
   horizontal Enter) with US-English + Chinese legends.
3. The operator's intent — *"just tell mac 'do what this Chinese keyboard
   layout is'"* — combined with the enabled **U.S.** input source means an ANSI
   board typing its own keycaps with zero remapping.
4. The current on-disk value **41 (ISO)** is exactly the mismatch that
   transposes the key right of Left Shift and the key left of "1" — the classic
   "wrong keyboard type" symptom.

**The single keypress that would confirm it** (Apple's own method): the key
**immediately to the right of Left Shift**. On ANSI that key is **Z**; on ISO it
is an extra **`\|`** key; on JIS it is different. If that key types Z, the board
is ANSI and the default is correct. If it types `\` or `|`, re-run with
`--layout iso`. (`--layout jis` for a JIS board.) The script's default is ANSI
**because** the evidence points there — but it is an explicit, overridable
default, not a silent one.

## The cost to apply (stated plainly)

The plist write itself needs **root on the Mac** (sudo over SSH). There is no
user-level or virtiofs route around this: the `/mnt/mac` mount is exported by a
daemon running as `aidanmcohen` (admin, not root), so it cannot write the
root-owned `/Library/Preferences` — verified live.

macOS reads the per-device keyboard type only when the keyboard is
**(re)enumerated** — there is **no HID daemon to restart** that re-reads it.
Therefore:

- **Keyboard currently disconnected (today's state):** the change simply
  persists and applies the **next time it is plugged in**. No further step.
- **Keyboard already connected:** apply = **unplug and re-plug it**, or log
  out/in, or reboot. No GUI step.

A logout/reboot is **not** required just to write the plist — it is one of the
ways to trigger re-enumeration when the board is already plugged in.

## How a human confirms it worked

1. Plug the keyboard in (or re-plug it if it was already connected).
2. Open TextEdit and type the **key immediately to the right of Left Shift**:
   it must produce **Z** (ANSI). Then type the **key immediately to the left of
   "1"**: it must produce **`** (backtick), not **§**.
3. Or check the record directly on the Mac:
   `defaults read /Library/Preferences/com.apple.keyboardtype.plist` — the
   `268-9610-0` entry should be `40`.

## The global remaps (inventory only — the operator's config)

macOS has three non-native **global** key remaps (they apply to *every*
keyboard, not just this one), defined in the operator's launch agent
`~/Library/LaunchAgents/key-binds-on-start.plist` (`RunAtLoad`), with a
`.bak-fa24` backup holding an earlier 2-mapping version:

| Mapping | Meaning |
|---|---|
| `0x7000000E3 → 0xFF00000003` | Left Command → Apple Fn |
| `0xFF00000003 → 0x7000000E3` | Apple Fn → Left Command  (with the above: **Cmd ↔ Fn swap**) |
| `0xFF0100000010 → 0x70000003C` | vendor key `0xFF01:0x10` → **F2** |

This mapping is **deliberate**, not leftover: it is what makes **Fn+C copy**
and **Fn+V paste** work, which is the operator's stated goal ("on the mac i want
fn c fn v to work as my copy paist os its like a winodws keybaird"). It is
inventoried and reported on every run and is **never** cleared, renamed,
unloaded, or overridden by this script. The launch agent is the persistence;
the live `hidutil --get UserKeyMapping` reads the same three entries whenever
the agent has run (it re-applies them at a GUI login).

## Verified live (2026-10-02)

- Read back `keyboardtype` entries: `{"153-5426-0": 40, "20522-4341-0": 40, "268-9610-0": 41}`.
- `--dry-run`, idempotent `--value 41`, `--revert`, and the sudo-failure path
  all exercised against the live Mac; the sudo-failure path exits 1 with the
  exact manual command:
  `sudo defaults write /Library/Preferences/com.apple.keyboardtype.plist keyboardtype -dict-add "268-9610-0" -integer 40`.
- The write was **not** applied live: it requires the Mac sudo password, which
  was not available in the run context (no passwordless sudo). The script is
  ready to apply on the next run that supplies `MAC_SUDO_PASSWORD`.
