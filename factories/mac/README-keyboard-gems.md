# mac-keyboard-gems

The good/weird macOS keyboard features a power user can actually have, made
idempotent and reversible — plus a hazard detector for the exact class of
breakage that bit us on 2026-10-01: a `hidutil` `UserKeyMapping` that remapped a
**Command** key to **Fn**, silently killing every ⌘ shortcut on the external
keyboard.

`keyboard-gems.sh` runs on the lima host as root and reaches the Mac over the
key-based SSH that `up.sh` established (`aidanmcohen@192.168.5.2`). It never
needs sudo on the Mac (there is no passwordless sudo there), and it **never**
uses the global `hidutil property --set '{"UserKeyMapping":…}'` form (see the
hazard note below for why).

## Quick start

```bash
sudo bash factories/mac/keyboard-gems.sh --safe          # the clearly-good set
sudo bash factories/mac/keyboard-gems.sh --detect        # hazard scan only
sudo bash factories/mac/keyboard-gems.sh --revert        # undo everything we applied
sudo bash factories/mac/keyboard-gems.sh --cheatsheet    # native shortcut sheet
```

## The gems

| flag | what it does | touches | logout? | reversible? |
|------|-------------|---------|---------|-------------|
| `--key-repeat` | `KeyRepeat=2`, `InitialKeyRepeat=15` | `defaults write -g KeyRepeat` / `InitialKeyRepeat` → `~/Library/Preferences/.GlobalPreferences.plist` (NSGlobalDomain) | yes (logout/restart) | yes (keys deleted) |
| `--press-hold` | `ApplePressAndHoldEnabled=false` | `defaults write -g ApplePressAndHoldEnabled` → same plist | yes (logout/relaunch apps) | yes |
| `--fn-standard` | `com.apple.keyboard.fnState=true` (F1–F12 as standard function keys) | `defaults write -g com.apple.keyboard.fnState` → same plist | no | yes |
| `--capslock-escape` | Caps Lock → Escape | per-device `hidutil` `UserKeyMapping` on the external keyboard (merged) | no (immediate) | yes (entry removed) |
| `--capslock-control` | Caps Lock → Control | same | no (immediate) | yes |

`--safe` is exactly `--key-repeat --press-hold`. The capslock gems and
`--fn-standard` are **debatable** and are opt-in only — they are **not** part
of `--safe`.

Every gem records its *prior* value to `~/.sudofleet-keyboard-gems.state` on
the Mac, so `--revert` restores exactly what was there before, not a guessed
default. Re-running a gem is a no-op (idempotent).

### Rationale

**`--key-repeat` — the single biggest win for a fast typist.** macOS's GUI
sliders cap key repeat well below what the system supports. `KeyRepeat=2` is the
fastest the GUI allows (15 ms per repeat); `InitialKeyRepeat=15` is the shortest
GUI delay (150 ms before a held key starts repeating). Defaults are 6 and 25
respectively — noticeably sluggish for hjkl/arrow-key navigation.

**`--press-hold` — stop the accent popup interrupting you.** By default, holding
a key pops the accented-character picker instead of repeating the character.
`ApplePressAndHoldEnabled=false` makes held keys repeat like a real keyboard.
**Tradeoff (state it clearly):** you lose hold-for-accents (é, ü, ñ, …). This
Mac has only the `U.S.` input source, so that loss is minimal — but it is real.

**`--fn-standard` (debatable).** Makes the top row behave as F1–F12 by default,
with media/brightness moving to `fn`+key. Good for developers/terminal users who
want F-keys; bad if you use one-touch brightness/volume/media.

**`--capslock-escape` / `--capslock-control` (debatable).** The single most
popular power-user remap (vim/tmux users want Escape on Caps Lock). macOS has no
GUI path for Caps Lock→Escape, so this uses `hidutil`. It is applied
**per-device** to the external keyboard and **merges** with whatever is already
mapped there (it never clobbers your existing Control/Option→Command remap).

## The hazard detector (this alone justifies the job)

