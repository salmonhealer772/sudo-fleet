# mac keyboard-mode — flip the external board between PC and Mac, and make it stick

`keyboard-mode.sh` flips the operator's external Chinese OEM USB keyboard
(product string **`Gaming Keyboard`**, vendor `BY Tech`, VID `0x258A` /
PID `0x010C`) between **PC muscle-memory** and **native Mac** behaviour, and
keeps it flipped across reboot **and** unplug/re-plug. The MacBook's built-in
keyboard is never touched in either mode.

It runs on the lima host as root and reaches the Mac over the key-based SSH
that `factories/mac/up.sh` established (`aidanmcohen@192.168.5.2`). It is
**dependency-free**: built-in `hidutil` + `launchd` only. No third-party app,
no kernel driver, and — importantly — **no Input-Monitoring / Accessibility
permission** (`hidutil` writes the HID event system directly; it needs neither
`sudo` nor any GUI permission, which we verified live on macOS 26.6.2).

## Run it

```bash
sudo bash factories/mac/keyboard-mode.sh --pc       # PC muscle-memory (persisted)
sudo bash factories/mac/keyboard-mode.sh --mac      # native Mac (persisted)
sudo bash factories/mac/keyboard-mode.sh --status   # show state
sudo bash factories/mac/keyboard-mode.sh --off      # remove everything, restore prior state
```

Each subcommand is idempotent and re-runnable, prints a `✓/✗` PASS/FAIL
summary, and exits non-zero on FAIL. Switching modes needs **no GUI step**.

## What each mode does

| | `--pc` (PC muscle-memory) | `--mac` (native) |
|---|---|---|
| bottom-left Ctrl | → **Command** (Ctrl+C copy, Ctrl+V paste) | stays **Control** |
| bottom-right Ctrl | → **Command** | stays Control |
| Alt (both sides) | → **Command** (Alt+Tab = app switcher) | stays Option |
| Win / Super key | Command (already, native — left alone) | Command (native) |
| global mapping | cleared (empty) | cleared (empty) |
| built-in keyboard | untouched (stock) | untouched (stock) |

The PC map is the exact state the operator applied live on 2026-10-02:

```json
{"UserKeyMapping":[
  {"HIDKeyboardModifierMappingSrc":30064771296,"HIDKeyboardModifierMappingDst":30064771299},  /* L Ctrl -> L Cmd */
  {"HIDKeyboardModifierMappingSrc":30064771300,"HIDKeyboardModifierMappingDst":30064771303},  /* R Ctrl -> R Cmd */
  {"HIDKeyboardModifierMappingSrc":30064771298,"HIDKeyboardModifierMappingDst":30064771303},  /* L Alt  -> R Cmd */
  {"HIDKeyboardModifierMappingSrc":30064771302,"HIDKeyboardModifierMappingDst":30064771303}   /* R Alt  -> R Cmd */
]}
```

scoped with `hidutil property --matching '{"VendorID":9610,"ProductID":268}'`
(`0x258A` / `0x010C`), so it applies to the external board only.

## How a human confirms it

On the **external** board:

- `--pc`: **Ctrl+C** copies, **Ctrl+V** pastes, **Alt+Tab** opens the app
  switcher, and the **Win** key behaves as Command. On the **built-in**
  keyboard, Ctrl+C does *not* copy (it sends Control) — proof the remap is
  scoped to the board.
- `--mac`: **Ctrl+C** no longer copies (it sends Control), **Win** is Command,
  and **Alt+Tab** does nothing special.
- `--status` prints the effective board mapping, the global mapping, and the
  remembered mode — no typing required.

## How persistence works (the load-bearing part)

`hidutil` mappings are **volatile**: they are lost on reboot *and* on keyboard
unplug/re-plug. A plain `RunAtLoad` LaunchAgent only covers login, which is why
the standard recipes half-work for a board that gets unplugged. This tool
installs a `KeepAlive` LaunchAgent running a small watch loop that **re-applies
the remembered mode at login, on every board re-plug, and on a 15 s periodic
safety cycle** (so any clobber self-heals within 15 s).

