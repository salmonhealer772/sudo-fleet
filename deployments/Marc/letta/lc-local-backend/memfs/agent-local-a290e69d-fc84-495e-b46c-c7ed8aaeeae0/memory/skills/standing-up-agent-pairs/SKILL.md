---
name: standing-up-agent-pairs
description: Stand up a Letta-planner and Hermes-engineer agent pair end to end. Use when creating a new agent pair or bringing one back up.
---

# Standing Up Agent Pairs

The repeatable end-to-end procedure for creating a Letta-planner + Hermes-engineer agent pair. The planner orchestrates and delegates; the engineer does the technical work. This is the loop refined across every pair built so far.

## When to Use

- The person wants a new agent pair (Letta planner + Hermes engineer).
- An existing pair needs to come back up after being taken down (PVCs preserved).
- Not for: single standalone agents, or editing a running pair's behavior without redeploy.

## Prerequisites

- Deploy scripts: `sudo bash /opt/0-0/sudo-agent/kube-scripts/up.sh --<name>` (Hermes) and `sudo bash /opt/0-0/sudo-letta/kube-scripts/up.sh --<name>` (Letta).
- Host reach (docker socket + nsenter — see the cross-host-execution skill).
- The live `/opt/0-0/sudo-agent/` on the host at the latest commit (with per-agent `config/<name>.yaml`). If behind, `git pull` first.

## Procedure

