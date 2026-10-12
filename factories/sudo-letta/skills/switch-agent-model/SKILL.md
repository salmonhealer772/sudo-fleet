---
name: switch-agent-model
description: Switch the model an agent runs on — for BOTH agent kinds (Hermes engineer and Letta planner). Use when you must change which model/provider a fleet agent uses, check whether a model handle is even available on this backend, or verify (for real) that a switch took effect. Read the whole skill before touching any config: the two kinds store their model in different places, and the #1 silent failure is writing the config but never rolling the pod.
---

# switch-agent-model

Switching the model an agent runs on is two different procedures depending on the agent KIND, and both have silent-failure modes that look like success. This skill covers the Hermes engineer (`sudo-agent`) path and the Letta planner (`sudo-letta`) path, plus the verification that is actually real.

## Step 0 — determine the agent kind BEFORE you change anything

The two kinds store their model in completely different places. Change the wrong store and you have silently changed nothing.

- **Hermes engineer** (`sudo-agent`) → per-agent YAML config on the host, mounted into the pod. Model is `model.default` + `model.provider`. **Requires a pod roll to take effect.**
- **Letta planner** (`sudo-letta`) → per-agent JSON record in the local backend inside the pod. Model is the `model` + `model_settings` fields. **Takes effect on the next turn with NO restart.**

Deploy names disambiguate: `sudo-<name>-h` / `-hermes` / `-hN` are Hermes engineers; `sudo-<name>-l` / `-letta` / `-letta1` are Letta planners. When unsure, `kubectl get deploy` and check the image/labels (Hermes = the `sudo-agent` factory image whose main process is `gateway run`; Letta = the `sudo-letta` image running the letta CLI / MCP server).

Everything below is host-level (kubectl, file edits, rollouts). Reach the host from any pod via the docker + nsenter bridge (see the `cross-host-execution` skill):

    docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c "nsenter -t 1 -m -u -i -n -p -- <cmd>"

with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` exported on the host for kubectl.

## Hermes engineer (sudo-agent) — the model lives in the per-agent config

> **Repo drift note (read first).** The live lima cluster and the current `origin/main` differ on TWO Hermes details: (1) where the provider key lives — the live cluster still uses `model.provider` (nested under `model:`), while `origin/main` moved it to a **top-level `provider`** key; (2) how the config is written — the live cluster has tracked, hand-edited `config/<name>.yaml` files, while `origin/main` made `config/` UNTRACKED and generated it at deploy time from `.env` (`LLM_MODEL` / `LLM_PROVIDER` / `LLM_BASE_URL`) plus the tracked `config.yaml` template. Also the factory scripts moved from `kube-scripts/` to `bin/`. Both forms are covered below — check which one the agent you are touching actually uses before you edit.

**Where it lives:** the host file `/opt/0-0/sudo-fleet/factories/sudo-agent/config/<name>.yaml`, mounted into the pod at `/opt/data/config.yaml` as a hostPath `File` (not a ConfigMap, not the shared `config.yaml`). Do NOT edit the shared `/opt/0-0/sudo-fleet/factories/sudo-agent/config.yaml` — every agent has its own `config/<name>.yaml`.

**The keys that matter:**

```yaml
# live cluster (legacy): provider nested under model:
model:
  default: deepseek-v4-pro     # the model handle
  provider: deepseek           # the provider backend that serves it

# origin/main (current): provider at TOP LEVEL, model.default nested:
provider: deepseek
model:
  default: deepseek-v4-pro
