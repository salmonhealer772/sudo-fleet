# mac rgb — reactive per-key RGB on the external SinoWealth keyboard

`rgb.sh` (lima host) + `rgb/rgb.swift` (compiled on the Mac) drive the external
**"Gaming Keyboard"** (VID `0x258A` / PID `0x010C`, a SinoWealth-chip board —
model id **`0xCD` = AULA F75**, 75% ANSI) with live, software-driven per-LED
colour: an idle steady colour ("ping") plus a **white ripple that propagates
outward from each key you press**, fading back to the idle colour.

It is **not** a remap and **not** a daemon. It runs as a plain foreground
process; on exit it restores the idle colour. It never touches `hidutil`
`UserKeyMapping` and never touches `~/Library/LaunchAgents/key-binds-on-start.plist`.

## Files

```
factories/mac/rgb.sh        orchestrator — runs on the lima host as root, reaches
                            the Mac over the key-based SSH (up.sh), compiles
                            rgb.swift there, launches/stops the effect.
factories/mac/rgb/rgb.swift the live program (Swift + IOKit). Compiled on the Mac.
factories/mac/rgb/rgb.py    single source of truth for the LED map + 2-D grid +
                            ripple math, plus a headless ASCII simulator. Its
                            --emit-swift output generates the tables embedded in
                            rgb.swift (keep them in sync: edit rgb.py, re-run
                            `python3 rgb.py --emit-swift`).
factories/mac/rgb/README.md this file.
```

## Commands (from the lima host)

```bash
sudo bash factories/mac/rgb.sh start [R G B]   # reactive ripple, default idle 20 40 120
sudo bash factories/mac/rgb.sh solid R G B     # steady solid colour
sudo bash factories/mac/rgb.sh off             # lights out
sudo bash factories/mac/rgb.sh stop            # stop whatever is running
sudo bash factories/mac/rgb.sh status          # running? + tail the log
sudo bash factories/mac/rgb.sh probe           # read-only: interfaces + model id
sudo bash factories/mac/rgb.sh selftest        # prove GET/SET/INPUT live
sudo bash factories/mac/rgb.sh map [--auto N]  # light each LED one at a time
```

`start` / `solid` / `off` launch the effect detached on the Mac (`nohup` + a pid
file), and `stop` kills it (pid file + `pkill -x rgb`). Logs go to `/tmp/rgb.log`
on the Mac (`/tmp/rgb-map.log` for `map`).

### Run it directly on the Mac (foreground, Ctrl+C to stop)

This is the primary human interface — Aidan opens Terminal and runs:

```bash
ssh aidanmcohen@192.168.5.2   # or sit at the Mac
/tmp/rgb ripple 20 40 120 --fps 60 --log-keys     # idle blue + ripple, log keypresses
/tmp/rgb solid 255 0 0                            # steady red
/tmp/rgb off                                      # lights out
/tmp/rgb map                                      # LED discovery (press any key to advance)
/tmp/rgb selftest                                 # one-shot self-test
/tmp/rgb probe                                    # model id + interfaces
```

Ctrl+C restores the idle/solid colour and exits.

## How it works

### The device (verified live 2026-10-05, do not re-derive)

macOS enumerates **two** HID interfaces for this VID/PID (both reported with
primary usage page 0x01):

| iface | maxInput | maxFeature | role |
|---|---|---|---|
| boot keyboard (usage 0x06) | 8 | 0 | 6KRO keypresses |
| composite (usage 0x80) | 16 | **520** | NKRO keypresses **and** the RGB feature report |

The RGB interface is the one with `maxFeature >= 520` (the composite collection).
It is opened directly; there is no separate `0xFF00` collection enumerated on
macOS (unlike Linux, where OpenRGB sees 3).

### Model-id query (read-only)

Send feature report id `0x06` (520 bytes): `{0x06, 0x82, 0x01, 0x00, 0x01, 0x00, 0x06, 0, …}`,
then read back report id `0x06`. The model id is the response byte at offset **13**.
`0xCD` → AULA F75 (confirmed), also known: `0xA4`=F99, `0x0B`=F87 Pro,
`0xA3`=LEOBOG Hi75C Pro, `0x20`/`0x05`=Redragon K686.

### The RGB write

One 520-byte HID **feature report** (report id `0x06`):

