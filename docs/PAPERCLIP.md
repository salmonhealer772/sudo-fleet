# Paperclip in sudo-fleet (auto-hire)

Paperclip is the control plane that assigns issues and fires heartbeats.
sudo-fleet ships with it, and **every agent sudo-fleet stands up is hired
automatically** — Marc, Caesar, ONalwase, and any new agent you build. There is
no manual wiring step.

Verified end to end on a fresh box (Ubuntu 24.04, 2 vCPU, 4 GB, hostname
`paperclip-test`, 2026-10-07): `setup.sh` → `bin/k8s-up.sh` → Marc + Caesar
hired with heartbeats → a brand-new `up.sh --smoketest` agent hired the moment
it was built → an issue assigned to that new agent was received and completed
(agent-authored comment, `status: done`).

## The three commands

```bash
bash setup.sh                 # bootstrap: docker + k3s + both factory images
cd bin && bash k8s-up.sh      # fleet up: Marc + Caesar, THEN Paperclip, THEN auto-hire
```

That is it. `k8s-up.sh` finishes by deploying Paperclip and hiring everything
that exists; every later `up.sh --<agent>` hires the agent it just built; and
`bin/k8s-auto-up.sh` re-runs the reconcile on every boot.

Want the control plane only, or to re-run it by hand:

```bash
bash bin/paperclip-up.sh      # deploy/re-apply Paperclip (idempotent)
bash bin/paperclip-adopt.sh   # hire every agent deployment in the cluster
bash bin/paperclip-hire.sh --name Marc --deploy sudo-marc   # hire one
```

## What "hired" means (all three halves)

1. **An agent record in Paperclip**, using the external `letta_local` adapter
   pointed at the LIVE pod's MCP door
   (`http://sudo-<agent>-mcp.<ns>.svc.cluster.local:8000/mcp`). A heartbeat
   therefore runs the prompt *inside* the running agent — never a detached
   clone. The same adapter drives a Hermes agent; only `mcpTool` changes
   (`letta_prompt` → `hermes_prompt`).
2. **`runtimeConfig.heartbeat` enabled** (`intervalSec`, default 120s), which is
   how Paperclip re-wakes the agent on a schedule.
3. **Callback credentials in the agent's own Deployment** —
   `PAPERCLIP_API_URL`, `PAPERCLIP_API_KEY`, `PAPERCLIP_AGENT_ID`,
   `PAPERCLIP_COMPANY_ID` — so the live agent can checkout, comment and close
   the issue it was woken for. The adapter also appends a "Paperclip control
   plane" block to every heartbeat prompt containing the exact `PATCH
   /api/issues/<id>` call to close the task.

## Layout

| Path | What it is |
|---|---|
| `bin/paperclip-up.sh` | deploy Paperclip (ns `paperclip` + Postgres), register the adapter, bootstrap the instance |
| `bin/paperclip-hire.sh` | hire ONE agent (record + heartbeat + pod env), idempotent |
| `bin/paperclip-adopt.sh` | reconcile: hire every `sudo-*` agent deployment |
| `factories/paperclip-letta-adapter/` | the external adapter (`dist/` is committed prebuilt — no npm on the target box) |
| `/logs/paperclip/` | credentials (`paperclip.env`, `admin.pw`, 0600) + `hired.jsonl` ledger |

## Bootstrap mechanics (why it works unattended)

Paperclip runs `PAPERCLIP_DEPLOYMENT_MODE=authenticated` +
`PAPERCLIP_DEPLOYMENT_EXPOSURE=private` (a loopback-bound `local_trusted`
instance is impossible in k8s: kubelet probes need a routable bind). The first
admin is created non-interactively:

1. `POST /api/auth/sign-up/email` → Better Auth session cookie
2. `POST /api/bootstrap/claim` → first instance admin
3. `POST /api/board-api-keys` → long-lived board key (stored 0600)
4. `GET/POST /api/companies` → the `sudo-fleet` company

Every control-plane call is made with `kubectl exec` into the Paperclip pod, so
`Host` is `127.0.0.1` and the private-hostname guard never 403s. The adapter is
registered through the file-based plugin store
(`$PAPERCLIP_HOME/adapter-plugins.json`) because `POST /api/adapters/install`
needs instance-admin auth that does not exist yet at that point.

## Pitfalls this integration had to solve (all fixed in-repo)

- **`letta model set` qualifies its argument itself.** Passing the
  provider-qualified handle produced `deepseek/deepseek/deepseek-v4-pro` and
  every prompt died with *Unknown model … for provider "deepseek"*. up.sh now
  passes the BARE id first and normalizes `prov/prov/id` → `prov/id` in the
  agent record.
- **letta's built-in `deepseek` catalog is stale.** Its upstream name for
  `deepseek-v4-pro` is the old `deepseek-ai/DeepSeek-V4-Pro`, which
  api.deepseek.com now 400s. up.sh connects a `deepseek` provider with a
  configured `LLM_BASE_URL` as `openai-compatible`, which passes the model id
  through verbatim (verified: `openai-compatible/deepseek-v4-pro` → completes).
  Override with `LLM_CONNECT_PROVIDER`.
- **The adapter must not send `new_chat` unconditionally.** `hermes_prompt` has
  no such parameter and rejects the whole call with
  `unexpected_keyword_argument`; the key is now sent only when a new chat is
  actually requested (omitting it is the Letta default anyway).
- **The `sudo-agent` manifest heredoc guard was stale**, blocking the Caesar
  deploy entirely (an unescaped backtick in a YAML comment + a
  command-substitution budget that did not count the two `base64` Secret
  encoders).
- **Per-agent ports must avoid the NodePort range.** Every agent pod is
  `hostNetwork: true` and listens on a port derived from its name. The window
  used to be `8000 + hash % 24768` = 8000..32767, which overlaps the Kubernetes
  NodePort range 30000–32767 — and a hostNetwork listener inside that range is
  **unreachable from other pods** (kube-proxy intercepts the packet, finds no
  such NodePort, and drops it: the client just times out). An agent named
  `reprobe` hashed to 30765 and failed every heartbeat with `fetch failed`
  while agents on 26926 / 22700 / 20247 worked. The window is now
  `8000 + hash % 22000` = 8000..29999.

## Residual / not done

- `bin/k8s-down.sh` does not yet tear Paperclip down as a unit.
- One of three issue runs on the seeded **planner** persona (Marc) stayed
  `in_progress` — the agent answered without closing the task. Wiring was
  fine (a run was delivered and succeeded); the manager/objective contract for
  planner-style agents still needs work. Fresh agents close reliably.
- Single-node demo defaults: Paperclip is reachable on the cluster NodePort
  (`:31310`) with no TLS and no edge gate.
