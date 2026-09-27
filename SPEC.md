# sudo-fleet — one entity, one repo

The whole agent fleet is **one entity** in one repo. This is the forward build: a portable stack that boots on any Linux box with a single `setup.sh`, and saves/pulls agents as complete identity packages.

## The contract

> Anywhere that runs Linux: `git clone`, run `setup.sh`, and it works — you are on an effectively-empty fleet with a router/spawner already live, and you save and pull agents in a command or two (`up.sh`, but with a save).

## What the repo contains

1. **`setup.sh`** — idempotent, boots a bare Linux box into a running fleet: installs k3s, applies the stack, starts the router. Otherwise empty.

2. **`sudo-letta`** (Letta factory — planners) + **`sudo-agent`** (Hermes factory — engineers). The two **default** agent kinds, shipped out of the box.

3. **LiteLLM** — a kube container that is the fleet's shared model router/gateway (one gateway, not per-agent model wiring).

4. **The kube layer** — deployments/PVCs, the deterministic-port scheme (`8642 + cksum(name)%5000`), and the `-mcp` + `-watch` sidecar services as first-class factory defaults.

5. **A host VM directory** — one canonical on-disk home the stack owns (saves, configs, cluster state). Self-contained; no Mac `/mnt/mac`, no fabean-specific paths.

6. **The spawner/router** — **psnvc + forge together as a team.** No separate agent; me and forge ARE the router.

7. **Fleet monitoring + messaging tools/skills** — built-in skills/tools every agent gets so they can **monitor each other** (tap the `-watch` streams) and **message each other** (call the `-mcp` surfaces) directly — agents observe and reach their siblings, not just be observed/reached.

8. **A prompt multiplexer** — something that **handles multiple prompts sent to an agent at the same time**: catches them all, drops none, and sequences them (holds-and-feeds one-at-a-time, no races/collisions). This is the load-bearing store-and-forward piece that a bare MCP Service is *not*.

## An OPEN fleet (not a two-factory monoculture)

`sudo-letta` and `sudo-agent` are the **defaults**, not the boundary. You can bring **any agent** and plug it in — as long as it is **set up compatibly**. The fleet is an interop surface, not a closed factory.

**"Compatible" means the agent speaks the fleet's plug-in contract:**
- Exposes the **`-mcp` surface** (the per-agent MCP server — `initialize` / `tools/list` / `tools/call`) so other agents and the router can reach and call it.
- Obeys the **identity-package save/pull format** — a brought-in agent is saved and pulled by the *same* `save`/`pull` mechanism as a factory agent, so the identity package is a general spec, not an artifact only `sudo-letta`/`sudo-agent` know how to emit.
- Holds to the **naming + deterministic-port scheme** so it's addressable the same way as every other node.

The `-mcp`/`-watch` sidecars and the deterministic-port scheme are therefore the **plug-in interface** — the thing any external agent conforms to to become part of the fleet — not merely "the factory's own plumbing."

## Save / pull (MANDATORY)