```
byte 0 = 0x06 (report id)      byte 6 = 0x7A
byte 1 = 0x08                  byte 7 = 0x01
byte 4 = 0x01                  bytes 8..  = RGB triplets, one per LED (R,G,B)
```

This is exactly OpenRGB's `SinowealthKeyboard10cController::SetLEDsDirect`
(`Controllers/SinowealthController/SinowealthKeyboard10cController/`). Measured
on the Mac: one `IOHIDDeviceSetReport` = **~10.9 ms** → ~91 fps ceiling, so the
default 60 fps target is comfortable.

**Keepalive is required.** The board reverts out of direct mode ~1 s after the
last packet, so the program sends continuously (idle colour between ripples).
OpenRGB documents the same (`KeepaliveThreadFunction`). There is **no
save-to-flash** on this board (OpenRGB marks it `@save :x:`), so a colour cannot
persist after the process exits — persistence would need a daemon, which this
job deliberately does not install (the operator will decide that later).

### Keypress detection (no permission needed)

An `IOHIDManager` matched on VID/PID, with
`IOHIDManagerRegisterInputValueCallback`, reads raw HID input reports as the
plain ssh user (`aidanmcohen`) — **no Accessibility / Input Monitoring
permission, no root, no GUI step** (verified; same mechanism as
`hid-capture.sh`). Each keyboard-page (0x07) keypress maps via HID usage →
key name → 2-D position, and spawns a ripple at that key.

### The LED map

`rgb/rgb.py` holds the LED-index → key-name map transcribed from OpenRGB's
`aula_f75_layout`, and a physical 2-D grid (ANSI 75%, 1u = 1.0, standard row
stagger). The board has 90 LED slots (indices 0–89) but only 80 are mapped to
keys; the 10 gap indices (`6, 23, 29, 41, 47, 65, 71, 75, 76, 84`) are written
with the idle colour and can be identified with `map`. The ripple uses Euclidean
distance in the grid (speed 40 u/s, ring half-width 0.6 u, decay τ 0.8 s — tune
in rgb.py / rgb.swift `SPEED`/`SIGMA`/`TAU`).

### Ripple math

Per frame, each LED's colour = idle colour blended toward white by
`Σ amp·exp(−(d−r)²/2σ²)` over active ripples, where `r = speed·age`,
`amp = exp(−age/τ)`, `d` = distance from the ripple origin. See
`rgb/rgb.py ripple_color` (and `python3 rgb.py --simulate --keys A S D` for an
ASCII preview).

## Verification (what "done" looked like)

```text
$ rgb probe
matched 2 interface(s):
  iface=0x10000645f … maxIn=8 maxFeature=0   (boot keyboard)
  iface=0x100006463 … maxIn=16 maxFeature=520 (composite / RGB)
model_id = 0xCD (AULA F75)

$ rgb selftest
selftest model_id = 0xCD (AULA F75)
selftest send red   -> 0x00000000 OK  (10.90 ms)
selftest send green -> 0x00000000 OK  (10.81 ms)
selftest send blue  -> 0x00000000 OK  (10.96 ms)
selftest send off   -> 0x00000000 OK  (10.98 ms)
selftest: listening for keypresses for 6s …

$ rgb ripple 20 40 120 --fps 60 --log-keys
ripple 20 40 120 @ 60 fps (Ctrl+C to stop)
KEYPRESS A usage=0x04 pos=(1.875, 3.000)     # ← as you type
KEYPRESS S usage=0x16 pos=(2.875, 3.000)
^C
stopped — restored colour 20 40 120.
```

`0x00000000` is `kIOReturnSuccess` on every frame write; the `KEYPRESS` lines are
the live keypress events feeding the ripple.

## To rebuild the LED map for a different board

1. `rgb probe` → note the model id.
2. If it is not `0xCD`, add the layout to `rgb/rgb.py` (LED map + grid) and the
   model-id name in `rgb.swift`'s `probe`.
3. `rgb map --auto 800` (or `/tmp/rgb map` interactively) lights each LED one at
   a time; write down index → physical key, put it into `rgb.py`, then
   `python3 rgb.py --emit-swift` and rebuild rgb.swift.

## Hard constraints honoured

- Does not touch `~/Library/LaunchAgents/key-binds-on-start.plist`.
- Does not write any `hidutil UserKeyMapping` (global or per-device).
- Installs no LaunchAgent, KeepAlive job, or watcher.
- `rgb.sh` does not edit `keyboard-mode.sh`.
