# GLIMORS — what an agent glimor is

> Dedicated definition. This is the canonical, self-contained spec of the unit called a **glimor**. It pulls the glimor idea out of `SPEC.md`'s prose and pins it down so the save/pull/fork machinery has one unambiguous target to build against. Branch `glimors`.

## The one-sentence definition

A **glimor** is the entire agent — its definition *and* its complete persistent state — captured as a single, printable, perpetually-current, forkable identity package that lives in a save directory and is restored wholesale by `pull`.

## The operational spine (2026-09-28 — how a glimor actually lives and gets used)

This is the load-bearing mechanics, the part that turns "a glimor is X" into "the fleet runs *on* glimors":

1. **Home = a `glimors/` directory** inside the sudo-fleet application directory. That is the canonical location where all agent glimors live.
2. **A glimor is a file.** One file per agent — not a directory tree, not a loose bundle of PVC delta manifests. The "complete agent" is packed into one file.
3. **The router pair knows how to stand agents up from glimors.** `spawn`/pull means: consume a glimor file → deploy the agent it describes → run it. The router does not hand-run `up.sh`; it brings an agent into the room *by glimor*.
4. **Every agent in the fleet MUST be stood up from a glimor.** No bare pod, no memory-only agent. When an agent enters the fleet, a glimor is either:
   - **created** — a brand-new agent's glimor is written at the moment it first goes up, or
   - **assigned** — an existing glimor is pulled in and that agent *is* that glimor.
   There is no third path. "Agent standing up" and "glimor exists" are the same event.
5. **One glimor = one running agent.** A glimor is a **unique identifier** — the 1:1 identity token of exactly one running agent. Not a snapshot of many, not a version history; it is the singular, nameable identity that one live agent corresponds to.

## Why it exists (the steering law)

An agent that lives only in memory (a pod, a PVC, a live process) is an agent you can lose, and the whole fleet evaporates with it. So every agent exists as a **glimor** — one complete save — and that save **updates automatically once a save directory is given.**

**"Running" is a temporary view of a *stored* agent.** Save is not a manual backup you remember to run; it is the state the agent lives in. This is load-bearing, not a ranked feature — if it fails, nothing else matters (the steering wheel that must turn the front wheels).

## What a glimor contains — three layers packed into one file

A full glimor is **one file** holding **three layers**, none sufficient alone:

1. **State (PVC contents)** — the agent's brain and memories:
   - identity: `persona.md` (Letta) / `SOUL.md` (Hermes)
   - memory + conversation history (`messages.jsonl` / recall store)
   - skills (`skills/`), agent config (`settings.json`, `config.yaml`, model/provider wiring)
   - the `watch` sidecar's accumulated logs (`events.jsonl`, `state.json`, `transcript.txt`)

2. **Wiring (kube manifests)** — the agent's plumbing:
   - the Deployment, the `-mcp` Service, the `-watch` Service, the `watch-config` ConfigMap
   - the deterministic port assignments, so sidecars + reachability come back too

3. **Secrets/env** — model keys and injected credentials, stored as **references** (secret *names*), **never** baked into the package as values.

## Required properties (the "done" bar for a glimor)

- **Printable** — a glimor can be rendered as a human-readable snapshot of "what is this agent, right now" (identity + state + wiring), not just a binary blob.
- **Living** — the package **updates as the agent is used**, not as a manual one-shot. Restore always lands on the agent's *latest* self.
- **Source-agnostic** — a glimor does not record *where* it lives; a router can be pointed at *any* location and told to fork it.

## Save (`save <name>`) and pull (`pull <name>`)

- **`save <name>`** produces a complete glimor: the three layers captured together.
  - **Trigger — continuous / as-used** (mandatory): the save fires **automatically whenever the agent is used**, piggybacking on the `-watch` tail that already sees every turn. State is refreshed live, not on a remembered schedule.
  - **Trigger — explicit**: `save <name>` forces a snapshot on demand.
- **`pull <name>`** restores the complete glimor (state + wiring + secret refs) on any instance — the *same agent*, mid-conversation, on the next box. One or two commands.

## Forking — a glimor is also a seed

A glimor is both:
- (a) the auto-updating stored state of *a* living agent, and
- (b) a portable **seed** you fork from.

Point any fleet's router at where glimors live (a path / address / source fleet), tell it "spawn N", and it forks the glimor into **N independent copies**. Each fork:
- is its **own agent from the moment it spawns** — not linked to, and does **not write back to**, the source;
- **itself becomes a glimor** that auto-saves in the **target fleet's own save directory**.

Source stays put as the template for future forks. "Copy" means copies are their own people, not linked instances ("change one → change all" is explicitly NOT the semantics).

## Fleet snapshot (disaster recovery)

The per-agent glimor is the granular primitive. A **fleet glimor snapshot** (`save all`) captures **all** glimors (all PVCs + all manifests + secret refs) off-box in one operation — the "lose my computer" answer. Live payload was measured ~6.1 GB across all PVCs (Hermes engineers 400 MB–1.2 GB each; Letta planners 4–80 MB each).

## Open questions to pin before building (flag, do not assume)

1. **Save storage backend (off-box mirror)** — the `glimors/` directory in the app directory is the canonical local store (settled). What remains: the **off-box mirror** (GCS / GitHub / fabean) for the "lose my computer" fleet snapshot. Pick the remote before building DR.
2. **Snapshot consolidation** — per-agent `save` is the primitive, but how often the fleet snapshot is consolidated (every use vs. rolling dedup) needs pinning.
3. **The glimor file format** — settled that it's *a file*; still open is *what kind of file*: a single-line JSON identity record, a tar/gzip of the state, or a content-addressed blob whose name is the agent's unique id. The "printable + living + source-agnostic + unique-identifier" properties constrain this but the encoding is not yet chosen.
4. **The unique-identifier format** — "one glimor = one running agent" means the glimor *is* the identifier, but the exact id scheme (agent name? a hash? `name@glimor`) is unpinned.

## What a glimor is NOT

- Not a docker image / `docker commit` snapshot (that captures a filesystem, not identity + wiring + secrets-as-refs).
- Not a linked instance in a multi-fleet "change one → change all" web.
- Not memory-only state that happens to be backed up occasionally.
