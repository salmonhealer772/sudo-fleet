#!/usr/bin/env python3
"""
rgb.py — the authoring half of the reactive-RGB system for Aidan's external
"SinoWealth / BY Tech Gaming Keyboard" (VID 0x258A, PID 0x010C).

This file is the SINGLE SOURCE OF TRUTH for the three pieces of data the live
Swift program (rgb.swift) needs, plus a headless simulator you can run on any
box (including the lima host) to preview the ripple and sanity-check the map
without touching the keyboard:

  1. LED index -> key name        (reverse-engineered from OpenRGB's AULA F75
                                  keymap; model id 0xCD was confirmed live on
                                  the Mac 2026-10-05 via the model-id query).
  2. key name -> (x, y)           (physical 2-D grid, ANSI 75% layout, 1u = 1.0;
                                  used for ripple distance).
  3. HID usage -> key name        (for mapping a keypress to a ripple origin).

The Swift binary does the live HID I/O; this file GENERATES the tables it
embeds (see `--emit-swift`) so the two never drift.

Usage:
  rgb.py --ledmap               print LED index -> key name -> (x,y), full table
  rgb.py --simulate             ASCII animation of an idle-color + ripple
  rgb.py --simulate --keys A S D  fire ripples from those keys in sequence
  rgb.py --emit-swift           print the Swift arrays to paste into rgb.swift
  rgb.py --models               list known model ids and their LED counts
"""

from __future__ import annotations

import math
import sys
import time

# ─────────────────────────────────────────────────────────────────────────────
# 1. LED map — model id 0xCD ("AULA F75"), 75% ANSI, 80 mapped LEDs,
#    indices 0..89 (sparse). Transcribed from OpenRGB
#    Controllers/SinowealthController/SinowealthKeyboard10cController/
#    SinowealthKeyboard10cDevices.cpp (aula_f75_layout), confirmed live.
# ─────────────────────────────────────────────────────────────────────────────

F75_LED_MAP: dict[int, str] = {
    # column 0 (left modifier / alnum left edge)
    0: "ESC", 1: "BACKTICK", 2: "TAB", 3: "CAPSLOCK", 4: "LSHIFT", 5: "LCTRL",
    # column 1
    7: "1", 8: "Q", 9: "A", 10: "Z", 11: "LWIN", 12: "F1",
    # column 2
    13: "2", 14: "W", 15: "S", 16: "X", 17: "LALT", 18: "F2",
    # column 3
    19: "3", 20: "E", 21: "D", 22: "C", 24: "F3",
    # column 4
    25: "4", 26: "R", 27: "F", 28: "V", 30: "F4",
    # column 5
    31: "5", 32: "T", 33: "G", 34: "B", 36: "F5",
    # column 6
    37: "6", 38: "Y", 39: "H", 40: "N", 42: "F6",
    # column 7
    43: "7", 44: "U", 45: "J", 46: "M", 48: "F7",
    # column 8
    49: "8", 50: "I", 51: "K", 52: "COMMA", 54: "F8",
    # column 9
    55: "9", 56: "O", 57: "L", 58: "PERIOD", 60: "F9",
    # column 10
    61: "0", 62: "P", 63: "SEMICOLON", 64: "SLASH", 66: "F10",
    # column 11
    67: "MINUS", 68: "LEFTBRACKET", 69: "QUOTE", 70: "RSHIFT", 72: "F11",
    # column 12
    73: "EQUAL", 74: "RIGHTBRACKET", 77: "LEFT", 78: "F12",
    # column 13 (right edge of the alnum block)
    79: "BACKSPACE", 80: "BACKSLASH", 81: "ENTER", 82: "UP", 83: "DOWN",
    # column 14 (far-right nav cluster)
    85: "DEL", 86: "PGUP", 87: "PGDN", 88: "END", 89: "RIGHT",
    # special wide keys that sit at an "offset" column in the logical matrix
    35: "SPACE", 53: "FN", 59: "RCTRL",
}

# Unmapped (gap) indices — no key is known to light them. They are still
# written (idle colour) so the whole board stays uniformly lit; the `map`
# command lights them one at a time so Aidan can identify what (if anything)
# is physically there.
GAP_INDICES = sorted(set(range(90)) - set(F75_LED_MAP.keys()))

LED_COUNT = 90  # indices 0..89 (max mapped index + 1)

