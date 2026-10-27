---
This file is maintained as part of the sudo-fleet documentation set.
---

# Components — what every directory is

This repository contains two kinds of thing, and it is worth knowing which is
which before you change or delete anything:

- **Fleet infrastructure** — the machinery that installs, deploys, and runs
  agents. Without it the repository does not do its job. Changes here affect
  every user of the repository.
- **Optional tooling and records** — useful capabilities that ship alongside the
  fleet but that a given install may never use. Safe to ignore; safe to remove
  from your own fork if you do not want them.

Anything that is **specific to one operator** — a personal account, a logins
path, a machine name, a saved agent identity — is deliberately **not** in this
repository. If you find something that looks personal, treat it as a bug and
see [`REPOSITORY-VS-INSTANCE.md`](REPOSITORY-VS-INSTANCE.md).

## Fleet infrastructure

| Path | Kind | What it is |
|---|---|---|
| `setup.sh` | infrastructure | Command 1. Installs docker and k3s, writes `.env`, builds both factory images, installs the boot-time recovery unit. Deploys no agent. |
| `bin/k8s-up.sh` | infrastructure | Command 2. Deploys the starter pair (a Letta planner and a Hermes engineer). Names configurable; identity seed optional. |
| `bin/k8s-down.sh` | infrastructure | Stops the pair (preserving state), or purges their PVCs, or tears down k3s. |
| `bin/k8s-auto-up.sh` | infrastructure | The boot-time re-apply. Run by the systemd unit `setup.sh` installs. |
| `bin/verify-change.sh` | infrastructure | Read-only post-change verification: runtime, config drift, auth, exposure. |
| `bin/talk.sh` | infrastructure | Unified "talk to an agent" entry point across both kinds. |
| `bin/paperclip-*.sh` | infrastructure (optional service) | Brings up the Paperclip control plane and hires agents into it. The fleet runs without it; see `docs/PAPERCLIP.md`. |
| `factories/sudo-agent/` | infrastructure | The Hermes engineer factory: `bin/up.sh`, the deploy script, the MCP server, the prompt queue, the watch sidecar, the comm gate. |
| `factories/sudo-letta/` | infrastructure | The Letta planner factory: `bin/up.sh`, mods, seeded skills, the queue, the watch sidecar. |
| `factories/sudo-agent/comm/` | infrastructure | The comm layer shared by both kinds: the three tools, their skills, the gate, the contracts, the tests. |
| `bin/hooks/` | infrastructure | Git pre-commit hook enforcing the change protocol. |
| `docs/` | infrastructure | This documentation set. |
| `factories/*/Dockerfile` | infrastructure | The image builds. |

## Optional tooling

These ship in the repository, are documented, and are supported — but a fleet
can run without them. Each is a self-contained capability.

| Path | Kind | What it is |
|---|---|---|
| `factories/sudo-letta/mods/dictation/` | optional tooling | `/listen` and `/done`: dictate speech into an agent's composer from a microphone on another machine over SSH. Adds no tools the model can call. |
| `factories/sudo-letta/mods/google-workspace/` | optional tooling | The Google Workspace MCP service (Drive, Docs, Sheets). Requires the operator to complete an OAuth consent once. |
| `factories/sudo-gws/` | optional tooling | The deployment side of the Google Workspace MCP service. |
| `factories/sudo-letta/mods/regulations-mcp/`, `statutes-mcp/` | optional tooling | MCP clients for the federal regulations and statutes services. |
| `factories/sudo-letta/mods/keyboard-mac/` | optional tooling | Mac keyboard modifier handling for the desktop client. |
| `factories/mac/` | optional tooling | Mac-side helpers: HID capture over SSH, keyboard modes, RGB control. Host-side scripts, not cluster code. |
| `factories/paperclip-ops/` | optional tooling | The ops skills and contracts for the Paperclip control plane. |
| `factories/paperclip-letta-adapter/` | optional tooling | The adapter that lets Paperclip drive a Letta agent. |
| `factories/sudo-letta/skills/` | optional tooling | Skills seeded into every planner on deploy (for example the open-source research procedure). |

## Committed records

| Path | Kind | What it is |
|---|---|---|
| `deployments/` | records | Saved agent identity packages. **Empty by default.** See below. |
| `docs/verifications/` | records | Dated verification records for specific past changes. |
| `PAPERCLIP-INTEGRATION-STATUS.md` | record | The control-plane integration history. |
| `SOURCE-OF-TRUTH.md` | pointer | Which repository owns which content. |

## `deployments/` is empty by default

A **glimor** is one agent's saved identity: its memory, its persona, its
per-agent settings. Glimors belong to the **instance** that created them, not to
this repository.

This repository therefore ships none. `bin/k8s-up.sh` deploys a clean agent when
no glimor is present, and resumes an identity when one is. `.gitignore` excludes
`deployments/*/` so that a `git add` does not accidentally publish someone's
live agent memory.

If you do commit one deliberately, it is your call and your responsibility: it
will be public, it will be in the history, and it will describe a real agent and
possibly a real person. See [`REPOSITORY-VS-INSTANCE.md`](REPOSITORY-VS-INSTANCE.md).

## Adding a component

If you add a directory:

1. Decide whether it is fleet infrastructure or optional tooling.
2. Add a row to the table above saying what it is and what it needs.
3. If it needs a personal account, a path on one machine, or a saved identity,
   it must read that from configuration — never commit the value.