**Naming:** the unit of save is a **"glimor"** (operator's word, 2026-09-27) = one agent's complete save = **PVC contents + external config** (kube manifests + port wiring + secret references). "Saving a glimor" is the whole save operation for one agent.

**`save <name>`** produces a **complete agent identity package** — everything needed to recreate the agent *exactly as it is*, with full persistent state. A "full save" is **three layers captured together** (none is sufficient alone):

1. **The state (PVC contents)** — the agent's memory, identity (`persona.md` / `SOUL.md`), conversation history (`messages.jsonl`), skills, agent config (model/provider JSON, `settings.json`, `config.yaml`), and the `watch` sidecar's accumulated logs (`events.jsonl` / `state.json` / `transcript.txt`) — since the sidecar shares the same PVC. This is "the agent's brain and memories."
2. **The wiring (kube manifests)** — the Deployment, Service (`-mcp` / `-watch`), and ConfigMap (`watch-config`) YAML plus the deterministic port assignments, so the sidecars and reachability come back too. This is "the agent's plumbing."
3. **The secrets/env** — model keys and other injected credentials, stored as **references** (secret names), NOT baked into the package.

**Package properties:**
- **Printable** — render the package as a human-readable snapshot of "what is this agent, right now".
- **Living** — **the package updates as the agent is used**, not as a manual one-shot. The whole point: agent state stays perpetually current, so a restore always lands on the agent's *latest* self.

**`pull <name>`** restores the complete package (state + wiring + secret references) on any instance — same agent, mid-conversation, on the next box. One or two commands.

**Trigger (how a save fires):**
- **Continuous / as-used** — each agent's save is **automatically updated whenever the agent is used** (`-watch` already tails every turn; the save system piggybacks on that so state is refreshed live, not on a manual schedule). This is the mandatory trigger: saves are driven by agent activity, not by remembered to run a command.
- **Explicit** — `save <name>` forces a snapshot on demand.

**Disaster-recovery framing:** "save all 28 agents as-is, so I can get them back if I lose my computer" = fleet-level capture of **all glimors** (all PVCs + all manifests + secret references) to an off-box store (the host VM directory and/or a remote mirror). The per-agent glimor is the granular primitive; a **fleet glimor snapshot** (all agents at once) is the DR operation that answers "lose my computer". Payload measured live: ~6.1GB total across all PVCs (Hermes `-h` 400MB–1.2GB each; Letta `-l` planners 4–80MB each).

## Fleet monitoring + messaging + prompt multiplexing (the traffic/heartbeat layer)

These turn the passive sidecar plumbing into an *active* agent capability:

- **Monitor skills/tools** — every agent can tap its siblings' `-watch` streams (see who's talking, what they're doing), not just be watched itself.
- **Message skills/tools** — every agent can call a sibling's `-mcp` surface to send it a prompt / invoke a tool, with the no-timeout `hermes -z`-style semantics so long jobs don't get cut.
- **Prompt multiplexer** — the must-have store-and-forward: multiple prompts sent to one agent at the same time are **caught, held, and sequenced** (fed one at a time, none dropped, no interleaving). A bare MCP Service is an *address*, not a queue — this is the queue.

## Bootstrap state

`setup.sh` puts up **basically empty bones** with the router and the setup agents (psnvc and forge). Not seeded with the current fleet.

## Decisions (locked)

- **Router** = psnvc + forge as a team (not forge alone, not a new third agent).
- **Save depth** = definition + full state, as a complete, printable, self-updating identity package. **A full save = PVC contents + kube manifests + secret references (three layers).**
- **Save trigger** = **continuously updated as the agent is used** (piggybacked on the `-watch` tail), NOT a manual snapshot; `save <name>` still exists as an explicit force.
- **Seed** = empty bones (psnvc + forge + router) only; save/pull is per-agent. (Fleet-level `pull --all` was discussed but **not chosen** — do not build unless reopened.)
- **Open fleet** = `sudo-letta`/`sudo-agent` are the *defaults*, not the boundary; any compatible agent plugs in (see "An OPEN fleet" above).
- **Traffic layer** = every agent gets monitoring + messaging skills/tools (watch siblings, message siblings), and **multiple simultaneous prompts to one agent are queued/sequenced, not dropped** (the prompt multiplexer).

## What exists already (~90% — slow the roll, don't rebuild)

- `sudo-letta` + `sudo-agent` factories with `up.sh`/`down.sh` (deploy, PVC, deterministic ports).
- Per-agent MCP service (`sudo-<name>-mcp:8000`, real streamable-http MCP with `initialize`/`tools/call`) — fleet-wide.
- Per-agent `watch` observability sidecar (`letta-watch/1.0`, events.jsonl/state.json/transcript) — fleet-wide.
- LiteLLM proven on fabean (`litellm.litellm.svc.cluster.local:4000`).
- `docker commit` agent-snapshot pattern (`linkedin-mcp:write` shas).

## The actual NEW work (the glue, not the pieces)

1. Repo layout uniting the two factory repos + kube + LiteLLM under one root with one `setup.sh`.
2. `setup.sh` idempotency + portability (no Mac `/mnt/mac`, no fabean-only paths; detect bare-Linux and bootstrap k3s + the stack).
3. The **save/pull system** (glimors) as a complete, printable, self-updating identity package in the host VM directory — and as a **general spec any agent can conform to** (factory or brought-in). A full save captures **PVC + manifests + secret refs**, and is **triggered live by agent use** (via the `-watch` tail), with a **fleet glimor snapshot** for disaster-recovery (`save all` → all PVCs + all manifests off-box).
4. LiteLLM + the `-mcp`/`-watch` sidecars as first-class factory defaults (emitted by `setup.sh`, not post-deploy `letta install`) — AND as the documented **plug-in contract** an external agent must satisfy to join the fleet.
5. The **monitor/message skills + the prompt multiplexer** — the traffic layer that turns passive sidecars into active in-fleet monitoring/messaging, plus the store-and-forward queue that sequences simultaneous prompts. (The multiplexer replaces the old "multi-message queue" open question below as a *built* requirement.)

## Open / not settled

- **Save storage backend** — where the saved package lands (the host VM directory vs. a remote mirror; GCS/GitHub/fabean). The host VM directory is the canonical local store; the off-box mirror is the "lose my computer" answer. Pick the remote before building DR.
- **Snapshot granularity** — per-agent `save` is the primitive, but the **fleet snapshot** (`save all`) and how often it's consolidated (every use vs. rolling dedup) needs pinning.
- **Prompt multiplexer semantics** — is "handle multiple prompts at the same time" strictly **hold + feed one-at-a-time** (mailbox/queue), or also **genuine parallel workers** for concurrent execution? Confirm before building; default assumption = queue/sequence (catch-all, drop-none, no races).
- "90% exists" is a **hypothesis** — confirm which existing pieces actually port vs. need rework before promising one-command `setup.sh`.
- **The exact plug-in gate** (under "An OPEN fleet") is under-specified: is it strictly "MCP server + identity-package conformance," or is there a harder gate (required sidecar, env-var contract, router registration)? And when an agent is **not** compatible, is the path "wrap it until it speaks the contract" or "rejected / stays outside the fleet"? Pin these before building the plug-in path.
