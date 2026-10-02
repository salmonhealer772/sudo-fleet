---
name: "@letta-ai/keyboard-mac"
description: "Agent-callable tool to switch the operator's Mac keyboard between PC mode and native Mac mode."
---

# keyboard-mac mod semantics

## When to use

Use `keyboard_mode` whenever the operator asks to change how their external
keyboard behaves: to make it act like a PC keyboard (Ctrl/Alt as Command, so
Ctrl+C / Ctrl+V / Alt+Tab work) or to restore native Mac behaviour. `status`
reports the current mode without changing anything.

## Tool

This package registers one tool:

- `keyboard_mode(mode)` — `mode` is `"pc" | "mac" | "status"`.

## How it reaches the Mac

The tool runs the repo's `factories/mac/keyboard-mode.sh` script on the lima
host over the docker-socket + nsenter host bridge:

    docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest \
      nsenter -t 1 -m -u -i -n -p -- \
      bash /opt/0-0/sudo-fleet/factories/mac/keyboard-mode.sh --<mode>

That script (built by a sibling engineer) reaches the Mac over key-based SSH
(`aidanmcohen@192.168.5.2`) and drives `hidutil` + a `launchd` KeepAlive agent
so the chosen mode persists across reboot AND unplug/re-plug. It is scoped to
the external "Gaming Keyboard" (VID 0x258A / PID 0x010C) only; the built-in
keyboard is never touched.

## Parameters

- `mode` (required string) — `"pc"` enables PC muscle-memory (Ctrl/Alt/Win act
  as Command, persisted); `"mac"` restores native Mac behaviour (no remap,
  persisted); `"status"` reports the remembered mode, per-device + global
  mappings, and the launchd agent state (read-only).

## Important behaviour

- No skill gate: the tool works in one call.
- `requiresApproval: false`, `parallelSafe: true`.
- The tool never throws: bridge/SSH failures are returned as an error result
  with the underlying detail.
- `--status` (and every mode) prints the script's status output verbatim to
  the caller; a non-zero exit returns stdout (if any) plus the failure detail.

## Requirements

- The pod must be privileged with `/var/run/docker.sock` mounted and `docker`
  on `$PATH` (the standard sudo-letta pod shape).
- The lima host must have `factories/mac/keyboard-mode.sh` present and
  key-based SSH to the Mac established (the `factories/mac/up.sh` contract).