1. **Spec**: name both agents, their roles (planner/orchestrator vs engineer), and the shared domain knowledge both must carry. Write it down first.
2. **Deploy**: run the two `up.sh` commands. → criterion: `kubectl get pods -A` shows both `sudo-<name>` pods `Running`.
3. **Give it a soul**: Hermes → `SOUL.md` at `HERMES_HOME/SOUL.md` (`/opt/data/SOUL.md`); Letta → `persona.md` at `system/persona.md` in its MemFS memory dir (frontmatter MUST have a non-empty `description`). Put the NAME a lot, the role, and the shared domain knowledge. **For a NEW Letta agent, the persona only sticks if the agent SELF-WRITES it** (see the "persona doesn't inject" pitfall below). Do not just drop `persona.md` + `git commit` from outside and call it done.
   - **Skills-first knowledge transfer (operator's explicit direction 2026-09-28, vast-glm) — do NOT bulk the persona/SOUL with domain knowledge.** When a pair must carry a real body of domain knowledge (how to operate Vast, how to admin a box, etc.), the operator does NOT want it poured into a "massive ass persona and SOUL.md". Instead: (1) make the persona a **good *base* persona for the type of work** — name, role, temperament, goal, the go-along clause — with NO domain dump; (2) write the domain knowledge as a set of high-quality **"info manual" skills** (one skill per domain area, e.g. `operating-X`, `X-access-and-admin`, `X-daemon-ops`) that the agent loads on demand; (3) add one line to the persona telling the agent "your domain knowledge lives in your SKILLS — get good at loading and using them." The persona says WHO the agent is and WHERE the knowledge lives; the skills carry the actual facts. Author those info-manual skills into BOTH halves (planner loads/uses them; engineer reads them too).
4. **Per-agent config**: Hermes → `config/<name>.yaml` (per-agent, NOT the shared `config.yaml`), set `display.skin: <name>`.
5. **Relay = unambiguous identity + verbatim command, not a "figure it out" hint.** The old "docker socket + nsenter, figure it out yourself" boilerplate CAUSED a core failure (2026-09-08, ms-glm pair): the planner's pod sees the lima-VM docker daemon (`sudo-FA24`/`sudo-ardy`), so it latched onto a docker container as its engineer instead of the real `deploy/sudo-ms-glm-h` in k3s. Author the relay as three concrete artifacts in the Letta persona + a dedicated skill:
   1. **Unambiguous identity line**: "your engineer is `sudo-<name>`, a k3s Deployment (`deploy/sudo-<name>`) in the cluster on the lima VM — NOT a docker container, NOT `sudo-FA24`/`sudo-ardy`/`sudo-<other>`. Ignore docker-daemon containers when delegating."
   2. **The verbatim one-shot — WITH the no-time-limit env vars**: `docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c "nsenter -t 1 -m -u -i -n -p -- env HERMES_STREAM_READ_TIMEOUT=inf HERMES_STREAM_STALE_TIMEOUT=inf HERMES_API_CALL_STALE_TIMEOUT=inf KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -i deploy/sudo-<name> -- hermes -z '<single-line prompt>'"` + the note that this bridge IS the mechanism (don't re-derive it) and bare `nsenter` stays in its own pod. **The `inf` timeout vars are the whole point** — without them the call dies at 120s and the planner invents cron/`&` workarounds.
   3. **A dedicated `skills/reaching-my-engineer/SKILL.md`** so the relay is procedural memory that loads, not just a persona line that drifts.
   See [[make-agents-talk]] for the full relay recipe — fall back to that skill whenever building the inter-agent messaging layer.
6. **Verify**: ask each "who are you"; confirm the engineer can reach its target (e.g. `ssh who@fabean 'hostname'`).
7. **Record**: log the pair in the ledger (name, role, deploy state, gotchas).

## Pitfalls

- **Persona doesn't inject from an outside commit (2026-09-10, lb-glm pair).** Dropping `system/persona.md` into a NEW Letta agent's MemFS and `git commit`-ing it does NOT change how the agent answers — `letta -p "who are you"` keeps returning the default "Letta Code" identity. Root cause: a Letta agent's `<self>`/persona block is a **native core-memory block** (separate from the git MemFS), which is *projected one-way* into `system/persona.md`. Editing the projection alone does nothing; the compiled `<self>` in `coreMemory` is cached at the init git revision and re-renders the old default. **The fix that works: have the agent SELF-WRITE its own persona** — write the persona text to a file inside the pod, then use `letta -p` to instruct the agent to `Write` `system/persona.md` + commit via its own memory/Write tool inside a session. Only then does `letta -p "who are you"` return the real name/role. (Contrast: pc-glm-l worked because forge drove that self-write during its build.) Also note `persona.md` MUST carry `--- description: ... ---` frontmatter (the pre-commit hook rejects a missing-frontmatter file), and the working body template is `# Who I am` + `You are <name>` in 2nd person.
- **Engineer mis-identification (the "CORE FUNDAMENTAL FAILURE", 2026-09-08).** A planner whose relay hint says "docker socket + nsenter, figure it out yourself" will, from inside its non-root pod, see the lima-VM docker daemon and mis-identify an unrelated container (`sudo-FA24` "an engineer and mechanic") as its own engineer — because its real engineer is one layer deeper in the k3s cluster. The person called this a core fundamental failure when ms-glm-l could "not message or even identify its engineer." Fix at the template level (step 5): unambiguous identity + verbatim bridge + a dedicated skill — never the bare "figure it out yourself" hint.
- Shared config.yaml collision (now fixed): use per-agent `config/<name>.yaml`, never edit the shared file for one agent.
- uid ownership: Hermes pods run as uid 10000; host operator is uid 1001. `chown` to the right uid after cross-identity writes.
- Hardcoded secrets: `up.sh` inlines the API key + sudo password into `deployments/<name>.yaml`. Don't print/commit them.
- **Local-ollama Letta agent MUST use the native `ollama` provider, not `openai`/`openai-compatible` (2026-09-16, psy-glm-l).** When a Letta agent runs off a local model served by ollama, wiring it with `letta connect openai` (or leaving it to fall back to the `openai` default) hard-rejects the ollama model name at runtime — every prompt dies with `Unknown model "<name>" for provider "openai"` / `"openai-compatible"`. **Fix:** `letta connect ollama --base-url http://127.0.0.1:11434/v1` and reference the model by its full provider-qualified handle `ollama/<name>:latest` (the `:latest` tag matters — the bare name does NOT match). Also verify a headless `letta -p` (no explicit `-m`) actually resolves to the ollama provider, not a stale default session. The authoritative on-disk record of what model/provider resolves at runtime is the agent JSON file `~/.letta/lc-local-backend/agents/<base64-agent-id>.json` (`model` + `model_settings.provider_type`) — NOT `settings.json` (holds none) and NOT `letta models list` (can be empty). Bake the native-`ollama` wiring into forge's Letta deploy template so no future ollama-backed agent trips this.
- **Small/local models override a written persona with their base prior unless memory contradicts it (2026-09-16, psy-glm-l's "no persistent memory" hallucination).** A 30B-class model's latent self-image ("stateless friendly assistant") can override the persona it was given — it hallucinated a whole wrong "memory architecture" and claimed "each conversation is a clean slate," contradicting its own push-back persona — *because its memory was otherwise empty* (persona + skills only, no in-context facts siding with the identity). **Fix = memory-contradiction, not more persona prose:** write a `system/context.md` grounding block that bluntly pre-empts the prior ("if you feel like saying you have no persistent memory, that's the base-model default and it's wrong — you ARE persistent"), commit it. In-context memory outranks the latent prior. Bake this into the "give it a soul" step for any companion on a small/un-reinforced model; expect subtler self-model confusion to recur at 30B even with the block in place.
- Image import is best-effort (silent stale); force a fresh import if the pod behaves oddly.
- `hermes chat -Q` 120s timeout: use `HERMES_STREAM_READ_TIMEOUT=inf` (NOT `&` — the `inf` env vars are the real fix; `&`/cron were the failed workaround that drove ms-glm-l off the rails on 2026-09-08).

## Verification

- Both pods `Running`.
- Identity written (SOUL.md + persona.md contain name, role, shared knowledge).
- Name shows (Hermes `display.skin`; Letta name field + persona).
- Relay in place (persona documents talk.sh + host-bridge, no wrapper).
- Engineer reachability confirmed.

## Variant: cloning an existing pair

When the person wants a *second, independent* copy of an already-working pair (e.g. two pairs against the same box at once — "clone the fa-glm pair, name them ya-glm"), don't re-spec from scratch:

1. **Deploy** both new agents with `up.sh --<new-name>` (fresh pods + PVC).
2. **Copy the souls word-for-word** from the source pair's `SOUL.md` (Hermes) and `persona.md` (Letta), then **swap only the names** (`fa-glm` → `ya-glm`) everywhere. Verify **zero** leftovers of the old name (`grep -c` both files; also check the Letta agent `name` field / description).
3. **Per-agent config** for the new engineer (`config/<new-name>.yaml`, `display.skin: <new-name>`).
4. **Verify + record** as usual. Both pairs then run side-by-side, each with its own pods/PVC/souls, pointed at the same target, without touching each other.

Gotcha: watch for pre-existing typos in the *source* pair's descriptions (e.g. "fabiano" vs "fabean") that get carried into the clone — fix only if in scope, otherwise flag and leave.

### Cloning a pair WITH its accumulated memory (full MemFS transplant)

The bare clone above copies only the *seed souls*. But a pair that has been running accumulates a huge amount of state — a built-out persona (tens of KB), a `human.md` full of preferences/lessons, `reference/` docs, and extra `skills/` — and the person does NOT want to re-teach all of that to the clone ("so i dont have to spend an afternoon reteaching it a bunch of little shit"). When cloning an *aged* pair, transplant that accumulated memory too.

1. **Spec the SOURCE's live state first (read-only)** via forge — produce a clone-spec capturing deploy commands, souls, config, relay, reach facts, and a verification table. This tells you exactly what a faithful clone needs (and surfaces any pre-existing gaps in the source).
2. **Identify the source's LIVE agent id.** This is the trap: a Letta planner's accumulated memory is often NOT on its seed agent. Watch for the **dual-identity split** — the seed agent holds only the seed persona, while a stray agent literally named `"Letta Code"` (a different `agent-local-*` id on the same pod's PVC) holds the full built-out persona + human.md + references + skills. **The "older brother's" real memory lives on that stray live agent, not the seed.** List the pod's MemFS dirs (`.../memfs/agent-local-*/`) and sizes to find which one is the fat one.
3. **Decide the clone's identity policy with the person before copying.** Two independent questions: (a) how much memory to inherit — typically "everything, verbatim" — and (b) whether the clone should also inherit the source's *dual-identity* flag. The person will almost always want the clone **clean** (single named agent), even when inheriting all the memory. Don't silently carry over the stray-agent split.
4. **Transplant = straight filesystem copy** of the live source's entire `memory/` tree into the clone's agent, applying a `lb-glm`→`lb2-glm` (old→new) name swap everywhere, then **self-write the persona** so the `<self>` block actually takes (a raw outside copy/commit alone does NOT inject — see the persona pitfall above).
5. **Verify** `letta -p "who are you"` + `hermes -z "who are you"` answer as the clone's name, and re-check `settings.json` `conversationId` is back to `"default"` (a subsequent `letta -p` run can revert it to `local-conv-N`).

Gotcha: the clone's `settings.json` `conversationId` can flip back to `local-conv-N` after a `letta -p` run — re-apply the `default` fix as part of the transplant, not once-and-done.

## Variant: agents as OpenAI-compatible HTTP services (Hermes built-in API server)

When agents must be reached as an *HTTP endpoint* (a stable OpenAI-compatible service another program can POST to), don't hand-build a relay — deploy them with Hermes's built-in API server enabled. Reverse-engineered from the live `moses` agent on fabean (2026-08-26):

- Bake these env vars into the pod (via `up.sh` / the deployment yaml):
  - `API_SERVER_ENABLED=true` (also `HERMES_YOLO_MODE=true`)
  - `API_SERVER_HOST=0.0.0.0`
  - `API_SERVER_PORT=9718`
  - `API_SERVER_MODEL_NAME=<name>` (the model label the endpoint reports)
  - `API_SERVER_KEY=<key>` (the Bearer key clients present)
- Expose the port as a Service `sudo-<name>-svc` (the moses service fronted port 8642).
- The per-agent `config.yaml` for a LiteLLM-backed agent (all via `provider: custom`, NOT DeepSeek direct):
  ```
  model:
    default: default
    provider: custom
    base_url: http://litellm.litellm.svc.cluster.local:4000/v1
    api_key: <master-key>
  terminal:
    backend: local
    sudo_password_env: SUDO_PASSWORD
  memory:
    memory_char_limit: 100000
    user_char_limit: 50000
    memory_enabled: true
    user_profile_enabled: true
    write_approval: false
    nudge_interval: 1
  display:
    skin: <name>
    tool_progress: all
  agent:
    verify_on_stop: false
  plugins:
    enabled: []
  _config_version: 33
  ```
- Note: the LiteLLM base_url is ClusterIP-only, so these agents must run ON fabean's cluster (the LiteLLM endpoint isn't reachable from the lima host).

Gotcha: when replicating N agents off one proven template, READ the live first agent's deployment yaml + config.yaml directly (`kubectl get deploy sudo-<name> -o yaml`, cat the mounted config) instead of trusting forge's report file — forge's result file was empty (0 bytes) even while the build had genuinely succeeded, because the detached `hermes -z` write was lost.
