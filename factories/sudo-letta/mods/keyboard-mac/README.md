# @letta-ai/keyboard-mac

A Letta Code mod package that gives an agent one extra tool: **`keyboard_mode`** --
switch the operator's Mac keyboard between PC mode (Ctrl/Alt act as Command so
Ctrl+C, Ctrl+V, Alt+Tab work) and native Mac mode, scoped to his external
keyboard only.

## What it does

Runs `factories/mac/keyboard-mode.sh` on the lima host over the docker-socket +
nsenter host bridge, and returns the script's status output. `mode` values:

- `pc` — PC muscle-memory on the external board (Ctrl/Alt/Win = Command), persisted.
- `mac` — native on the external board (no remap), persisted.
- `status` — report the remembered mode, per-device + global mappings, and the
  launchd agent state (read-only).

## Usage

Ask the agent to switch the keyboard:

- "switch my keyboard to PC mode"
- "put my keyboard back to native Mac mode"
- "what keyboard mode is active right now?"

## Install (per agent pod)

The package directory lives under the agent's mods root and is declared in
`packages.json`:

    ~/.letta/mods/packages/npm/@letta-ai/keyboard-mac/
      package.json
      MOD.md
      README.md
      mods/index.mjs

    ~/.letta/mods/packages.json  ->  packages[] entry, enabled: true

No build step is needed: the entry is plain ESM (`mods/index.mjs`), and the
Letta Code CLI activates mods on process start.

## Requirements

- The pod must be privileged with `/var/run/docker.sock` mounted and `docker` on
  `$PATH` (the standard sudo-letta pod shape).
- The lima host must have `factories/mac/keyboard-mode.sh` present and key-based
  SSH to the Mac established (the `factories/mac/up.sh` contract).

## Scope

Switches the operator's EXTERNAL keyboard (VID 0x258A / PID 0x010C) between PC
and native Mac modes only; the built-in keyboard is unaffected. It runs a
host-side shell script and never touches pods, secrets, or writable cluster
state directly.