What it puts on the Mac (all as `aidanmcohen`, no `sudo`):

| path | what |
|---|---|
| `~/.sudofleet-keyboard/mode` | the remembered mode (`pc` or `mac`) |
| `~/.sudofleet-keyboard/watch.sh` | the re-apply loop |
| `~/.sudofleet-keyboard/watch.log` | one line per re-apply / mode change |
| `~/.sudofleet-keyboard/neutralized-key-binds-on-start` | flag: prior-art agent neutralised |
| `~/Library/LaunchAgents/com.sudofleet.keyboard-mode.plist` | the LaunchAgent (`RunAtLoad` + `KeepAlive`) |

`--off` removes all of the above, clears the mappings, and restores the
prior-art agent (see below).

The re-apply is **verified live, not reasoned about**: `--pc`/`--mac` wipe the
board mapping and then watch the watcher restore it on its own within 15 s,
and report that as a PASS/FAIL check. The one thing that cannot be simulated
remotely is the physical unplug/re-plug — the same `apply()` runs on that
trigger (presence change, detected via `hidutil list`), and the operator can
confirm it by unplugging the board and seeing the mode return.

## Prior art — checked, not blindly adopted

- **`~/Library/LaunchAgents/key-binds-on-start.plist`** (operator's own, from a
  prior experiment): a `RunAtLoad` agent that sets a **global** `Left Command
  → Fn` mapping at every login — the exact thing the operator cleared today
  because it broke every ⌘ shortcut. It **conflicts** with our cleared-global
  state, so `--pc`/`--mac` **neutralise it** (`launchctl bootout` + `disable`)
  and record the fact; `--off` re-enables it (without re-applying its broken
  mapping). `--status` reports its state.
- **`~/bin/mac-kbd-watch`** (operator's own, for a *different* keyboard —
  `Vulcan II TKL`, VID `0x10f5`/PID `0x502a`): a `KeepAlive` watch loop that
  polls `hidutil list` for device presence and re-applies per-device mappings.
  This is the proven pattern our watcher reuses (polling presence + re-apply),
  but scoped to this board and driven by a mode file instead of the frontmost
  app. Not loaded, not touched.
- **hidutil + `RunAtLoad` LaunchAgent recipes** (rakhesh.com, nanoANT, Amit's
  Thoughts): correct for the login case, but they do **not** survive unplug/
  re-plug — insufficient for this board, hence the watch loop.
- **`autokbisw`**: a per-keyboard *input-source* switcher, not a modifier
  remapper — wrong tool, and a compiled daemon (not dependency-free).
- **Karabiner-Elements**: kernel driver + extensive permissions — heavy for 4
  modifier maps. Rejected.

## Permissions / what could block it

- **No permission needed.** `hidutil property --set` writes the HID event
  system directly as the plain user; it does not use `CGEventTap`, so there is
  **no Input-Monitoring prompt and no `sudo`**. Verified live: the mapping is
  applied and `sudo -n` on the Mac reports "a password is required" (i.e. we
  never needed it).
- **macOS version caveat.** `hidutil` remapping was reported broken on
  macOS 13.6 and 14.2. This Mac is **26.6.2**, where it works (verified). If a
  mapping ever silently stops applying, run `--status` and confirm the macOS
  version first.
- If the operator ever does want a `LaunchDaemon` (system-wide, survives before
  login), that *would* require `sudo` on the Mac — not needed here, so we stay
  in the user domain.

## Gotchas

- The Mac's login shell is **zsh**: a remote command with a bare word starting
  with `=` (e.g. `echo ===FOO===`) dies with `zsh:1: ==FOO=== not found`. The
  script runs everything as `bash /tmp/xxx.sh`, so this never bites.
- All paths, VID/PID and key codes are hardcoded facts verified live
  2026-10-02; they are not re-derived at runtime.
- `--status` is read-only and harmless to run at any time.
