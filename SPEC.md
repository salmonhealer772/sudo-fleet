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

## Native cross-agent communication (the mesh) — SPEC IN PROGRESS, testbed = fa-glm + ya-glm

The goal: make cross-agent communication **native** — any agent messages any agent, and any agent checks on any agent, without psnvc/forge hand-running a bridge each time. The `-mcp` + `-watch` sidecars already exist fleet-wide (the plumbing); this spec turns them into a native capability.

### The model (operator's spec, 2026-09-27)

- **Full mesh — any agent → any agent.** Every agent can message every other agent, any direction. Not just planner→engineer within a pair; planners, engineers, across pairs, all of it.
- **Same idea for monitoring — any agent → any agent's activity.** Every agent can check what any other agent is doing (tap its `-watch` stream), not just be watched itself.
- **Concurrency is mandatory.** If an agent is mid-run and a second/third prompt arrives, it **MUST be handled** — caught, held, sequenced, none dropped, no races. This is the prompt-multiplexer requirement, now concrete and non-optional.
- **Keep orchestrator/engineer tendencies.** The mesh does NOT flatten pairs into undifferentiated peers: planner-delegates-to-engineer stays as the primary grain. The mesh adds *reachability in every direction*, not role collapse.

### What "native" concretely becomes

**Three tools + three skills, paired, on every agent** (operator's spec, 2026-09-27) — plus a persona alignment so agents *know* the functionality exists and reach for it:

| Surface | Tool (mechanism) | Skill (procedure) |
|---|---|---|
| **message-agent** | call a sibling's `-mcp` to send it a prompt / invoke a tool | the reach-and-message recipe (no-timeout, naming, quoting) |
| **check-what-agent-is-doing** | read a sibling's live `-watch` stream (current turn / activity) | the "what is X doing right now" recipe |
| **check-agent-logs** | tail a sibling's event/transcript history | the "read X's recent trail" recipe |

**`message-agent` is BY FAR the most important** — it's the mesh's whole point; the two check tools are the observability that makes messaging safe.

**Persona alignment (the third layer, mandatory):** every agent's persona is **tweaked to teach it that this functionality exists and when to use it** — so "all levels align": tool (mechanism) + skill (procedure) + persona (awareness/intent). A tool without persona awareness gets ignored (the psy-glm lesson); a persona that names the tools makes the agent actually reach for them. This is the difference between "the capability is in the plumbing" and "the agent uses it."

This is the Reaching-my-engineer pattern, generalized to **Reaching-any-sibling** (with check + logs alongside the core message).

### What we know (verified plumbing)

- Every pod exposes `sudo-<name>-mcp:8000` (real MCP: `initialize` / `tools/list` / `tools/call`, sessions) pinned to a deterministic host-LAN port.
- Every pod exposes `sudo-<name>-watch:8000` (`letta-watch/1.0`) serving an event stream (`events.jsonl` / `state.json` / `transcript.txt`).
- Deterministic ports: `8642 + cksum(name) % 5000`.
- The proven one-shot reach paths: `hermes -z` (engineers) and `letta -p` (planners), with `HERMES_STREAM_*_TIMEOUT=inf` for long jobs.
- fa-glm + ya-glm are the live testbed (both just swapped to `deepseek-flash` 2026-09-27).

### Questions to investigate (answers as of 2026-09-27, verified live on fa/ya-glm)

1. **MCP tool surface per agent — ANSWERED.** Both `-mcp` endpoints expose exactly ONE generic tool, uniform in shape, two variants:
   - Letta planner (`-l`) → **`letta_prompt(prompt, stream, json, new_chat)`** — **stateful** by default (resumes the agent's persisted conversation unless `new_chat=true`); `stream` = stream-json joined deltas, `json` = raw object.
   - Hermes engineer (`-h`) → **`hermes_prompt(prompt, json)`** — **stateless** one-shot (`json` = pretty-print if stdout is JSON).
   - So "message any agent" is one generic tool (`*_prompt`), but **planners are stateful, engineers are one-shot** — a real distinction the messaging skill must encode.

2. **Session semantics — ANSWERED (see #1).** Messaging a planner lands in its *live* conversation (stateful); messaging an engineer is a fresh stateless eval. The "message-agent" skill must be explicit about which, or pass `new_chat` deliberately.

3. **Concurrency/multiplexer mechanic — STILL OPEN.** The `letta_prompt`/`hermes_prompt` tools are synchronous (return the reply inline); nothing yet holds/sequences a second prompt when the agent is mid-run. The `-watch` sidecar (process-namespace + docker-socket access) is the candidate home for a hold-and-feed queue — to be designed, not assumed.

4. **Discoverability — STILL OPEN.** No registry; an agent must know a sibling's name + port. Candidates: a baked phonebook in each agent vs. deriving from the deterministic `cksum` scheme vs. a fleet-list route. Pick one to make the "full mesh" actually *reachable*.

5. **Monitoring read-shape — ANSWERED.** The `-watch` server (`letta-watch/1.0`) serves exactly two live routes:
   - **`GET /status`** → `{agent, deploy, uptime_s, agent_container_up, active, current_conversation, last_event_ts, events_logged, transcript_bytes, watch_port}` — the clean "what is this agent doing right now" contract.
   - **`GET /events`** → newline-delimited `{ts, conversation, event, text/name/args}` — the trailing event/history stream.
   - So **check-what-agent-is-doing → `/status`** and **check-agent-logs → `/events`** are the two stable read contracts for the check tools.

6. **Auth/keys — PARTLY OPEN.** The `-mcp` handshake issues an `mcp-session-id` automatically (no key gate observed on the probe — initialize returned a session with no auth). Whether sibling calls need a per-agent key (matching the `API_SERVER_KEY`/bearer pattern for host-root-safety) must be pinned before building.

### Deliverable

Extend this `sudo-fleet` spec into the definitive native cross-agent-communication contract (mesh + monitoring + multiplexing), with the per-agent messaging + check-on skills specced at the same level as the existing Reaching-my-engineer skill. Test on fa-glm/ya-glm, then record the verified mechanics here.

## Open / not settled

- **Save storage backend** — where the saved package lands (the host VM directory vs. a remote mirror; GCS/GitHub/fabean). The host VM directory is the canonical local store; the off-box mirror is the "lose my computer" answer. Pick the remote before building DR.
- **Snapshot granularity** — per-agent `save` is the primitive, but the **fleet snapshot** (`save all`) and how often it's consolidated (every use vs. rolling dedup) needs pinning.
- **Prompt multiplexer semantics** — is "handle multiple prompts at the same time" strictly **hold + feed one-at-a-time** (mailbox/queue), or also **genuine parallel workers** for concurrent execution? Confirm before building; default assumption = queue/sequence (catch-all, drop-none, no races).
- "90% exists" is a **hypothesis** — confirm which existing pieces actually port vs. need rework before promising one-command `setup.sh`.
- **The exact plug-in gate** (under "An OPEN fleet") is under-specified: is it strictly "MCP server + identity-package conformance," or is there a harder gate (required sidecar, env-var contract, router registration)? And when an agent is **not** compatible, is the path "wrap it until it speaks the contract" or "rejected / stays outside the fleet"? Pin these before building the plug-in path.