```

- `model.default` — the model handle. Observed forms on this fleet: a bare name (`deepseek-v4-pro`, `deepseek-flash`) or a namespaced handle (`deepseek/deepseek-flash`, `inclusionai/ling-3.0-flash`, `z-ai/glm-5.3`).
- the provider key — `model.provider` (nested) on the live cluster, or top-level `provider` on `origin/main`. It is the Hermes provider backend (`deepseek`, `openrouter`, `anthropic`, `openai`, …) and decides which API key and base URL are used. NOTE: the prefix in `model.default` is NOT the provider — `inclusionai/ling-3.0-flash` is served with `provider: openrouter`. On `origin/main` a custom (non-DeepSeek) endpoint also carries a top-level `base_url` and a `custom_providers:` entry whose key is referenced by env-var name (`key_env:`), never embedded.

**Switch it:**

There are two paths. Both end in a roll.

- **Direct edit (works on both):** edit `config/<name>.yaml` on the host; set `model.default` and the provider key (`model.provider` or top-level `provider`, whichever the file uses) to the new values.
- **Env-driven (the `origin/main` way):** set `LLM_MODEL` (and `LLM_PROVIDER` / `LLM_BASE_URL` when changing endpoint) in `/opt/0-0/sudo-fleet/factories/sudo-agent/.env`, then re-run `bin/up.sh --<name>` — the deploy-time convergence step rewrites `model.default` (and provider/base_url for a custom endpoint) into `config/<name>.yaml` and recreates the pod.

1. Capture the current value first (for revert) — see "Before/after + revert" below.
2. Edit (or re-generate via `.env` + up.sh) the config to the new model/provider.
3. Fix ownership so the pod can read it (the config files are owned by uid 10000 = the hermes user; a root-written file breaks the pod read — see the adversarial checklist).
4. **ROLL THE POD** — this is the load-bearing step, see below (the `.env` + up.sh path recreates the pod as part of its run).
5. Verify (see "Verification that is actually real").

**Read it back:**

```sh
HERMES_HOME=/opt/data hermes config get model
# default: <handle>
# (also prints "provider: <backend>" when provider is NESTED under model: — the live cluster form)

