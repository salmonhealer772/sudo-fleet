# mac keyboard-mode — flip between his two keyboards

`keyboard-mode.sh` flips the operator between **his two keyboards**:

- **`--mac`** — *"my mac keyboard"*: his **baseline, exactly**. It re-applies
  his global `UserKeyMapping` verbatim from
  `~/Library/LaunchAgents/key-binds-on-start.plist` (the `Left Command ↔ Fn`
  swap, so **Fn acts as Command — Fn+C copies, Fn+V pastes**) and applies
  **no** per-device override on the external board.
- **`--chinese`** — *"the chinese keyboard"*: his baseline **left completely
  alone**, **plus** a per-device override on the external board only, in the
  **paired form** (bare pass-through + modified-key), so `Ctrl+C`, `Ctrl+V`
  and `Alt+Tab` work with the Windows-keyboard hand position **and** `Ctrl+C`
  still works as a shell interrupt in the terminal — both at the same time.

The MacBook's built-in keyboard is never given a per-device override in either
mode; it just follows his global baseline.

It runs on the lima host as root and reaches the Mac over the key-based SSH
that `factories/mac/up.sh` established (`aidanmcohen@192.168.5.2`). It is
**dependency-free**: built-in `hidutil` only. No watcher, no LaunchAgent, no
third-party app, no kernel driver, no Input-Monitoring / Accessibility
permission (`hidutil` writes the HID event system directly; verified live on
macOS 26.6.2).

## Run it

```bash
sudo bash factories/mac/keyboard-mode.sh --mac      # his baseline (my mac keyboard)
sudo bash factories/mac/keyboard-mode.sh --chinese  # baseline + board override (the chinese keyboard)
sudo bash factories/mac/keyboard-mode.sh --status   # read-only: three layers, separately
sudo bash factories/mac/keyboard-mode.sh --toggle   # flip mac <-> chinese
sudo bash factories/mac/keyboard-mode.sh --off      # remove our override + state + old agent; leave his baseline + plist alone
```

Each subcommand is idempotent and re-runnable, prints a `✓/✗` PASS/FAIL
summary, and exits non-zero on FAIL. Switching modes needs **no GUI step**.

## What each mode does

| | `--mac` ("my mac keyboard") | `--chinese` ("the chinese keyboard") |
|---|---|---|
| global mapping | **his baseline, re-applied verbatim** if drifted | **left completely alone** |
| board (external) override | none (board follows his baseline) | paired: bare Ctrl/Alt pass through + held Ctrl→Cmd, held Alt→Alt+Tab |
| copy / paste | Fn+C / Fn+V (Fn is Command) | Ctrl+C / Ctrl+V |
| app switcher | Fn+Tab | Alt+Tab |
| built-in keyboard | stock (follows baseline) | stock (follows baseline) |

His baseline global mapping (verbatim — the only global `UserKeyMapping` this
tool ever writes, and only in `--mac`):

```json
{"UserKeyMapping":[
  {"HIDKeyboardModifierMappingSrc":30064771299,"HIDKeyboardModifierMappingDst":1095216660483},  /* L Cmd -> Fn */
  {"HIDKeyboardModifierMappingSrc":1095216660483,"HIDKeyboardModifierMappingDst":30064771299},  /* Fn -> L Cmd */
  {"HIDKeyboardModifierMappingSrc":280379760050192,"HIDKeyboardModifierMappingDst":30064771132} /* Apple vendor 0x10 -> F3 */
]}
```

The `--chinese` board override (per-device only, scoped with
`--matching '{"VendorID":9610,"ProductID":268}'`, i.e. `0x258A`/`0x010C`) is the
**paired form**: four entries, bare pass-through + modified-key. It exists
specifically so `Ctrl+C` works **both** as copy/paste **and** as a shell
interrupt in the terminal at the same time:

```json
{"UserKeyMapping":[
  {"HIDKeyboardModifierMappingSrc":30064771296,"HIDKeyboardModifierMappingDst":30064771299},  /* bare L Ctrl -> L Cmd (Ctrl+C/V = Cmd+C/V) */
  {"HIDKeyboardModifierMappingSrc":30064771298,"HIDKeyboardModifierMappingDst":30064771303},  /* bare L Alt  -> R Cmd (Alt+Tab) */
  {"HIDKeyboardModifierMappingSrc":47244640384,"HIDKeyboardModifierMappingDst":47244640391},  /* held Ctrl   -> Cmd (0x1:0xE3) */
  {"HIDKeyboardModifierMappingSrc":47244640386,"HIDKeyboardModifierMappingDst":47244640515}   /* held Alt    -> Alt+Cmd (0x1:0x1000003) */
]}
```

