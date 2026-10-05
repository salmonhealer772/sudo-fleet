# ONalwase — always-on Letta planner (glimor)

An always-on Letta Code agent for the sudo-fleet, built by mirroring `deployments/Marc`
(the sudo-letta factory pattern) but with the two hard-won Marc fixes baked in.

- kind: `letta`
- source_agent_id: `agent-local-7c00bb99-a606-4cb4-91c6-b3f42112ff82`
- model: `Qwen/Qwen3-Coder-30B-A3B-Instruct` — LOCAL vLLM on the A6000
  (provider `openai-compatible`, base_url `http://127.0.0.1:8000/v1`, key `local-vllm-no-auth`)
- deploy name: `sudo-onalwase` (ns `sudo-fleet`), agent label `onalwase`
- ports (hostNetwork, hashed from the name): MCP **24918**, WATCH **27653**
  (marc uses 26926 / 8886 — no collision)

## Layout

```
name                ONalwase
kind                letta
meta.yaml           kind/source_agent_id/name/model/ports
allowlist.txt       what is (and is not) in the glimor
letta/settings.json resume pointer -> the pinned memfs agent ("default" conversation)
letta/lc-local-backend/agents/<b64url(id)>.json   the agent record
letta/lc-local-backend/memfs/<id>/memory/
    system/persona.md   the self block ("ONalwase — an always-on Letta planner...")
    system/human.md     minimal human block
    .gitkeep
```

## Deploy (recipe)

`up.sh` needs root on fabean (it imports the image into containerd). Root is available
without a sudo password via the docker+nsenter bridge, or just run as `who` with a
readable KUBECONFIG (the image is already in containerd after the first deploy).

```bash
# 1. canonical factory deploy (same primitive bin/k8s-up.sh uses for marc)
KUBECONFIG=/home/who/.kube/config \
bash /home/who/sudo-fleet/factories/sudo-letta/bin/up.sh \
  --onalwase --from-glimor /home/who/sudo-fleet/deployments/ONalwase

# 2. re-apply the glimor's declared context cap (see FIX B below) — idempotent
bash /home/who/sudo-fleet/factories/sudo-letta/bin/fix-model-settings.sh \
  --name onalwase --from-glimor /home/who/sudo-fleet/deployments/ONalwase
```

## The two fixes baked in (the bugs that broke Marc)

**A. TAGS.** The agent record's `tags` MUST be exactly
`["origin:letta-code","git-memory-enabled"]`. Tags such as `personality:tutorial`,
`origin:onboarding`, or `default:tutorial` force a blank "Letta Code" identity and
shadow the persona. (`letta model set` never touches `tags`, so this stays put.)

**B. CONTEXT CAP.** The served model's real ceiling is `max_model_len=65536`, but
`letta model set <handle>` — run by `up.sh` on **every** deploy — applies the CLI's
catalog default **128000** for a BYOK `openai-compatible` model (the catalog has no
entry for it). The server then 400s on long prompts. `up.sh` cannot be told otherwise
(the CLI has no context-window flag), so this glimor declares
`model_settings.context_window_limit=65536` + `max_tokens=4096`, and
`bin/fix-model-settings.sh` re-applies those exact values to the live pod record after
a deploy. The agent record's `model_settings` is the source of truth — verified with
`letta model get`.

## Verify

```bash
POD=$(kubectl -n sudo-fleet get pods -l agent=onalwase -o jsonpath='{.items[0].metadata.name}')
kubectl -n sudo-fleet get pods -l agent=onalwase            # expect 2/2 Running
kubectl -n sudo-fleet exec $POD -c sudo-letta -- env HOME=/home/node \
  letta --backend local model get --agent agent-local-7c00bb99-a606-4cb4-91c6-b3f42112ff82
kubectl -n sudo-fleet exec $POD -c sudo-letta -- env HOME=/home/node \
  letta --backend local -p "What is your name and who/what are you?" --output-format text
```