HERMES_HOME=/opt/data hermes status      # shows Model + Provider + which API keys are set — format-agnostic
```

`hermes status` is the most reliable read-back: it prints `Model:` and `Provider:` regardless of whether the provider key is nested (`model.provider`) or top-level (`provider`). `hermes config get model` reads the mounted file, so it shows the NEW value the moment you edit it — BEFORE the roll. That is exactly why it is NOT, by itself, proof the switch took effect (see the roll requirement).

**The roll requirement (the #1 silent failure):**

The gateway process reads `config.yaml` once at startup. Editing the host file changes what a FRESH `hermes config get` sees, but the running gateway keeps the old model in memory until it restarts. A wrote-config-but-never-rolled pod keeps silently running the old model. Roll it:

```sh
kubectl rollout restart deploy/sudo-<name>
```

(or `up.sh --<name>`, which recreates the pod). After the roll, confirm the pod is Ready again (`kubectl get pods`).

**Provider keys — each provider needs its own key:**

`model.provider` determines which API-key env var the gateway must have. Switching provider without that provider's key set means the switch "succeeds" in config but fails on the first real turn. Check which keys are set with `hermes status` (the "API Keys" section). Common ones:

| provider | env var |
|---|---|
| deepseek | `DEEPSEEK_API_KEY` |
| openrouter | `OPENROUTER_API_KEY` |
| anthropic | `ANTHROPIC_API_KEY` |
| openai | `OPENAI_API_KEY` |

Keys are injected as pod env vars. `up.sh` seeds `DEEPSEEK_API_KEY` by default; any other provider key you add to the live deployment by hand (`kubectl set env deploy/sudo-<name> ANTHROPIC_API_KEY=...`) is PRESERVED across `up.sh` re-deploys (the factory carries forward operator-added env), but you must add it yourself before the new provider will work. `hermes status` is the authority on what is actually set.

## Letta planner (sudo-letta) — the model lives in the local backend

**Where it lives:** per-agent JSON in the local backend, inside the pod:

    /home/node/.letta/lc-local-backend/agents/<base64(agent_id)>.json

The filename is the base64 of the agent id (`agent-local-<uuid>`), and the model is the `model` + `model_settings` fields in that JSON. Find the agent id first — do not guess:

```sh
# inside the pod, HOME=/home/node
letta --info                      # "Will resume: <agent-id>"
# or read it from settings:
cat /home/node/.letta/settings.json    # lastAgent / sessionsByServer[].agentId
```

**Switch it:**

```sh
# inside the pod: kubectl exec deploy/sudo-<name> -- bash -c "HOME=/home/node letta model set <handle> --agent <agent-id>"
letta model set <handle> --agent <agent-id>
```

The handle is the catalog id form, e.g. `deepseek/deepseek-flash`, `deepseek/deepseek-v4-pro` (run `letta model list` to see the exact handles this backend serves). Optional: `--reasoning <level>` to set a reasoning level advertised by `model list`; `--conversation <id>` to set one conversation's override instead of the agent default.

> Note: at INITIAL deploy time the factory also wires the model from `.env` (`LLM_MODEL`, via `letta connect` + a model pin in `bin/up.sh`; a custom OpenAI-compatible endpoint is connected as provider `openai-compatible`). That is the deploy-time default. The RUNTIME switch — the one this skill is about — is `letta model set` above, which works regardless of how the agent was first deployed.

**Read it back:**

```sh
letta model get --agent <agent-id>              # that agent's default model
letta model get --conversation <conversation-id> # a specific conversation's override
```

`model get` returns JSON: `model`, `context_window_limit`, and the full `model_settings`. There are three scopes — agent default vs per-conversation override (`--default` forces agent-default scope even when a conversation is current). A persisted conversation override SHADOWS the agent default, and **agent-default changes do NOT remove conversation overrides** (stated in `letta model --help`). So if the agent still answers on the old model after a switch, check for a stale conversation override with `letta model get --conversation <id>`.

**NO restart needed — and why (state this clearly):**

The local backend is FILE-backed with no resident model cache. There is no long-running letta server that loads the agent record once: every turn spawns a fresh `node …/letta-code/letta.js` process (this is how `letta-p.py` and the per-pod MCP server both invoke it — a fresh CLI per prompt), and that fresh process reads the agent JSON off disk. So `letta model set` writes the file, and the very next turn picks it up. Do NOT `kubectl rollout restart` the Letta pod for a model change — it is not needed. The one caveat: the CLI notes it "does not interrupt or restart an in-flight inference", so a turn already running when you set the model finishes on the old model.

**Check availability BEFORE switching (`letta model list`):**

`letta model list` lists what THIS backend can actually serve — its catalog. Run it first and confirm the handle you want is in it:

```sh
letta model list          # full catalog: id, handle, label, context_window_limit, reasoning_levels
letta model list --byok   # only BYOK / user-configured models
letta model list --hosted # only hosted models
```

**"The model exists upstream" is NOT "this backend can serve it":**

The catalog is INLINED in the letta-code CLI bundle (`/usr/local/lib/node_modules/@letta-ai/letta-code/letta.js`), and the model gate rejects any handle not in it — even when the provider's real API serves that model. Concrete case from this fleet:

    $ letta model set anthropic/claude-sonnet-5-5 --agent <id>
    Model is not available on this backend: anthropic/claude-sonnet-5-5

`claude-sonnet-5-5` is a real, released Anthropic model (their API serves it), but the bundled catalog carries `claude-sonnet-5` and `claude-opus-5-5` and NOT `claude-sonnet-5-5` — so the backend refuses it. Two distinct failure modes, both look like "bad model name":

1. Handle absent from the catalog → `Model is not available on this backend: <handle>` (the claude-sonnet-5-5 case). Fails fast, mutates nothing.
2. Handle present in the catalog but no provider auth → a provider/"not configured" error on the turn (the backend also needs the provider's key in `providers/auth.json` — see the ownership gotcha).

Don't confuse "it exists at the provider" with "this backend will serve it" — `letta model list` is the authority on the latter.

## Verification that is actually real

This section is what keeps an engineer from reporting a switch as done when it isn't. There is a verification that DOES NOT EXIST, and you must not invent it.

**What does NOT exist:** a live Hermes prompt returns ONLY the assistant's text answer. There is no `model` field in the prompt-response metadata, and the `/events` trail that `check-agent` reads carries no model field either. So "I saw the model come back in the response" is not a thing — do not claim it, do not document it. (The `sudo-watch-stream` token tap writes a separate `stream.jsonl` served at `/stream` that tags `model`/`response_model` per event, but that is an observer feed populated from plugin hook kwargs — not the prompt reply, not the `/events` trail, and not the authoritative check.)

**Hermes — what "switched" actually means (all three, not any one):**

1. Persisted config shows the new model: `hermes config get model` returns the new `default` + `provider`. (Reads the file — shows the new value immediately, even before the roll.)
2. The pod was rolled AFTER the config write: the rollout happened after the file edit (`kubectl rollout status deploy/sudo-<name>` / restart timestamp). Config edited but pod never rolled = still on the old model.
3. A real LLM turn completes: send a live prompt and confirm the agent answers (not an error, not a fallback). This proves the new provider/key path actually works end-to-end.

`hermes config get model` alone is a trap: it reads the file fresh and shows the new value while the running gateway is still on the old model.

**Letta — resolution is not the same as an exercised turn:**

`letta model get --agent <id>` proves the file now says the new model — that is the RESOLUTION check. It does NOT prove an inference actually ran on it. The real proof is a completed turn: send a prompt (`letta-p.py --<name> "..."` on the host, or a live `letta -p` inside the pod) and confirm the reply comes back. Resolution + one exercised turn together = switched.

## Adversarial checklist — the specific ways this fails silently

Run through this list before you declare a switch done. Several of these bit us in the last 24h.

- **Wrong file / wrong place (tmpfs vs real config).** Hermes: edit the real host file `/opt/0-0/sudo-fleet/factories/sudo-agent/config/<name>.yaml`, not a copy under `/tmp`, not the shared `config.yaml`. (Editing the in-pod `/opt/data/config.yaml` IS editing the host file — it's a hostPath bind — but editing any other path is a no-op.) Letta: edit via `letta model set` (or the agent record JSON in the pod), not a hand-edit of `settings.json`.
- **Wrote config, never rolled (Hermes).** The #1 silent failure. `hermes config get model` shows the new value (fresh file read) while the gateway still runs the old model. Always roll after the write.
- **fallback / moa preset shadowing the primary model (Hermes).** Check `hermes config get fallback` (unset on most pods → "Config key not set") and `hermes config get moa` (a `moa` preset with `enabled: true` + `reference_models` can override the primary `model.default`). If a fallback is set or a preset is active, `model.default` is not what the agent actually runs.
- **Stale conversation-level override (Letta).** `letta model get --conversation <id>` — a persisted override shadows the agent default, and `model set --agent` does NOT clear it.
- **Wrong agent kind.** Hermes model lives in `config/<name>.yaml` on the host; Letta model lives in the agent record JSON in the pod. Check the kind (Step 0) before editing, or you edit the wrong store and change nothing.
- **File ownership (both kinds).** A root-written file the pod user can't read/write fails with EACCES/EPERM even though the value "reads fine today" as root.
  - Hermes config files are owned by uid **10000** (the hermes user), mode 640 — after a root edit, `chown 10000:10000 config/<name>.yaml`.
  - Letta agent records are owned by uid **1000** (node); `/home/node/.letta/lc-local-backend/providers/auth.json` on `sudo-lb-glm-l` is currently ROOT-owned (uid 0, mode 644) — readable but not writable by node, so the next write there fails. `chown 1000:1000` before writing.
- **Provider key not present for the new provider.** Switching `model.provider` to anthropic/openrouter/openai without that provider's `*_API_KEY` env var set → the turn fails. `hermes status` shows which keys are set; add the missing one.

## Before/after capture + revert

Always record the prior value so the switch is reversible.

- **Hermes:** before editing, `hermes config get model` (or `cat config/<name>.yaml`) and save the old `model.default` + `model.provider`. To revert: write the old values back and roll the pod again.
- **Letta:** `letta model get --agent <id>` before switching; save the old `model` + `model_settings`. To revert: `letta model set <old-handle> --agent <id>` (and re-apply any `--reasoning` level). If you changed a conversation override, revert with `--conversation <id>`.

(The sudo-agent factory already keeps timestamped rollback copies of prior configs under `config/rollback-<ts>-<tag>/` when switches are done in bulk — follow that convention if you are switching several agents.)

## Gotchas

- `letta --info` may print "Pinned agents: (none)" and "Will resume: <id> (not found)" when the pod is missing `LETTA_LOCAL_BACKEND_EXPERIMENTAL=1` — that is a session-resume/pinning issue, not the model. `letta model get/set --agent <id>` with an explicit id works regardless.
- `letta model set` runs its availability gate up front: an out-of-catalog handle fails fast with "Model is not available on this backend" and mutates nothing — safe to try a candidate handle.