`--detect` (which also runs automatically before every apply/revert) reads both
the **global** `UserKeyMapping` and the **per-device** `UserKeyMapping` on the
external keyboard, and warns loudly on any mapping whose **source is a Command
key and whose destination is not a Command key** — i.e. anything that eats ⌘.

The exact burn we saw: `HIDKeyboardModifierMappingSrc = 30064771299` (Left
Command) → `HIDKeyboardModifierMappingDst = 1095216660483` (Fn). The detector
prints that as `CRITICAL (Command→Fn kills every ⌘ shortcut)`.

HID usage values (decimal) you'll see in the output, for decoding:

| key | value |
|-----|-------|
| Left Control / Right Control | 30064771296 / 30064771300 |
| Left Option / Right Option | 30064771298 / 30064771302 |
| Left Command / Right Command | 30064771299 / 30064771303 |
| Caps Lock | 30064771129 |
| Escape | 30064771113 |
| Fn / Globe | 1095216660483 |

### Hazard note — the trap this script exists to avoid

`hidutil property --set '{"UserKeyMapping":[…]}'` **without** `--matching` is
global, and a global set **overwrites per-device mappings** (verified live
2026-10-02: a global `--set '{"UserKeyMapping":[]}'` wiped the operator's
existing per-device Control/Option→Command remap). This script therefore only
ever does **per-device** `--matching … --set` with a merge, and never touches the
global set form. Do not "fix" this by hand with a global set/clear.

## Native shortcut cheat sheet (no changes made — these are stock)

```
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
```

## Proposed, not installed (no third-party installs here)

**Per-app menu shortcuts (`NSUserKeyEquivalents`).** macOS stores custom menu
shortcuts as a dict of `"Menu Item Name" → "shortcut string"`, where `@`=⌘,
`~`=⌥, `^`=⌃, `$`=⇧. Two safe examples:

```bash
# global (all apps): bind ⌘⌥M to the "Minimize" menu item
defaults write -g NSUserKeyEquivalents -dict-add "Minimize" "@~m"
# per-app (Finder): bind ⌘N to "New Finder Window"
defaults write com.apple.finder NSUserKeyEquivalents -dict-add "New Finder Window" "@n"
```

We deliberately did **not** script these: they are app-specific, the menu-item
name must match exactly (localized apps differ), and a wrong entry silently
conflicts with an existing shortcut. They belong in a per-app setup file, not a
fleet-wide script.

**Karabiner-Elements.** If you want complex remaps (layers, per-app keys,
hyper-keys, Caps Lock as an Escape/Control *dual* key) — or a Caps Lock remap
that persists across reboots — Karabiner is genuinely better than `hidutil`.
It is a third-party install, so we do not install it; it's the right tool if
`--capslock-*` isn't enough.

**Full Keyboard Access.** `⌃F7` toggles it natively (Tab reaches every control,
not just text fields). We did not script it: its `AppleKeyboardUIMode` default
value on macOS 26 was observed as `1` (not the classic 0/2/3 scheme), so the
defaults lever is murky — use the keyboard or System Settings instead.

## What is dead / unsupported on macOS 26 (be honest)

- **No passwordless sudo on this Mac** (`sudo -n` requires a password), so
  `hidutil` writes are **user-level and session-only**: a Caps Lock remap applied
  here is lost on logout/reboot. To persist it: install a LaunchAgent that
  re-applies the mapping at login, or use `sudo hidutil … --set` once
  interactively, or use Karabiner.
- **`AppleKeyboardUIMode` default is murky** on macOS 26 (observed `1`); the
  classic `defaults write -g AppleKeyboardUIMode -int 3` may not map to the
  current Full Keyboard Access toggle — hence it's documented, not scripted.
- **The external keyboard already carries a per-device remap**
  (Control→Command, Option→Command) — this script detects it as *informational*
  (it eats ⌃/⌥, not ⌘) and leaves it untouched. If you didn't intend that remap,
  it is worth reviewing: on that keyboard there is no Control and no Option key,
  which breaks ⌃/⌥ shortcuts.
