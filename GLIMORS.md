# GLIMORS — what an agent glimor is

> Dedicated definition. This is the canonical, self-contained spec of the unit called a **glimor**. It pins down what a glimor is on disk, so the save/pull/fork machinery has one unambiguous target to build against. Branch `glimors`.

## The one-sentence definition

A **glimor** is one agent, fully described — a folder holding that agent's **yaml** (its wiring/definition) and its **`pvc/` dir** (its live state, on a path we own). One glimor = one yaml + one pvc dir = one running agent.

## The operational spine (the part that makes the fleet run *on* glimors)

1. **Home = `/opt/sudo-fleet/deployments/`.** The fleet application directory is **`/opt/sudo-fleet/`** — the top of everything, holding the two factories (`sudo-letta/`, `sudo-agent/`) and the spec docs *inside* it (see `LAYOUT.md`). Inside that, `deployments/` is the glimor store: **one folder per agent**, named by the agent's bare name.

2. **The two factories write their yamls INTO the shared `deployments/` store, not into themselves.** The `sudo-letta` and `sudo-agent` repos do **not** keep their own `deployments/` directories anymore. When `up.sh` stands an agent up, it writes that agent's yaml into `deployments/<name>/`. The repos are *source*; `deployments/` is the *runtime* store they emit into.

3. **Each glimor holds exactly: the yaml + a `pvc/` directory (its live state, on a path we own).**

   ```
   /opt/sudo-fleet/deployments/
   ├── fa-glm-l/
   │   ├── fa-glm-l.yaml          ← written here by the planner factory
   │   └── pvc/                   ← hostPath dir = the agent's live state (memory, persona, skills, watch logs)
   ├── fa-glm-h/
   │   ├── fa-glm-h.yaml          ← written here by the engineer factory
   │   └── pvc/
   └── ...
   ```

   - The **yaml** is the agent's wiring: the Deployment, the `-mcp`/`-watch` sidecars, the env/model wiring, and the deterministic ports. (No PVC claim anymore — see `BUILD-STEPS.md`.) Its `image:` line points at the shared `sudo-letta:latest` / `sudo-agent:latest` (built from the factory Dockerfiles — but the Dockerfile is **factory-level**, one per kind, NOT part of any single glimor).
   - The **`pvc/`** is the agent's **state**, on a `hostPath` directory **we own** (not a k3s-managed PVC). It holds persona/SOUL, memory, conversations, skills, config, and watch logs. It is the one, canonical, *live* state dir for that agent — there is no copy.

4. **Every agent in the fleet MUST be stood up from a glimor.** No bare pod, no memory-only agent, no k3s-managed PVC. When an agent enters the fleet, a glimor is either:
   - **created** — a brand-new agent's yaml is written and its `pvc/` dir is created (`DirectoryOrCreate`) at the moment it first goes up, or
   - **assigned** — an existing glimor is pulled in and that agent *is* that glimor.
   There is no third path. "Agent standing up" and "glimor exists" are the same event.

5. **One glimor = one running agent.** A glimor is a **unique identifier** — the 1:1 identity token of exactly one running agent. One folder, one yaml, one `pvc/` dir; no snapshot history, no "change one → change all" linking.

## Why it exists (the steering law)

An agent that lives only in a k3s-managed PVC (or a bare pod, or a bare process) is an agent you can lose, and the whole fleet evaporates with it. So every agent exists as a **glimor** — its yaml + its `pvc/` dir, named and pinned on a path we own.

**"Running" is a temporary view of a *stored* agent.** The `pvc/` dir is the persistent state the agent lives in; the yaml is how it runs. Save isn't a manual backup you remember to run — it is the state the agent already lives in, made unambiguous. This is load-bearing, not a ranked feature — if it fails, nothing else matters (the steering wheel that must turn the front wheels).

## What the two halves mean

- **`pvc/` dir = the agent's state** (its "brain and memories"): identity (`persona.md` / `SOUL.md`), memory + conversation history, skills, agent config, model/provider wiring, and the `watch` sidecar's accumulated logs. This is the *save* of "persistent state."
- **Yaml = the agent's wiring** (its "plumbing"): the Deployment + sidecars + ports + env. This is how the state gets *run and reached*.

The **secrets** stay referenced: model keys and injected credentials are **never** baked into the glimor folder as values — they remain env/secret references, resolved by the cluster.

## Required properties (the "done" bar for a glimor)

- **Living** — the `pvc/` dir is the *live* state; there is no stale copy to drift. The yaml is what `up.sh` wrote at spawn and re-writes on change.
- **Source-agnostic** — a glimor does not record *where* it lives. A router pointed at any `deployments/` store (or a copy of the `pvc/` dir + yaml) can stand the agent up.
- **Printable** — `deployments/<name>/` is browsable: `cat fa-glm-l.yaml` + `ls pvc` shows exactly what the agent is, no decoding.

## Save and pull

- **`save <name>`** = make the glimor unambiguous and portable: ensure `deployments/<name>/<name>.yaml` is current and the `pvc/` dir holds the agent's latest state. Off-box DR = copy the `pvc/` dir (only then is a copy made, for the "lose my computer" case) to the mirror.
- **`pull <name>`** = apply `deployments/<name>/<name>.yaml` + place the `pvc/` dir → the same agent returns, mid-conversation, on the next box. One or two commands.

*Note:* within the live cluster the `pvc/` dir is the single source of truth — "one glimor = one pvc dir" holds. A **copy** of the `pvc/` dir is made *only* for off-box disaster recovery or forking, never as part of the glimor's normal life.

## Forking — a glimor is also a seed

A glimor is both (a) the stored identity of *a* living agent, and (b) a portable **seed**. Point a router at a glimor and tell it "spawn N": each fork gets its **own new `pvc/` dir** (a copy at fork time) + a yaml, and becomes its own independent glimor. It does not write back to the source.

## Fleet snapshot (disaster recovery)

The per-agent glimor is the granular primitive. **`save all`** = copy every agent's `pvc/` dir off-box (the only time copies are taken) to the mirror. Live payload measured ~6.1 GB across all agents (Hermes engineers 400 MB–1.2 GB each; Letta planners 4–80 MB each).

## What a glimor is NOT

- Not a docker image / `docker commit` snapshot — the Dockerfile builds the shared kind image (`sudo-letta:latest` / `sudo-agent:latest`), which lives in the factory, not in any one glimor.
- Not a linked instance in a "change one → change all" web.
- Not memory-only state that happens to be backed up occasionally.
- Not a k3s-managed `local-path` PVC — the state is a `hostPath` directory we own (see `BUILD-STEPS.md`); a copy is made only for DR/fork.