# ─────────────────────────────────────────────────────────────────────────────
# 2. Physical grid — key name -> (x, y). ANSI 75% layout, 1u = 1.0 horizontally,
#    1 row = 1.0 vertically. x = key CENTER (left edge + width/2). Standard
#    ANSI stagger is baked into the row offsets. Good enough for a ripple;
#    exact mm not required.
# ─────────────────────────────────────────────────────────────────────────────

# row stagger (left-edge x offset of the row), then per-key (left_edge, width)
_F75_GRID: dict[str, tuple[float, float]] = {
    # row 0 — F row (y=0)
    "ESC": (0.5, 0.0),
    "F1": (2.0, 0.0), "F2": (3.0, 0.0), "F3": (4.0, 0.0), "F4": (5.0, 0.0),
    "F5": (6.5, 0.0), "F6": (7.5, 0.0), "F7": (8.5, 0.0), "F8": (9.5, 0.0),
    "F9": (11.0, 0.0), "F10": (12.0, 0.0), "F11": (13.0, 0.0), "F12": (14.0, 0.0),
    # row 1 — number row (y=1)
    "BACKTICK": (0.5, 1.0),
    "1": (1.5, 1.0), "2": (2.5, 1.0), "3": (3.5, 1.0), "4": (4.5, 1.0),
    "5": (5.5, 1.0), "6": (6.5, 1.0), "7": (7.5, 1.0), "8": (8.5, 1.0),
    "9": (9.5, 1.0), "0": (10.5, 1.0), "MINUS": (11.5, 1.0), "EQUAL": (12.5, 1.0),
    "BACKSPACE": (14.0, 1.0), "DEL": (15.5, 1.0),
    # row 2 — Q row (y=2, stagger +0.25)
    "TAB": (0.75, 2.0),
    "Q": (1.75, 2.0), "W": (2.75, 2.0), "E": (3.75, 2.0), "R": (4.75, 2.0),
    "T": (5.75, 2.0), "Y": (6.75, 2.0), "U": (7.75, 2.0), "I": (8.75, 2.0),
    "O": (9.75, 2.0), "P": (10.75, 2.0), "LEFTBRACKET": (11.75, 2.0),
    "RIGHTBRACKET": (12.75, 2.0), "BACKSLASH": (14.0, 2.0), "PGUP": (15.5, 2.0),
    # row 3 — A row (y=3, stagger +0.5)
    "CAPSLOCK": (0.875, 3.0),
    "A": (1.875, 3.0), "S": (2.875, 3.0), "D": (3.875, 3.0), "F": (4.875, 3.0),
    "G": (5.875, 3.0), "H": (6.875, 3.0), "J": (7.875, 3.0), "K": (8.875, 3.0),
    "L": (9.875, 3.0), "SEMICOLON": (10.875, 3.0), "QUOTE": (11.875, 3.0),
    "ENTER": (13.625, 3.0), "PGDN": (15.5, 3.0),
    # row 4 — Z row (y=4, stagger +0.75)
    "LSHIFT": (1.125, 4.0),
    "Z": (2.625, 4.0), "X": (3.625, 4.0), "C": (4.625, 4.0), "V": (5.625, 4.0),
    "B": (6.625, 4.0), "N": (7.625, 4.0), "M": (8.625, 4.0), "COMMA": (9.625, 4.0),
    "PERIOD": (10.625, 4.0), "SLASH": (11.625, 4.0), "RSHIFT": (13.375, 4.0),
    "UP": (15.0, 4.0), "END": (16.0, 4.0),
    # row 5 — space row (y=5, stagger +0.25)
    "LCTRL": (0.875, 5.0), "LWIN": (1.875, 5.0), "LALT": (2.875, 5.0),
    "SPACE": (6.5, 5.0), "FN": (10.25, 5.0), "RCTRL": (11.25, 5.0),
    "LEFT": (14.0, 5.0), "DOWN": (15.0, 5.0), "RIGHT": (16.0, 5.0),
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. HID usage -> key name (keyboard page 0x07), for keypress -> ripple origin.
# ─────────────────────────────────────────────────────────────────────────────

HID_USAGE_TO_KEY: dict[int, str] = {
    0x04: "A", 0x05: "B", 0x06: "C", 0x07: "D", 0x08: "E", 0x09: "F",
    0x0A: "G", 0x0B: "H", 0x0C: "I", 0x0D: "J", 0x0E: "K", 0x0F: "L",
    0x10: "M", 0x11: "N", 0x12: "O", 0x13: "P", 0x14: "Q", 0x15: "R",
    0x16: "S", 0x17: "T", 0x18: "U", 0x19: "V", 0x1A: "W", 0x1B: "X",
    0x1C: "Y", 0x1D: "Z",
    0x1E: "1", 0x1F: "2", 0x20: "3", 0x21: "4", 0x22: "5", 0x23: "6",
    0x24: "7", 0x25: "8", 0x26: "9", 0x27: "0",
    0x28: "ENTER", 0x29: "ESC", 0x2A: "BACKSPACE", 0x2B: "TAB",
    0x2C: "SPACE", 0x2D: "MINUS", 0x2E: "EQUAL", 0x2F: "LEFTBRACKET",
    0x30: "RIGHTBRACKET", 0x31: "BACKSLASH", 0x33: "SEMICOLON",
    0x34: "QUOTE", 0x35: "BACKTICK", 0x36: "COMMA", 0x37: "PERIOD",
    0x38: "SLASH", 0x39: "CAPSLOCK",
    0x3A: "F1", 0x3B: "F2", 0x3C: "F3", 0x3D: "F4", 0x3E: "F5", 0x3F: "F6",
    0x40: "F7", 0x41: "F8", 0x42: "F9", 0x43: "F10", 0x44: "F11", 0x45: "F12",
    0x4C: "DEL", 0x4A: "HOME", 0x4B: "PGUP", 0x4D: "END", 0x4E: "PGDN",
    0x4F: "RIGHT", 0x50: "LEFT", 0x51: "DOWN", 0x52: "UP",
    0xE0: "LCTRL", 0xE1: "LSHIFT", 0xE2: "LALT", 0xE3: "LWIN",
    0xE4: "RCTRL", 0xE5: "RSHIFT", 0xE6: "RALT", 0xE7: "RWIN",
}

# Keys that exist in the HID table but have no LED on this board (harmless).
# "FN" and "RALT" have no HID usage on this board's consumer/system pages; FN is
# reported as a consumer/system key, not keyboard-page, so it won't trigger here.


def led_positions() -> dict[int, tuple[float, float] | None]:
    """LED index -> (x, y) physical centre, or None for gap indices."""
    out: dict[int, tuple[float, float] | None] = {}
    for i in range(LED_COUNT):
        key = F75_LED_MAP.get(i)
        out[i] = _F75_GRID.get(key) if key else None
    return out


def key_position(key: str) -> tuple[float, float] | None:
    return _F75_GRID.get(key)


# ─────────────────────────────────────────────────────────────────────────────
# Ripple model — the exact math rgb.swift runs per frame. Kept here so it can be
# simulated headlessly and tweaked in one place.
# ─────────────────────────────────────────────────────────────────────────────

def ripple_color(px: float, py: float, idle: tuple[int, int, int],
                 ripples: list[tuple[float, float, float]], now: float) -> tuple[int, int, int]:
    """Colour of an LED at (px,py) given a set of active ripples.

    ripples: list of (cx, cy, t0) — ripple centre and start time.
    A ripple is a white Gaussian ring expanding at SPEED u/s, fading over TAU.
    """
    r, g, b = idle
    if not ripples:
        return (r, g, b)
    total = 0.0
    for (cx, cy, t0) in ripples:
        age = now - t0
        if age < 0 or age > MAX_AGE:
            continue
        d = math.hypot(px - cx, py - cy)
        radius = SPEED * age
        amp = math.exp(-age / TAU)
        total += amp * math.exp(-((d - radius) ** 2) / (2.0 * SIGMA * SIGMA))
    total = min(1.0, total)
    return (
        int(round(r + (255 - r) * total)),
        int(round(g + (255 - g) * total)),
        int(round(b + (255 - b) * total)),
    )


SPEED = 40.0   # ripple wavefront speed, key-units per second
SIGMA = 0.6    # ripple ring half-width, key-units
TAU = 0.8      # ripple amplitude decay time constant, seconds
MAX_AGE = 2.5  # drop a ripple entirely after this many seconds


# ─────────────────────────────────────────────────────────────────────────────
# Model registry (for --models / future boards)
# ─────────────────────────────────────────────────────────────────────────────
MODELS = {
    0xCD: ("AULA F75", 90, F75_LED_MAP),
    0xA4: ("AULA F99", 113, None),
    0x0B: ("AULA F87 Pro", 102, None),
    0xA3: ("LEOBOG Hi75C Pro", 90, None),
    0x20: ("Redragon K686 Eisa Pro", 113, None),
    0x05: ("Redragon K686 Eisa Pro", 113, None),
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def _emit_swift() -> None:
    pos = led_positions()
    print("// AUTO-GENERATED by rgb.py --emit-swift. Do not edit by hand.")
    print("let LED_POSITIONS: [Int32] = [  // index -> (x*1000, y*1000); -1 = gap")
    for i in range(LED_COUNT):
        p = pos[i]
        if p is None:
            print(f"    -1, -1, // {i}: (gap)")
        else:
            key = F75_LED_MAP[i]
            print(f"    {int(round(p[0]*1000))}, {int(round(p[1]*1000))}, // {i}: {key}")
    print("]")
    print()
    print("let LED_KEY_NAMES: [Int32: String] = [  // LED index -> key name (mapped LEDs only)")
    for i in range(LED_COUNT):
        key = F75_LED_MAP.get(i)
        if key:
            print(f'    {i}: "{key}",')
    print("]")
    print()
    print("let KEY_POSITIONS: [String: (x: Int32, y: Int32)] = [")
    for key, (x, y) in sorted(_F75_GRID.items()):
        print(f'    "{key}": ({int(round(x*1000))}, {int(round(y*1000))}),')
    print("]")
    print()
    print("let HID_USAGE_TO_KEY: [Int32: String] = [")
    for usage, key in sorted(HID_USAGE_TO_KEY.items()):
        print(f'    {usage}: "{key}",')
    print("]")


def _simulate(keys: list[str]) -> None:
    pos = led_positions()
    idle = (20, 40, 120)  # a calm blue "ping"
    # build a terminal grid (roughly matching the board's aspect)
    xs = [p[0] for p in pos.values() if p]
    ys = [p[1] for p in pos.values() if p]
    xmin, xmax = min(xs), max(xs)
    ymin, ymax = min(ys), max(ys)
    W = 100
    H = 16
    sx = (W - 2) / (xmax - xmin + 1)
    sy = (H - 2) / (ymax - ymin + 1)

    def screen(p):
        x, y = p
        return int((x - xmin) * sx) + 1, int((y - ymin) * sy) + 1

    ripples: list[tuple[float, float, float]] = []
    fire_every = 0.35
    key_i = 0
    last_fire = -1.0
    t0 = time.time()
    try:
        while True:
            now = time.time() - t0
            if keys and now - last_fire >= fire_every:
                key = keys[key_i % len(keys)]
                kp = key_position(key)
                if kp:
                    ripples.append((kp[0], kp[1], now))
                last_fire = now
                key_i += 1
            ripples = [r for r in ripples if now - r[2] <= MAX_AGE]
            # render
            grid = [[" "] * W for _ in range(H)]
            for i in range(LED_COUNT):
                p = pos[i]
                if not p:
                    continue
                col = ripple_color(p[0], p[1], idle, ripples, now)
                sx_, sy_ = screen(p)
                grid[sy_][sx_] = "@" if sum(col) > 300 else "+"
            out = "\n".join("".join(row) for row in grid)
            sys.stdout.write("\033[H\033[2J" + out + "\n")
            sys.stdout.flush()
            time.sleep(0.05)
    except KeyboardInterrupt:
        print("\n(stopped)")


def _ledmap() -> None:
    pos = led_positions()
    print(f"model: AULA F75 (id 0xCD) — {LED_COUNT} LED slots, {len(F75_LED_MAP)} mapped keys")
    print(f"{'LED':>3}  {'key':<12} {'x':>7} {'y':>7}")
    for i in range(LED_COUNT):
        key = F75_LED_MAP.get(i)
        p = pos[i]
        if key and p:
            print(f"{i:>3}  {key:<12} {p[0]:>7.3f} {p[1]:>7.3f}")
        elif key:
            print(f"{i:>3}  {key:<12}   (no position!)")
        else:
            print(f"{i:>3}  {'<gap>':<12}")
    print(f"\ngap indices (no known key): {GAP_INDICES}")


def _models() -> None:
    for mid, (name, count, _m) in sorted(MODELS.items()):
        mapped = "yes" if _m else "no"
        print(f"0x{mid:02X}  {name:<22} {count:>4} LEDs  map={mapped}")


def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    if args[0] == "--ledmap":
        _ledmap()
    elif args[0] == "--models":
        _models()
    elif args[0] == "--emit-swift":
        _emit_swift()
    elif args[0] == "--simulate":
        keys = []
        if "--keys" in args:
            i = args.index("--keys")
            keys = [k.upper() for k in args[i + 1:]]
        _simulate(keys)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
