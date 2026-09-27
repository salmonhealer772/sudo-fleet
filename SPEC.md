# sudo-fleet — one entity, one repo

The whole agent fleet is **one entity** in one repo. This is the forward build: a portable stack that boots on any Linux box with a single `setup.sh`, and saves/pulls agents as complete identity packages.

## The contract

> Anywhere that runs Linux: `git clone`, run `setup.sh`, and it works — you are on an effectively-empty fleet with a router/spawner already live, and you save and pull agents in a command or two (`up.sh`, but with a save).

## What the repo contains

1. **`setup.sh`** — idempotent, boots a bare Linux box into a running fleet: installs k3s, applies the stack, starts the router. Otherwise empty.

2. **`sudo-letta`** (Letta factory — planners) + **`sudo-agent`** (Hermes factory — engineers). The two agent kinds.

3. **LiteLLM** — a kube container that is the fleet's shared model router/gateway (one gateway, not per-agent model wiring).

4. **The kube layer** — deployments/PVCs, the deterministic-port scheme (`8642 + cksum(name)%5000`), and the `-mcp` + `-watch` sidecar services as first-class factory defaults.

5. **A host VM directory** — one canonical on-disk home the stack owns (saves, configs, cluster state). Self-contained; no Mac `/mnt/mac`, no fabean-specific paths.

6. **The spawner/router** — **psnvc + forge together as a team.** No separate agent; me and forge ARE the router.

## Save / pull (MANDATORY)

- **`save <name>`** → a **complete agent identity package**: definition (persona/SOUL/config/model/ports) AND full state (memory, conversation history, PVC contents).
- **Printable** — render the package as a human-readable snapshot of "what is this agent, right now".
- **Living** — the package updates as the agent is used; not a one-time snapshot.
- **`pull <name>`** → restores the complete package (definition + full state) on any instance, so an agent survives fleet moves intact — same agent, mid-conversation, on the next box.
- Both in one or two commands, stored in the host VM directory.

## Bootstrap state

`setup.sh` puts up **basically empty bones** with the router and the setup agents (psnvc and forge). Not seeded with the current fleet.

## Decisions (locked)

- **Router** = psnvc + forge as a team (not forge alone, not a new third agent).
- **Save depth** = definition + full state, as a complete, printable, self-updating identity package.
- **Seed** = empty bones (psnvc + forge + router) only; save/pull is per-agent. (Fleet-level `pull --all` was discussed but **not chosen** — do not build unless reopened.)

## What exists already (~90% — slow the roll, don't rebuild)

- `sudo-letta` + `sudo-agent` factories with `up.sh`/`down.sh` (deploy, PVC, deterministic ports).
- Per-agent MCP service (`sudo-<name>-mcp:8000`, real streamable-http MCP with `initialize`/`tools/call`) — fleet-wide.
- Per-agent `watch` observability sidecar (`letta-watch/1.0`, events.jsonl/state.json/transcript) — fleet-wide.
- LiteLLM proven on fabean (`litellm.litellm.svc.cluster.local:4000`).
- `docker commit` agent-snapshot pattern (`linkedin-mcp:write` shas).

## The actual NEW work (the glue, not the pieces)

1. Repo layout uniting the two factory repos + kube + LiteLLM under one root with one `setup.sh`.
2. `setup.sh` idempotency + portability (no Mac `/mnt/mac`, no fabean-only paths; detect bare-Linux and bootstrap k3s + the stack).
3. The **save/pull system** as a complete, printable, self-updating identity package in the host VM directory.
4. LiteLLM + the `-mcp`/`-watch` sidecars as first-class factory defaults (emitted by `setup.sh`, not post-deploy `letta install`).

## Open / not settled

- **Multi-message queue** (store-and-forward mailbox) still unresolved — a bare MCP Service is an address, not a queue. Decide later; do NOT bake a Service-only answer and rediscover the gap.
- "90% exists" is a **hypothesis** — confirm which existing pieces actually port vs. need rework before promising one-command `setup.sh`.
