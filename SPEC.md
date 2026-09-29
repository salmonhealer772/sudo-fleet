# sudo-fleet — the room

**sudo-fleet is a disposable room you stand up anywhere, where saved agents are pulled in, talk to each other, and survive the room's destruction.**

The thing is three aspects, in one breath:

1. **Glimors — the transportable agent.** A glimor is one complete save of an agent's setup AND its persistent state, the *entire* agent. This isn't new — you already move agents today via `docker commit`, PVC copies, the fabean snapshot pattern. The work here is **standardizing it**: one name, one format, one `save`/`pull`, so an agent is *reliably* movable instead of ad-hoc.

2. **The social layer — agents see and talk to each other.** This is the genuinely new part. Agents can natively list, message, and check on one another (the three tools + three skills + persona: `list-siblings`, `message-agent`, `check-agent`). This is what makes the room *not* just a pile of containers — it's a party.

3. **The room itself — a disposable environment.** Stand it up, use it, **destroy it**, stand up a fresh one — and the glimors are already saved, so the party reconstitutes. The room is throwaway *because the agents aren't.* An ephemeral environment with durable people inside it.

The three aspects lock together: **the room is disposable (3) because every agent is stored as a glimor (1), and the reason there's a room at all instead of just containers is that the agents talk (2).**

You `git clone` + `setup.sh` on any Linux box and you get an *empty room* — no agents yet, just the plumbing and the room itself. Then you talk to the **two router agents** (psnvc + forge), and they pull any **saved agent** into the room, fast, by name.

**The steering law — agents are STORED, never memory-only.** An agent that lives only in memory (a pod, a PVC, a live process) is an agent you can lose, and the whole project evaporates with it. Every agent exists as a **"glimor"** — one complete save of its setup AND its persistent state, the *entire* agent — and that save **updates automatically once a save directory is given.** Save is not a manual backup you remember to run; it is the state the agent lives in. "Running" is a temporary view of a *stored* agent. Like a steering wheel that must turn the front wheels: this isn't a feature you rank, it's the thing that has to work or nothing else matters.

**A glimor is also a seed — you fork copies across fleets.** It doesn't matter *where* a glimor physically lives; what matters is that a router can be told where it is. If fleet B's router is pointed at that source and told "set up as many copies as I want," it forks the glimor into **as many independent agents as you ask for**. Each fork is its own agent from the moment it spawns — it does not stay linked to, or write back to, the source. And each fork **itself becomes a glimor that auto-saves in fleet B's own save directory** — it lands wherever B saves its own glimors. The source glimor stays put as a template you can fork from again later.

The room currently hosts exactly **two kinds of guest**, and relies on the repo pair that builds them: **`sudo-letta`** (Letta planners — the brain) and **`sudo-agent`** (Hermes engineers — the hands). Those two factories are the *defaults*, not the boundary — but the glimor save/pull format and the plug-in contract are derived from them, so they're load-bearing, not incidental.

## What "done" means (the three aspects, made concrete)

When the three aspects are all real, the room is done:

1. **Glimors are real.** Every agent is saved as a complete glimor — setup + persistent state, the *entire* agent — and the save **updates automatically once a save directory is given.** No agent hangs out in memory only; an agent *is* its stored glimor, kept perpetually current. (The steering law.)
2. **The party talks.** The 3 tools + 3 skills + persona are built and baked into every spawned agent, so a new guest arrives already able to list, message, and check on its siblings — natively, no bridge, no hand-running.
3. **The room is disposable.** You can stand up a room (`setup.sh`, reproducible + idempotent), use it, destroy it, and stand up another — and every agent comes back from its glimor. The router pair (psnvc + forge) pull and deploy agents by talking ("spawn X", "spawn N of X"), not by hand-running `up.sh`.