The `47244640xxx` entries are the "this modifier is held while this key is
pressed" form (`0x100000000 + key`). Net effect: **bare Ctrl stays a real
Control key** — the terminal still receives a Control key, so `Ctrl+C` still
interrupts — while **held Ctrl becomes Command**, so `Ctrl+C`/`Ctrl+V` reach
the app as `Cmd+C`/`Cmd+V`. Both work at once. (The old all-bare form mapped
bare Ctrl → Cmd and killed SIGINT in the terminal; it is rejected.)

## `--status` — the three layers, separately

```
baseline_global=applied|drifted|empty|other   (a) his baseline global mapping
board_override=chinese|other|absent           (b) the board override
remembered_mode=mac|chinese|none              (c) which mode is remembered
board_attached=yes|no                         (d) is the board plugged in
--- global mapping ---
<raw hidutil readback>
--- board mapping ---
<raw hidutil readback>
```

## How a human confirms it

- `--mac`: **Fn+C** copies, **Fn+V** pastes (Fn acts as Command). On the
  external board, `Ctrl+C` does *not* copy (it sends Control) — proof there is
  no board override.
- `--chinese`: on the external board **Ctrl+C** copies, **Ctrl+V** pastes,
  **Alt+Tab** opens the app switcher — and in a terminal **Ctrl+C** still
  interrupts (bare Ctrl stays a real Control key; held Ctrl is Command). On
  the built-in keyboard Ctrl+C still sends Control (the override is scoped to
  the board only).
- `--status` prints the three layers — no typing required.

## Persistence (deliberately minimal)

`hidutil` mappings are **volatile** (lost on reboot and on unplug/re-plug).
This revision installs **no watcher and no LaunchAgent** — a keep-alive
re-apply loop is what fought his configuration all session, so it is gone.

- **`--mac`** persists because it *is* his baseline, and his own
  `key-binds-on-start.plist` re-applies that baseline at login. We only
  restore it if it drifted.
- **`--chinese`** applies the board override live; it is **not** persisted
  across reboot/re-plug by this tool. Re-running `--chinese` (or `--toggle`)
  re-applies it. If the operator wants the board override to survive
  reboot/re-plug, that needs a one-shot `RunAtLoad` agent that re-applies the
  *remembered* mode once at login — that is a running agent and is **not
  installed here**; it should be agreed before adding.

The remembered mode lives in `~/.sudofleet-keyboard/mode` (nothing else of ours
is on the Mac).

## Hard rules this revision enforces

- The **only** global `UserKeyMapping` we ever write is **his baseline,
  verbatim**. Never empty, never ours. In `--mac` we re-apply it if it drifted;
  in `--chinese` we leave it completely alone.
- We **never** rename, disable, move, or overwrite
  `key-binds-on-start.plist`, and we do not touch its launchd disabled-state.
  (The old `neutralized-key-binds-on-start` logic and `.disabled` handling are
  removed.)
- No watcher, no LaunchAgent that writes `UserKeyMapping`.
- The `--chinese` override is the **paired form** (bare pass-through +
  modified-key), never the all-bare form: bare Ctrl must stay a real Control
  key so `Ctrl+C` still interrupts in a terminal, while held Ctrl becomes
  Command for copy/paste.

## Prior art — checked, not blindly adopted

- **`~/Library/LaunchAgents/key-binds-on-start.plist`** (operator's own): a
  `RunAtLoad` agent that applies his **baseline** global mapping at every
  login. This is the feature, not debris — it is the persistence for `--mac`.
  We leave it alone.
- **`~/Library/LaunchAgents/com.sudofleet.keyboard-mode.plist`** (the *old*
  revision of this tool): a `KeepAlive` watcher. Removed by this revision; a
  leftover one is cleaned up by `--off`.
- **`autokbisw`**: a per-keyboard *input-source* switcher — wrong tool.
- **Karabiner-Elements**: kernel driver + permissions — heavy for 4 modifier
  maps. Rejected.

## Permissions / what could block it

- **No permission needed.** `hidutil property --set` writes the HID event
  system directly as the plain user; no `sudo`, no Input-Monitoring prompt.
  Verified live on macOS 26.6.2.
- `hidutil` remapping was reported broken on macOS 13.6 / 14.2; this Mac is
  26.6.2 where it works. If a mapping silently stops applying, run `--status`
  and confirm the macOS version first.

## Gotchas

- The Mac's login shell is **zsh**: a bare word starting with `=` dies with
  `zsh:1: ==FOO=== not found`. The script runs everything as `bash /tmp/xxx.sh`,
  so this never bites.
- All paths, VID/PID and key codes are hardcoded facts verified live
  2026-10-02; they are not re-derived at runtime.
- `--status` is read-only and harmless to run at any time.