The supporting cast (still required, in service of the three):
- **The hosts work** — psnvc/forge pull + deploy fast, source-agnostic (point them at where a glimor lives, they fork N independent copies, each landing its own auto-saving glimor in that fleet's save dir).
- **The door is clear** — "compatible" is pinned: `-mcp` surface + glimor format + naming/port scheme = in the room.

## The build order (three phases, mapped to the three aspects)

This is not a moonshot — it is *"the fleet I already rebuild by hand on kube every time, made good": `setup.sh` + save/pull so the room reproduces clean and fast instead of from memory. Done is small on purpose: you stop rebuilding by hand, and your agents come back talking.

1. **Phase 1 — make the talky tools work.** Build the 3 tools + 3 skills + persona (aspect #2, the social layer) and prove a live pair actually talks on its own. This is the only genuinely-new, ready-to-build part, and the mechanism is ~90% already shipped (`letta mcp call` in the image, `-mcp`/`-watch` sidecars, Redis queue). Done = the three tools built + baked in + a live pair (fa-glm/ya-glm) messages and checks each other *unprompted*, not just invokable by hand.

2. **Phase 2 — get glimors working well.** Save/pull/fork solidly (aspect #1, the transportable agent). This is the steering law — "agents are STORED, never memory-only" — and everything downstream (disposable room, forking N) assumes it. Done = save an agent on box A, destroy the room, stand up a fresh room on box B, pull, and the *same agent* returns mid-conversation and immediately messages its siblings.

3. **Phase 3 — the room + the router.** `setup.sh` (the disposable environment), LiteLLM (the shared model gateway), and the kube substrate, with psnvc/forge as the router that operates it all (aspect #3). This is NOT a fourth mountain — it is Phases 1+2 *composed*: the router pair driving the fleet is just the two host agents using the talky tools to run the glimor layer over the kube substrate. Done = `setup.sh` on a fresh box gives an empty room, you talk to the router, it pulls the glimors in, the party runs and talks.

The three phases line up exactly with the three aspects, and each phase sits on the last. There is no hidden fourth phase.

## What is NOT the point (furniture, not the vision)

These matter only insofar as they make the room faster to stand up or cheaper to run — they are not the vision and are deferred on purpose:

- **LiteLLM / the shared model gateway** — an optimization (fewer keys, one swap point), not a promise. The room works with per-agent wiring; LiteLLM makes it tidier.
- **Resource substrate / scale-to-zero** — a cost optimization, not a promise.
- **Off-box DR mirrors** — replicating the glimors off the box is *extra* safety, not a promise. The glimor itself (steering law) is mandatory; mirroring it off-box is furniture.

The test: *if one of the three aspects is false but the room still works, it was really furniture.* The steering law is above all of it — false steering, no car.

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

### Ground truth (the sidecars are a GIVEN — they live in each agent's directory)

The sidecars are **already part of every agent**: the `watch` sidecar + the `-mcp` service live **inside each agent's directory** (co-located with its PVC/state, deployed by `up.sh` per agent). This is assumed — do NOT redesign or rebuild the sidecar itself. (The operator is building the Hermes-side sidecars in parallel; the Letta-side `watch_sidecar.py` + `letta_prompt` MCP already ship in `sudo-letta`.)

- **Letta MCP**: `sudo-{name}-mcp:8000`, `/mcp`, one tool `letta_prompt(prompt, stream, json, new_chat)` — resumes the agent's persisted conversation (or `new_chat=true`). Source `kube-scripts/letta_prompt.py` + `mcp_server.py`.
- **Letta watch sidecar**: `sudo-{name}-watch:8000`, routes `/healthz /status /ps /events?n=N /stream`. `kube-scripts/watch_sidecar.py`, stdlib-only, unprivileged (no docker socket). Writes `events.jsonl` + `transcript.txt` + `state.json` to the agent dir. Event schema `{ts, conversation, event}` (user/thinking/assistant/tool_call/tool_result/session/process_state); `process_state` captures idle↔active transitions.

### The real work: tools + skills + persona that INTERACT with the sidecars

The sidecars are the substrate; what we build is the **agent-facing layer that makes each agent actually USE its own (and its siblings') sidecars**. This is the missing piece — not the plumbing, but the agent's hands on it.

**Three tools + three skills, paired, on every agent** (operator's spec, 2026-09-27) — plus a persona alignment so agents *know* the functionality exists and reach for it:

| Surface | Tool (mechanism) | Skill (procedure) |
|---|---|---|
| **message-agent** | call a sibling's `-mcp` to send it a prompt / invoke a tool | the reach-and-message recipe (no-timeout, naming, quoting) |
| **check-agent** | read a sibling's trail at any depth — `GET ...-watch/events?n=N` or the compressed `transcript.txt` (`n=-1` = the whole file). ONE merged tool, replacing the separate check-what-agent-is-doing + check-agent-logs | the "what is X doing right now / read X's trail" recipe |

**`message-agent` is BY FAR the most important** — it's the mesh's whole point; check-agent is the observability that makes messaging safe.

**Persona alignment (the third layer, mandatory):** every agent's persona is **tweaked to teach it that this functionality exists and when to use it** — so "all levels align": tool (mechanism) + skill (procedure) + persona (awareness/intent). A tool without persona awareness gets ignored (the psy-glm lesson); a persona that names the tools makes the agent actually reach for them. This is the difference between "the capability is in the plumbing" and "the agent uses it."

This is the Reaching-my-engineer pattern, generalized to **Reaching-any-sibling** (with check + logs alongside the core message).

### The tools — contracts (backend = forge's call, spec only the shape)

Each tool takes a sibling agent as target and does one thing. Contracts (backend undecided per operator "shit idk" — shell script vs. Letta mod tool is forged during build):

**1. `message-agent` (BY FAR the most important)**
- Input: `sibling` (name, e.g. `ms-glm-l`), `prompt` (the message), optional `new_chat` (fresh vs. resume).
- Behavior: reach `http://sudo-{sibling}-mcp:8000/mcp`, MCP handshake → `tools/call` `letta_prompt`/`hermes_prompt` with the prompt → return the sibling's reply.
- Sessions: planner sibling = stateful (resumes unless `new_chat`); engineer sibling = stateless one-shot.
- Must be no-timeout (long jobs don't get cut — the `HERMES_STREAM_*_TIMEOUT=inf` lesson).

**2. `check-agent`** (the merged observability tool — replaces the separate check-what-agent-is-doing + check-agent-logs)
- Input: `sibling`, optional `n` (trailing depth; `-1` = the whole file), optional `mode` (`full` = raw event trail, `compressed` = plain chat transcript).
- Behavior: `mode=full` → `GET http://sudo-{sibling}-watch:8000/events?n=N` → the trailing event trail; `mode=compressed` → read the sibling's `transcript.txt` directly (`kubectl exec ... tail -n N`, or `cat` for `n=-1`). ONE read answers both "what has it been doing" and "what is it doing right now" (the freshest events carry the current conversation + the latest `process_state`).
- Retired: the separate `GET /status` and `GET /ps` surface of check-what-agent-is-doing — the what-is-it-doing answer falls out of the trail.

### The skills — procedure (same three, written as Letta skills)

Each tool has a matching skill documenting *when + how* to use it (the reach syntax, naming, quoting, which route maps to which intent). Pattern = the existing `reaching-my-engineer` skill, generalized to `reaching-any-sibling`. Skills live in the agent's MemFS `skills/` dir: `message-agent`, `check-agent`.

### The persona layer — awareness (the alignment that makes them USE it)

Every agent's persona gets a short block teaching it: *"You are part of a fleet. You can message any sibling agent by name, check what it's doing, and read its logs. Here are the three tools/skills for that, and when to reach for them."* This is what makes the tools get *used* rather than sat-unused (the psy-glm lesson: capability without persona awareness is ignored).

### The router default — how agents are born able to talk

In **sudo-fleet**, the router pair (psnvc + forge) **bakes these into every spawned agent as a spawn-time default**: the 3 tools + 3 skills + persona block are part of what `up.sh`/spawn gives an agent, NOT a post-hoc per-agent bolting. A new agent comes out of the spawner already able to message/check any sibling. This is what "native" means — the fleet, as a whole, talks.

### Remaining questions (the ONLY things not already in the shipped code)

Most of the earlier "open questions" are answered by `sudo-letta`'s shipped sidecar/MCP (see "Ground truth" above). What genuinely remains to design for the **native mesh** (the new part beyond the per-pod plumbing):

1. **Cross-agent routing / discoverability** — the shipped MCP is **per-pod only**: `letta_prompt` prompts ITS OWN agent, and `--list`/cross-agent name-resolution is explicitly host-side (needs kubectl/kubeconfig), NOT exposed in-pod. For "any agent → any agent," an agent still needs to **know + reach a sibling's `-mcp` Service** (`http://sudo-{name}-mcp:8000/mcp`) and call `letta_prompt`/`hermes_prompt` on it. The native layer = bake that reach syntax + a sibling phonebook into skill/tool, over the per-pod MCP the repo already ships.
2. **Concurrency/multiplexer** — the `letta_prompt`/`hermes_prompt` tools are synchronous; a second prompt to a mid-run agent is NOT yet held/queued. The `-watch` sidecar already exposes `process_state` (idle↔active) — that is the signal a queue can key on. Feed-a-second-prompt-when-idle is the mechanic to add (and it can live in/next to the existing sidecar, not a new broker).
3. **Auth/keys** — `-mcp` initialize auto-issues an `mcp-session-id`, no key gate observed. For host-root-safety on cross-agent calls, mint a per-agent key (the `API_SERVER_KEY`/bearer pattern).

### Deliverable

Extend this `sudo-fleet` spec into the definitive native cross-agent-communication contract (mesh + monitoring + multiplexing), with the per-agent messaging + check-on skills specced at the same level as the existing Reaching-my-engineer skill. Test on fa-glm/ya-glm, then record the verified mechanics here.

## Open / not settled

- **Save storage backend** — where the saved package lands (the host VM directory vs. a remote mirror; GCS/GitHub/fabean). The host VM directory is the canonical local store; the off-box mirror is the "lose my computer" answer. Pick the remote before building DR.
- **Snapshot granularity** — per-agent `save` is the primitive, but the **fleet snapshot** (`save all`) and how often it's consolidated (every use vs. rolling dedup) needs pinning.
- **Prompt multiplexer semantics** — is "handle multiple prompts at the same time" strictly **hold + feed one-at-a-time** (mailbox/queue), or also **genuine parallel workers** for concurrent execution? Confirm before building; default assumption = queue/sequence (catch-all, drop-none, no races).
- "90% exists" is a **hypothesis** — confirm which existing pieces actually port vs. need rework before promising one-command `setup.sh`.
- **The exact plug-in gate** (under "An OPEN fleet") is under-specified: is it strictly "MCP server + identity-package conformance," or is there a harder gate (required sidecar, env-var contract, router registration)? And when an agent is **not** compatible, is the path "wrap it until it speaks the contract" or "rejected / stays outside the fleet"? Pin these before building the plug-in path.
